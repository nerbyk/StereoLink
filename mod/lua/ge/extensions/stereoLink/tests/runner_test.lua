local t = require("stereoLink/testlib")
local runner = require("stereoLink/testRunner")

local cases = {}

function cases.eqPasses()
  t.eq(2 + 2, 4)
end

function cases.eqFailsWithMessage()
  local err = t.errors(function() t.eq(1, 2, "sum") end)
  t.truthy(tostring(err):find("sum: expected 2, got 1", 1, true), tostring(err))
end

function cases.nearToleratesEpsilon()
  t.near(0.1 + 0.2, 0.3, 1e-9)
  t.errors(function() t.near(1, 1.1, 0.01) end)
  t.errors(function() t.near(0/0, 1) end, "NaN must fail")
end

local fixturesDir = "/lua/ge/extensions/stereoLink/tests/fixtures/"

function cases.runAllReportsFailingCase()
  local summary = runner.runAll(fixturesDir .. "failing/")
  t.truthy(summary:find("^1 passed, 1 failed %(1 files%)"), summary)
  t.truthy(summary:find("FAIL x_test.b: ", 1, true), summary)
  t.truthy(summary:find("fixture boom", 1, true), summary)
end

function cases.runAllReportsBrokenFile()
  local summary = runner.runAll(fixturesDir .. "broken/")
  t.truthy(summary:find("^0 passed, 1 failed"), summary)
  t.truthy(summary:find("FAIL y_test (load): test file must return a table", 1, true), summary)
end

function cases.truthyFalsy()
  t.truthy(1); t.falsy(nil); t.falsy(false)
  t.errors(function() t.truthy(false) end)
end

function cases.errorsFailsWhenNothingRaised()
  local ok = pcall(t.errors, function() end)
  t.falsy(ok)
end

-- One failing case is reported by name and does not stop the others.
function cases.failingCaseIsIsolated()
  local ran = {}
  local p, f, failures = runner.runCases({
    a = function() ran.a = true end,
    b = function() error("boom") end,
    c = function() ran.c = true end,
  }, "fake.")
  t.eq(p, 2); t.eq(f, 1)
  t.truthy(ran.a); t.truthy(ran.c)
  t.eq(failures[1].name, "fake.b")
  t.truthy(failures[1].err:find("boom", 1, true))
end

return cases
