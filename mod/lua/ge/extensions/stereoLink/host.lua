-- The head unit's side of a session: the host table every source gets (docs/ADDING_A_SOURCE.md),
-- which source owns the player, what it plays and whether it is playing. No engine calls, so the
-- extension passes in what it needs and the tests pass in fakes.

local session = require('stereoLink/session')
local airplayVolume = require('stereoLink/airplay/volume')

local M = {}

local PLAYING_TIMEOUT = 1.0 -- no audio for this long means paused
-- The phone answers each volume request the wheel sent; reports this soon after a change from
-- the game are echoes of older values, held back until the wheel rests.
local VOLUME_SETTLE = 1.0

local function copyWithoutId(message)
  local copy = {}
  for key, value in pairs(message) do copy[key] = value end
  copy.id = nil
  return copy
end

-- deps:
--   send(message)          queues a message for the UI player
--   now()                  seconds, the same clock for every call
--   showCover(seq, data)   hands the artwork to the UI; data is nil when there is none
--   changed()              the head unit screen state is stale
--   log(level, tag, text)  optional
local function new(deps)
  local activeSource
  local connected = false
  local lastStream
  local playing = false
  local lastAudioAt = 0
  local track = {}
  local cover
  local coverSeq = 0
  local phoneVolume = airplayVolume.INITIAL_VOLUME -- until a phone reports its own volume
  local settleUntil
  local heldVolume
  local restorePending = true -- the first volume report of a session is the phone's per-speaker default

  local function setCover(dataUri)
    cover = dataUri
    coverSeq = coverSeq + 1
    deps.showCover(coverSeq, dataUri)
  end

  local function applyPhoneVolume(value)
    phoneVolume = value
    if deps.rememberVolume then deps.rememberVolume(value) end
    deps.send({ type = 'volume', value = session.gainFromVolume(value) })
    deps.changed()
  end

  local function settling() return settleUntil ~= nil and deps.now() < settleUntil end

  local function settleVolume()
    if heldVolume == nil or settling() then return end
    local value = heldVolume
    heldVolume = nil
    applyPhoneVolume(value)
  end

  local function clear()
    activeSource, connected, lastStream, playing = nil, false, nil, false
    track = {}
    heldVolume = nil -- a report from the phone that just went away
    restorePending = true
    if cover then setCover(nil) end
    deps.changed()
  end

  -- The source that replaced another is the only one heard from now on; the replaced one is
  -- asked to let its phone go.
  local function capture(source)
    if activeSource == source then return end
    local previous = activeSource
    clear()
    activeSource = source
    if previous and previous.release then previous.release() end
  end

  -- Returns false for whatever a source sends while another one owns the player.
  local function accepts(source, kind)
    local decision = session.route(activeSource and activeSource.id, source.id, kind)
    if decision == 'capture' then capture(source) end
    return decision ~= 'drop'
  end

  local function noteAudio()
    local now = deps.now()
    if not playing then
      playing = true
      session.resumeClock(track, now)
      deps.changed()
    end
    lastAudioAt = now
  end

  -- Called every frame: a pause shows up only as audio that stopped coming.
  local function noticeAudioStopped()
    if not playing or deps.now() - lastAudioAt < PLAYING_TIMEOUT then return end
    playing = false
    session.freezeClock(track, lastAudioAt)
    deps.changed()
  end

  local function endSession(source, reason)
    if activeSource ~= source then return end
    if deps.log then deps.log('I', 'stereoLink', source.id .. ' session ended: ' .. tostring(reason)) end
    clear()
  end

  local setVolume

  -- iOS starts every session at the volume it keeps for this speaker (often a third of the slider),
  -- not at the volume the player listened at last. Put that one back on the phone.
  local function restoreVolume(reported)
    local remembered = deps.rememberedVolume and deps.rememberedVolume()
    if not remembered or math.abs(remembered - reported) < 0.01 then return false end
    setVolume(remembered)
    return true
  end

  local function hostFor(source)
    return {
      toUi = function(message)
        if not accepts(source, message.type) then return end
        if message.type == 'stream' then lastStream = message end
        if message.type == 'audio' then noteAudio() end
        message.source = source.id -- the UI answers requests through uiReply(source, id, value)
        deps.send(message)
      end,
      onSession = function(info, reason)
        if not info then return endSession(source, reason) end
        capture(source)
        connected = true
        track.device = info.device
        deps.changed()
      end,
      onVolume = function(volume)
        if not accepts(source, 'volume') then return end
        if restorePending then
          restorePending = false
          if restoreVolume(volume) then return end
        end
        if settling() then
          heldVolume = volume
          return
        end
        applyPhoneVolume(volume)
      end,
      onTrack = function(info)
        if not accepts(source, 'track') then return end
        track.title, track.artist, track.album = info.title, info.artist, info.album
        deps.changed()
      end,
      onCover = function(dataUri)
        if not accepts(source, 'cover') then return end
        setCover(dataUri)
        deps.changed()
      end,
      onProgress = function(position, duration)
        if not accepts(source, 'progress') then return end
        track.position, track.duration, track.positionAt = position, duration, deps.now()
        deps.changed()
      end,
    }
  end

  -- A reloaded UI has a fresh player: give it the volume, the running stream and the artwork
  -- again. The stream goes without its id, so the UI does not answer a request nobody waits for.
  local function replay()
    deps.send({ type = 'volume', value = session.gainFromVolume(phoneVolume) })
    if connected and lastStream then deps.send(copyWithoutId(lastStream)) end
    if cover then deps.showCover(coverSeq, cover) end
  end

  -- The session part of the head unit screen state.
  local function state()
    return {
      connected = connected,
      source = connected and activeSource.label or nil,
      device = track.device,
      canControl = connected and activeSource.canControl(),
      playing = playing,
      title = track.title,
      artist = track.artist,
      album = track.album,
      position = session.trackPosition(track, deps.now(), playing),
      duration = track.duration,
      phoneVolume = phoneVolume,
    }
  end

  -- command: 'playpause' | 'next' | 'prev'
  local function control(command)
    if connected then activeSource.control(command) end
  end

  -- The volume set on the head unit: heard at once, then sent to the phone if the source can.
  -- Without a phone remote it stays a volume of the game only.
  function setVolume(value)
    value = tonumber(value)
    if not value or value ~= value then return end -- nil or NaN from a broken call
    value = math.max(0, math.min(1, value))
    heldVolume = nil
    restorePending = false -- the player chose a volume this session already
    settleUntil = deps.now() + VOLUME_SETTLE
    applyPhoneVolume(value)
    if connected and activeSource.setVolume then activeSource.setVolume(value) end
  end

  -- Called every frame.
  local function update()
    noticeAudioStopped()
    settleVolume()
  end

  return {
    hostFor = hostFor,
    update = update,
    clear = clear,
    replay = replay,
    state = state,
    control = control,
    setVolume = setVolume,
  }
end

M.new = new

return M
