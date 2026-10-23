// UI codec tests, run inside the game's browser (not shipped in the release zip):
//   import(location.origin + '/ui/modModules/stereoLink/tests/run.js').then(m => m.runAll())
// Resolves to a summary like "17 passed, 0 failed, 0 skipped". The ALAC reference test needs
// tools/fetch-fixtures.ps1 and is skipped without it.

import { b64ToBytes, bytesToB64, appleResponse, decryptAesKey, Aes128, rsaKey } from '../crypto.js'
import { AlacDecoder } from '../alac.js'
import { Player } from '../player.js'
import { streamKeys } from '../airplay.js'
import { coverBackground, SETTINGS } from '../headUnit.js'
import { text } from '../strings.js'

const cases = {}
const SKIPPED = Symbol('skipped')

const range = (from, to) => Array.from({ length: to - from + 1 }, (_, i) => from + i)
const hex = s => Uint8Array.from(s.match(/../g), h => parseInt(h, 16))
const toHex = bytes => Array.from(bytes, b => b.toString(16).padStart(2, '0')).join('')
const bigFrom = bytes => bytes.reduce((x, b) => (x << 8n) | BigInt(b), 0n)

function assertEqual(actual, expected, label) {
  if (actual !== expected) throw new Error(`${label || 'value'}: expected ${expected}, got ${actual}`)
}

function modPow(base, exp, mod) {
  let result = 1n
  base %= mod
  for (; exp > 0n; exp >>= 1n) {
    if (exp & 1n) result = result * base % mod
    base = base * base % mod
  }
  return result
}

cases.aesDecryptsFips197Vector = () => {
  const aes = new Aes128(hex('000102030405060708090a0b0c0d0e0f'))
  const block = hex('69c4e0d86a7b0430d8cdb78070b4c55a')
  aes.decryptBlock(block)
  assertEqual(toHex(block), '00112233445566778899aabbccddeeff')
}

cases.aesCbcLeavesTheTailUnencrypted = () => {
  const aes = new Aes128(new Uint8Array(16))
  const data = new Uint8Array(20).fill(7)
  const out = aes.decryptCbc(data, new Uint8Array(16))
  assertEqual(toHex(out.subarray(16)), '07070707', 'tail')
}

// Verifying with the public exponent recovers the PKCS#1 type 1 block around our data.
cases.appleResponseSignsChallengeIpAndMac = () => {
  const challenge = bytesToB64(hex('00112233445566778899aabbccddeeff'))
  const signature = b64ToBytes(appleResponse(challenge, [192, 168, 1, 2], [1, 2, 3, 4, 5, 6]))
  assertEqual(signature.length, 256, 'signature length')
  const block = modPow(bigFrom(signature), bigFrom(rsaKey.e), bigFrom(rsaKey.n)).toString(16)
  assertEqual(block.slice(0, 5), '1ffff', 'padding')
  assertEqual(block.slice(-64), '00112233445566778899aabbccddeeffc0a80102010203040506000000000000', 'payload')
}

cases.aesKeySurvivesOaepRoundTrip = async () => {
  const b64url = bytes => bytesToB64(bytes).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
  const publicKey = await crypto.subtle.importKey('jwk',
    { kty: 'RSA', n: b64url(rsaKey.n), e: b64url(rsaKey.e), alg: 'RSA-OAEP', ext: true },
    { name: 'RSA-OAEP', hash: 'SHA-1' }, false, ['encrypt'])
  const key = hex('2b7e151628aed2a6abf7158809cf4f3c')
  const encrypted = new Uint8Array(await crypto.subtle.encrypt({ name: 'RSA-OAEP' }, publicKey, key))
  assertEqual(toHex(await decryptAesKey(bytesToB64(encrypted))), toHex(key))
}

