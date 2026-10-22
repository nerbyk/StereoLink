// AirPlay crypto: base64 helpers, RSA with the AirPort Express private key (extracted in 2011
// and used by every open source AirPlay receiver, see THIRD_PARTY_NOTICES.md) and
// AES-128-CBC decryption.

function b64ToBytes(s) {
  s = s.replace(/[^A-Za-z0-9+/]/g, '')
  while (s.length % 4) s += '='
  const bin = atob(s)
  const out = new Uint8Array(bin.length)
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i)
  return out
}

function bytesToB64(bytes) {
  let bin = ''
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i])
  return btoa(bin)
}

function bytesToB64Url(bytes) {
  return bytesToB64(bytes).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

const AIRPORT_KEY_B64 =
  'MIIEpQIBAAKCAQEA59dE8qLieItsH1WgjrcFRKj6eUWqi+bGLOX1HL3U3GhC/j0Qg90u3sG/1CUt' +
  'wC5vOYvfDmFI6oSFXi5ELabWJmT2dKHzBJKa3k9ok+8t9ucRqMd6DZHJ2YCCLlDRKSKv6kDqnw4U' +
  'wPdpOMXziC/AMj3Z/lUVX1G7WSHCAWKf1zNS1eLvqr+boEjXuBOitnZ/bDzPHrTOZz0Dew0uowxf' +
  '/+sG+NCK3eQJVxqcaJ/vEHKIVd2M+5qL71yJQ+87X6oV3eaYvt3zWZYD6z5vYTcrtij2VZ9Zmni/' +
  'UAaHqn9JdsBWLUEpVviYnhimNVvYFZeCXg/IdTQ+x4IRdiXNv5hEewIDAQABAoIBAQDl8Axy9XfW' +
  'BLmkzkEiqoSwF0PsmVrPzH9KsnwLGH+QZlvjWd8SWYGN7u1507HvhF5N3drJoVU3O14nDY4TFQAa' +
  'LlJ9VM35AApXaLyY1ERrN7u9ALKd2LUwYhM7Km539O4yUFYikE2nIPscEsA5ltpxOgUGCY7b7ez5' +
  'NtD6nL1ZKauw7aNXmVAvmJTcuPxWmoktF3gDJKK2wxZuNGcJE0uFQEG4Z3BrWP7yoNuSK3dii2jm' +
  'lpPHr0O/KnPQtzI3eguhe0TwUem/eYSdyzMyVx/YpwkzwtYL3sR5k0o9rKQLtvLzfAqdBxBurciz' +
  'aaA/L0HIgAmOit1GJA2saMxTVPNhAoGBAPfgv1oeZxgxmotiCcMXFEQEWflzhWYTsXrhUIuz5jFu' +
  'a39GLS99ZEErhLdrwj8rDDViRVJ5skOp9zFvlYAHs0xh92ji1E7V/ysnKBfsMrPkk5KSKPrnjndM' +
  'oPdevWnVkgJ5jxFuNgxkOLMuG9i53B4yMvDTCRiIPMQ++N2iLDaRAoGBAO9v//mU8eVkQaoANf0Z' +
  'oMjW8CN4xwWA2cSEIHkd9AfFkftuv8oyLDCG3ZAf0vrhrrtkrfa7ef+AUb69DNggq4mHQAYBp7L+' +
  'k5DKzJrKuO0r+R0YbY9pZD1+/g9dVt91d6LQNepUE/yY2PP5CNoFmjedpLHMOPFdVgqDzDFxU8hL' +
  'AoGBANDrr7xAJbqBjHVwIzQ4To9pb4BNeqDndk5Qe7fT3+/H1njGaC0/rXE0Qb7q5ySgnsCb3DvA' +
  'cJyRM9SJ7OKlGt0FMSdJD5KG0XPIpAVNwgpXXH5MDJg09KHeh0kXo+QA6viFBi21y340NonnEfdf' +
  '54PX4ZGS/Xac1UK+pLkBB+zRAoGAf0AY3H3qKS2lMEI4bzEFoHeK3G895pDaK3TFBVmD7fV0Zhov' +
  '17fegFPMwOII8MisYm9ZfT2Z0s5Ro3s5rkt+nvLAdfC/PYPKzTLalpGSwomSNYJcB9HNMlmhkGzc' +
  '1JnLYT4iyUyx6pcZBmCd8bD0iwY/FzcgNDaUmbX9+XDvRA0CgYEAkE7pIPlE71qvfJQgoA9em0gI' +
  'LAuE4Pu13aKiJnfft7hIjbK+5kyb3TysZvoyDnb3HOKvInK7vXbKuU4ISgxB2bB3HcYzQMGsz1qJ' +
  '2gG0N5hvJpzwwhbhXqFKA4zaaSrw622wDniAK5MlIE0tIAKKP4yxNGjoD2QYjhBGuhvkWKY='

// Minimal DER reader for an RSAPrivateKey (PKCS#1): SEQUENCE { version, n, e, d, p, q, dp, dq, qi }
function parseRsaKey(der) {
  let pos = 0
  function readLen() {
    let len = der[pos++]
    if (len & 0x80) {
      const n = len & 0x7f
      len = 0
      for (let i = 0; i < n; i++) len = len * 256 + der[pos++]
    }
    return len
  }
  if (der[pos++] !== 0x30) throw new Error('bad key')
  readLen()
  const ints = []
  while (pos < der.length) {
    if (der[pos++] !== 0x02) throw new Error('bad key int')
    const len = readLen()
    let start = pos
    while (der[start] === 0 && start < pos + len - 1) start++ // strip sign byte
    ints.push(der.slice(start, pos + len))
    pos += len
  }
  const [, n, e, d, p, q, dp, dq, qi] = ints
  return { n, e, d, p, q, dp, dq, qi }
}

function bytesToBig(b) {
  let x = 0n
  for (const v of b) x = (x << 8n) | BigInt(v)
  return x
}

function bigToBytes(x, len) {
  const out = new Uint8Array(len)
  for (let i = len - 1; i >= 0; i--) { out[i] = Number(x & 0xffn); x >>= 8n }
  return out
}

function modPow(base, exp, mod) {
  let result = 1n
  base %= mod
  while (exp > 0n) {
    if (exp & 1n) result = (result * base) % mod
    base = (base * base) % mod
    exp >>= 1n
  }
  return result
}

const rsaKey = parseRsaKey(b64ToBytes(AIRPORT_KEY_B64))
const rsaN = bytesToBig(rsaKey.n)
const rsaD = bytesToBig(rsaKey.d)
const RSA_LEN = rsaKey.n.length // 256

// Apple-Challenge: RSA PKCS#1 v1.5 "sign" (type 1 padding, no hashing) of challenge | ip | mac
function appleResponse(challengeB64, ipBytes, macBytes) {
  const chall = b64ToBytes(challengeB64)
  let buf = [...chall, ...ipBytes, ...macBytes]
  while (buf.length < 32) buf.push(0)
  const em = new Uint8Array(RSA_LEN).fill(0xff)
  em[0] = 0; em[1] = 1
  em[RSA_LEN - buf.length - 1] = 0
  em.set(buf, RSA_LEN - buf.length)
  const sig = bigToBytes(modPow(bytesToBig(em), rsaD, rsaN), RSA_LEN)
  return bytesToB64(sig).replace(/=+$/, '')
}

let oaepKeyPromise = null
function oaepKey() {
  if (!oaepKeyPromise) {
    const k = rsaKey
    oaepKeyPromise = crypto.subtle.importKey('jwk', {
      kty: 'RSA', alg: 'RSA-OAEP', ext: true, key_ops: ['decrypt'],
      n: bytesToB64Url(k.n), e: bytesToB64Url(k.e), d: bytesToB64Url(k.d),
      p: bytesToB64Url(k.p), q: bytesToB64Url(k.q),
      dp: bytesToB64Url(k.dp), dq: bytesToB64Url(k.dq), qi: bytesToB64Url(k.qi),
    }, { name: 'RSA-OAEP', hash: 'SHA-1' }, false, ['decrypt'])
  }
  return oaepKeyPromise
}

async function decryptAesKey(rsaaeskeyB64) {
  const key = await oaepKey()
  return new Uint8Array(await crypto.subtle.decrypt({ name: 'RSA-OAEP' }, key, b64ToBytes(rsaaeskeyB64)))
}


const SBOX = new Uint8Array(256), INV_SBOX = new Uint8Array(256)
;(function buildSbox() {
  let p = 1, q = 1
  do {
    p = p ^ ((p << 1) & 0xff) ^ (p & 0x80 ? 0x1b : 0)
    q ^= q << 1; q ^= q << 2; q ^= q << 4; q &= 0xff
    if (q & 0x80) q ^= 0x09
    const x = q ^ ((q << 1) | (q >> 7)) ^ ((q << 2) | (q >> 6)) ^ ((q << 3) | (q >> 5)) ^ ((q << 4) | (q >> 4))
    SBOX[p] = (x ^ 0x63) & 0xff
  } while (p !== 1)
  SBOX[0] = 0x63
  for (let i = 0; i < 256; i++) INV_SBOX[SBOX[i]] = i
})()

function xtime(a) { return ((a << 1) ^ (a & 0x80 ? 0x1b : 0)) & 0xff }
function gmul(a, b) {
  let r = 0
  while (b) { if (b & 1) r ^= a; a = xtime(a); b >>= 1 }
  return r
}

class Aes128 {
  constructor(key) {
    const w = new Uint8Array(176)
    w.set(key)
    let rcon = 1
    for (let i = 16; i < 176; i += 4) {
      let t0 = w[i - 4], t1 = w[i - 3], t2 = w[i - 2], t3 = w[i - 1]
      if (i % 16 === 0) {
        const tmp = t0
        t0 = SBOX[t1] ^ rcon; t1 = SBOX[t2]; t2 = SBOX[t3]; t3 = SBOX[tmp]
        rcon = xtime(rcon)
      }
      w[i] = w[i - 16] ^ t0; w[i + 1] = w[i - 15] ^ t1; w[i + 2] = w[i - 14] ^ t2; w[i + 3] = w[i - 13] ^ t3
    }
    this.w = w
    this.m9 = new Uint8Array(256); this.m11 = new Uint8Array(256); this.m13 = new Uint8Array(256); this.m14 = new Uint8Array(256)
    for (let i = 0; i < 256; i++) { this.m9[i] = gmul(i, 9); this.m11[i] = gmul(i, 11); this.m13[i] = gmul(i, 13); this.m14[i] = gmul(i, 14) }
  }

  decryptBlock(s) { // in place, 16 bytes
    const w = this.w, m9 = this.m9, m11 = this.m11, m13 = this.m13, m14 = this.m14
    for (let i = 0; i < 16; i++) s[i] ^= w[160 + i]
    for (let round = 9; round >= 0; round--) {
      // inverse shift rows
      let t = s[13]; s[13] = s[9]; s[9] = s[5]; s[5] = s[1]; s[1] = t
      t = s[2]; s[2] = s[10]; s[10] = t; t = s[6]; s[6] = s[14]; s[14] = t
      t = s[3]; s[3] = s[7]; s[7] = s[11]; s[11] = s[15]; s[15] = t
      for (let i = 0; i < 16; i++) s[i] = INV_SBOX[s[i]] ^ w[round * 16 + i]
      if (round === 0) break
      for (let c = 0; c < 16; c += 4) {
        const a0 = s[c], a1 = s[c + 1], a2 = s[c + 2], a3 = s[c + 3]
        s[c] = m14[a0] ^ m11[a1] ^ m13[a2] ^ m9[a3]
        s[c + 1] = m9[a0] ^ m14[a1] ^ m11[a2] ^ m13[a3]
        s[c + 2] = m13[a0] ^ m9[a1] ^ m14[a2] ^ m11[a3]
        s[c + 3] = m11[a0] ^ m13[a1] ^ m9[a2] ^ m14[a3]
      }
    }
  }

  // AirPlay: CBC over whole 16-byte blocks with the session IV, remaining bytes are not encrypted
  decryptCbc(data, iv) {
    const out = new Uint8Array(data.length)
    out.set(data)
    const prev = new Uint8Array(iv)
    const blk = new Uint8Array(16)
    const end = data.length & ~15
    for (let i = 0; i < end; i += 16) {
      blk.set(data.subarray(i, i + 16))
      this.decryptBlock(blk)
      for (let j = 0; j < 16; j++) out[i + j] = blk[j] ^ prev[j]
      prev.set(data.subarray(i, i + 16))
    }
    return out
  }
}

export { b64ToBytes, bytesToB64, appleResponse, decryptAesKey, Aes128, rsaKey }
