-- luacheck config for the BeamNG 0.40 GE Lua of this mod (tools/lint.ps1 runs it).
-- Engine globals are read-only; add a name here only when the code really uses it.

std = "luajit"
max_line_length = false
unused_args = false

read_globals = {
  "log", "guihooks", "extensions", "setExtensionUnloadMode", "settings", "Lua", "FS",
  "getPlayerVehicle", "jsonWriteFile", "readFile", "writeFile",
  "core_camera",
  "stereoLink", "stereoLink_testRunner", "stereoLink_dev_fakeSender",
}

-- testRunner wraps the global log() for in-memory capture (rawset), see testRunner.lua
files["mod/lua/ge/extensions/stereoLink/testRunner.lua"] = {globals = {"log"}}
