-- Who may start and own the AirPlay session. Pure functions, no sockets: clients are passed
-- as opaque ids (raop passes its client tables), nil meaning "nobody".
--
-- Only the phone that sent the last accepted ANNOUNCE may SETUP. A second phone that
-- announces takes over, like on a real head unit, and the first one is disconnected.

local M = {}

local rtsp = require('stereoLink/airplay/rtsp')

local MAX_KEY_CHARS = 512 -- base64 of the 256 byte RSA-wrapped AES key is 344
local NOT_VALID_IN_STATE = 455

-- method: 'ANNOUNCE' or 'SETUP'. ownerId is the client of the running session (only ANNOUNCE needs it).
-- Returns 'ok', 'takeover' (the current owner has to be dropped first) or 455.
local function decide(method, clientId, announcerId, ownerId)
  if method == 'SETUP' then
    -- the announcer already took over at ANNOUNCE, so the session is its own or there is none
    if clientId ~= announcerId then return NOT_VALID_IN_STATE end
    return 'ok'
  end
  local current = ownerId or announcerId
  if current ~= nil and current ~= clientId then return 'takeover' end
  return 'ok'
end

-- The whole ANNOUNCE decision. The stream is checked before ownership, so a broken ANNOUNCE
-- from another phone never ends the running session.
-- Returns 'ok' or 'takeover', or an error status and a reason for the log.
local function announce(sdp, clientId, announcerId, ownerId, uiBusy)
  if not (sdp.rtpmap or ''):find('AppleLossless', 1, true) then
    return 415, 'unsupported codec: ' .. tostring(sdp.rtpmap):sub(1, 64)
  end
  local fmtp, fmtpError = rtsp.parseFmtp(sdp.fmtp)
  if not fmtp then return 415, 'unsupported ALAC stream: ' .. fmtpError end
  if #(sdp.rsaaeskey or '') > MAX_KEY_CHARS or #(sdp.aesiv or '') > MAX_KEY_CHARS then
    return 400, 'AES key or IV too long'
  end
  if uiBusy then return 503 end
  return decide('ANNOUNCE', clientId, announcerId, ownerId)
end

-- The announcer after `clientId` disconnects or its stream fails to start in the UI.
local function release(announcerId, clientId)
  if announcerId == clientId then return nil end
  return announcerId
end

M.decide = decide
M.announce = announce
M.release = release

return M
