local t = require("stereoLink/testlib")
local hostModule = require("stereoLink/host")

local cases = {}

-- A host with fake engine parts: what went to the UI, the artwork shown and a hand-set clock.
local function newRig()
  local rig = { sent = {}, covers = {}, time = 100 }
  rig.host = hostModule.new({
    send = function(message) table.insert(rig.sent, message) end,
    now = function() return rig.time end,
    showCover = function(seq, data) table.insert(rig.covers, { seq = seq, data = data }) end,
    changed = function() end,
    rememberedVolume = function() return rig.remembered end,
    rememberVolume = function(value) rig.remembered = value end,
  })
  return rig
end

local function fakeSource(id, withRelease)
  local source = { id = id, label = id:upper(), releases = 0, controls = {} }
  if withRelease then
    source.release = function() source.releases = source.releases + 1 end
  end
  source.canControl = function() return true end
  source.control = function(command) table.insert(source.controls, command) end
  source.volumes = {}
  source.setVolume = function(value)
    table.insert(source.volumes, value)
    return true
  end
  return source
end

local function sentTypes(rig)
  local types = {}
  for _, message in ipairs(rig.sent) do table.insert(types, message.type) end
  return table.concat(types, ",")
end

local function stream(id)
  return { type = "stream", id = id, codec = "alac", fmtp = "96 352 0 16 40 10 14 2 255 0 0 44100" }
end

local function audio() return { type = "audio", packets = {} } end

function cases.streamFromBReleasesA()
  local rig = newRig()
  local a, b = fakeSource("a", true), fakeSource("b", true)
  rig.host.hostFor(a).toUi(stream(1))
  rig.host.hostFor(b).toUi(stream(1))
  t.eq(a.releases, 1, "the replaced source lets its phone go")
  t.eq(b.releases, 0)
  t.eq(sentTypes(rig), "stream,stream")
  t.eq(rig.sent[2].source, "b")
end

function cases.aSourceWithoutReleaseIsReplacedQuietly()
  local rig = newRig()
  local a, b = fakeSource("a", false), fakeSource("b", true)
  rig.host.hostFor(a).toUi(stream(1))
  rig.host.hostFor(b).toUi(stream(1))
  rig.host.hostFor(b).toUi(audio())
  t.eq(sentTypes(rig), "stream,stream,audio")
end

function cases.sessionFromBReleasesA()
  local rig = newRig()
  local a, b = fakeSource("a", true), fakeSource("b", true)
  rig.host.hostFor(a).onSession({ device = "iPhone" })
  rig.host.hostFor(b).onSession({ device = "Pixel" })
  t.eq(a.releases, 1)
  local state = rig.host.state()
  t.eq(state.connected, true)
  t.eq(state.source, "B")
  t.eq(state.device, "Pixel")
end

function cases.aNewStreamFromTheSameSourceKeepsItsSession()
  local rig = newRig()
  local a = fakeSource("a", true)
  local hostA = rig.host.hostFor(a)
  hostA.onSession({ device = "iPhone" })
  hostA.toUi(stream(1))
  hostA.toUi(stream(2))
  t.eq(a.releases, 0)
  t.eq(rig.host.state().connected, true)
end

function cases.audioFromAAfterBCapturedIsNotSent()
  local rig = newRig()
  local a, b = fakeSource("a", false), fakeSource("b", true)
  local hostA = rig.host.hostFor(a)
  hostA.toUi(stream(1))
  rig.host.hostFor(b).toUi(stream(1))
  rig.sent = {}
  hostA.toUi(audio())
  hostA.toUi({ type = "flush" })
  hostA.toUi({ type = "teardown" })
  t.eq(sentTypes(rig), "")
  t.eq(rig.host.state().playing, false, "audio from a replaced source does not start the clock")
end

