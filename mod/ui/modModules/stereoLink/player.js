// Turns the packet stream from Lua into sound: reorders packets, decrypts and decodes them,
// and schedules the PCM on a Web Audio clock. Web Workers are disabled in BeamNG's browser,
// so decoding runs here, on the UI thread (it is roughly ten times faster than realtime).

import { b64ToBytes, Aes128 } from './crypto.js'
import { AlacDecoder } from './alac.js'

const LEAD_SECONDS = 0.35       // audio kept queued ahead of the play head
const MAX_EXTRA_SECONDS = 0.3   // queued beyond LEAD before the backlog is dropped
const UNDERRUN_SECONDS = 0.02   // closer to the play head than this counts as run dry
const REORDER_SECONDS = 0.12    // how long a late UDP packet may trail its neighbours
const MIN_REORDER_PACKETS = 6
const MAX_JUMP = 250            // about two seconds of packets; beyond that we start over
const MAX_LATE_RUN = 64         // this many stale packets in a row: the sender renumbered
const SEQ_MASK = 0xffff
const SEQ_RANGE = 0x10000
const HALF_SEQ_RANGE = 0x8000   // a packet more than this ahead is really behind
const DEFAULT_FMTP = '96 352 0 16 40 10 14 2 255 0 0 44100'

// Waiting is measured in time, not packets: at low frame rates Lua delivers packets in big
// batches, and a resend from the phone needs a frame or two to come back.
function reorderWindow(alac) {
  return Math.max(MIN_REORDER_PACKETS, Math.ceil(REORDER_SECONDS * alac.sampleRate / alac.frameLength))
}

class Player {
  constructor() {
    this.ctx = null
    this.stream = null      // {aes, iv, alac, reorder (packets)} while a phone is streaming
    this.pending = new Map() // seq -> base64 payload
    this.nextSeq = -1
    this.decodedAny = false
    this.lateRun = 0
    this.nextTime = 0
    this.sources = []
    this.phoneVolume = 1
    this.level = 1           // from the game: cabin / outside / walking
    this.muffle = 0          // 0 clear .. 1 heard through the car body
    this.stats = { packets: 0, decoded: 0, lost: 0, late: 0, resyncs: 0, catchUps: 0, errors: 0, lastError: '' }
    this.generation = 0       // bumped by stop(), so a start() still waiting for its key can tell
  }

  get audible() { return !!this.ctx && this.ctx.state === 'running' }

  // Browsers keep audio locked until a real click, so this is called from click handlers.
  unlock() {
    if (!this.ctx) this.createContext()
    if (this.ctx.state !== 'running') this.ctx.resume()
  }

  // Power off: lets the audio device idle; unlock() wakes it.
  suspend() {
    if (this.audible) this.ctx.suspend()
  }

  createContext() {
    const ctx = new (window.AudioContext || window.webkitAudioContext)({ latencyHint: 'playback' })
    this.gain = ctx.createGain()
    this.filter = ctx.createBiquadFilter()
    this.filter.type = 'lowpass'
    this.filter.frequency.value = 20000
    this.filter.connect(this.gain)
    this.gain.connect(ctx.destination)
    this.ctx = ctx
    this.applyMix()
  }

  setPhoneVolume(value) {
    this.phoneVolume = value
    this.applyMix()
  }

  setAmbient(level, muffle) {
    this.level = level
    this.muffle = muffle
    this.applyMix()
  }

  applyMix() {
    if (!this.ctx) return
    const now = this.ctx.currentTime
    this.gain.gain.setTargetAtTime(this.phoneVolume * this.level, now, 0.08)
    this.filter.frequency.setTargetAtTime(20000 * Math.pow(600 / 20000, this.muffle), now, 0.1)
  }

  // key: AES key bytes, or a promise of them (the source may still be unwrapping it); null when
  // the stream is not encrypted. iv: bytes or null.
  async start({ codec, fmtp, key, iv }) {
    if (codec !== 'alac') throw new Error(`unsupported codec ${codec}`)
    this.stop()
    const generation = this.generation
    const alac = new AlacDecoder(fmtp || DEFAULT_FMTP)
    const aesKey = await key
    if (generation !== this.generation) throw new Error('the stream was stopped while starting')
    this.stream = { aes: aesKey ? new Aes128(aesKey) : null, iv: iv || null, alac, reorder: reorderWindow(alac) }
  }

  stop() {
    this.flush()
    this.stream = null
    this.generation++
  }

  // Drops everything queued (pause / seek on the phone).
  flush() {
    this.stopSources()
    this.pending.clear()
    this.nextSeq = -1
    this.decodedAny = false
    this.lateRun = 0
    this.nextTime = 0
  }

