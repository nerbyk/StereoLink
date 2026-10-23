-- "Pause when the engine is off": when to press play/pause on the phone. Pure; the caller passes
-- what the car and the player are doing.

local M = {}

-- The head unit notices that music stopped about a second late; until this has passed after a
-- press, "playing" still describes the moment before it.
local SETTLE = 3

-- state: what the previous call returned, or {}.
-- vehicle: the player's vehicle id, nil on foot. engineOn: true / false, nil while unknown.
-- playing: whether music is playing now. now: seconds.
-- Returns the new state and 'pause', 'resume' or nil.
local function decide(state, vehicle, engineOn, playing, now)
  local result = {
    vehicle = vehicle,
    engineOn = engineOn,
    pausedByEngine = state.pausedByEngine,
    pressedAt = state.pressedAt,
  }
  if vehicle ~= state.vehicle or engineOn == nil or state.engineOn == nil then
    -- another car, on foot or not known yet: start from what it is now, without pressing anything
    result.pausedByEngine = false
    return result, nil
  end
  local settled = not state.pressedAt or now - state.pressedAt > SETTLE
  if state.engineOn and not engineOn and playing then
    result.pausedByEngine, result.pressedAt = true, now
    return result, 'pause'
  end
  if not state.engineOn and engineOn then
    result.pausedByEngine = false
    -- only undo a pause this made; a pause the player made stays
    if state.pausedByEngine and (not playing or not settled) then
      result.pressedAt = now
      return result, 'resume'
    end
    return result, nil
  end
  if playing and settled then result.pausedByEngine = false end -- the player started it again by hand
  return result, nil
end

M.decide = decide

return M
