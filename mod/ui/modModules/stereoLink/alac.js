// Apple Lossless (ALAC) decoder, 16 bit mono/stereo.
//
// Ported to JavaScript from FFmpeg's libavcodec/alac.c and alacdsp.c
// Copyright (c) 2005 David Hammerton and the FFmpeg developers.
// Modified in 2026: translated from C to JavaScript, reduced to 16 bit output,
// stream format and frame length checks added.
//
// This file is part of a derivative work of FFmpeg and is licensed under the
// GNU Lesser General Public License, version 2.1 or (at your option) any later version.
// It is distributed WITHOUT ANY WARRANTY. Full text: LICENSES/LGPL-2.1.txt (in the release zip:
// mod_info/stereo_link/LGPL-2.1.txt). The rest of this mod
// is MIT licensed.

class BitReader {
  constructor(buf) { this.buf = buf; this.pos = 0; this.size = buf.length * 8 }
  left() { return this.size - this.pos }
  bit() {
    const b = (this.buf[this.pos >> 3] >> (7 - (this.pos & 7))) & 1
    this.pos++
    return b
  }
  bits(n) { // n <= 32, unsigned result; reads up to a byte at a time
    let v = 0
    while (n > 0) {
      const avail = 8 - (this.pos & 7)
      const take = avail < n ? avail : n
      const chunk = ((this.buf[this.pos >> 3] | 0) >> (avail - take)) & ((1 << take) - 1)
      v = v * (1 << take) + chunk
      this.pos += take
      n -= take
    }
    return v
  }
  peek(n) { const p = this.pos; const v = this.bits(n); this.pos = p; return v }
  skip(n) { this.pos += n }
  sbits(n) { const v = this.bits(n); return v >= 2 ** (n - 1) ? v - 2 ** n : v }
}

function log2i(x) { return x > 0 ? 31 - Math.clz32(x) : 0 }
function signExtend(v, bits) { const s = 32 - bits; return (v << s) >> s }
function signOnly(v) { return v > 0 ? 1 : v < 0 ? -1 : 0 }

const MAX_FRAME_LENGTH = 4096
const SAMPLE_RATES = [44100, 48000]

// The format comes from the network and sizes the buffers, so only what AirPlay sends passes.
function checkFormat({ frameLength, sampleSize, channels, sampleRate }) {
  const ok = Number.isInteger(frameLength) && frameLength >= 1 && frameLength <= MAX_FRAME_LENGTH &&
    sampleSize === 16 && channels === 2 && SAMPLE_RATES.includes(sampleRate)
  if (!ok) throw new Error(`alac: unsupported format ${frameLength}/${sampleSize}/${channels}/${sampleRate}`)
}

class AlacDecoder {
  // fmtp: "96 352 0 16 40 10 14 2 255 0 0 44100"
  constructor(fmtp) {
    const f = fmtp.trim().split(/\s+/).map(Number)
    this.frameLength = f[1] || 352
    this.sampleSize = f[3] || 16
    this.riceHistoryMult = f[4] || 40
    this.riceInitialHistory = f[5] || 10
    this.riceLimit = f[6] || 14
    this.channels = f[7] || 2
    this.sampleRate = f[11] || 44100
    checkFormat(this)
    const n = this.frameLength
    this.err = [new Int32Array(n), new Int32Array(n)]
    this.out = [new Int32Array(n), new Int32Array(n)]
  }

  decodeScalar(gb, k, bps) {
    let x = 0
    while (x < 9 && gb.bit() === 1) x++
    if (x > 8) return gb.bits(bps)
    if (k !== 1) {
      const extra = gb.peek(k)
      x = x * ((1 << k) - 1)
      if (extra > 1) { x += extra - 1; gb.skip(k) } else gb.skip(k - 1)
    }
    return x
  }

  riceDecompress(gb, out, n, bps, mult) {
    let history = this.riceInitialHistory
    let signModifier = 0
    for (let i = 0; i < n; i++) {
      if (gb.left() <= 0) throw new Error('alac: out of bits')
      let k = Math.min(log2i((history >>> 9) + 3), this.riceLimit)
      let x = this.decodeScalar(gb, k, bps) + signModifier
      signModifier = 0
      out[i] = (x >>> 1) ^ -(x & 1)
      if (x > 0xffff) history = 0xffff
      else history = (history + x * mult - ((history * mult) >>> 9)) >>> 0
      if (history < 128 && i + 1 < n) {
        k = Math.min(7 - log2i(history) + ((history + 16) >> 6), this.riceLimit)
        let block = this.decodeScalar(gb, k, 16)
        if (block > 0) {
          if (block >= n - i) block = n - i - 1
          out.fill(0, i + 1, i + 1 + block)
          i += block
        }
        if (block <= 0xffff) signModifier = 1
        history = 0
      }
    }
  }

