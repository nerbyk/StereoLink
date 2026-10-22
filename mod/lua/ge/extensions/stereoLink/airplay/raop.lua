-- AirPlay 1 (RAOP) receiver: RTSP control connections plus RTP audio over UDP.
--
-- Crypto (the Apple-Challenge signature, the session AES key) and decoding run in the UI,
-- so OPTIONS and ANNOUNCE are answered only once the UI replies (see M.uiReply).
-- Everything that arrives here comes from the local network and is treated as untrusted:
-- only the phone that sent the last ANNOUNCE may set up a session, and only the session's
-- phone controls it.

local M = {}

local socket = require('socket')
local mime = require('mime')
local rtsp = require('stereoLink/airplay/rtsp')
local rtp = require('stereoLink/airplay/rtp')
local ownership = require('stereoLink/airplay/ownership')
local throttle = require('stereoLink/airplay/throttle')
local net = require('stereoLink/net')

local PORT_ATTEMPTS = 10    -- base, base+10, base+20..., the last one any free port
local PORT_STEP = 10
local MAX_CLIENTS = 8
local MAX_ACCEPTS_PER_FRAME = 4
local REQUESTS_PER_FRAME = 16
local READ_BYTES = 65536
local IDLE_TIMEOUT = 30     -- iOS sends OPTIONS every couple of seconds while connected
local UI_TIMEOUT = 5
-- The UI may not have seen the request yet after a long frame or while the window is
-- minimised, so the timeout also waits this many frames after the request was sent.
local UI_TIMEOUT_FRAMES = 60
local MAX_PENDING = 4       -- each challenge is an RSA signature in the UI thread
local MAX_CHALLENGE_CHARS = 48 -- base64 of 32 bytes; iOS sends 16
local MAX_AUDIO_PER_FRAME = 400
local MAX_RESENDS_PER_FRAME = 100
local MAX_TIMING_PER_FRAME = 20
local REASONS = {
  [400] = 'Bad Request',
  [415] = 'Unsupported Media Type',
  [455] = 'Method Not Valid in This State',
  [503] = 'Service Unavailable',
}
local PUBLIC_METHODS = 'ANNOUNCE, SETUP, RECORD, PAUSE, FLUSH, TEARDOWN, OPTIONS, GET_PARAMETER, SET_PARAMETER, POST, GET'

local listener
local port
local macBytes
local events
local clients = {}
local udp = {}
local session
local announcer -- the client whose stream the UI has; only it may SETUP
local pending = {}
local nextRequestId = 0
local frame = 0
local mayWarn = throttle.perPeer()
local stats = { forwarded = 0, flushed = 0 } -- audio packets sent to the UI / dropped by FLUSH

local function byteArray(s)
  local out = {}
  for i = 1, #s do out[i] = s:byte(i) end
  return out
end

-- A misbehaving device cannot flood the log: see throttle.perPeer.
local function warn(level, ip, message)
  if not mayWarn(ip, socket.gettime()) then return end
  log(level, 'stereoLink.airplay', tostring(ip) .. ': ' .. message)
end

local function reply(client, request, code, reason, headers, body)
  client.sock:send(rtsp.formatResponse(request.headers['cseq'], code, reason, headers, body))
end

local function sessionOwner() return session and session.client end
local function ownsSession(client) return session ~= nil and session.client == client end

local function uiBusy()
  local count = 0
  for _ in pairs(pending) do count = count + 1 end
  return count >= MAX_PENDING
end

-- Sends work to the UI and answers the request when the UI calls back (or after a timeout).
local function askUi(message, onAnswer)
  nextRequestId = nextRequestId + 1
  message.id = nextRequestId
  pending[nextRequestId] = {
    onAnswer = onAnswer,
    deadline = socket.gettime() + UI_TIMEOUT,
    sentFrame = frame,
    kind = message.type,
  }
  events.toUi(message)
end

---------------------------------------------------------------------------
-- session

local function closeUdp()
  for _, s in pairs(udp) do s:close() end
  udp = {}
end

local function openUdp()
  closeUdp()
  for offset, name in ipairs({ 'audio', 'control', 'timing' }) do
    local s = socket.udp()
    if not s:setsockname('*', port + offset) then s:setsockname('*', 0) end
    s:settimeout(0)
    udp[name] = s
  end
  local _, audioPort = udp.audio:getsockname()
  local _, controlPort = udp.control:getsockname()
  local _, timingPort = udp.timing:getsockname()
  return audioPort, controlPort, timingPort
