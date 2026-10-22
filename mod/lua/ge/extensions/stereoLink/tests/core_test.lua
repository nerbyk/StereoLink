local t = require("stereoLink/testlib")
local session = require("stereoLink/session")

local cases = {}

function cases.streamTakesOverFromAnySource()
  t.eq(session.route(nil, "airplay", "stream"), "capture", "nobody playing")
  t.eq(session.route("android", "airplay", "stream"), "capture", "another source playing")
  t.eq(session.route("airplay", "airplay", "stream"), "capture", "same source, new stream")
end

function cases.playbackFromTheActiveSourceIsDelivered()
  for _, kind in ipairs({ "audio", "flush", "teardown", "track", "cover", "progress", "volume" }) do
    t.eq(session.route("airplay", "airplay", kind), "deliver", kind)
  end
end

function cases.playbackFromAnInactiveSourceIsDropped()
  for _, kind in ipairs({ "audio", "flush", "teardown", "track", "cover", "progress", "volume" }) do
    t.eq(session.route("android", "airplay", kind), "drop", kind)
    t.eq(session.route(nil, "airplay", kind), "drop", kind .. " with nobody playing")
  end
end

function cases.requestsPassFromAnySource()
  -- a phone has to get its challenge answered before it can take over
  t.eq(session.route("android", "airplay", "challenge"), "deliver")
  t.eq(session.route(nil, "airplay", "challenge"), "deliver")
end

function cases.positionRunsWhilePlaying()
  local clock = { position = 10, positionAt = 100, duration = 200 }
  t.eq(session.trackPosition(clock, 105, true), 15)
end

function cases.positionStopsAtTheEndOfTheTrack()
  local clock = { position = 190, positionAt = 100, duration = 200 }
  t.eq(session.trackPosition(clock, 130, true), 200)
end

function cases.noProgressMeansNoPosition()
  local clock = {}
  t.eq(session.trackPosition(clock, 5, true), nil)
  session.freezeClock(clock, 5)
  session.resumeClock(clock, 6)
  t.eq(session.trackPosition(clock, 7, true), nil)
end

function cases.pauseFreezesThePositionAtTheLastAudio()
  local clock = { position = 10, positionAt = 100, duration = 200 }
  session.freezeClock(clock, 104) -- the pause is noticed a second after the last packet
  t.eq(session.trackPosition(clock, 105, false), 14)
  t.eq(session.trackPosition(clock, 500, false), 14, "still there much later")
end

function cases.resumeDoesNotCountThePause()
  local clock = { position = 10, positionAt = 100, duration = 200 }
  session.freezeClock(clock, 104)
  session.resumeClock(clock, 300)
  t.eq(session.trackPosition(clock, 302, true), 16)
end

function cases.progressDuringAPauseIsKept()
  local clock = { position = 10, positionAt = 100, duration = 200 }
  session.freezeClock(clock, 104)
  clock.position, clock.positionAt = 20, 110 -- the phone reports a seek while paused
  t.eq(session.trackPosition(clock, 120, false), 20)
  session.resumeClock(clock, 130)
  t.eq(session.trackPosition(clock, 131, true), 21)
end

function cases.gainFromVolumeIsSquared()
  t.eq(session.gainFromVolume(0), 0)
  t.near(session.gainFromVolume(0.5), 0.25, 1e-9)
  t.eq(session.gainFromVolume(1), 1)
end

return cases
