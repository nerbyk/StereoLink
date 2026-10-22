local t = require("stereoLink/testlib")
local rtp = require("stereoLink/airplay/rtp")

local cases = {}

local function packet(typeByte, seq, payload)
  return string.char(0x80, typeByte, math.floor(seq / 256), seq % 256, 0, 0, 0, 0, 0, 0, 0, 1) .. (payload or "x")
end

function cases.audioPacketIsRecognisedWithAndWithoutMarker()
  t.truthy(rtp.isAudio(packet(0x60, 1)))
  t.truthy(rtp.isAudio(packet(0xE0, 1)), "marker bit set on the first packet")
  t.falsy(rtp.isAudio(packet(0x54, 1)), "sync packet")
  t.falsy(rtp.isAudio(string.char(0x80, 0x60)), "too short")
end

function cases.sequenceAndPayloadAreRead()
  local p = packet(0x60, 0x1234, "abc")
  t.eq(rtp.sequence(p), 0x1234)
  t.eq(rtp.payload(p), "abc")
end

function cases.resendIsUnwrapped()
  local inner = packet(0x60, 7)
  t.eq(rtp.unwrapResend(string.char(0x80, 0xD6, 0, 1) .. inner), inner)
  t.eq(rtp.unwrapResend(inner), nil)
end

function cases.trackStartsAtFirstPacket()
  t.eq(rtp.track(nil, 500), 500)
end

function cases.trackAsksForMissingPackets()
  local last, first, count = rtp.track(10, 14)
  t.eq(last, 14)
  t.eq(first, 11)
  t.eq(count, 3)
end

function cases.trackWrapsAround()
  local last, first, count = rtp.track(65535, 1)
  t.eq(last, 1)
  t.eq(first, 0)
  t.eq(count, 1)
end

function cases.trackIgnoresOlderAndDuplicatePackets()
  t.eq(rtp.track(100, 90), 100)
  t.eq(rtp.track(100, 100), 100)
end

function cases.trackDoesNotAskForHugeHoles()
  local last, first = rtp.track(10, 200)
  t.eq(last, 200)
  t.eq(first, nil)
end

function cases.precedesCountsAcrossTheWrap()
  t.truthy(rtp.precedes(90, 100))
  t.falsy(rtp.precedes(100, 100), "same packet")
  t.falsy(rtp.precedes(110, 100))
  t.truthy(rtp.precedes(65530, 3), "just before the wrap")
  t.falsy(rtp.precedes(3, 65530), "just after the wrap")
end

function cases.flushDropsThePacketJustBeforeTheFlushPoint()
  local flush = rtp.flushFilter(1000, 50)
  t.truthy(rtp.isFlushed(flush, 999, 50))
  t.truthy(rtp.isFlushed(flush, 999, 51.9), "still inside the 2 s window")
end

function cases.flushPassesTheFlushPointAndLater()
  local flush = rtp.flushFilter(1000, 50)
  t.falsy(rtp.isFlushed(flush, 1000, 50))
  t.falsy(rtp.isFlushed(flush, 1001, 50))
end

function cases.flushExpires()
  t.falsy(rtp.isFlushed(rtp.flushFilter(1000, 50), 999, 52.1))
end

function cases.flushCountsAcrossTheWrap()
  t.truthy(rtp.isFlushed(rtp.flushFilter(2, 0), 65534, 0))
end

-- the phone may resume from an unrelated sequence number after a FLUSH
function cases.flushPassesPacketsFarBehind()
  local flush = rtp.flushFilter(10000, 0)
  t.falsy(rtp.isFlushed(flush, 5000, 0))
  t.truthy(rtp.isFlushed(flush, 10000 - 1024, 0), "edge of the window")
  t.falsy(rtp.isFlushed(flush, 10000 - 1025, 0), "just past the window")
end

function cases.flushWithoutRtpInfoPassesEverything()
  local flush = rtp.flushFilter(nil, 0)
  t.eq(flush, nil)
  t.falsy(rtp.isFlushed(flush, 999, 0))
end

function cases.resendRequestBytes()
  t.eq(rtp.resendRequest(2, 0x0102, 3), string.char(0x80, 0xD5, 0, 2, 1, 2, 0, 3))
end

return cases
