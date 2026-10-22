-- Head unit decisions that do not need the engine: which source owns the player and where the
-- track is. Pure functions, stereoLink/host.lua holds the state.

local M = {}

-- What only the source that owns the player may send. Requests (an Apple-Challenge) pass from
-- any source: a phone has to be answered before it can take over.
local OWNER_ONLY = {
  audio = true, flush = true, teardown = true,
  volume = true, track = true, cover = true, progress = true,
}

-- activeId: the source that owns the player, or nil. kind: a UI message type or a host
-- callback ('volume', 'track', 'cover', 'progress').
-- Returns 'capture' (the sender takes the player over), 'deliver' or 'drop'.
local function route(activeId, sourceId, kind)
  if kind == 'stream' then return 'capture' end
  if OWNER_ONLY[kind] and sourceId ~= activeId then return 'drop' end
  return 'deliver'
end

-- clock: {position, positionAt, duration} from the last progress report, times in seconds.
-- The position only moves while audio is playing.
local function trackPosition(clock, now, playing)
  if not clock.position then return nil end
  if not playing then return clock.position end
  local position = clock.position + math.max(0, now - clock.positionAt)
  if clock.duration and clock.duration > 0 then position = math.min(position, clock.duration) end
  return position
end

-- A pause is noticed a moment after the last packet, so the clock stops at that packet.
local function freezeClock(clock, lastAudioAt)
  if not clock.position then return end
  clock.position = trackPosition(clock, lastAudioAt, true)
end

local function resumeClock(clock, now)
  if not clock.position then return end
  clock.positionAt = now
end

-- The phone volume is a slider position, 0..1; squared, it sounds natural at low positions too.
local function gainFromVolume(volume)
  return volume * volume
end

M.route = route
M.trackPosition = trackPosition
M.freezeClock = freezeClock
M.resumeClock = resumeClock
M.gainFromVolume = gainFromVolume

return M
