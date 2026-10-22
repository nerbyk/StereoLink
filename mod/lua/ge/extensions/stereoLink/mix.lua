-- How the head unit sounds from where the player is: clear in the cabin, quieter and muffled
-- looking at the car from outside, quiet when walking. Pure functions, the extension finds out
-- where the player is.

local M = {}

local CABIN_LEVEL, CABIN_MUFFLE = 1, 0
local OUTSIDE_LEVEL, OUTSIDE_MUFFLE = 0.7, 0.75
local ON_FOOT_LEVEL, ON_FOOT_MUFFLE = 0.35, 1

local function isCabinCamera(name)
  name = tostring(name)
  return name:find('driver') ~= nil or name:find('^occupant') ~= nil
end

-- fullSoundOutside: the player's option for third-person driving; walking away stays quiet.
-- Returns the level (0..1, before the volume settings) and how muffled it is (0..1).
local function ambient(onFoot, cabinCamera, fullSoundOutside)
  if onFoot then return ON_FOOT_LEVEL, ON_FOOT_MUFFLE end
  if cabinCamera or fullSoundOutside then return CABIN_LEVEL, CABIN_MUFFLE end
  return OUTSIDE_LEVEL, OUTSIDE_MUFFLE
end

M.isCabinCamera = isCabinCamera
M.ambient = ambient

return M