// An "escape" frame stores raw samples: element 1 (stereo), 16 header bits, flags, samples, END.
function uncompressedFrame(samples) {
  const bits = []
  const put = (value, count) => { for (let i = count - 1; i >= 0; i--) bits.push((value >> i) & 1) }
  put(1, 3); put(0, 4); put(0, 12); put(0, 1); put(0, 2); put(1, 1)
  for (const [left, right] of samples) { put(left & 0xffff, 16); put(right & 0xffff, 16) }
  put(7, 3)
  while (bits.length % 8) bits.push(0)
  const bytes = new Uint8Array(bits.length / 8)
  bits.forEach((bit, i) => { bytes[i >> 3] |= bit << (7 - (i & 7)) })
  return bytes
}

cases.alacDecodesUncompressedFrame = () => {
  const samples = Array.from({ length: 352 }, (_, i) => [i * 10 - 1000, -i * 7])
  const [left, right] = new AlacDecoder('96 352 0 16 40 10 14 2 255 0 0 44100').decode(uncompressedFrame(samples))
  assertEqual(left.length, 352, 'frames')
  assertEqual(Math.round(left[0] * 32768), -1000, 'first left')
  assertEqual(Math.round(right[351] * 32768), -2457, 'last right')
}

cases.alacRejectsFrameWithoutEndTag = () => {
  const frame = uncompressedFrame([[1, 1]]).subarray(0, 3)
  let failed = false
  try { new AlacDecoder('96 352 0 16 40 10 14 2 255 0 0 44100').decode(frame) } catch (e) { failed = true }
  assertEqual(failed, true, 'throws')
}

function failureOf(fn) {
  try { fn() } catch (e) { return e.message }
  return 'no error'
}

// fmtp comes from the network and sizes the decoder's buffers
cases.alacRejectsFormatsAirPlayNeverSends = () => {
  const bad = [
    '96 100000 0 16 40 10 14 2 255 0 0 44100', // frame length
    '96 352.5 0 16 40 10 14 2 255 0 0 44100',
    '96 352 0 24 40 10 14 2 255 0 0 44100',    // sample size
    '96 352 0 16 40 10 14 6 255 0 0 44100',    // channels
    '96 352 0 16 40 10 14 2 255 0 0 1',        // sample rate
    '96 352 0 16 40 10 14 2 255 0 0 9999999',
  ]
  for (const fmtp of bad) {
    if (!failureOf(() => new AlacDecoder(fmtp)).startsWith('alac: unsupported format')) throw new Error(`accepted ${fmtp}`)
  }
  assertEqual(new AlacDecoder('96 4096 0 16 40 10 14 2 255 0 0 48000').frameLength, 4096, 'largest valid frame')
}

cases.alacStopsWhenRawSamplesRunOut = () => {
  const frame = uncompressedFrame(range(1, 352).map(i => [i, i])).subarray(0, 200)
  assertEqual(failureOf(() => new AlacDecoder('96 352 0 16 40 10 14 2 255 0 0 44100').decode(frame)), 'alac: out of bits')
}

