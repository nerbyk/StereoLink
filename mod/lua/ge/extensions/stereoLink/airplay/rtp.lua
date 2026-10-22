-- RTP packets of an AirPlay stream. Pure functions, no sockets.

local M = {}

local RTP_VERSION_2 = 0x80
local TYPE_AUDIO, TYPE_RESEND = 0x60, 0x56
local TYPE_RESEND_REQUEST = 0xD5 -- 0x55 with the marker bit, as iTunes sends it
local HEADER_BYTES = 12
local RESEND_HEADER_BYTES = 4
local SEQ_RANGE = 65536
local HALF_SEQ_RANGE = 0x8000
local MAX_RESEND_GAP = 64 -- bigger holes are not worth asking for, the player skips them
local FLUSH_SECONDS = 2
-- Only packets this close behind the flush point are leftovers of the old position: if the
-- phone resumes from an unrelated sequence number, its new packets must still play.
local FLUSH_WINDOW = 1024

local function u16(s, i) return s:byte(i) * 256 + s:byte(i + 1) end
local function be16(n) return string.char(math.floor(n / 256) % 256, n % 256) end
local function payloadType(packet) return packet:byte(2) % 128 end -- without the marker bit

local function isAudio(packet)
  return #packet > HEADER_BYTES and payloadType(packet) == TYPE_AUDIO
end

-- A retransmitted packet arrives on the control port wrapped in a 4 byte header.
local function unwrapResend(packet)
  if #packet > RESEND_HEADER_BYTES + HEADER_BYTES and payloadType(packet) == TYPE_RESEND then
    return packet:sub(RESEND_HEADER_BYTES + 1)
  end
  return nil
end

local function sequence(packet) return u16(packet, 3) end
local function payload(packet) return packet:sub(HEADER_BYTES + 1) end

-- True when `seq` comes before `ref`, counting across the 16 bit wrap.
local function precedes(seq, ref)
  return (seq - ref) % SEQ_RANGE >= HALF_SEQ_RANGE
end

-- Follows the sequence numbers of fresh packets. Returns the new last sequence number and,
-- when packets in between went missing, the first missing one and how many.
local function track(lastSeq, seq)
  if not lastSeq then return seq end
  if seq == lastSeq or precedes(seq, lastSeq) then return lastSeq end -- duplicate or older packet
  local missing = (seq - lastSeq) % SEQ_RANGE - 1
  if missing > 0 and missing < MAX_RESEND_GAP then return seq, (lastSeq + 1) % SEQ_RANGE, missing end
  return seq
end

-- What a FLUSH with "RTP-Info: seq=N" filters out, or nil when the phone sent no seq.
local function flushFilter(seq, now)
  if not seq then return nil end
  return { seq = seq, untilTime = now + FLUSH_SECONDS }
end

-- Packets sent before a FLUSH can still arrive after it; they belong to the old position.
local function isFlushed(flush, seq, now)
  if not flush or now > flush.untilTime then return false end
  local behind = (flush.seq - seq) % SEQ_RANGE
  return behind >= 1 and behind <= FLUSH_WINDOW
end

local function resendRequest(requestSeq, first, count)
  return string.char(RTP_VERSION_2, TYPE_RESEND_REQUEST) .. be16(requestSeq) .. be16(first) .. be16(count)
end

M.isAudio = isAudio
M.unwrapResend = unwrapResend
M.sequence = sequence
M.payload = payload
M.precedes = precedes
M.track = track
M.flushFilter = flushFilter
M.isFlushed = isFlushed
M.resendRequest = resendRequest

return M