end

local function endSession(reason)
  if not session then return end
  closeUdp()
  session = nil
  events.toUi({ type = 'teardown' })
  events.onSession(nil, reason)
end

-- Disconnects the phone that had the session or the stream (ownership verdict 'takeover').
local function takeOver()
  local owner = sessionOwner() or announcer
  owner.closed = true
  endSession('replaced')
end

local function drain(sock, limit)
  for _ = 1, limit do
    if not sock:receive() then return end
  end
end

---------------------------------------------------------------------------
-- RTSP methods

local handlers = {}

handlers.OPTIONS = function(client, request)
  local headers = { { 'Public', PUBLIC_METHODS } }
  local challenge = request.headers['apple-challenge']
  -- iOS signs in once per connection; more would only keep the UI busy with RSA
  if not challenge or client.challenged then return reply(client, request, 200, 'OK', headers) end
  if #challenge > MAX_CHALLENGE_CHARS then return reply(client, request, 400, 'Bad Request') end
  if uiBusy() then return reply(client, request, 503, 'Service Unavailable') end
  client.challenged = true
  -- the signature covers the address the phone connected to, so take it from this socket
  local localIp = client.sock:getsockname()
  askUi({ type = 'challenge', challenge = challenge, ip = net.ipv4Octets(localIp) or { 0, 0, 0, 0 }, mac = byteArray(macBytes) }, function(signature)
    if signature and signature ~= '' then table.insert(headers, { 'Apple-Response', signature }) end
    reply(client, request, 200, 'OK', headers)
  end)
end

handlers.ANNOUNCE = function(client, request)
  local sdp = rtsp.parseSdp(request.body)
  local verdict, why = ownership.announce(sdp, client, announcer, sessionOwner(), uiBusy())
  if type(verdict) == 'number' then
    if why then warn('W', client.peerIp, why) end
    return reply(client, request, verdict, REASONS[verdict] or 'Error')
  end
  if verdict == 'takeover' then takeOver() end
  announcer = client
  local stream = { type = 'stream', codec = 'alac', fmtp = sdp.fmtp:gsub('^%s+', ''), aesKey = sdp.rsaaeskey, aesIv = sdp.aesiv }
  askUi(stream, function(result)
    if result == 'ok' then return reply(client, request, 200, 'OK') end
    announcer = ownership.release(announcer, client)
    warn('E', client.peerIp, 'UI could not start the stream: ' .. tostring(result))
    reply(client, request, 500, 'Internal Server Error')
  end)
end

handlers.SETUP = function(client, request)
  local verdict = ownership.decide('SETUP', client, announcer, sessionOwner())
  if type(verdict) == 'number' then
    warn('W', client.peerIp, 'SETUP without ANNOUNCE')
    return reply(client, request, verdict, REASONS[verdict] or 'Error')
  end
  local transport = rtsp.parseTransport(request.headers['transport'])
  local audioPort, controlPort, timingPort = openUdp()
  session = {
    client = client,
    peerIp = client.peerIp,
    controlPort = transport.controlPort,
    dacpId = request.headers['dacp-id'],
    activeRemote = request.headers['active-remote'],
    lastSeq = nil,
    resendSeq = 0,
    flush = nil, -- rtp.flushFilter after a FLUSH; see rtp.isFlushed for what it drops
  }
  events.onSession(session)
  local transportReply = string.format(
    'RTP/AVP/UDP;unicast;interleaved=0-1;mode=record;control_port=%d;timing_port=%d;server_port=%d',
    controlPort, timingPort, audioPort)
  reply(client, request, 200, 'OK', {
    { 'Transport', transportReply },
    { 'Session', '1' },
    { 'Audio-Jack-Status', 'connected; type=analog' },
  })
end

handlers.RECORD = function(client, request)
  reply(client, request, 200, 'OK', { { 'Audio-Latency', '11025' } })
end

