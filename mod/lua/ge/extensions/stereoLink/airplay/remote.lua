-- DACP, the remote control side of AirPlay. The phone advertises iTunes_Ctrl_<DACP-ID>._dacp._tcp
-- and takes plain HTTP commands authorised by the Active-Remote token from the RTSP SETUP.

local M = {}

local socket = require('socket')
local mdns = require('stereoLink/airplay/mdns')
local volume = require('stereoLink/airplay/volume')

local REQUEST_TIMEOUT = 3
local MAX_QUEUED = 4 -- presses while the port is still unknown; more would just pile up
local RESOLVE_RETRY = 5 -- a phone without a remote port is asked again this rarely
local PATHS = {
  playpause = 'playpause',
  next = 'nextitem',
  prev = 'previtem',
}

-- {ip, dacpId, activeRemote, port, resolving, resolvedAt, slider, presses, pressing}
-- slider: volume.slider() of this phone; presses: volume buttons still to press, + up, - down
local target
local queued = {}
local requests = {}
local volumeRequestsSent = 0
local lastVolumePath

-- iOS sends a 64 bit hex id and a 32 bit decimal token. Both end up in a DNS name and an
-- HTTP header, so nothing else is accepted.
local function isValidTarget(dacpId, activeRemote)
  return type(dacpId) == 'string' and dacpId:match('^%x+$') ~= nil and #dacpId <= 16
    and type(activeRemote) == 'string' and activeRemote:match('^%d+$') ~= nil and #activeRemote <= 10
end

