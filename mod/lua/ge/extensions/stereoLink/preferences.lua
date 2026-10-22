-- Contents of the settings file: parsing, defaults and validation. Pure functions, the file I/O
-- stays in the extension.

local M = {}

local json = require('json')

local DEFAULT_NAME = 'BeamNG'
local DEFAULT_CAR_VOLUME = 0.8
local MAX_NAME_BYTES = 40 -- the advertised name ends up inside a 63 byte DNS label

-- What the settings panel on the screen may change, with the type and the default of each.
-- The panel lists its checkboxes in ui/modModules/stereoLink/headUnit.js (SETTINGS).
local OPTIONS = {
  fullSoundOutside = { type = 'boolean', default = false },
}

-- UTF-8 continuation bytes look like 10xxxxxx; a cut must not land in front of one.
local function isContinuationByte(byte)
  return byte ~= nil and byte >= 0x80 and byte < 0xC0
end

-- Drops characters that break the advertised service name ('.' separates DNS labels,
-- '@' separates the id from the name) and cuts it to MAX_NAME_BYTES on a UTF-8 boundary.
local function sanitizeName(name)
  if type(name) ~= 'string' then return nil end
  name = name:gsub('[%c@%.]', ''):match('^%s*(.-)%s*$')
  if #name > MAX_NAME_BYTES then
    local cut = MAX_NAME_BYTES
    while cut > 0 and isContinuationByte(name:byte(cut + 1)) do cut = cut - 1 end
    name = name:sub(1, cut)
  end
  return name ~= '' and name or nil
end

local function clampVolume(value)
  return math.max(0, math.min(1, tonumber(value) or DEFAULT_CAR_VOLUME))
end

local function isMac(value)
  return type(value) == 'string' and #value == 12 and value:match('^%x+$') ~= nil
end

-- text: the file contents, nil when there is no file.
-- Returns the decoded table, or nil and a reason when the file is broken.
local function decode(text)
  if text == nil or text == '' then return nil end
  local ok, saved = pcall(json.decode, text)
  if not ok then return nil, tostring(saved) end
  if type(saved) ~= 'table' then return nil, 'not a JSON object' end
  return saved
end

-- saved: whatever was read from the file (may be nil or garbage).
-- newMac: called when there is no valid id yet.
local function normalize(saved, newMac)
  saved = type(saved) == 'table' and saved or {}
  local prefs = {
    mac = isMac(saved.mac) and saved.mac:upper() or newMac(),
    power = saved.power ~= false,
    carVolume = clampVolume(saved.carVolume),
    -- the phone volume listened at last, put back when a phone connects; none until then
    phoneVolume = type(saved.phoneVolume) == 'number' and clampVolume(saved.phoneVolume) or nil,
    name = sanitizeName(saved.name) or DEFAULT_NAME,
  }
  for key, option in pairs(OPTIONS) do
    local value = saved[key]
    if type(value) == option.type then prefs[key] = value else prefs[key] = option.default end
  end
  return prefs
end

-- Changes one option in prefs. Returns true, or nil and a reason when key is not an option or
-- value has the wrong type (prefs stays as it was).
local function setOption(prefs, key, value)
  local option = OPTIONS[key]
  if not option then return nil, 'unknown option ' .. tostring(key) end
  if type(value) ~= option.type then return nil, key .. ' must be a ' .. option.type end
  prefs[key] = value
  return true
end

-- The options' current values, for the screen.
local function options(prefs)
  local values = {}
  for key in pairs(OPTIONS) do values[key] = prefs[key] end
  return values
end

M.sanitizeName = sanitizeName
M.clampVolume = clampVolume
M.decode = decode
M.normalize = normalize
M.setOption = setOption
M.options = options

return M