handlers.FLUSH = function(client, request)
  if ownsSession(client) then
    -- whatever is still queued on the sockets belongs to the position before the seek
    drain(udp.audio, MAX_AUDIO_PER_FRAME)
    drain(udp.control, MAX_RESENDS_PER_FRAME)
    local seq = rtsp.parseRtpInfo(request.headers['rtp-info'])
    session.flush = rtp.flushFilter(seq, socket.gettime())
    session.lastSeq = nil
    events.toUi({ type = 'flush' })
  end
  reply(client, request, 200, 'OK')
end

handlers.TEARDOWN = function(client, request)
  reply(client, request, 200, 'OK')
  if ownsSession(client) then endSession('teardown') end
end

handlers.GET_PARAMETER = function(client, request)
  if request.body:find('volume', 1, true) then
    local body = string.format('volume: %.6f\r\n', events.getVolumeDb())
    return reply(client, request, 200, 'OK', { { 'Content-Type', 'text/parameters' } }, body)
  end
  reply(client, request, 200, 'OK')
end

local function coverDataUri(contentType, body)
  local imageType = rtsp.coverType(contentType)
  if not imageType or #body == 0 then return nil end
  return 'data:' .. imageType .. ';base64,' .. mime.b64(body)
end

handlers.SET_PARAMETER = function(client, request)
  reply(client, request, 200, 'OK')
  if not ownsSession(client) then return end
  local contentType = (request.headers['content-type'] or ''):lower()
  if contentType:find('text/parameters', 1, true) then
    local params = rtsp.parseParameters(request.body)
    if params.volume then events.onVolume(params.volume) end
    if params.progress then events.onProgress(params.progress) end
  elseif contentType:find('dmap', 1, true) then
    events.onTrack(rtsp.trackInfo(request.body))
  elseif contentType:find('image/', 1, true) then
    events.onCover(coverDataUri(contentType, request.body))
  end
end

handlers.POST = function(client, request) reply(client, request, 200, 'OK') end
handlers.GET = handlers.POST

local function handle(client, request)
  local handler = handlers[request.method]
  if not handler then return reply(client, request, 501, 'Not Implemented') end
  local ok, err = pcall(handler, client, request)
  if not ok then
    warn('E', client.peerIp, request.method .. ' failed: ' .. tostring(err))
    pcall(reply, client, request, 500, 'Internal Server Error')
  end
end

---------------------------------------------------------------------------
-- audio

-- Returns the next datagram (nil when there is none) and whether the session's phone sent it.
local function receive(sock)
  local packet, ip = sock:receivefrom()
  return packet, packet ~= nil and ip == session.peerIp
end

local function dropFlushed(packet, now)
  if not rtp.isFlushed(session.flush, rtp.sequence(packet), now) then return false end
  stats.flushed = stats.flushed + 1
  return true
end

local function audioItem(packet)
  return { rtp.sequence(packet), (mime.b64(rtp.payload(packet))) }
end

local function requestMissing(seq)
  local last, first, missing = rtp.track(session.lastSeq, seq)
  session.lastSeq = last
  if not (missing and session.controlPort) then return end
  session.resendSeq = (session.resendSeq + 1) % 65536
  udp.control:sendto(rtp.resendRequest(session.resendSeq, first, missing), session.peerIp, session.controlPort)
end

local function readAudio(out, now)
  for _ = 1, MAX_AUDIO_PER_FRAME do
    local packet, fromPhone = receive(udp.audio)
    if not packet then return end
    if fromPhone and rtp.isAudio(packet) and not dropFlushed(packet, now) then
      requestMissing(rtp.sequence(packet))
      table.insert(out, audioItem(packet))
    end
  end
end

local function readResends(out, now)
  for _ = 1, MAX_RESENDS_PER_FRAME do
    local packet, fromPhone = receive(udp.control)
    if not packet then return end
    local inner = fromPhone and rtp.unwrapResend(packet)
    if inner and not dropFlushed(inner, now) then table.insert(out, audioItem(inner)) end
  end
end

local function pumpAudio(now)
  if not session or not udp.audio then return end
  local out = {}
  readAudio(out, now)
  readResends(out, now)
  -- playback follows the packets as they come, the clock sync on this port is not used
  drain(udp.timing, MAX_TIMING_PER_FRAME)
  if #out == 0 then return end
  stats.forwarded = stats.forwarded + #out
  session.client.lastSeen = now
  events.toUi({ type = 'audio', packets = out })
end

---------------------------------------------------------------------------
-- connections

