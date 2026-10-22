local t = require("stereoLink/testlib")
local airplay = require("stereoLink/sources/airplay")
local remote = require("stereoLink/airplay/remote")
local volume = require("stereoLink/airplay/volume")

local cases = {}

function cases.volumeFromDb()
  t.eq(volume.fromDb(-144), 0, "mute")
  t.eq(volume.fromDb(-30), 0, "slider at minimum")
  t.eq(volume.fromDb(0), 1, "slider at maximum")
  t.near(volume.fromDb(-15), 0.5, 1e-9, "half way, the same scale as the slider")
  t.eq(volume.fromDb(6), 1, "clamped above")
  t.eq(volume.fromDb(-40), 0, "clamped below")
end

function cases.volumeToDb()
  t.eq(volume.toDb(0), -144, "zero mutes, like the phone's slider at the bottom")
  t.eq(volume.toDb(1), 0)
  t.near(volume.toDb(0.5), -15, 1e-9)
  t.eq(volume.toDb(2), 0, "clamped")
  for _, value in ipairs({ 0, 0.05, 0.5, 0.8, 1 }) do
    t.near(volume.fromDb(volume.toDb(value)), value, 1e-9, "round trip " .. value)
  end
end

-- iOS moves its slider by 1/16 per volumeup / volumedown
function cases.volumeStepsBetweenTwoPositions()
  t.eq(volume.stepsBetween(0.5, 0.75), 4)
  t.eq(volume.stepsBetween(0.5, 0.25), -4)
  t.eq(volume.stepsBetween(0, 1), 16)
  t.eq(volume.stepsBetween(0.5, 0.52), 0, "less than half a step")
end

function cases.progressInSeconds()
  local position, duration = airplay.progressSeconds(1000, 1000 + 44100 * 30, 1000 + 44100 * 200)
  t.eq(position, 30)
  t.eq(duration, 200)
end

function cases.progressAcrossTimestampWrap()
  local start = 4294967296 - 44100
  local position, duration = airplay.progressSeconds(start, 44100 * 9, 44100 * 99)
  t.eq(position, 10)
  t.eq(duration, 100)
end

function cases.remoteCommandRequest()
  t.eq(remote.commandRequest("192.168.1.5", "123", "next"),
    "GET /ctrl-int/1/nextitem HTTP/1.1\r\nHost: 192.168.1.5\r\nActive-Remote: 123\r\n\r\n")
  t.truthy(remote.commandRequest("x", "1", "prev"):find("/previtem ", 1, true))
  t.truthy(remote.commandRequest("x", "1", "playpause"):find("/playpause ", 1, true))
end

function cases.sourceInterface()
  t.eq(airplay.id, "airplay")
  for _, name in ipairs({ "start", "stop", "update", "control", "canControl", "setVolume", "status" }) do
    t.eq(type(airplay[name]), "function", name)
  end
  t.eq(airplay.setName, nil, "the name only changes on a restart")
end

return cases