// Pulls ALAC packets out of an m4a: sample sizes (stsz), chunk offsets (stco), samples per chunk (stsc).
function readM4a(bytes) {
  const view = new DataView(bytes.buffer)
  const type = p => String.fromCharCode(bytes[p + 4], bytes[p + 5], bytes[p + 6], bytes[p + 7])
  const find = (path, start = 0, end = bytes.length) => {
    for (let p = start; p + 8 <= end;) {
      const size = view.getUint32(p) || end - p
      if (type(p) === path[0]) return path.length === 1 ? p + 8 : find(path.slice(1), p + 8, p + size)
      p += size
    }
    return -1
  }
  const stbl = ['moov', 'trak', 'mdia', 'minf', 'stbl']
  const at = box => find([...stbl, box])
  const cookie = at('stsd') + 8 + 8 + 28 + 12
  const config = [view.getUint32(cookie), 0, bytes[cookie + 5], bytes[cookie + 6], bytes[cookie + 7], bytes[cookie + 8],
    bytes[cookie + 9], view.getUint16(cookie + 10), view.getUint32(cookie + 12), view.getUint32(cookie + 16), view.getUint32(cookie + 20)]
  const sizes = Array.from({ length: view.getUint32(at('stsz') + 8) }, (_, i) => view.getUint32(at('stsz') + 12 + i * 4))
  const chunks = Array.from({ length: view.getUint32(at('stco') + 4) }, (_, i) => view.getUint32(at('stco') + 8 + i * 4))
  const stsc = Array.from({ length: view.getUint32(at('stsc') + 4) }, (_, i) => ({
    first: view.getUint32(at('stsc') + 8 + i * 12), perChunk: view.getUint32(at('stsc') + 12 + i * 12),
  }))
  const packets = []
  chunks.forEach((offset, chunk) => {
    const perChunk = stsc.filter(entry => entry.first <= chunk + 1).pop().perChunk
    for (let k = 0; k < perChunk && packets.length < sizes.length; k++) {
      packets.push(bytes.subarray(offset, offset + sizes[packets.length]))
      offset += sizes[packets.length - 1]
    }
  })
  return { fmtp: '96 ' + config.join(' '), packets }
}

async function fetchFixture(name) {
  const response = await fetch(`${location.origin}/ui/modModules/stereoLink/tests/fixtures/${name}`)
  return response.ok ? new Uint8Array(await response.arrayBuffer()) : null
}

// Bit-exact against the browser's own FLAC decoder on the same recording.
cases.alacMatchesFlacReference = async () => {
  const m4a = await fetchFixture('luckynight.m4a')
  const flac = await fetchFixture('luckynight.flac')
  if (!m4a || !flac) return SKIPPED
  const { fmtp, packets } = readM4a(m4a)
  const reference = await new OfflineAudioContext(2, 44100, 44100).decodeAudioData(flac.buffer)
  const refLeft = reference.getChannelData(0)
  const refRight = reference.getChannelData(1)
  // compare 16 bit integers: Chrome scales positive samples by 1/32767, we use 1/32768
  const ours = x => Math.round(x * 32768)
  const theirs = x => Math.round(x * (x > 0 ? 32767 : 32768))
  const decoder = new AlacDecoder(fmtp)
  let position = 0
  for (const packet of packets.slice(0, 40)) {
    const [left, right] = decoder.decode(packet)
    for (let i = 0; i < left.length; i++, position++) {
      if (ours(left[i]) !== theirs(refLeft[position]) || ours(right[i]) !== theirs(refRight[position])) {
        throw new Error(`sample ${position} differs: ${ours(left[i])}/${ours(right[i])} vs ${theirs(refLeft[position])}/${theirs(refRight[position])}`)
      }
    }
  }
  return `${position} samples identical`
}

// Web Audio stand-in: the test moves the clock by hand and sees what got scheduled when.
function fakeAudio() {
  const started = []
  const ctx = {
    state: 'running',
    currentTime: 0,
    createBuffer: (channels, length, rate) => ({ duration: length / rate, copyToChannel() {} }),
    createBufferSource: () => ({
      connect() {},
      start(when) { this.when = when; started.push(this) },
      stop() { this.stopped = true },
    }),
  }
  return { ctx, started }
}

const PACKET_SECONDS = 352 / 44100
// what start() works out for this format: ~120 ms is 16 packets
const REORDER_PACKETS = 16

// 352 frames at 44.1 kHz per packet, like an iPhone; decode records the packet's first byte
function stubbedPlayer() {
  const player = new Player()
  const order = []
  const { ctx, started } = fakeAudio()
  player.ctx = ctx
  player.filter = {}
  const frames = () => new Float32Array(352)
  const decode = data => { order.push(data[0]); return [frames(), frames()] }
  const alac = { frameLength: 352, sampleRate: 44100, decode }
  player.stream = { aes: null, iv: null, alac, reorder: REORDER_PACKETS }
  return { player, order, ctx, started }
}

