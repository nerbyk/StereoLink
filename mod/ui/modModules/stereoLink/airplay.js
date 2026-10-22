// The AirPlay-only work Lua hands to the UI: both need the receiver's RSA key, and BigInt and
// WebCrypto are here, not in Lua.

import { b64ToBytes, appleResponse, decryptAesKey } from './crypto.js'

// The phone checks this signature before it streams to us. Returns base64.
function answerChallenge({ challenge, ip, mac }) {
  return appleResponse(challenge, ip, mac)
}

// The packet key arrives wrapped with the receiver's RSA key; `key` is a promise because
// unwrapping goes through WebCrypto.
function streamKeys({ aesKey, aesIv }) {
  return {
    key: aesKey ? decryptAesKey(aesKey) : null,
    iv: aesIv ? b64ToBytes(aesIv) : null,
  }
}

export { answerChallenge, streamKeys }
