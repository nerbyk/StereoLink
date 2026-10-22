// UI side of StereoLink, loaded once at UI start-up (ui/modModules convention).
// Lua (lua/ge/extensions/stereoLink.lua) does the networking and sends messages here;
// this module plays the audio, answers the sources' requests and shows the head unit overlay.

import { answerChallenge, streamKeys } from './airplay.js'
import { Player } from './player.js'
import { registerHeadUnit } from './headUnit.js'

const LUA = 'stereoLink'

// JSON string literals are valid Lua string literals for the ASCII we send (base64, commands).
const luaString = value => JSON.stringify(String(value))

function callLua(code) {
  if (window.bngApi) window.bngApi.engineLua(code)
}

// The source that asked is waiting for this (and times out without it).
function replyToLua(message, value) {
  // after a UI reload Lua resends the running stream without an id: nobody waits for that one
  if (!Number.isInteger(message.id)) return
  callLua(`${LUA}.uiReply(${luaString(message.source)}, ${message.id}, ${luaString(value)})`)
}

function createListeners() {
  const listeners = new Set()
  return {
    add(fn) { listeners.add(fn); return () => listeners.delete(fn) },
    emit(value) {
      for (const fn of listeners) {
        try { fn(value) } catch (e) { console.error('StereoLink listener failed', e) }
      }
    },
  }
}

const player = new Player()
const stateListeners = createListeners()
const coverListeners = createListeners()

// What the head unit works with. Lua owns the state; this relays it and the button presses.
const multimedia = {
  player,
  state: {},
  cover: null,

  subscribe(fn) {
    fn(this.state)
    return stateListeners.add(fn)
  },

  onCover(fn) { return coverListeners.add(fn) },

  powerOn() {
    player.unlock()
    callLua(`${LUA}.uiPower(true)`)
  },

  powerOff() {
    player.suspend()
    callLua(`${LUA}.uiPower(false)`)
  },

  // 'playpause' | 'next' | 'prev', forwarded to the phone
  control(command) { callLua(`${LUA}.uiControl(${luaString(command)})`) },

  // The phone volume, 0..1. Shown at once; Lua presses the phone's volume buttons to match.
  setVolume(value) {
    const volume = Math.round(Math.max(0, Math.min(1, value)) * 1000) / 1000
    callLua(`${LUA}.uiSetVolume(${volume})`)
    setState({ ...multimedia.state, phoneVolume: volume })
  },

  // applied here at once, so quick wheel steps add up before Lua's state comes back
  setCarVolume(value) {
    const volume = Math.round(Math.max(0, Math.min(1, value)) * 100) / 100
    callLua(`${LUA}.uiSetCarVolume(${volume})`)
    setState({ ...multimedia.state, carVolume: volume })
  },

  // a checkbox of the settings panel; Lua checks the key against its list of options
  setOption(key, on) {
    const value = on === true
    callLua(`${LUA}.uiSetOption(${luaString(key)}, ${value})`)
    setState({ ...multimedia.state, options: { ...multimedia.state.options, [key]: value } })
  },
}

function setState(state) {
  multimedia.state = state
  stateListeners.emit(state)
}

function setCover(cover) {
  multimedia.cover = cover && cover.data || null
  coverListeners.emit(multimedia.cover)
}

async function startStream(message) {
  await player.start({ codec: message.codec, fmtp: message.fmtp, ...streamKeys(message) })
  return 'ok'
}

// Lua waits for an answer to these; `failed` is what it gets when the work throws.
const requests = {
  challenge: { run: answerChallenge, failed: () => '' }, // Lua then answers without Apple-Response
  stream: { run: startStream, failed: e => e.message },
}

const events = {
  audio: message => player.push(message.packets),
  flush: () => player.flush(),
  teardown: () => player.stop(),
  volume: message => player.setPhoneVolume(message.value),
  ambient: message => player.setAmbient(message.level, message.muffle),
}

async function answer(message, request) {
  let value
  try {
    value = await request.run(message)
  } catch (e) {
    console.error(`StereoLink: ${message.type} failed`, e)
    value = request.failed(e)
  }
  replyToLua(message, value)
}

function handle(message) {
  const request = requests[message.type]
  if (request) return answer(message, request)
  const event = events[message.type]
  if (!event) return
  try {
    event(message)
  } catch (e) {
    console.error(`StereoLink: ${message.type} failed`, e)
  }
}

// for the console and in-game checks
window.StereoLink = { diagnostics: () => player.diagnostics() }

// Audio stays locked until the user clicks something; any click in the game UI will do.
document.addEventListener('pointerdown', () => {
  if (multimedia.state.power && !player.audible) player.unlock()
}, true)

const module = angular.module('stereoLink', [])
registerHeadUnit(module, multimedia)

module.run(['$rootScope', '$compile', ($rootScope, $compile) => {
  $rootScope.$on('StereoLinkBatch', (event, messages) => {
    for (const message of messages) handle(message)
  })
  $rootScope.$on('StereoLinkState', (event, state) => setState(state))
  $rootScope.$on('StereoLinkCover', (event, cover) => setCover(cover))

  // The overlay lives outside the UI apps layout, so the mod works without any setup.
  const host = document.createElement('div')
  host.id = 'stereo-link-overlay'
  host.innerHTML = '<sl-overlay></sl-overlay>'
  document.body.appendChild(host)
  $compile(host)($rootScope.$new(true))

  callLua(`if ${LUA} then ${LUA}.uiReady() end`)
}])