const packet = seq => [seq, bytesToB64([seq & 0xff])]

cases.playerReordersLatePackets = () => {
  const { player, order } = stubbedPlayer()
  player.push([packet(2), packet(1)])
  player.push([packet(3)])
  assertEqual(order.join(','), '1,2,3')
}

// the reorder window is ~120 ms: 16 packets at 352 frames / 44.1 kHz
cases.playerFillsAGapOnceTheWindowIsFull = () => {
  const { player, order } = stubbedPlayer()
  player.push([packet(1)])
  player.push(range(3, 20).map(packet))
  assertEqual(player.stats.lost, 1, 'lost')
  assertEqual(order.join(','), [1, ...range(3, 20)].join(','))
}

cases.playerWaitsAbout120msForALatePacket = () => {
  const { player, order } = stubbedPlayer()
  player.push([packet(1)])
  player.push(range(3, 12).map(packet))
  player.push([packet(2)])
  assertEqual(player.stats.lost, 0, 'lost')
  assertEqual(order.join(','), range(1, 12).join(','))
}

cases.playerTreatsAStalePacketAsLateNotAJump = () => {
  const { player } = stubbedPlayer()
  player.push([packet(1000)])
  player.push([packet(700)])
  assertEqual(player.stats.late, 1, 'late')
  assertEqual(player.stats.resyncs, 0, 'resyncs')
  assertEqual(player.nextSeq, 1001, 'play head')
}

cases.playerFollowsASenderThatRenumberedBackwards = () => {
  const { player, order } = stubbedPlayer()
  player.push([packet(1000)])
  player.push(range(100, 199).map(packet))
  assertEqual(player.stats.resyncs, 1, 'resyncs')
  assertEqual(order[order.length - 1], 199, 'plays the new numbering')
}

// After each 1 s freeze ~125 packets arrive in one batch; the queue must stay near LEAD
// (0.35 s) + 0.3 s instead of keeping the whole backlog.
cases.playerDropsTheBacklogAfterAFrozenFrame = () => {
  const { player, ctx, started } = stubbedPlayer()
  const maxQueued = 0.66
  let seq = 1
  for (let freeze = 1; freeze <= 3; freeze++) {
    ctx.currentTime += 1
    player.push(range(1, 125).map(() => packet(seq++)))
    const queued = player.diagnostics().queuedSeconds
    if (queued > maxQueued) throw new Error(`${queued.toFixed(2)} s queued after freeze ${freeze}`)
    // the dropped backlog must also go quiet, not just leave the clock
    const live = started.filter(source => !source.stopped).length
    if (live > Math.ceil(maxQueued / PACKET_SECONDS)) throw new Error(`${live} sources still queued after freeze ${freeze}`)
  }
  if (player.stats.catchUps === 0) throw new Error('never caught up')
}

cases.playerPlaysABrokenPacketAsSilence = () => {
  const { player, started } = stubbedPlayer()
  const decode = player.stream.alac.decode
  player.stream.alac.decode = data => {
    if (data[0] === 2) throw new Error('broken frame')
    return decode(data)
  }
  player.push([1, 2, 3].map(packet))
  assertEqual(player.stats.errors, 1, 'errors')
  assertEqual(player.stats.decoded, 2, 'decoded')
  assertEqual(started.length, 3, 'scheduled, silence included')
}

// a failing createBuffer must not break the loop that drains the packets
cases.playerKeepsDrainingWhenSchedulingFails = () => {
  const { player, ctx } = stubbedPlayer()
  ctx.createBuffer = () => { throw new Error('no buffer') }
  player.push([1, 2].map(packet))
  assertEqual(player.nextSeq, 3, 'play head moved on')
  assertEqual(player.stats.errors, 4, 'each packet and its silence failed')
  assertEqual(player.stats.lastError, 'no buffer', 'last error')
}

