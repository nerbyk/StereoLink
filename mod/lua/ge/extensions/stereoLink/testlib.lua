-- Minimal assertion helpers for stereoLink in-game tests.
-- Pure Lua, no engine dependencies. Every assert raises an error with a readable message.

local M = {}

local function fmt(v)
  if type(v) == "string" then return string.format("%q", v) end
  return tostring(v)
end

local function fail(msg, userMsg)
  if userMsg then msg = userMsg .. ": " .. msg end
  error(msg, 3)
end

function M.eq(actual, expected, msg)
  if actual ~= expected then
    fail("expected " .. fmt(expected) .. ", got " .. fmt(actual), msg)
  end
end

function M.near(actual, expected, eps, msg)
  eps = eps or 1e-6
  -- written as "not <=" so that NaN fails too
  if type(actual) ~= "number" or not (math.abs(actual - expected) <= eps) then -- luacheck: ignore 581
    fail("expected " .. fmt(expected) .. " ±" .. eps .. ", got " .. fmt(actual), msg)
  end
end

function M.truthy(v, msg)
  if not v then fail("expected truthy, got " .. fmt(v), msg) end
end

function M.falsy(v, msg)
  if v then fail("expected falsy, got " .. fmt(v), msg) end
end

-- Asserts that fn raises an error; returns the error message.
function M.errors(fn, msg)
  local ok, err = pcall(fn)
  if ok then fail("expected an error, none raised", msg) end
  return err
end

return M
