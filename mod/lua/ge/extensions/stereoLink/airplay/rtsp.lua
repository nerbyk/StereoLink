-- RTSP / SDP / DMAP parsing for the AirPlay receiver. Pure functions, no sockets.

local M = {}

local SERVER = 'AirTunes/105.1'

local MAX_HEAD_BYTES = 16 * 1024
local MAX_BODY_BYTES = 4 * 1024 * 1024 -- the largest body is the cover art
local MAX_DMAP_BYTES = 64 * 1024        -- track info is well under 1 KB
local MAX_DMAP_DEPTH = 3
local DMAP_CONTAINERS = { mlit = true, mlcl = true }
local MAX_FRAME_LENGTH = 4096           -- iOS sends 352
local SAMPLE_RATES = { [44100] = true, [48000] = true }
-- The UI builds a data: URI from the type, so only plain image types get through.
local COVER_TYPES = { ['image/jpeg'] = true, ['image/png'] = true, ['image/gif'] = true, ['image/webp'] = true }

local function u32(s, i)
  return ((s:byte(i) * 256 + s:byte(i + 1)) * 256 + s:byte(i + 2)) * 256 + s:byte(i + 3)
end

-- Takes one complete request off the front of `buffer`. Header names are lowercased.
-- Returns request, rest; nil, buffer while the request is incomplete; or nil, nil, error for
-- input that can never become a valid request (the connection should be dropped).
local function parseRequest(buffer)
  local headEnd = buffer:find('\r\n\r\n', 1, true)
  if not headEnd then
    if #buffer > MAX_HEAD_BYTES then return nil, nil, 'request head too large' end
    return nil, buffer
  end
  if headEnd > MAX_HEAD_BYTES then return nil, nil, 'request head too large' end
  local head = buffer:sub(1, headEnd - 1)
  local method, uri = head:match('^(%S+)%s+(%S+)')
  if not method then return nil, nil, 'malformed request line' end
  local headers = {}
  for line in head:gmatch('[^\r\n]+') do
    local name, value = line:match('^([^:]+):%s*(.*)$')
    if name then headers[name:lower()] = value end
  end
  local length = 0
  if headers['content-length'] then
    length = tonumber(headers['content-length']:match('^%s*(%d+)%s*$'))
    if not length or length > MAX_BODY_BYTES then return nil, nil, 'bad Content-Length' end
  end
  local bodyStart = headEnd + 4
  if #buffer < bodyStart + length - 1 then return nil, buffer end
  local request = {
    method = method,
    uri = uri,
    headers = headers,
    body = buffer:sub(bodyStart, bodyStart + length - 1),
  }
  return request, buffer:sub(bodyStart + length)
end

-- headers: array of {name, value}, kept in order.
local function formatResponse(cseq, code, reason, headers, body)
  local lines = { 'RTSP/1.0 ' .. code .. ' ' .. reason, 'CSeq: ' .. (cseq or '0'), 'Server: ' .. SERVER }
  for _, header in ipairs(headers or {}) do table.insert(lines, header[1] .. ': ' .. header[2]) end
  if body and #body > 0 then table.insert(lines, 'Content-Length: ' .. #body) end
  return table.concat(lines, '\r\n') .. '\r\n\r\n' .. (body or '')
end

-- Only the a= attributes matter for AirPlay: rtpmap, fmtp, rsaaeskey, aesiv.
local function parseSdp(body)
  local attributes = {}
  for line in body:gmatch('[^\r\n]+') do
    local name, value = line:match('^a=([%w%-]+):(.*)$')
    if name then attributes[name] = value end
  end
  return attributes
end

-- "RTP/AVP/UDP;unicast;mode=record;control_port=6001;timing_port=6002"
local function parseTransport(value)
  value = value or ''
  return {
    controlPort = tonumber(value:match('control_port=(%d+)')),
    timingPort = tonumber(value:match('timing_port=(%d+)')),
  }
end

-- text/parameters bodies: "volume: -11.5" or "progress: start/current/end" (RTP timestamps).
local function parseParameters(body)
  local params = {}
  local volume = body:match('volume:%s*([%-%d%.]+)')
  if volume then params.volume = tonumber(volume) end
  local first, current, last = body:match('progress:%s*(%d+)/(%d+)/(%d+)')
  if first then params.progress = { tonumber(first), tonumber(current), tonumber(last) } end
  return params
end

-- "RTP-Info: seq=1234;rtptime=5678" on FLUSH: the first sequence number after the flush.
local function parseRtpInfo(value)
  local seq = tonumber((value or ''):match('seq=(%d+)'))
  if seq and seq < 65536 then return seq end
  return nil
end

-- "96 352 0 16 40 10 14 2 255 0 0 44100": payload type, then the ALAC decoder settings.
-- The UI sizes its buffers from these, so anything a phone would not send is refused.
-- Returns {frameLength, sampleSize, channels, sampleRate} or nil, reason.
local function parseFmtp(value)
  local fields = {}
  for field in (value or ''):gmatch('%S+') do
    if #fields == 12 or not field:match('^%d+$') then return nil, 'malformed fmtp' end
    table.insert(fields, tonumber(field))
  end
  if #fields ~= 12 then return nil, 'malformed fmtp' end
  local fmtp = { frameLength = fields[2], sampleSize = fields[4], channels = fields[8], sampleRate = fields[12] }
  if fmtp.frameLength < 1 or fmtp.frameLength > MAX_FRAME_LENGTH then return nil, 'frame length ' .. fmtp.frameLength end
  if fmtp.sampleSize ~= 16 then return nil, 'sample size ' .. fmtp.sampleSize end
  if fmtp.channels ~= 2 then return nil, 'channels ' .. fmtp.channels end
  if not SAMPLE_RATES[fmtp.sampleRate] then return nil, 'sample rate ' .. fmtp.sampleRate end
  return fmtp
end

-- The image type of a cover art SET_PARAMETER, or nil when it is not one we show.
local function coverType(contentType)
  local mimeType = (contentType or ''):lower():match('^%s*([%w%-%./+]+)')
  if COVER_TYPES[mimeType] then return mimeType end
  return nil
end

-- DMAP: 4-char tag, 32-bit length, value. Containers nest; their items are flattened into `out`.
-- Works on offsets so that nested containers never copy the data.
local function readDmap(data, first, last, depth, out)
  local i = first
  while i + 7 <= last do
    local tag, length = data:sub(i, i + 3), u32(data, i + 4)
    local valueEnd = math.min(i + 7 + length, last) -- a length past the end keeps what is there
    if not DMAP_CONTAINERS[tag] then
      out[tag] = data:sub(i + 8, valueEnd)
    elseif depth < MAX_DMAP_DEPTH then
      readDmap(data, i + 8, valueEnd, depth + 1, out)
    end
    i = valueEnd + 1
  end
end

local function parseDmap(data)
  local out = {}
  if #data <= MAX_DMAP_BYTES then readDmap(data, 1, #data, 1, out) end
  return out
end

local function trackInfo(dmapBody)
  local tags = parseDmap(dmapBody)
  return { title = tags.minm, artist = tags.asar, album = tags.asal }
end

M.MAX_HEAD_BYTES = MAX_HEAD_BYTES
M.MAX_DMAP_BYTES = MAX_DMAP_BYTES
M.parseRequest = parseRequest
M.formatResponse = formatResponse
M.parseSdp = parseSdp
M.parseTransport = parseTransport
M.parseParameters = parseParameters
M.parseRtpInfo = parseRtpInfo
M.parseFmtp = parseFmtp
M.coverType = coverType
M.parseDmap = parseDmap
M.trackInfo = trackInfo

return M
