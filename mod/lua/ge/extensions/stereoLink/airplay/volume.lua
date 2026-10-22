-- AirPlay volume. The phone's slider is -30..0 dB and -144 means mute; the head unit works with
-- the slider position, 0..1. Pure functions, the caller passes the time.
--
-- The game moves the phone's slider by pressing its volume buttons over DACP. iOS answers a
-- setproperty?dmcp.device-volume with 204 and leaves its slider where it was, so that is not used.

local M = {}

local MUTED_DB = -144
local MIN_DB = -30
local STEPS = 16 -- one volumeup / volumedown moves the iOS slider by 1/16
local INITIAL_VOLUME = 0.5 -- AirPlay starts a session at -15 dB, until the phone reports its slider
local STEPS_SETTLE = 1.0 -- reports this soon after the last press may still be for older presses

local function fromDb(db)
  if db <= MUTED_DB then return 0 end
  return math.max(0, math.min(1, (db - MIN_DB) / -MIN_DB))
end

-- The bottom of the slider is mute, as on the phone.
local function toDb(volume)
  if volume <= 0 then return MUTED_DB end
  return MIN_DB - MIN_DB * math.min(1, volume)
end

-- Signed number of volumeup (positive) or volumedown presses between two positions.
local function stepsBetween(from, to)
  return math.floor((to - from) * STEPS + 0.5)
end

-- The presses that move the slider from phone to wanted, never more than the whole slider.
local function stepsToSend(phone, wanted)
  return math.max(-STEPS, math.min(STEPS, stepsBetween(phone, wanted)))
end

-- Where the phone's slider is while the game presses its volume buttons. The phone reports each
-- press late, so its reports are ignored until the presses have rested a while; until then the
-- slider is where the presses put it.
local function slider()
  local value = INITIAL_VOLUME
  local quietAt

  local function get() return value end

  local function pressed(steps, now)
    value = math.max(0, math.min(1, value + steps / STEPS))
    quietAt = now + STEPS_SETTLE
  end

  local function pressDone(now) quietAt = now + STEPS_SETTLE end

  -- Returns false when the report was ignored.
  local function report(reported, now)
    if quietAt and now < quietAt then return false end
    value = reported
    return true
  end

  return { get = get, pressed = pressed, pressDone = pressDone, report = report }
end

M.STEPS = STEPS
M.INITIAL_VOLUME = INITIAL_VOLUME
M.STEPS_SETTLE = STEPS_SETTLE
M.fromDb = fromDb
M.toDb = toDb
M.stepsBetween = stepsBetween
M.stepsToSend = stepsToSend
M.slider = slider

return M