cases.playerDoesNotFillAGapThatAlreadyPlayed = () => {
  const { player, ctx, started } = stubbedPlayer()
  player.push([packet(1)])
  ctx.currentTime = 2
  player.push(range(3, 20).map(packet))
  assertEqual(player.stats.lost, 1, 'lost')
  assertEqual(started.length, player.stats.decoded, 'scheduled only decoded packets')
  assertEqual(started[1].when.toFixed(3), '2.350', 'resumes LEAD ahead')
}

cases.playerSkipsDecodingWhileAudioIsLocked = () => {
  const { player, order, ctx } = stubbedPlayer()
  ctx.state = 'suspended'
  player.push([1, 2, 3].map(packet))
  assertEqual(order.length, 0, 'decoded while locked')
  assertEqual(player.nextSeq, 4, 'play head moved on')
  ctx.state = 'running'
  player.push([packet(4)])
  assertEqual(order.join(','), '4')
}

cases.playerDropsPacketsOlderThanThePlayHead = () => {
  const { player } = stubbedPlayer()
  player.push([packet(10)])
  player.push([packet(9)])
  assertEqual(player.stats.late, 1)
}

cases.playerContinuesAcrossSequenceWrap = () => {
  const { player, order } = stubbedPlayer()
  player.push([packet(65534), packet(65535)])
  player.push([packet(0), packet(1)])
  assertEqual(order.join(','), '254,255,0,1', 'order (low bytes)')
  assertEqual(player.stats.lost + player.stats.late, 0, 'nothing lost')
}

cases.playerCanStartRightAtTheWrap = () => {
  const { player, order } = stubbedPlayer()
  player.push([packet(65535), packet(0), packet(1)])
  assertEqual(order.join(','), '255,0,1')
}

cases.playerStartsOverAfterALongGap = () => {
  const { player, order } = stubbedPlayer()
  player.push([packet(1)])
  player.push([5001, 5002, 5003].map(packet))
  assertEqual(player.stats.resyncs, 1, 'resync')
  assertEqual(player.stats.lost, 0, 'no silence for the gap')
  assertEqual(order.length, 4, 'all four packets decoded')
}

cases.aesCbcReusesTheSessionIvForEveryPacket = () => {
  const aes = new Aes128(hex('000102030405060708090a0b0c0d0e0f'))
  const iv = new Uint8Array(16).fill(9)
  const data = hex('69c4e0d86a7b0430d8cdb78070b4c55a69c4e0d86a7b0430d8cdb78070b4c55a')
  const first = toHex(aes.decryptCbc(data, iv))
  assertEqual(toHex(aes.decryptCbc(data, iv)), first, 'second packet')
  assertEqual(toHex(iv), '09'.repeat(16), 'iv untouched')
}

// The full iPhone path: AES key wrapped with RSA-OAEP, packets AES-CBC encrypted (tail left plain).
cases.playerDecodesAnEncryptedStream = async () => {
  const b64url = bytes => bytesToB64(bytes).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
  const publicKey = await crypto.subtle.importKey('jwk',
    { kty: 'RSA', n: b64url(rsaKey.n), e: b64url(rsaKey.e), alg: 'RSA-OAEP', ext: true },
    { name: 'RSA-OAEP', hash: 'SHA-1' }, false, ['encrypt'])
  const key = hex('2b7e151628aed2a6abf7158809cf4f3c')
  const iv = hex('000102030405060708090a0b0c0d0e0f')
  const wrappedKey = new Uint8Array(await crypto.subtle.encrypt({ name: 'RSA-OAEP' }, publicKey, key))
  const aesKey = await crypto.subtle.importKey('raw', key, 'AES-CBC', false, ['encrypt'])
  const encryptPacket = async frame => {
    const blocks = frame.length & ~15
    const cipher = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-CBC', iv }, aesKey, frame.subarray(0, blocks)))
    const out = new Uint8Array(frame.length)
    out.set(cipher.subarray(0, blocks))
    out.set(frame.subarray(blocks), blocks)
    return out
  }
  const frame = uncompressedFrame(Array.from({ length: 352 }, (_, i) => [i, -i]))
  const player = new Player()
  const keys = streamKeys({ aesKey: bytesToB64(wrappedKey), aesIv: bytesToB64(iv) })
  await player.start({ codec: 'alac', fmtp: '96 352 0 16 40 10 14 2 255 0 0 44100', ...keys })
  player.ctx = fakeAudio().ctx
  const left = []
  player.schedule = l => left.push(Math.round(l[351] * 32768))
  player.push([[1, bytesToB64(await encryptPacket(frame))], [2, bytesToB64(await encryptPacket(frame))]])
  assertEqual(player.stats.errors, 0, 'errors')
  assertEqual(left.join(','), '351,351', 'decoded samples')
}