-- No SO_REUSEADDR here: on Windows it would let us bind a port another program is using.
local function bindListener(basePort)
  for attempt = 1, PORT_ATTEMPTS do
    -- the last try takes any free port: Hyper-V and WSL can reserve the whole range
    local candidate = attempt < PORT_ATTEMPTS and basePort + (attempt - 1) * PORT_STEP or 0
    local tcp = socket.tcp()
    if tcp:bind('*', candidate) then
      tcp:listen(MAX_CLIENTS)
      tcp:settimeout(0)
      local _, boundPort = tcp:getsockname()
      return tcp, tonumber(boundPort)
    end
    tcp:close()
  end
  return nil
end

local function acceptClients(now)
  for _ = 1, MAX_ACCEPTS_PER_FRAME do
    local sock = listener:accept()
    if not sock then break end
    if #clients >= MAX_CLIENTS then
      sock:close()
    else
      sock:settimeout(0)
      sock:setoption('tcp-nodelay', true)
      table.insert(clients, { sock = sock, buffer = '', peerIp = sock:getpeername(), lastSeen = now })
    end
  end
end

local function dropClient(index, reason)
  local client = table.remove(clients, index)
  client.sock:close()
  announcer = ownership.release(announcer, client)
  if ownsSession(client) then endSession(reason) end
end

-- Handles the complete requests in the client's buffer. Returns a reason to drop the client.
local function handleRequests(client, now)
  for _ = 1, REQUESTS_PER_FRAME do
    local request, rest, parseError = rtsp.parseRequest(client.buffer)
    if parseError then
      warn('W', client.peerIp, 'dropping the connection: ' .. parseError)
      return 'bad request'
    end
    client.buffer = rest
    if not request then return nil end
    client.lastSeen = now
    handle(client, request)
    if client.closed then return 'replaced' end
  end
  return nil
end

local function readClient(client, now)
  local data, err, partial = client.sock:receive(READ_BYTES)
  local chunk = data or partial
  if chunk and #chunk > 0 then client.buffer = client.buffer .. chunk end
  -- a TEARDOWN may arrive together with the close, so the buffer is handled first
  local reason = handleRequests(client, now)
  if reason then return reason end
  if err and err ~= 'timeout' then return 'disconnected' end -- closed or reset by the phone
  if now - client.lastSeen > IDLE_TIMEOUT then return 'idle' end
  return nil
end

local function readClients(now)
  for i = #clients, 1, -1 do
    local client = clients[i]
    local reason = client.closed and 'replaced' or readClient(client, now)
    if reason then dropClient(i, reason) end
  end
end

local function expirePending(now)
  for id, request in pairs(pending) do
    if now > request.deadline and frame - request.sentFrame >= UI_TIMEOUT_FRAMES then
      pending[id] = nil
      log('W', 'stereoLink.airplay', 'no answer from the UI for ' .. request.kind)
      request.onAnswer(nil)
    end
  end
end

---------------------------------------------------------------------------

-- callbacks: toUi(msg), onSession(session|nil, reason), onVolume(db), onTrack(info),
--   onCover(dataUri|nil), onProgress({start, current, end}), getVolumeDb()
-- options: {port = 47000, macBytes = 6 raw bytes}
-- Returns true, port or false, error.
local function start(callbacks, options)
  events, macBytes = callbacks, options.macBytes
  if listener then return true, port end
  listener, port = bindListener(options.port)
  if not listener then return false, 'no free TCP port near ' .. options.port end
  return true, port
end

local function stop()
  endSession('stopped')
  for i = #clients, 1, -1 do dropClient(i, 'stopped') end
  if listener then listener:close() end
  listener = nil
  announcer = nil
  pending = {}
end

local function update()
  if not listener then return end
  frame = frame + 1
  local now = socket.gettime()
  acceptClients(now)
  -- audio first: after a long frame its packets prove the phone is still there
  pumpAudio(now)
  readClients(now)
  expirePending(now)
end

local function uiReply(id, value)
  local request = pending[id]
  if not request then return end
  pending[id] = nil
  request.onAnswer(value)
end

-- Packet counters since Lua was loaded, for the dev self-check: {forwarded, flushed}.
local function getStats()
  return { forwarded = stats.forwarded, flushed = stats.flushed }
end

M.start = start
M.stop = stop
M.update = update
M.uiReply = uiReply
M.stats = getStats

return M
