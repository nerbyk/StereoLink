-- Development tool, not shipped: pretends to be a phone on 127.0.0.1 and streams a 440 Hz tone
-- through the whole AirPlay path (RTSP handshake, RTP packets, UI decoding and playback).
--   extensions.load("stereoLink_dev_fakeSender"); stereoLink_dev_fakeSender.play(5)
--   stereoLink_dev_fakeSender.report()  -- handshake log and packets sent
--   stereoLink_dev_fakeSender.setVolume(-15)  -- the phone's slider half way, while it plays
-- Hostile requests for checking the receiver's limits:
--   stereoLink_dev_fakeSender.probe('setupHijack')  -- from a second connection, see PROBES
--   stereoLink_dev_fakeSender.inject('dmapBomb')    -- on the streaming connection, see INJECTIONS
--   stereoLink_dev_fakeSender.probeReport()         -- what each probe got back
-- All of it at once, while a tone plays:
--   stereoLink_dev_fakeSender.selfCheck()           -- takes about 5 s
--   stereoLink_dev_fakeSender.selfCheckReport()     -- {name = {expected, got, ok}, streamStillPlaying, allOk}

local M = {}

local socket = require('socket')
local raop = require('stereoLink/airplay/raop')

local FRAMES = 352
local SAMPLE_RATE = 44100
local SEQ_RANGE = 65536
local DEFAULT_PORT = 47000
local FMTP = '96 352 0 16 40 10 14 2 255 0 0 44100'
local HUGE_FMTP = '96 1000000000 0 16 40 10 14 2 255 0 0 44100'
local TRANSPORT = 'RTP/AVP/UDP;unicast;mode=record;control_port=47990;timing_port=47991'
local CHALLENGE = 'ABEiM0RVZneImaq7zN3u/w'
local STALE_PACKETS = 8
local STALE_SETTLE_SECONDS = 0.5   -- the receiver reads them on its next frames
local SELF_CHECK_SECONDS = 12      -- tone length; the checks need about 5 s of it
local SELF_CHECK_WARMUP = 1        -- let audio flow before the checks start
local SELF_CHECK_TIMEOUT = 7       -- the UI may take up to 5 s to answer a challenge
local SELF_CHECK_PLAYING_WINDOW = 1

local run
local probes = {}
local injected = {}
local selfCheckState

local function sdp(fmtp)
  return 'v=0\r\no=fake 1 0 IN IP4 127.0.0.1\r\ns=fake\r\nc=IN IP4 127.0.0.1\r\nt=0 0\r\n'
    .. 'm=audio 0 RTP/AVP 96\r\na=rtpmap:96 AppleLossless\r\na=fmtp:' .. fmtp .. '\r\n'
end

local function dmapItem(tag, value)
  local n = #value
  return tag .. string.char(math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256) .. value
end

-- An ALAC "escape" frame: raw 16 bit stereo samples, no compression.
local function toneFrame(phase)
  local bits, acc, count = {}, 0, 0
  local function put(value, width)
    for i = width - 1, 0, -1 do
      acc = acc * 2 + math.floor(value / 2 ^ i) % 2
      count = count + 1
      if count == 8 then
        table.insert(bits, string.char(acc))
        acc, count = 0, 0
      end
    end
  end
  put(1, 3); put(0, 4); put(0, 12); put(0, 1); put(0, 2); put(1, 1)
  for _ = 1, FRAMES do
    local sample = math.floor(math.sin(phase) * 6000) % 65536
    phase = phase + 2 * math.pi * 440 / SAMPLE_RATE
    put(sample, 16)
    put(sample, 16)
  end
  put(7, 3)
  if count > 0 then put(0, 8 - count) end
  return table.concat(bits), phase
end

