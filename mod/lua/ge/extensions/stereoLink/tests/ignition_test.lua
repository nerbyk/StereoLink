local t = require("stereoLink/testlib")
local ignition = require("stereoLink/ignition")

local cases = {}

-- runs {vehicle, engineOn, playing} steps a second apart and returns the actions, "-" for none
local function run(steps)
  local state, actions = {}, {}
  for i, step in ipairs(steps) do
    local action
    state, action = ignition.decide(state, step[1], step[2], step[3], 100 + i)
    table.insert(actions, action or "-")
  end
  return table.concat(actions, ",")
end

function cases.engineOffPausesAndEngineOnResumes()
  t.eq(run({ { 1, true, true }, { 1, false, true }, { 1, false, false }, { 1, true, false } }), "-,pause,-,resume")
end

function cases.aPauseThePlayerMadeStays()
  t.eq(run({ { 1, true, false }, { 1, false, false }, { 1, true, false } }), "-,-,-")
end

function cases.musicStartedByHandWithTheEngineOffIsLeftAlone()
  -- paused by the engine, then the player pressed play while parked
  local steps = { { 1, true, true }, { 1, false, true }, { 1, false, false }, { 1, false, false },
    { 1, false, false }, { 1, false, true }, { 1, true, true } }
  t.eq(run(steps), "-,pause,-,-,-,-,-", "starting the engine must not press play/pause again")
end

function cases.nothingHappensWhileTheEngineStateIsUnknown()
  t.eq(run({ { 1, nil, true }, { 1, false, true }, { 1, nil, true }, { 1, true, true } }), "-,-,-,-")
end

function cases.anotherCarStartsFresh()
  t.eq(run({ { 1, true, true }, { 2, false, true }, { 2, true, true } }), "-,-,-",
    "switching to a parked car is not turning the engine off")
end

function cases.walkingAwayDoesNotPause()
  t.eq(run({ { 1, true, true }, { nil, nil, true }, { 1, true, true } }), "-,-,-")
end

function cases.engineOffWhileNothingPlaysDoesNothing()
  t.eq(run({ { 1, true, false }, { 1, false, false } }), "-,-")
end

function cases.thePauseItPressedIsNotMistakenForThePlayer()
  -- after the press the head unit still says "playing" for a moment
  t.eq(run({ { 1, true, true }, { 1, false, true }, { 1, false, true }, { 1, false, false }, { 1, true, false } }),
    "-,pause,-,-,resume")
end

return cases
