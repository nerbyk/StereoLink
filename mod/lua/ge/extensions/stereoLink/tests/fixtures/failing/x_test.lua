-- Fixture for runner_test: one passing and one failing case.
local cases = {}

function cases.a() end

function cases.b() error("fixture boom") end

return cases