local function formatRequest(cseq, method, headers, body)
  local lines = { method .. ' rtsp://127.0.0.1/1 RTSP/1.0', 'CSeq: ' .. cseq }
  for name, value in pairs(headers or {}) do table.insert(lines, name .. ': ' .. value) end
  if body then table.insert(lines, 'Content-Length: ' .. #body) end
  return table.concat(lines, '\r\n') .. '\r\n\r\n' .. (body or '')
end

-- Sends a request on the streaming connection and returns its CSeq.
local function request(method, headers, body)
  run.cseq = run.cseq + 1
  run.tcp:send(formatRequest(run.cseq, method, headers, body))
  return run.cseq
end

local function statusOf(head) return head and head:match('^RTSP/1%.0 (%d+)') end

local function receiveInto(conn)
  local data, _, partial = conn.tcp:receive(65536)
  conn.buffer = conn.buffer .. (data or partial or '')
end

-- Takes one complete response off conn.buffer: its head and CSeq, or nil while incomplete.
local function takeResponse(conn)
  local headEnd = conn.buffer:find('\r\n\r\n', 1, true)
  if not headEnd then return nil end
  local head = conn.buffer:sub(1, headEnd - 1)
  local length = tonumber(head:match('Content%-Length: (%d+)')) or 0
  if #conn.buffer < headEnd + 3 + length then return nil end
  conn.buffer = conn.buffer:sub(headEnd + 4 + length)
  return head, tonumber(head:match('CSeq: (%d+)'))
end

---------------------------------------------------------------------------
-- streaming connection

local STEPS = {
  function() request('OPTIONS', { ['Apple-Challenge'] = CHALLENGE }) end,
  function() request('ANNOUNCE', { ['Content-Type'] = 'application/sdp' }, sdp(FMTP)) end,
  function() request('SETUP', { Transport = TRANSPORT }) end,
  function() request('RECORD', { ['RTP-Info'] = 'seq=0;rtptime=0' }) end,
  function() request('SET_PARAMETER', { ['Content-Type'] = 'text/parameters' }, 'volume: -10.0\r\n') end,
}

local function closeRun()
  if not run or run.closed then return end
  run.tcp:close()
  run.udp:close()
  run.closed = true
end

-- Audio packet number `index`; its sequence number wraps like a phone's.
local function sendPacket(index, phase)
  local seq, timestamp = index % SEQ_RANGE, (index * FRAMES) % 4294967296
  local header = string.char(0x80, 0x60, math.floor(seq / 256), seq % 256,
    math.floor(timestamp / 16777216) % 256, math.floor(timestamp / 65536) % 256, math.floor(timestamp / 256) % 256, timestamp % 256,
    0, 0, 0, 1)
  local frame, nextPhase = toneFrame(phase)
  run.udp:sendto(header .. frame, '127.0.0.1', run.audioPort)
  return nextPhase
end

local function sendAudio()
  local due = math.floor((socket.gettime() - run.startedAt) * SAMPLE_RATE / FRAMES) + 20
  while run.sent < due and run.sent < run.total do
    run.phase = sendPacket(run.sent, run.phase)
    run.sent = run.sent + 1
  end
  if run.sent >= run.total then
    request('TEARDOWN')
    run.done = true
    closeRun()
  end
end

local function onHandshakeResponse(head)
  if run.step == 1 then run.signed = head:find('Apple%-Response: [%w+/]+') ~= nil end
  run.audioPort = run.audioPort or tonumber(head:match('server_port=(%d+)'))
  run.step = run.step + 1
  if STEPS[run.step] then
    STEPS[run.step]()
  else
    run.startedAt = socket.gettime()
  end
end

local function onResponse(head, cseq)
  table.insert(run.log, head:match('^[^\r\n]*'))
  if statusOf(head) ~= '200' then run.failed = true end
  if not run.startedAt then return onHandshakeResponse(head) end
  if cseq then run.responses[cseq] = head end
  local after = cseq and run.afterResponse[cseq]
  if after then
    run.afterResponse[cseq] = nil
    after()
  end
end

local function readResponses()
  receiveInto(run)
  while true do
    local head, cseq = takeResponse(run)
    if not head then return end
    onResponse(head, cseq)
  end
end

---------------------------------------------------------------------------
-- hostile requests

-- Requests from a second connection that never announced. `verdict` turns the answers
-- ({[cseq] = head}) into the value compared with `expected`, nil while incomplete.
local PROBES = {
  setupHijack = { expected = '455', request = function() return formatRequest(1, 'SETUP', { Transport = TRANSPORT }) end },
  hugeFmtp = { expected = '415', request = function() return formatRequest(1, 'ANNOUNCE', { ['Content-Type'] = 'application/sdp' }, sdp(HUGE_FMTP)) end },
  longChallenge = { expected = '400', request = function() return formatRequest(1, 'OPTIONS', { ['Apple-Challenge'] = string.rep('A', 4096) }) end },
  -- iOS signs in once per connection; a second challenge must not cost another RSA signature
  secondChallenge = {
    expected = 'second unsigned',
    request = function()
      return formatRequest(1, 'OPTIONS', { ['Apple-Challenge'] = CHALLENGE }) .. formatRequest(2, 'OPTIONS', { ['Apple-Challenge'] = CHALLENGE })
    end,
    verdict = function(responses)
      if not (responses[1] and responses[2]) then return nil end
      return responses[2]:find('Apple-Response', 1, true) and 'second signed' or 'second unsigned'
    end,
  },
}

local function sendStale(check)
  check.droppedBefore = raop.stats().flushed
  for back = STALE_PACKETS, 1, -1 do sendPacket(check.flushIndex - back, 0) end
  check.staleSentAt = socket.gettime()
end

-- Old packets after a FLUSH answered with 200 must be dropped, not played.
local function flushStale(check)
  check.flushIndex = run.sent
  local cseq = request('FLUSH', { ['RTP-Info'] = 'seq=' .. run.sent % SEQ_RANGE .. ';rtptime=0' })
  run.afterResponse[cseq] = function() sendStale(check) end
  return cseq
end

local function flushStaleVerdict(check)
  if not check.staleSentAt or socket.gettime() - check.staleSentAt < STALE_SETTLE_SECONDS then return nil end
  return (raop.stats().flushed - check.droppedBefore) .. ' dropped'
end

-- Requests on the streaming connection (the session owner). Each must leave the stream playing.
-- `send` returns the CSeq whose answer is compared with `expected`, unless there is a `verdict`.
local INJECTIONS = {
  -- containers that all claim the rest of the body
  dmapBomb = {
    expected = '200',
    send = function()
      return request('SET_PARAMETER', { ['Content-Type'] = 'application/x-dmap-tagged' },
        string.rep('mlit\255\255\255\255', 6000) .. dmapItem('minm', 'Bomb'))
    end,
  },
  coverWithBadType = {
    expected = '200',
    send = function() return request('SET_PARAMETER', { ['Content-Type'] = 'image/svg+xml' }, '<svg/>') end,
  },
  flushStale = { expected = STALE_PACKETS .. ' dropped', send = flushStale, verdict = flushStaleVerdict },
}

local function closeProbes()
  for _, p in pairs(probes) do p.tcp:close() end
  probes = {}
end

local function readProbes()
  for _, p in pairs(probes) do
    receiveInto(p)
    while true do
      local head, cseq = takeResponse(p)
      if not head then break end
      p.responses[cseq or 1] = head
    end
  end
end

local function probeVerdict(kind)
  local p = probes[kind]
  if not p then return nil end
  local verdict = PROBES[kind].verdict
  if verdict then return verdict(p.responses) end
  return statusOf(p.responses[1])
end

local function injectionVerdict(kind)
  local check = injected[kind]
  if not check then return nil end
  local verdict = INJECTIONS[kind].verdict
  if verdict then return verdict(check) end
  return statusOf(run and run.responses[check.cseq])
end

local function connect(port)
  local tcp = socket.tcp()
  tcp:settimeout(1)
  local ok, err = tcp:connect('127.0.0.1', port or DEFAULT_PORT)
  if not ok then
    tcp:close()
    return nil, 'cannot connect: ' .. tostring(err)
  end
  tcp:settimeout(0)
  return tcp
end

---------------------------------------------------------------------------

-- Streams `seconds` of tone to the receiver on `port` (default 47000).
local function play(seconds, port)
  closeRun()
  selfCheckState = nil
  local tcp, err = connect(port)
  if not tcp then return err end
  local udp = socket.udp()
  udp:setsockname('*', 0)
  run = { tcp = tcp, udp = udp, buffer = '', log = {}, responses = {}, afterResponse = {},
    cseq = 0, step = 1, sent = 0, phase = 0, total = math.floor((seconds or 5) * SAMPLE_RATE / FRAMES) }
  STEPS[1]()
  return 'streaming'
end

local function report()
  if not run then return 'not started' end
  return {
    responses = run.log,
    challengeSigned = run.signed == true,
    allOk = not run.failed and #run.log >= #STEPS,
    packetsSent = run.sent,
    done = run.done == true,
  }
end

-- Sends one of PROBES from a fresh connection; the answer shows up in probeReport().
local function probe(kind, port)
  if not PROBES[kind] then return 'unknown probe' end
  if probes[kind] then probes[kind].tcp:close() end
  local tcp, err = connect(port)
  if not tcp then return err end
  tcp:send(PROBES[kind].request())
  probes[kind] = { tcp = tcp, buffer = '', responses = {} }
  return 'sent'
end

local function probeReport()
  local out = {}
  for kind in pairs(probes) do out[kind] = probeVerdict(kind) or 'no answer yet' end
  return out
end

-- Sends one of INJECTIONS on the streaming connection; its answer lands in report().responses.
local function inject(kind)
  if not INJECTIONS[kind] then return 'unknown injection' end
  if not run or run.done or not run.startedAt then return 'not streaming' end
  local check = {}
  check.cseq = INJECTIONS[kind].send(check)
  injected[kind] = check
  return 'sent'
end

-- Moves the fake phone's volume slider, as a phone reports it: -30..0 dB, -144 is mute.
local function setVolume(db)
  if not run or run.done or not run.startedAt then return 'not streaming' end
  request('SET_PARAMETER', { ['Content-Type'] = 'text/parameters' }, string.format('volume: %.6f\r\n', db))
  return 'sent'
end

---------------------------------------------------------------------------
-- self-check: every probe and injection during one tone

local function collectChecks()
  local result, complete = {}, true
  local function add(name, expected, got)
    if got == nil then complete = false end
    result[name] = { expected = expected, got = got or 'no answer', ok = got == expected }
  end
  for kind, spec in pairs(PROBES) do add(kind, spec.expected, probeVerdict(kind)) end
  for kind, spec in pairs(INJECTIONS) do add(kind, spec.expected, injectionVerdict(kind)) end
  return result, complete
end

-- Also called when the tone ends early: then the stream does not count as still playing.
local function finishSelfCheck(state)
  local result = collectChecks()
  local allOk = true
  for _, check in pairs(result) do allOk = allOk and check.ok end
  result.streamStillPlaying = state.forwardedAt ~= nil and not run.done and raop.stats().forwarded > state.forwardedAt
  result.allOk = allOk and result.streamStillPlaying
  state.result = result
  state.phase = 'done'
end

local function startChecks(state, now)
  closeProbes()
  injected = {}
  for kind in pairs(PROBES) do probe(kind, state.port) end
  for kind in pairs(INJECTIONS) do inject(kind) end
  state.phase = 'checking'
  state.deadline = now + SELF_CHECK_TIMEOUT
end

local function advanceSelfCheck(state, now)
  if state.phase == 'handshake' then
    if run.failed or now > state.deadline then
      state.result = { error = 'handshake failed', responses = run.log }
      state.phase = 'done'
    elseif run.startedAt and now - run.startedAt > SELF_CHECK_WARMUP then
      startChecks(state, now)
    end
  elseif state.phase == 'checking' then
    local _, complete = collectChecks()
    if complete or now > state.deadline then
      state.phase = 'playing'
      state.forwardedAt = raop.stats().forwarded
      state.playingUntil = now + SELF_CHECK_PLAYING_WINDOW
    end
  elseif state.phase == 'playing' and now > state.playingUntil then
    finishSelfCheck(state)
  end
end

local function updateSelfCheck()
  local state = selfCheckState
  if not state or state.phase == 'done' then return end
  if run.done then return finishSelfCheck(state) end
  advanceSelfCheck(state, socket.gettime())
end

---------------------------------------------------------------------------

local function onUpdate()
  readProbes()
  if not run or run.done then return end
  readResponses()
  if run.startedAt and run.audioPort then sendAudio() end
  updateSelfCheck()
end

-- Plays a tone and, once it flows, sends every probe and injection; the outcome lands in
-- selfCheckReport() a few seconds later.
local function selfCheck(port)
  local status = play(SELF_CHECK_SECONDS, port)
  if status ~= 'streaming' then return status end
  selfCheckState = { phase = 'handshake', port = port, deadline = socket.gettime() + SELF_CHECK_TIMEOUT }
  return 'running'
end

local function selfCheckReport()
  if not selfCheckState then return 'not started' end
  if selfCheckState.phase ~= 'done' then return 'running: ' .. selfCheckState.phase end
  return selfCheckState.result
end

local function onExtensionUnloaded()
  closeRun()
  closeProbes()
  run = nil
  injected = {}
  selfCheckState = nil
end

M.onUpdate = onUpdate
M.onExtensionUnloaded = onExtensionUnloaded
M.play = play
M.report = report
M.probe = probe
M.probeReport = probeReport
M.inject = inject
M.setVolume = setVolume
M.selfCheck = selfCheck
M.selfCheckReport = selfCheckReport

return M