cases.playerStoppedWhileStartingStaysStopped = async () => {
  const player = new Player()
  const b64url = bytes => bytesToB64(bytes).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
  const publicKey = await crypto.subtle.importKey('jwk',
    { kty: 'RSA', n: b64url(rsaKey.n), e: b64url(rsaKey.e), alg: 'RSA-OAEP', ext: true },
    { name: 'RSA-OAEP', hash: 'SHA-1' }, false, ['encrypt'])
  const wrapped = new Uint8Array(await crypto.subtle.encrypt({ name: 'RSA-OAEP' }, publicKey, new Uint8Array(16)))
  const keys = streamKeys({ aesKey: bytesToB64(wrapped), aesIv: bytesToB64(new Uint8Array(16)) })
  const starting = player.start({ codec: 'alac', ...keys })
  player.stop()
  let failed = false
  try { await starting } catch (e) { failed = true }
  assertEqual(failed, true, 'start reports the stop')
  assertEqual(player.stream, null, 'no stream')
}

cases.textFillsInItsParameters = () => {
  assertEqual(text('hint_airplay', { name: 'Car' }), 'iPhone: Control Center → AirPlay → “Car”')
  assertEqual(text('noSuchKey'), 'noSuchKey', 'a missing string shows its key')
}

// a missing string shows the key on the screen
cases.everySettingHasALabel = () => {
  for (const setting of SETTINGS) {
    assertEqual(text(setting.label) !== setting.label, true, setting.key)
  }
}

// the cover goes into CSS url(): only inline images, always quoted
cases.coverAllowsOnlyInlineImages = () => {
  assertEqual(coverBackground('data:image/png;base64,iVBORw0K+/==')['background-image'], 'url("data:image/png;base64,iVBORw0K+/==")')
  const rejected = [
    'http://192.168.1.5/cover.jpg',
    'data:image/svg+xml;base64,PHN2Zz4=',
    'data:text/html;base64,PGI+',
    'data:image/jpeg;base64,AAAA), url(http://192.168.1.5/x',
    'data:image/jpeg;base64,AAAA" onerror="x',
    null,
  ]
  for (const cover of rejected) assertEqual(coverBackground(cover), null, String(cover))
}

async function runAll() {
  const lines = []
  let passed = 0
  let failed = 0
  let skipped = 0
  for (const [name, test] of Object.entries(cases)) {
    try {
      const note = await test()
      if (note === SKIPPED) {
        skipped++
        lines.push(`skip ${name}: run tools/fetch-fixtures.ps1`)
      } else {
        passed++
        if (note) lines.push(`ok ${name}: ${note}`)
      }
    } catch (e) {
      failed++
      lines.push(`FAIL ${name}: ${e.message}`)
    }
  }
  return [`${passed} passed, ${failed} failed, ${skipped} skipped`, ...lines].join('\n')
}

export { runAll }