-- iOS sends DACP-ID as a number, so an id that starts with 0 arrives a digit short; the service it
-- advertises keeps all 16 digits.
local function remoteServiceName(dacpId)
  return 'iTunes_Ctrl_' .. string.rep('0', 16 - #dacpId) .. dacpId .. '._dacp._tcp.local'
end

local function request(ip, activeRemote, path)
  return 'GET /ctrl-int/1/' .. path .. ' HTTP/1.1\r\n'
    .. 'Host: ' .. ip .. '\r\n'
    .. 'Active-Remote: ' .. activeRemote .. '\r\n\r\n'
end

local function commandRequest(ip, activeRemote, command)
  return request(ip, activeRemote, PATHS[command])
end

-- The status of an HTTP reply, or nil while its status line is incomplete.
local function statusCode(response)
  return tonumber(response:match('^HTTP/%d%.%d (%d%d%d)[ \r]'))
end

-- onStatus(code) is called once the phone answers; code is nil when it closed or timed out
-- without a status line.
local function send(path, onStatus)
  local c = socket.tcp()
  c:settimeout(0)
  c:connect(target.ip, target.port) -- finishes in update()
  table.insert(requests, {
    sock = c,
    message = request(target.ip, target.activeRemote, path),
    sent = false,
    response = '',
    onStatus = onStatus,
    deadline = socket.gettime() + REQUEST_TIMEOUT,
  })
end

local function sendCommand(name) send(PATHS[name]) end

-- One volume button press at a time, the next once the phone answered the last: presses sent
-- together reach the phone out of order or not at all.
local function pressNext()
  if target.pressing or target.presses == 0 or not target.port then return end
  local up = target.presses > 0
  local path = up and 'volumeup' or 'volumedown'
  target.presses = target.presses + (up and -1 or 1)
  target.pressing = true
  local pressedOn = target
  send(path, function()
    pressedOn.slider.pressDone(socket.gettime())
    pressedOn.pressing = false
  end)
  volumeRequestsSent = volumeRequestsSent + 1
  lastVolumePath = path
end

local function onResolved(port)
  target.resolving = false
  target.port = port
  if not port then
    log('W', 'stereoLink.airplay', 'phone did not tell its remote control port')
  else
    for _, command in ipairs(queued) do sendCommand(command) end
  end
  queued = {}
end

-- Starts a lookup of the phone's remote port unless one ran recently. True while one runs.
local function resolve(now)
  if target.resolving then return true end
  if target.resolvedAt and now - target.resolvedAt < RESOLVE_RETRY then return false end
  target.resolving = true
  target.resolvedAt = now
  local resolving = target
  local ok, err = pcall(mdns.lookupSrv, remoteServiceName(target.dacpId), target.ip, function(port)
    if target == resolving then onResolved(port) end
  end)
  if not ok then
    log('W', 'stereoLink.airplay', 'cannot look up the remote control port: ' .. tostring(err))
    onResolved(nil)
    return false
  end
  return true
end

local function setTarget(ip, dacpId, activeRemote)
  if not (ip and isValidTarget(dacpId, activeRemote)) then
    target = nil
    queued = {}
    return
  end
  if target and target.ip == ip and target.dacpId == dacpId then
    target.activeRemote = activeRemote
    return
  end
  target = {
    ip = ip,
    dacpId = dacpId,
    activeRemote = activeRemote,
    slider = volume.slider(),
    presses = 0,
    pressing = false,
  }
  queued = {}
  resolve(socket.gettime())
end

local function clear()
  target = nil
  queued = {}
  for _, pending in ipairs(requests) do pending.sock:close() end
  requests = {}
end

local function available() return target ~= nil end

-- command: 'playpause' | 'next' | 'prev'
local function command(name)
  if not target or not PATHS[name] then return false end
  if target.port then
    sendCommand(name)
    return true
  end
  if not resolve(socket.gettime()) then return false end
  if #queued < MAX_QUEUED then table.insert(queued, name) end
  return true
end

-- wanted: the slider position, 0..1. The phone's slider moves by its own volume buttons, so it
-- lands on the nearest 1/16. Returns false when there is no phone to tell.
local function setVolume(wanted)
  if not target then return false end
  local now = socket.gettime()
  local steps = volume.stepsToSend(target.slider.get(), wanted)
  if steps ~= 0 then
    target.slider.pressed(steps, now)
    target.presses = target.presses + steps
  end
  if target.port then pressNext() else resolve(now) end -- update() presses once the port is known
  return true
end

-- The phone's SET_PARAMETER report of its slider: the echo of a change from the game or the
-- player moving the slider on the phone.
local function notePhoneVolume(value)
  if not target then return end
  local now = socket.gettime()
  target.slider.report(value, now)
end

-- Reads what came back; true once the request is done.
local function readReply(pending)
  local data, err, partial = pending.sock:receive('*a')
  pending.response = pending.response .. (data or partial or '')
  return data ~= nil or err == 'closed' or statusCode(pending.response) ~= nil
end

local function update()
  local now = socket.gettime()
  if target then pressNext() end
  for i = #requests, 1, -1 do
    local pending = requests[i]
    local finished = now > pending.deadline
    if not pending.sent then
      local _, writable = socket.select(nil, { pending.sock }, 0)
      if writable and writable[1] then
        pending.sock:send(pending.message)
        pending.sent = true
      end
    elseif readReply(pending) then
      finished = true
    end
    if finished then
      pending.sock:close()
      table.remove(requests, i)
      -- may queue more requests; they go to the end and are not visited in this pass
      if pending.onStatus then pending.onStatus(statusCode(pending.response)) end
    end
  end
end

-- for in-game checks: require('stereoLink/airplay/remote').stats()
local function stats()
  return {
    available = target ~= nil,
    port = target and target.port,
    presses = target and target.presses,
    volumeRequestsSent = volumeRequestsSent,
    lastVolumePath = lastVolumePath,
    phoneVolume = target and target.slider.get(),
  }
end

M.setTarget = setTarget
M.clear = clear
M.available = available
M.command = command
M.setVolume = setVolume
M.notePhoneVolume = notePhoneVolume
M.update = update
M.stats = stats
M.commandRequest = commandRequest
M.statusCode = statusCode
M.isValidTarget = isValidTarget
M.remoteServiceName = remoteServiceName

return M