  stopSources() {
    for (const source of this.sources) {
      try { source.stop() } catch (e) { /* already ended */ }
    }
    this.sources = []
  }

  // packets: [[seq, base64 payload], ...]; seq is 16 bit and wraps around.
  push(packets) {
    if (!this.stream) return
    for (const [seq, payload] of packets) {
      this.stats.packets++
      if (this.accept(seq)) this.pending.set(seq, payload)
    }
    this.drain()
  }

  // Places a packet relative to the play head; false drops it as late.
  accept(seq) {
    if (this.nextSeq < 0) this.nextSeq = seq
    const ahead = (seq - this.nextSeq) & SEQ_MASK
    if (ahead < HALF_SEQ_RANGE) {
      this.lateRun = 0
      // a jump this far (level loading, a frozen frame) is not worth filling with silence
      if (ahead > MAX_JUMP) this.resync(seq)
      return true
    }
    if (!this.decodedAny && ahead >= SEQ_RANGE - this.stream.reorder) {
      // nothing played yet, so an earlier packet arriving late still becomes the start
      this.nextSeq = seq
      return true
    }
    // A stray old packet must not restart playback; only a long run of them means the
    // sender started numbering again without a flush.
    this.lateRun++
    if (this.lateRun < MAX_LATE_RUN) {
      this.stats.late++
      return false
    }
    this.resync(seq)
    return true
  }

  resync(seq) {
    this.flush()
    this.nextSeq = seq
    this.stats.resyncs++
  }

  drain() {
    while (this.pending.size > 0) {
      if (this.pending.has(this.nextSeq)) {
        const payload = this.pending.get(this.nextSeq)
        this.pending.delete(this.nextSeq)
        this.decodedAny = true
        this.play(payload)
      } else if (this.pending.size > this.stream.reorder) {
        this.stats.lost++
        this.play(null)
      } else {
        break
      }
      this.nextSeq = (this.nextSeq + 1) & SEQ_MASK
    }
  }

  // payload null is a lost packet. Locked audio would only pile up, so nothing is decoded
  // until the user clicks; a broken packet plays as silence to keep the timing.
  play(payload) {
    if (!this.audible) return
    if (payload === null) return this.silence()
    try {
      const [left, right] = this.decode(payload)
      this.stats.decoded++
      this.schedule(left, right)
    } catch (e) {
      this.noteError(e)
      this.silence()
    }
  }

  noteError(e) {
    this.stats.errors++
    this.stats.lastError = String(e && e.message || e)
  }

  decode(payload) {
    const { aes, iv, alac } = this.stream
    let data = b64ToBytes(payload)
    if (aes) data = aes.decryptCbc(data, iv)
    return alac.decode(data)
  }

  // A gap whose time has already gone by is not filled: that would only add delay.
  // Scheduling can fail too (createBuffer), and drain must keep going, so nothing escapes here.
  silence() {
    if (this.nextTime < this.ctx.currentTime + UNDERRUN_SECONDS) return
    const frames = this.stream.alac.frameLength
    try {
      this.schedule(new Float32Array(frames), new Float32Array(frames))
    } catch (e) {
      this.noteError(e)
    }
  }

  schedule(left, right) {
    const ctx = this.ctx
    const rate = this.stream.alac.sampleRate
    const now = ctx.currentTime
    if (this.nextTime < now + UNDERRUN_SECONDS) this.nextTime = now + LEAD_SECONDS
    else if (this.nextTime > now + LEAD_SECONDS + MAX_EXTRA_SECONDS) this.catchUp(now)
    const buffer = ctx.createBuffer(2, left.length, rate)
    buffer.copyToChannel(left, 0)
    buffer.copyToChannel(right, 1)
    const source = ctx.createBufferSource()
    source.buffer = buffer
    source.connect(this.filter)
    source.start(this.nextTime)
    source.onended = () => {
      const index = this.sources.indexOf(source)
      if (index >= 0) this.sources.splice(index, 1)
    }
    this.sources.push(source)
    this.nextTime += left.length / rate
  }

  // A frozen frame delivers seconds of packets at once (and the phone's clock drifts from
  // ours). Queuing all of it would delay the music, and the phone's pause and volume, for
  // good, so the backlog is dropped and playback continues LEAD ahead.
  catchUp(now) {
    this.stopSources()
    this.nextTime = now + LEAD_SECONDS
    this.stats.catchUps++
  }

  diagnostics() {
    return {
      context: this.ctx ? this.ctx.state : 'none',
      streaming: !!this.stream,
      queuedSeconds: this.ctx ? Math.max(0, this.nextTime - this.ctx.currentTime) : 0,
      phoneVolume: this.phoneVolume, // the gain from Lua, not the slider position
      gain: this.gain ? this.gain.gain.value : null,
      ...this.stats,
    }
  }
}

export { Player }
