-- AirPlay source (iPhone, iPad, Mac). See docs/ADDING_A_SOURCE.md for the source interface.

local M = {}

local socket = require('socket')
local mdns = require('stereoLink/airplay/mdns')
local raop = require('stereoLink/airplay/raop')
local remote = require('stereoLink/airplay/remote')
local volume = require('stereoLink/airplay/volume')

local BASE_PORT = 47000
local SAMPLE_RATE = 44100
local RTP_TIMESTAMP_WRAP = 2 ^ 32
local STANDBY_TIME = 10 * 60 -- a phone paused longer than this is taken as gone

M.id = 'airplay'
M.label = 'AirPlay'

local host
local options
local running = false
local port
local volumeDb = volume.toDb(volume.INITIAL_VOLUME) -- what GET_PARAMETER answers: the phone's report or the game's change
local standbyUntil -- set while the phone is paused: iOS ends the stream on pause and keeps the speaker

-- Progress comes as RTP timestamps (start/current/end), which wrap around at 2^32.
local function progressSeconds(first, current, last)
  return ((current - first) % RTP_TIMESTAMP_WRAP) / SAMPLE_RATE,
    ((last - first) % RTP_TIMESTAMP_WRAP) / SAMPLE_RATE
end

local function serviceInfo()
  return {
    type = '_raop._tcp.local',
    instance = options.mac .. '@' .. options.name,
    host = 'BeamNG-' .. options.mac .. '.local',
    port = port,
    txt = {
      'txtvers=1', 'ch=2', 'cn=0,1', 'et=0,1', 'ek=1', 'sv=false', 'da=true', 'sr=44100', 'ss=16',
      'pw=false', 'vn=65537', 'tp=UDP', 'md=0,1,2', 'vs=105.1', 'am=AirPort4,107', 'sf=0x4', 'sm=false',
    },
  }
end

-- 'AABBCCDDEEFF' -> the 6 raw bytes RAOP signs the challenge with
local function macBytes(hex)
  local bytes = {}
  for i = 1, 12, 2 do table.insert(bytes, string.char(tonumber(hex:sub(i, i + 1), 16))) end
  return table.concat(bytes)
end

local function endStandby(reason)
  standbyUntil = nil
  remote.clear()
  host.onSession(nil, reason)
end

local raopEvents = {
  toUi = function(message) host.toUi(message) end,
  getVolumeDb = function() return volumeDb end,
  onSession = function(session, reason)
    if session then
      standbyUntil = nil
      remote.setTarget(session.peerIp, session.dacpId, session.activeRemote)
      host.onSession({})
    elseif reason == 'teardown' then
      -- iOS sends TEARDOWN when the music is paused; the phone still has us selected
      standbyUntil = socket.gettime() + STANDBY_TIME
      host.onStreamEnded()
    else
      endStandby(reason)
    end
  end,
  onVolume = function(db)
    volumeDb = db
    local position = volume.fromDb(db)
    remote.notePhoneVolume(position)
    host.onVolume(position)
  end,
  onTrack = function(info) host.onTrack(info) end,
  onCover = function(dataUri) host.onCover(dataUri) end,
  onProgress = function(progress)
    local position, duration = progressSeconds(progress[1], progress[2], progress[3])
    host.onProgress(position, duration)
  end,
}

-- opts: {mac = 'AABBCCDDEEFF', name = 'BeamNG'}; a new name takes a stop() and start().
local function start(hostCallbacks, opts)
  host, options = hostCallbacks, opts
  if running then return true end
  local ok, result = raop.start(raopEvents, { port = BASE_PORT, macBytes = macBytes(options.mac) })
  if not ok then return false, result end
  port = result
  ok, result = mdns.start(serviceInfo())
  if not ok then
    raop.stop()
    return false, result
  end
  running = true
  log('I', 'stereoLink.airplay', 'advertising "' .. options.name .. '" on port ' .. port)
  return true
end

local function stop()
  standbyUntil = nil
  raop.stop()
  mdns.stop()
  remote.clear()
  running = false
end

local function update()
  if not running then return end
  mdns.update()
  raop.update()
  remote.update()
  if standbyUntil and socket.gettime() > standbyUntil then endStandby('paused too long') end
end

-- value: the slider position, 0..1. The phone confirms with its own report.
local function setVolume(value)
  volumeDb = volume.toDb(value)
  return remote.setVolume(value)
end

local function status()
  return { sawNetwork = mdns.sawTraffic() }
end

M.start = start
M.stop = stop
M.update = update
M.control = remote.command
M.canControl = remote.available
M.setVolume = setVolume
M.uiReply = raop.uiReply
M.status = status
M.progressSeconds = progressSeconds

return M
