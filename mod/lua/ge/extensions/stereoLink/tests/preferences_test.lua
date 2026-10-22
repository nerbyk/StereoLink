local t = require("stereoLink/testlib")
local preferences = require("stereoLink/preferences")

local cases = {}

local function newMac() return "02AABBCCDDEE" end

function cases.missingFileGetsDefaults()
  local prefs = preferences.normalize(nil, newMac)
  t.eq(prefs.mac, "02AABBCCDDEE")
  t.eq(prefs.power, true)
  t.eq(prefs.carVolume, 0.8)
  t.eq(prefs.name, "BeamNG")
  t.eq(prefs.fullSoundOutside, false)
end

function cases.garbageValuesAreReplaced()
  local prefs = preferences.normalize({ mac = "ZZZZZZZZZZZZ", power = "yes", carVolume = "abc", name = 5 }, newMac)
  t.eq(prefs.mac, "02AABBCCDDEE")
  t.eq(prefs.power, true)
  t.eq(prefs.carVolume, 0.8)
  t.eq(prefs.name, "BeamNG")
end

function cases.validValuesAreKept()
  local prefs = preferences.normalize({ mac = "0211aabbccdd", power = false, carVolume = 0.3, name = "Truck" }, newMac)
  t.eq(prefs.mac, "0211AABBCCDD")
  t.eq(prefs.power, false)
  t.eq(prefs.carVolume, 0.3)
  t.eq(prefs.name, "Truck")
end

function cases.volumeIsClamped()
  t.eq(preferences.clampVolume(5), 1)
  t.eq(preferences.clampVolume(-1), 0)
end

function cases.nameLosesCharactersThatBreakTheServiceName()
  t.eq(preferences.sanitizeName("My.Car@1"), "MyCar1")
  t.eq(preferences.sanitizeName("  ...  "), nil)
end

function cases.longNameIsCutOnACharacterBoundary()
  local name = preferences.sanitizeName(string.rep("Ж", 30)) -- 2 bytes each
  t.eq(#name, 40)
  t.eq(name, string.rep("Ж", 20))
  t.eq(#preferences.sanitizeName("a" .. string.rep("Ж", 30)), 39, "a half character is dropped")
end

function cases.longNameIsCutBeforeAThreeByteCharacter()
  t.eq(#preferences.sanitizeName("ab" .. string.rep("€", 20)), 38) -- € is 3 bytes
end

function cases.decodeTreatsAMissingFileAsEmpty()
  local saved, err = preferences.decode(nil)
  t.eq(saved, nil)
  t.eq(err, nil)
  saved, err = preferences.decode("")
  t.eq(saved, nil)
  t.eq(err, nil)
end

function cases.decodeReadsAnObject()
  local saved, err = preferences.decode('{"name": "Truck", "power": false}')
  t.eq(err, nil)
  t.eq(saved.name, "Truck")
  t.eq(saved.power, false)
end

function cases.decodeReportsABrokenFile()
  local saved, err = preferences.decode('{"name": "Tru')
  t.eq(saved, nil)
  t.truthy(err, "cut off")
  saved, err = preferences.decode("42")
  t.eq(saved, nil)
  t.truthy(err, "not an object")
end

function cases.oldFileWithoutOptionsKeepsItsNameAndId()
  local prefs = preferences.normalize({ mac = "0211AABBCCDD", power = true, carVolume = 0.5, name = "Truck" }, newMac)
  t.eq(prefs.fullSoundOutside, false)
  t.eq(prefs.name, "Truck")
  t.eq(prefs.mac, "0211AABBCCDD")
  t.eq(prefs.carVolume, 0.5)
end

function cases.fullSoundOutsideMustBeABoolean()
  for _, value in ipairs({ "true", 1, 0, {} }) do
    t.eq(preferences.normalize({ fullSoundOutside = value }, newMac).fullSoundOutside, false, tostring(value))
  end
end

function cases.fullSoundOutsideIsKept()
  t.eq(preferences.normalize({ fullSoundOutside = true }, newMac).fullSoundOutside, true)
  t.eq(preferences.normalize({ fullSoundOutside = false }, newMac).fullSoundOutside, false)
end

function cases.setOptionChangesAKnownOption()
  local prefs = preferences.normalize(nil, newMac)
  t.eq(preferences.setOption(prefs, "fullSoundOutside", true), true)
  t.eq(prefs.fullSoundOutside, true)
  t.eq(preferences.setOption(prefs, "fullSoundOutside", false), true)
  t.eq(prefs.fullSoundOutside, false)
end

function cases.setOptionRefusesTheWrongType()
  local prefs = preferences.normalize(nil, newMac)
  local ok, err = preferences.setOption(prefs, "fullSoundOutside", "yes")
  t.eq(ok, nil)
  t.truthy(err)
  t.eq(prefs.fullSoundOutside, false, "unchanged")
end

function cases.setOptionRefusesKeysThatAreNotOptions()
  local prefs = preferences.normalize(nil, newMac)
  for _, key in ipairs({ "name", "mac", "power", "carVolume", "nonsense" }) do
    local ok, err = preferences.setOption(prefs, key, true)
    t.eq(ok, nil, key)
    t.truthy(err, key)
  end
  t.eq(prefs.name, "BeamNG")
  t.eq(prefs.mac, "02AABBCCDDEE")
  t.eq(prefs.power, true)
  t.eq(prefs.carVolume, 0.8)
  t.eq(prefs.nonsense, nil)
end

function cases.optionsListsEveryOptionWithItsValue()
  local prefs = preferences.normalize({ fullSoundOutside = true, name = "Truck" }, newMac)
  local options = preferences.options(prefs)
  t.eq(options.fullSoundOutside, true)
  t.eq(options.name, nil, "only options, not the whole file")
end

function cases.phoneVolumeIsKeptOrLeftOut()
  local function mac() return "0211AABBCCDD" end
  t.eq(preferences.normalize({ phoneVolume = 0.7 }, mac).phoneVolume, 0.7)
  t.eq(preferences.normalize({ phoneVolume = 3 }, mac).phoneVolume, 1, "clamped")
  t.eq(preferences.normalize({}, mac).phoneVolume, nil, "none until a phone was heard")
  t.eq(preferences.normalize({ phoneVolume = "loud" }, mac).phoneVolume, nil)
end

return cases
