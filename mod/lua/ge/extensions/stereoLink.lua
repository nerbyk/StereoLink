-- StereoLink: the car's head unit plays music streamed from your phone.
-- Networking lives in the sources (stereoLink/sources/*); decoding and playback in the UI
-- module (ui/modModules/stereoLink). This extension ties them together.

local M = {}

local socket = require('socket')
local preferences = require('stereoLink/preferences')
local hostModule = require('stereoLink/host')
local mix = require('stereoLink/mix')
local ignition = require('stereoLink/ignition')

local SOURCES = {
  require('stereoLink/sources/airplay'),
}

local SETTINGS_FILE = '/settings/stereoLink.json'
local SAVE_DELAY = 1.0 -- the volume wheel sends a value per notch; write once it settles
local AMBIENT_INTERVAL = 0.25
local STATE_INTERVAL = 1.0

local prefs
local saveAt -- when the pending settings write is due; nil when there is none
local running = false
local startError
local startedSources = {}
local outbox = {}
local stateDirty = true
local lastStateAt = 0
local lastAmbientAt = 0
local ignitionState = {}
local engineWatched = {} -- vehicle id -> true once the vehicle reports engineRunning changes
local engineFirstReply = {} -- vehicle id -> engineRunning before the first change was reported

---------------------------------------------------------------------------
-- settings file

local function randomMac()
  math.randomseed(os.time())
  local bytes = {}
  for i = 1, 6 do bytes[i] = math.random(0, 255) end
  bytes[1] = bytes[1] - bytes[1] % 4 + 2 -- locally administered unicast address
  return string.format('%02X%02X%02X%02X%02X%02X', unpack(bytes))
end

local function saveSettings()
  saveAt = nil
  -- atomic: a write cut short by a crash or a killed game must not leave a truncated file
  jsonWriteFile(SETTINGS_FILE, prefs, true, nil, true)
end

local function scheduleSave() saveAt = socket.gettime() + SAVE_DELAY end

local function flushSettings()
  if saveAt then saveSettings() end
end

-- A broken file is kept as .bak, so the name and id the phone knows are not lost silently.
local function readSettingsFile()
  local text = readFile(SETTINGS_FILE)
  local saved, err = preferences.decode(text)
  if err then
    log('W', 'stereoLink', 'settings file is broken, starting from defaults (copy in ' .. SETTINGS_FILE .. '.bak): ' .. err)
    writeFile(SETTINGS_FILE .. '.bak', text)
  end
  return saved
end

local function loadSettings()
  prefs = preferences.normalize(readSettingsFile(), randomMac)
  saveSettings()
end

---------------------------------------------------------------------------
-- the session of the source that owns the player (stereoLink/host.lua)

local function send(message) table.insert(outbox, message) end
local function markDirty() stateDirty = true end

local function showCover(seq, dataUri)
  guihooks.trigger('StereoLinkCover', { seq = seq, data = dataUri })
end

local host = hostModule.new({
  send = send,
  now = socket.gettime,
  showCover = showCover,
  changed = markDirty,
  rememberedVolume = function() return prefs.phoneVolume end,
  rememberVolume = function(value)
    if prefs.phoneVolume == value then return end
    prefs.phoneVolume = value
    scheduleSave()
  end,
  -- looked up on each call: the test runner's log capture swaps the global
  log = function(level, tag, text) log(level, tag, text) end,
})

local function start()
  if running then return end
  local errors = {}
  startedSources = {}
  for _, source in ipairs(SOURCES) do
    local ok, err = source.start(host.hostFor(source), { mac = prefs.mac, name = prefs.name })
    if ok then
      table.insert(startedSources, source)
    else
      table.insert(errors, source.label .. ': ' .. tostring(err))
      log('E', 'stereoLink', source.id .. ' did not start: ' .. tostring(err))
    end
  end
  running = #startedSources > 0
  startError = #errors > 0 and table.concat(errors, '; ') or nil
  markDirty()
end

local function stop()
  for _, source in ipairs(SOURCES) do source.stop() end
  startedSources = {}
  running = false
  host.clear()
end

---------------------------------------------------------------------------
-- where the player is: in a cabin (clear), looking at the car from outside (muffled) or on foot

local function isOnFoot(vehicle)
  return vehicle == nil or vehicle:getJBeamFilename() == 'unicycle' -- walking is a unicycle in 0.40
end

local function ambient()
  local cabinCamera = not core_camera or mix.isCabinCamera(core_camera.getActiveCamName(0))
  local level, muffle = mix.ambient(isOnFoot(getPlayerVehicle(0)), cabinCamera, prefs.fullSoundOutside)
  local master = prefs.carVolume
  local ok, gameVolume = pcall(function() return settings.getValue('AudioMasterVol') end)
  if ok and type(gameVolume) == 'number' then master = master * gameVolume end
  return master * level, muffle
end

---------------------------------------------------------------------------
-- state for the head unit screen

local function sawNetwork()
  for _, source in ipairs(SOURCES) do
    if source.status().sawNetwork then return true end
  end
  return false
end

-- the UI picks the connect hint and icon by id
local function sourceList()
  local list = {}
  for _, source in ipairs(startedSources) do table.insert(list, { id = source.id, label = source.label }) end
  return list
end

local function buildState()
  local state = host.state()
  state.power = prefs.power
  state.running = running
  state.error = startError
  state.name = prefs.name
  state.carVolume = prefs.carVolume
  state.options = preferences.options(prefs)
  state.inVehicle = not isOnFoot(getPlayerVehicle(0))
  state.sawNetwork = sawNetwork()
  state.sources = sourceList()
  return state
end

local function pushState()
  guihooks.trigger('StereoLinkState', buildState())
  stateDirty = false
  lastStateAt = socket.gettime()
end

local function flushOutbox()
  if #outbox == 0 then return end
  guihooks.trigger('StereoLinkBatch', outbox)
  outbox = {}
end

-- Whether the engine of this vehicle runs, nil until its own Lua has said so. The vehicle Lua
-- runs apart from this one, so the answer comes back later and is cached by core_vehicleBridge.
local function engineOn(vehicle)
  if not core_vehicleBridge then return nil end
  local id = vehicle:getId()
  if not engineWatched[id] then
    engineWatched[id] = true
    core_vehicleBridge.registerValueChangeNotification(vehicle, 'engineRunning')
    core_vehicleBridge.requestValue(vehicle, function(reply)
      if reply and reply.result ~= nil then engineFirstReply[id] = reply.result end
    end, 'electricsValue', 'engineRunning')
  end
  local value = tonumber(core_vehicleBridge.getCachedVehicleData(id, 'engineRunning') or engineFirstReply[id])
  if value == nil then return nil end
  return value > 0
end

-- "Pause when the engine is off": presses play/pause on the phone as the engine stops and starts.
local function followEngine(now)
  if not prefs.pauseWithEngine then
    ignitionState = {}
    return
  end
  local vehicle = getPlayerVehicle(0)
  local id, on
  if not isOnFoot(vehicle) then id, on = vehicle:getId(), engineOn(vehicle) end
  local state = host.state()
  local action
  ignitionState, action = ignition.decide(ignitionState, id, on, state.playing, now)
  if action and state.connected then host.control('playpause') end
end

local function sendAmbient(now)
  if now - lastAmbientAt <= AMBIENT_INTERVAL then return end
  lastAmbientAt = now
  local level, muffle = ambient()
  send({ type = 'ambient', level = level, muffle = muffle })
  followEngine(now)
end

---------------------------------------------------------------------------
-- hooks

local function onExtensionLoaded()
  loadSettings()
  if prefs.power then start() end
end

-- The UI outlives the extension: hand it the teardown and a state with the receiver stopped.
local function onExtensionUnloaded()
  stop()
  flushSettings()
  flushOutbox()
  pushState()
end

local function onUpdate()
  for _, source in ipairs(startedSources) do source.update() end
  local now = socket.gettime()
  host.update()
  sendAmbient(now)
  flushOutbox()
  if saveAt and now >= saveAt then saveSettings() end
  if stateDirty or now - lastStateAt > STATE_INTERVAL then pushState() end
end

---------------------------------------------------------------------------
-- called from the UI

local function uiReady()
  pushState()
  host.replay()
end

local function uiReply(sourceId, id, value)
  for _, source in ipairs(SOURCES) do
    if source.id == sourceId and source.uiReply then return source.uiReply(id, value) end
  end
end

local function uiPower(on)
  prefs.power = on == true
  scheduleSave()
  if prefs.power then start() else stop() end
end

local function uiSetCarVolume(value)
  prefs.carVolume = preferences.clampVolume(value)
  scheduleSave()
  markDirty()
end

-- key: an option from preferences.lua (OPTIONS), value of its type. Anything else is ignored.
local function uiSetOption(key, value)
  local ok, err = preferences.setOption(prefs, key, value)
  if not ok then
    log('W', 'stereoLink', 'option not changed: ' .. err)
    return false
  end
  scheduleSave()
  markDirty()
  return true
end

M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onUpdate = onUpdate
M.onExit = flushSettings

M.uiReady = uiReady
M.uiReply = uiReply
M.uiPower = uiPower
M.uiControl = host.control -- command: 'playpause' | 'next' | 'prev'
M.uiSetVolume = host.setVolume -- the phone volume, 0..1
M.uiSetCarVolume = uiSetCarVolume
M.uiSetOption = uiSetOption

-- for troubleshooting from the console: dump(stereoLink.debugState())
M.debugState = buildState

return M