function cases.callbacksFromAnInactiveSourceAreIgnored()
  local rig = newRig()
  local a, b = fakeSource("a", false), fakeSource("b", true)
  local hostA, hostB = rig.host.hostFor(a), rig.host.hostFor(b)
  hostB.onSession({ device = "Pixel" })
  hostB.onTrack({ title = "B song", artist = "B artist", album = "B album" })
  hostB.onProgress(10, 200)
  rig.sent = {}

  hostA.onVolume(0.9)
  hostA.onTrack({ title = "A song", artist = "A artist", album = "A album" })
  hostA.onCover("data:image/png;base64,AAAA")
  hostA.onProgress(50, 300)

  t.eq(sentTypes(rig), "", "no volume message")
  t.eq(#rig.covers, 0, "no artwork")
  local state = rig.host.state()
  t.eq(state.title, "B song")
  t.eq(state.artist, "B artist")
  t.eq(state.album, "B album")
  t.eq(state.position, 10)
  t.eq(state.duration, 200)
  rig.host.replay()
  t.eq(rig.sent[1].value, 0.25, "the phone volume stays the initial one")
end

function cases.teardownBeforeSessionEndIsDelivered()
  local rig = newRig()
  local b = fakeSource("b", true)
  local hostB = rig.host.hostFor(b)
  hostB.onSession({ device = "Pixel" })
  hostB.toUi(stream(1))
  hostB.toUi({ type = "teardown" })
  hostB.onSession(nil, "closed")
  t.eq(sentTypes(rig), "stream,teardown", "the UI gets the teardown")
  t.eq(rig.host.state().connected, false)
  t.eq(b.releases, 0, "ending its own session is not a release")
end

function cases.theEndOfAReplacedSessionIsIgnored()
  local rig = newRig()
  local a, b = fakeSource("a", false), fakeSource("b", true)
  local hostA = rig.host.hostFor(a)
  hostA.onSession({ device = "iPhone" })
  rig.host.hostFor(b).onSession({ device = "Pixel" })
  hostA.onSession(nil, "closed")
  local state = rig.host.state()
  t.eq(state.connected, true)
  t.eq(state.device, "Pixel")
end

function cases.endingTheSessionTakesTheCoverAway()
  local rig = newRig()
  local b = fakeSource("b", true)
  local hostB = rig.host.hostFor(b)
  hostB.onSession({})
  hostB.onCover("data:image/png;base64,AAAA")
  hostB.onSession(nil, "closed")
  t.eq(#rig.covers, 2)
  t.eq(rig.covers[2].data, nil)
  t.truthy(rig.covers[2].seq > rig.covers[1].seq, "a newer seq, so the UI does not skip it")
end

function cases.pauseDetectedOneSecondLaterFreezesAtLastPacket()
  local rig = newRig()
  local hostB = rig.host.hostFor(fakeSource("b", true))
  hostB.onSession({})
  hostB.toUi(stream(1))
  hostB.onProgress(10, 200)
  hostB.toUi(audio())
  t.eq(rig.host.state().playing, true)
  rig.time = 104
  hostB.toUi(audio()) -- the last packet before the pause

  rig.time = 104.5
  rig.host.update()
  t.eq(rig.host.state().playing, true, "half a second without audio is not a pause yet")

  rig.time = 105.2
  rig.host.update()
  local state = rig.host.state()
  t.eq(state.playing, false)
  t.near(state.position, 14, 1e-9, "stopped at the last packet, not when the pause was noticed")
  rig.time = 500
  t.near(rig.host.state().position, 14, 1e-9, "still there much later")
end

function cases.resumeAfterAPauseCountsFromTheResume()
  local rig = newRig()
  local hostB = rig.host.hostFor(fakeSource("b", true))
  hostB.onSession({})
  hostB.toUi(stream(1))
  hostB.onProgress(10, 200)
  hostB.toUi(audio())
  rig.time = 104
  hostB.toUi(audio())
  rig.time = 105.2
  rig.host.update()

  rig.time = 300
  hostB.toUi(audio())
  t.eq(rig.host.state().playing, true)
  rig.time = 302
  t.near(rig.host.state().position, 16, 1e-9)
end

function cases.uiReadyResendsTheStreamWithoutId()
  local rig = newRig()
  local hostB = rig.host.hostFor(fakeSource("b", true))
  hostB.onSession({ device = "Pixel" })
  local original = stream(7)
  hostB.toUi(original)
  hostB.onVolume(0.6)
  hostB.onCover("data:image/png;base64,AAAA")
  rig.sent, rig.covers = {}, {}

  rig.host.replay()
  t.eq(sentTypes(rig), "volume,stream")
  t.near(rig.sent[1].value, 0.36, 1e-9, "the player gets the gain: the slider position squared")
  local resent = rig.sent[2]
  t.eq(resent.id, nil, "nobody waits for an answer to the resent stream")
  t.eq(resent.codec, "alac")
  t.eq(resent.fmtp, original.fmtp)
  t.eq(resent.source, "b")
  t.eq(original.id, 7, "the stream that went out first is not changed")
  t.eq(#rig.covers, 1)
  t.eq(rig.covers[1].seq, 1, "the same artwork keeps its seq")
  t.eq(rig.covers[1].data, "data:image/png;base64,AAAA")
end

function cases.uiReadyWithoutASessionSendsOnlyTheVolume()
  local rig = newRig()
  rig.host.replay()
  t.eq(sentTypes(rig), "volume")
  t.eq(rig.sent[1].value, 0.25)
  t.eq(#rig.covers, 0)
end

function cases.controlGoesToTheConnectedSourceOnly()
  local rig = newRig()
  local b = fakeSource("b", true)
  rig.host.control("next")
  rig.host.hostFor(b).onSession({})
  rig.host.control("playpause")
  t.eq(table.concat(b.controls, ","), "playpause")
end

local function lastVolumeMessage(rig)
  for i = #rig.sent, 1, -1 do
    if rig.sent[i].type == "volume" then return rig.sent[i] end
  end
end

function cases.phoneVolumeGoesToTheScreenAndThePlayer()
  local rig = newRig()
  local hostB = rig.host.hostFor(fakeSource("b", true))
  hostB.onSession({})
  hostB.onVolume(0.5)
  t.eq(rig.host.state().phoneVolume, 0.5, "the screen shows the slider position")
  t.near(lastVolumeMessage(rig).value, 0.25, 1e-9, "the player gets the gain")
end

function cases.phoneVolumeStartsAtAirPlaysDefault()
  local rig = newRig()
  t.eq(rig.host.state().phoneVolume, 0.5)
end

function cases.setVolumeAppliesAtOnceAndTellsTheSource()
  local rig = newRig()
  local b = fakeSource("b", true)
  rig.host.hostFor(b).onSession({})
  rig.host.setVolume(0.8)
  t.eq(rig.host.state().phoneVolume, 0.8)
  t.near(lastVolumeMessage(rig).value, 0.64, 1e-9, "heard at once, before the phone answers")
  t.eq(table.concat(b.volumes, ","), "0.8")
end

function cases.setVolumeWithoutAConnectedSourceStaysLocal()
  local rig = newRig()
  local b = fakeSource("b", true)
  rig.host.hostFor(b) -- started, but no phone yet
  rig.host.setVolume(0.8)
  t.eq(rig.host.state().phoneVolume, 0.8)
  t.near(lastVolumeMessage(rig).value, 0.64, 1e-9)
  t.eq(#b.volumes, 0)
end

function cases.setVolumeWorksWithASourceThatCannotSetIt()
  local rig = newRig()
  local b = fakeSource("b", true)
  b.setVolume = nil
  rig.host.hostFor(b).onSession({})
  rig.host.setVolume(0.3)
  t.eq(rig.host.state().phoneVolume, 0.3)
  t.near(lastVolumeMessage(rig).value, 0.09, 1e-9)
end

function cases.setVolumeIsClampedAndIgnoresGarbage()
  local rig = newRig()
  rig.host.setVolume(5)
  t.eq(rig.host.state().phoneVolume, 1)
  rig.host.setVolume(-1)
  t.eq(rig.host.state().phoneVolume, 0)
  rig.host.setVolume("abc")
  t.eq(rig.host.state().phoneVolume, 0, "unchanged")
end

-- The phone answers every request it got while the wheel turned; those echoes are older than
-- the number on the screen and must not pull it back. The phone still has the last word.
function cases.phoneEchoesWhileTheWheelTurnsDoNotPullTheNumberBack()
  local rig = newRig()
  local hostB = rig.host.hostFor(fakeSource("b", true))
  hostB.onSession({})
  rig.host.setVolume(0.8)
  rig.time = 100.3
  hostB.onVolume(0.6)
  t.eq(rig.host.state().phoneVolume, 0.8, "an echo of an older request")
  rig.time = 100.5
  hostB.onVolume(0.75)
  rig.host.update()
  t.eq(rig.host.state().phoneVolume, 0.8, "still settling")
  rig.time = 101.5
  rig.host.update()
  t.eq(rig.host.state().phoneVolume, 0.75, "the phone's last report wins once the wheel settled")
  t.near(lastVolumeMessage(rig).value, 0.5625, 1e-9)
end

function cases.phoneReportAfterTheWheelSettledAppliesAtOnce()
  local rig = newRig()
  local hostB = rig.host.hostFor(fakeSource("b", true))
  hostB.onSession({})
  rig.host.setVolume(0.8)
  rig.time = 110
  hostB.onVolume(0.2)
  t.eq(rig.host.state().phoneVolume, 0.2)
end

function cases.mutedPhoneStaysMuted()
  local rig = newRig()
  local hostB = rig.host.hostFor(fakeSource("b", true))
  hostB.onSession({})
  hostB.onVolume(0)
  rig.time = 200
  rig.host.update()
  rig.sent = {}
  rig.host.replay()
  t.eq(rig.sent[1].value, 0, "a reloaded UI stays silent")
  t.eq(rig.host.state().phoneVolume, 0)
end

function cases.aNewSessionPutsTheRememberedVolumeBack()
  local rig = newRig()
  rig.remembered = 0.8
  local b = fakeSource("b", true)
  local host = rig.host.hostFor(b)
  host.onSession({})
  host.onVolume(1 / 3) -- iOS starts at its own default for this speaker
  t.eq(rig.host.state().phoneVolume, 0.8)
  t.eq(table.concat(b.volumes, ","), "0.8", "the phone is moved to it")
end

function cases.laterReportsFromThePhoneAreTaken()
  local rig = newRig()
  rig.remembered = 0.8
  local b = fakeSource("b", true)
  local host = rig.host.hostFor(b)
  host.onSession({})
  host.onVolume(1 / 3)
  rig.time = rig.time + 5
  host.onVolume(0.4) -- the player moved the slider on the phone
  t.eq(rig.host.state().phoneVolume, 0.4)
  t.eq(rig.remembered, 0.4, "remembered for the next session")
end

function cases.withoutARememberedVolumeThePhoneDecides()
  local rig = newRig()
  local b = fakeSource("b", true)
  local host = rig.host.hostFor(b)
  host.onSession({})
  host.onVolume(0.6)
  t.eq(rig.host.state().phoneVolume, 0.6)
  t.eq(#b.volumes, 0, "nothing sent back")
  t.eq(rig.remembered, 0.6)
end

function cases.everySessionRestoresOnce()
  local rig = newRig()
  rig.remembered = 0.8
  local b = fakeSource("b", true)
  local host = rig.host.hostFor(b)
  host.onSession({})
  host.onVolume(1 / 3)
  host.onSession(nil, "teardown")
  rig.time = rig.time + 5
  host.onSession({})
  host.onVolume(0.25)
  t.eq(table.concat(b.volumes, ","), "0.8,0.8")
end

function cases.aPausedPhoneStaysConnected()
  local rig = newRig()
  local b = fakeSource("b", true)
  local host = rig.host.hostFor(b)
  host.toUi(stream(1))
  host.onSession({})
  host.onTrack({ title = "Song", artist = "Band" })
  host.toUi({ type = "teardown" }) -- iOS ends the stream on pause
  host.onStreamEnded()
  local state = rig.host.state()
  t.eq(state.connected, true, "the phone still has the head unit selected")
  t.eq(state.title, "Song")
  rig.host.control("playpause")
  t.eq(table.concat(b.controls, ","), "playpause", "play goes to the phone")
  host.onSession(nil, "paused too long")
  t.eq(rig.host.state().connected, false)
end

function cases.aPausedPhoneDoesNotResendItsOldStream()
  local rig = newRig()
  local host = rig.host.hostFor(fakeSource("b", true))
  host.toUi(stream(1))
  host.onSession({})
  host.onStreamEnded()
  rig.sent = {}
  rig.host.replay()
  t.eq(sentTypes(rig), "volume", "a reloaded UI gets no stream that has ended")
end

return cases
