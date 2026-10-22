-- In-game test runner. Loaded only on demand:
--   extensions.load("stereoLink_testRunner"); return stereoLink_testRunner.runAll()
-- Each file stereoLink/tests/*_test.lua returns a table { caseName = function() ... end }.

local M = {}

local logTag = "stereoLink.testRunner"
local testsDir = "/lua/ge/extensions/stereoLink/tests/"

-- Runs a table of cases; one failing case never stops the others.
-- Returns passed, failed, failures = { {name=, err=} }
local function runCases(cases, prefix)
  local names = {}
  for name, fn in pairs(cases) do
    if type(fn) == "function" then table.insert(names, name) end
  end
  table.sort(names)

  local passed, failed, failures = 0, 0, {}
  for _, name in ipairs(names) do
    local ok, err = xpcall(cases[name], debug.traceback)
    if ok then
      passed = passed + 1
    else
      failed = failed + 1
      local firstLine = tostring(err):match("^[^\n]*") or tostring(err)
      table.insert(failures, {name = (prefix or "") .. name, err = firstLine})
    end
  end
  return passed, failed, failures
end

local function loadTestFile(filePath)
  local moduleName = filePath:gsub("^/lua/ge/extensions/", ""):gsub("%.lua$", "")
  package.loaded[moduleName] = nil -- always pick up the current file
  local ok, cases = pcall(require, moduleName)
  if not ok then return nil, tostring(cases):match("^[^\n]*") end
  if type(cases) ~= "table" then return nil, "test file must return a table" end
  return cases
end

-- dir is optional (default: the tests folder); subfolders are not scanned.
local function runAll(dir)
  package.loaded["stereoLink/testlib"] = nil -- stateless, pick up edits without reload_lua
  local files = FS:findFiles(dir or testsDir, "*_test.lua", 0, false, false) or {}
  table.sort(files)

  local passed, failed, failures = 0, 0, {}
  for _, file in ipairs(files) do
    local fileName = file:match("([^/]+)%.lua$") or file
    local cases, loadErr = loadTestFile(file)
    if cases then
      local p, f, fl = runCases(cases, fileName .. ".")
      passed, failed = passed + p, failed + f
      for _, x in ipairs(fl) do table.insert(failures, x) end
    else
      failed = failed + 1
      table.insert(failures, {name = fileName .. " (load)", err = loadErr})
    end
  end

  local lines = {string.format("%d passed, %d failed (%d files)", passed, failed, #files)}
  for _, x in ipairs(failures) do
    table.insert(lines, "FAIL " .. x.name .. ": " .. x.err)
  end
  local summary = table.concat(lines, "\n")
  if not dir then -- fixture runs from the runner's own tests must not leave W lines in the log
    log(failed == 0 and "I" or "W", logTag, "tests: " .. lines[1])
  end
  return summary
end

-- beamng.log is written through a large buffer, so fresh lines may not be on disk yet.
-- Pushes 5000 short D-level lines (the writer flushes by line count, not bytes)
-- to force a flush before tools/log_errors.ps1 reads the file.
local function flushLog()
  for i = 1, 5000 do log("D", "stereoLink.logFlush", "flush") end
end

-- In-memory log capture for scenarios, independent of the file buffer.
-- startCapture() wraps the global log(); stopCapture() restores it and returns the W/E lines
-- whose tag/message match the pattern (default: our mod and jsonDecode).
local originalLog = nil
local captured = {}

local function startCapture(pattern)
  if originalLog then return false end
  pattern = pattern or "stereoLink"
  captured = {}
  -- survive career/level switches, otherwise unloading would end the capture early
  setExtensionUnloadMode("stereoLink_testRunner", "manual")
  originalLog = _G.log
  rawset(_G, "log", function(level, tag, msg, ...)
    if (level == "W" or level == "E") and (tostring(tag):find(pattern, 1, true) or tostring(tag):find("jsonDecode", 1, true) or tostring(msg):find(pattern, 1, true)) then
      table.insert(captured, level .. "|" .. tostring(tag) .. "| " .. tostring(msg))
    end
    return originalLog(level, tag, msg, ...)
  end)
  return true
end

local function stopCapture()
  if originalLog then
    rawset(_G, "log", originalLog)
    originalLog = nil
  end
  return captured
end

M.onExtensionUnloaded = stopCapture -- never leave log() wrapped after a reload
M.runCases = runCases
M.runAll = runAll
M.startCapture = startCapture
M.stopCapture = stopCapture
M.flushLog = flushLog

return M
