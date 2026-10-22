-- raop.lua's decisions live in pure modules: session ownership and the rate limits.
local t = require("stereoLink/testlib")
local ownership = require("stereoLink/airplay/ownership")
local throttle = require("stereoLink/airplay/throttle")

local cases = {}

local A, B = "phone A", "phone B"
local GOOD_FMTP = "96 352 0 16 40 10 14 2 255 0 0 44100"

local function sdp(overrides)
  local out = { rtpmap = "96 AppleLossless", fmtp = GOOD_FMTP, rsaaeskey = "key", aesiv = "iv" }
  for k, v in pairs(overrides or {}) do out[k] = v end
  return out
end

function cases.setupWithoutAnnounceIsRefused()
  t.eq(ownership.decide("SETUP", B, nil, nil), 455, "nobody announced")
  t.eq(ownership.decide("SETUP", B, A, A), 455, "A announced and plays")
  t.eq(ownership.decide("SETUP", B, A, nil), 455, "A announced, no session yet")
end

function cases.setupAfterAnnounceIsAllowed()
  t.eq(ownership.decide("SETUP", A, A, nil), "ok")
  t.eq(ownership.decide("SETUP", A, A, A), "ok", "setting up again")
end

function cases.announceFromSecondPhoneTakesOver()
  t.eq(ownership.decide("ANNOUNCE", B, A, A), "takeover", "A plays")
  t.eq(ownership.decide("ANNOUNCE", B, A, nil), "takeover", "A announced only")
  t.eq(ownership.decide("ANNOUNCE", B, nil, A), "takeover", "A plays, its re-announce failed")
end

function cases.announceFromTheOwnerOrOnAFreeReceiverIsOk()
  t.eq(ownership.decide("ANNOUNCE", A, nil, nil), "ok")
  t.eq(ownership.decide("ANNOUNCE", A, A, A), "ok")
end

function cases.goodAnnounceFromSecondPhoneTakesOver()
  t.eq(ownership.announce(sdp(), B, A, A, false), "takeover")
end

-- a broken ANNOUNCE is refused before ownership is looked at, so A keeps playing
function cases.badAnnounceDoesNotTakeOver()
  local code, why = ownership.announce(sdp({ fmtp = "96 1000000000 0 16 40 10 14 2 255 0 0 44100" }), B, A, A, false)
  t.eq(code, 415, "huge frame length")
  t.truthy(why)
  t.eq(ownership.announce(sdp({ fmtp = "garbage" }), B, A, A, false), 415, "malformed fmtp")
  local noFmtp = sdp()
  noFmtp.fmtp = nil
  t.eq(ownership.announce(noFmtp, B, A, A, false), 415, "no fmtp")
  t.eq(ownership.announce(sdp({ rtpmap = "96 mpeg4-generic" }), B, A, A, false), 415, "AAC")
  t.eq(ownership.announce(sdp({ rsaaeskey = string.rep("A", 513) }), B, A, A, false), 400, "long key")
  t.eq(ownership.announce(sdp({ aesiv = string.rep("A", 513) }), B, A, A, false), 400, "long IV")
  t.eq(ownership.announce(sdp(), B, A, A, true), 503, "UI busy")
end

function cases.droppedAnnouncerCannotSetup()
  local announcer = ownership.release(A, A)
  t.eq(announcer, nil)
  t.eq(ownership.decide("SETUP", A, announcer, nil), 455)
end

function cases.failedAnnounceClearsOnlyItsOwnClaim()
  t.eq(ownership.release(A, A), nil)
  t.eq(ownership.release(B, A), B, "A failed after B took over")
  t.eq(ownership.release(nil, A), nil)
end

function cases.throttleAllowsOncePerIntervalPerPeer()
  local allow = throttle.perPeer()
  t.truthy(allow("10.0.0.2", 100))
  t.falsy(allow("10.0.0.2", 100 + throttle.INTERVAL - 1))
  t.truthy(allow("10.0.0.3", 101), "another peer")
  t.truthy(allow("10.0.0.2", 100 + throttle.INTERVAL))
end

function cases.throttleForgetsPeersInsteadOfGrowing()
  local allow = throttle.perPeer()
  for i = 1, throttle.MAX_PEERS do t.truthy(allow("10.0.1." .. i, 0)) end
  t.falsy(allow("10.0.1.1", 1), "still remembered")
  t.truthy(allow("10.0.2.1", 1), "one more peer resets the table")
  t.truthy(allow("10.0.1.1", 2), "forgotten after the reset")
end

return cases