  lpcPrediction(err, out, n, bps, coefs, order, quant) {
    out[0] = err[0]
    if (n <= 1) return
    if (!order) { for (let i = 1; i < n; i++) out[i] = err[i]; return }
    if (order === 31) {
      for (let i = 1; i < n; i++) out[i] = signExtend(out[i - 1] + err[i], bps)
      return
    }
    let i = 1
    for (; i <= order && i < n; i++) out[i] = signExtend(out[i - 1] + err[i], bps)
    const round = 2 ** (quant - 1), div = 2 ** quant
    for (; i < n; i++) {
      const base = i - order - 1
      const d = out[base]
      let val = 0
      for (let j = 0; j < order; j++) val = (val + Math.imul(out[base + 1 + j] - d, coefs[j])) | 0
      val = Math.floor((val + round) / div)
      let errVal = err[i]
      val = (val + d + errVal) | 0
      out[i] = signExtend(val, bps)
      const errSign = signOnly(errVal)
      if (errSign) {
        for (let j = 0; j < order && Math.imul(errVal, errSign) > 0; j++) {
          let v = (d - out[base + 1 + j]) | 0
          const sign = signOnly(v) * errSign
          coefs[j] -= sign
          v = Math.imul(v, sign)
          errVal = (errVal - Math.imul(v >> quant, j + 1)) | 0
        }
      }
    }
  }

  // returns [Float32Array left, Float32Array right]
  decode(packet) {
    const gb = new BitReader(packet)
    let nSamples = 0
    let gotEnd = false
    while (gb.left() >= 3) {
      const element = gb.bits(3)
      if (element === 7) { gotEnd = true; break } // END
      if (element !== 1 && element !== 0) throw new Error('alac: element ' + element)
      const channels = element === 1 ? 2 : 1 // CPE or SCE
      gb.skip(4 + 12)
      const hasSize = gb.bit()
      const extraBits = gb.bits(2) << 3
      const bps = this.sampleSize - extraBits + channels - 1
      const compressed = !gb.bit()
      const n = hasSize ? gb.bits(32) : this.frameLength
      if (!n || n > this.frameLength) throw new Error('alac: bad sample count ' + n)
      nSamples = n
      let decorrShift = 0, decorrLeftWeight = 0
      if (compressed) {
        decorrShift = gb.bits(8)
        decorrLeftWeight = gb.bits(8)
        const pt = [], quant = [], mult = [], order = [], coefs = []
        for (let ch = 0; ch < channels; ch++) {
          pt[ch] = gb.bits(4); quant[ch] = gb.bits(4); mult[ch] = gb.bits(3); order[ch] = gb.bits(5)
          coefs[ch] = new Int32Array(32)
          for (let i = order[ch] - 1; i >= 0; i--) coefs[ch][i] = gb.sbits(16)
        }
        if (extraBits) gb.skip(n * channels * extraBits) // 16 bit streams never have these
        for (let ch = 0; ch < channels; ch++) {
          this.riceDecompress(gb, this.err[ch], n, bps, (mult[ch] * this.riceHistoryMult) >> 2)
          if (pt[ch] === 15) this.lpcPrediction(this.err[ch], this.err[ch], n, bps, null, 31, 0)
          this.lpcPrediction(this.err[ch], this.out[ch], n, bps, coefs[ch], order[ch], quant[ch])
        }
      } else {
        if (gb.left() < n * channels * this.sampleSize) throw new Error('alac: out of bits')
        for (let i = 0; i < n; i++)
          for (let ch = 0; ch < channels; ch++) this.out[ch][i] = gb.sbits(this.sampleSize)
      }
      if (channels === 2 && decorrLeftWeight) {
        const a = this.out[0], b = this.out[1]
        for (let i = 0; i < n; i++) {
          let x = a[i], y = b[i]
          x = (x - (Math.imul(y, decorrLeftWeight) >> decorrShift)) | 0
          y = (y + x) | 0
          a[i] = y; b[i] = x
        }
      }
      if (channels === 1) this.out[1].set(this.out[0].subarray(0, n))
    }
    if (!gotEnd) throw new Error('alac: no end tag')
    const L = new Float32Array(nSamples), R = new Float32Array(nSamples)
    for (let i = 0; i < nSamples; i++) { L[i] = this.out[0][i] / 32768; R[i] = this.out[1][i] / 32768 }
    return [L, R]
  }
}

export { AlacDecoder }
