local t = require("stereoLink/testlib")
local volume = require("stereoLink/airplay/volume")

local cases = {}

function cases.stepsToSendAreAtMostTheWholeSlider()
  t.eq(volume.stepsToSend(0, 1), 16)
  t.eq(volume.stepsToSend(1, 0), -16)
  t.eq(volume.stepsToSend(-1, 2), 16, "clamped")
  t.eq(volume.stepsToSend(0.5, 0.75), 4)
  t.eq(volume.stepsToSend(0.5, 0.52), 0, "less than half a step sends nothing")
end

function cases.sliderStartsAtTheInitialVolume()
  t.eq(volume.slider().get(), volume.INITIAL_VOLUME)
  t.eq(volume.INITIAL_VOLUME, 0.5)
  t.eq(volume.toDb(volume.INITIAL_VOLUME), -15, "AirPlay's starting volume")
end

function cases.sliderTakesReportsWhenNothingIsPressed()
  local slider = volume.slider()
  t.truthy(slider.report(0.3, 100))
  t.eq(slider.get(), 0.3)
end

function cases.sliderIgnoresLateReportsWhilePressesAreOnTheirWay()
  local slider = volume.slider()
  slider.pressed(4, 100)
  t.eq(slider.get(), 0.75)
  t.falsy(slider.report(0.5625, 100.1), "the echo of the first press")
  t.eq(slider.get(), 0.75)
  t.eq(volume.stepsToSend(slider.get(), 0.875), 2, "counted from where the presses put it")
end

function cases.sliderIgnoresReportsUntilTheSettleTime()
  local slider = volume.slider()
  slider.pressed(-2, 100)
  slider.pressDone(100.1)
  slider.pressDone(100.2)
  t.falsy(slider.report(0.4375, 100.5))
  t.eq(slider.get(), 0.375)
  t.truthy(slider.report(0.4, 100.2 + volume.STEPS_SETTLE + 0.01), "after a pause the phone corrects")
  t.eq(slider.get(), 0.4)
end

function cases.sliderStaysOnTheScale()
  local slider = volume.slider()
  slider.pressed(16, 100)
  t.eq(slider.get(), 1)
end

return cases
