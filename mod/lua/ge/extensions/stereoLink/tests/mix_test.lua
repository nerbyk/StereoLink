local t = require("stereoLink/testlib")
local mix = require("stereoLink/mix")

local cases = {}

local function check(onFoot, cabinCamera, fullSoundOutside, level, muffle)
  local gotLevel, gotMuffle = mix.ambient(onFoot, cabinCamera, fullSoundOutside)
  t.eq(gotLevel, level, "level")
  t.eq(gotMuffle, muffle, "muffle")
end

function cases.cabinIsClear()
  check(false, true, false, 1, 0)
end

function cases.cabinIsClearWithFullSoundOutside()
  check(false, true, true, 1, 0)
end

function cases.outsideIsQuieterAndMuffled()
  check(false, false, false, 0.7, 0.75)
end

function cases.outsideSoundsLikeTheCabinWithFullSoundOutside()
  check(false, false, true, 1, 0)
end

function cases.onFootIsQuietAndMuffled()
  check(true, false, false, 0.35, 1)
end

function cases.onFootStaysQuietWithFullSoundOutside()
  check(true, false, true, 0.35, 1)
  check(true, true, true, 0.35, 1) -- a driver camera name left over from the car does not count
end

function cases.cabinCamerasAreDriverAndOccupant()
  t.eq(mix.isCabinCamera("driver"), true)
  t.eq(mix.isCabinCamera("onboard.driver"), true)
  t.eq(mix.isCabinCamera("occupant1"), true)
  t.eq(mix.isCabinCamera("orbit"), false)
  t.eq(mix.isCabinCamera("chase"), false)
  t.eq(mix.isCabinCamera(nil), false)
end

return cases
