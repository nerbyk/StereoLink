# How it works

```
 iPhone ──Wi-Fi──▶  Lua (game engine)                         UI (game browser)
                    ┌──────────────────────────────┐          ┌───────────────────────────┐
  mDNS query  ────▶ │ airplay/mdns   unicast answer│          │                           │
  RTSP (TCP)  ────▶ │ airplay/raop ──"challenge"───┼─────────▶│ crypto.js  RSA signature  │
                    │              ◀──uiReply──────┼──────────│                           │
                    │              ──"stream"──────┼─────────▶│ airplay.js AES key (OAEP) │
  RTP (UDP)   ────▶ │              ──"audio"───────┼─────────▶│ player.js  reorder, AES,  │
                    │                              │          │ alac.js    decode, Web    │
                    │ airplay/remote (DACP) ◀──────┼──────────│            Audio, effects │
                    │ stereoLink.lua  state ───────┼─────────▶│ headUnit.js  the screen   │
                    └──────────────────────────────┘          └───────────────────────────┘
```

## Why it is split this way

The game gives mods two places to run code, and each can do only half the job:

- **Lua** can open sockets, but it has no big-integer maths for RSA and no way to output a
  stream of raw audio.
- **The UI browser** has WebCrypto, BigInt and Web Audio, but cannot open sockets.

So Lua is the network card and the browser is the sound card. Lua talks to the UI through three
`guihooks.trigger` events; the UI answers with `bngApi.engineLua(...)`.

| Hook | What | When |
|---|---|---|
| `StereoLinkBatch` | ordered messages from the sources (`stream`, `audio`, `flush`, `teardown`, `challenge`) and from the head unit (`volume`, `ambient`) | once per frame, if there is anything |
| `StereoLinkState` | a snapshot for the screen: power, connection, track, position, `phoneVolume`, `sources`, `options` | when something changed, and once a second |
| `StereoLinkCover` | artwork as a `data:image/...` URI | when it changes; kept apart because it is big |

## AirPlay in short

This is AirPlay 1 ("RAOP"), the audio-only protocol every iPhone still speaks to older speakers.

1. **Discovery.** The phone multicasts a query for `_raop._tcp.local`. The mod is not allowed to
   multicast, so it answers by unicast. iOS accepts that because a new browse starts with
   "unicast response" queries.
2. **Handshake (RTSP over TCP, port 47000 unless taken).** `OPTIONS` carries an `Apple-Challenge`; the reply is
   signed with the AirPort Express key. `ANNOUNCE` carries the codec and the session AES key,
   encrypted with the same RSA key. `SETUP` agrees on UDP ports, `RECORD` starts playback.
3. **Audio (RTP over UDP, the next ports).** 352-frame Apple Lossless packets, AES-128-CBC encrypted.
   Lost packets are requested again over the control port. Only packets from the phone that owns
   the session are accepted; a second phone that connects takes over and the first is dropped.
4. **Metadata.** `SET_PARAMETER` delivers volume, track info (DMAP), artwork and progress.
5. **Remote control.** The phone advertises a DACP service; play/pause/next and the volume
   from the car are plain HTTP requests to it, authorised by the `Active-Remote` token. The
   volume is pressed on the phone's own buttons, `volumeup`/`volumedown`, one at a time, so its
   slider moves in 1/16 steps; iOS answers `setproperty?dmcp.device-volume` with 204 and
   ignores it. A new session puts back the volume the player listened at last, since iOS starts
   each one at the volume it keeps for the speaker.

Only one source owns the player at a time; a `stream` message takes it over, and audio from any
other source is dropped (docs/ADDING_A_SOURCE.md).

Playback runs about 0.35 s behind the network instead of the 2 s an AirPlay speaker normally
waits for; music does not need multi-room sync, and it keeps pause and skip responsive. After a
long hole in the stream (a level loading, a frozen frame) the player starts again from the newest
packet instead of filling the hole with silence, and if a frozen frame left too much queued it
drops the backlog so the delay stays the same.

## Files

| File | Role |
|---|---|
| `lua/ge/extensions/stereoLink.lua` | settings, power, state for the UI, cabin/outside mix |
| `stereoLink/host.lua` | the host table sources get: who owns the player, what it plays, pause detection (pure, engine parts passed in) |
| `stereoLink/session.lua` | routing rule (capture/deliver/drop) and track position maths (pure) |
| `stereoLink/mix.lua` | how loud and muffled the music is in the cabin, from outside and on foot (pure) |
| `stereoLink/ignition.lua` | when the engine stopping or starting presses play/pause on the phone (pure) |
| `stereoLink/sources/airplay.lua` | AirPlay as a source (see ADDING_A_SOURCE.md) |
| `stereoLink/airplay/dns.lua` | DNS packets (pure) |
| `stereoLink/airplay/mdns.lua` | responder and SRV lookups (sockets) |
| `stereoLink/airplay/rtsp.lua` | RTSP, SDP, DMAP parsing (pure) |
| `stereoLink/airplay/rtp.lua` | RTP packets, gaps and resend requests (pure) |
| `stereoLink/airplay/raop.lua` | RTSP server, session, RTP sockets |
| `stereoLink/airplay/remote.lua` | DACP remote control: commands and volume, at most five volume requests a second |
| `stereoLink/airplay/volume.lua` | AirPlay dB to slider position and back (pure) |
| `stereoLink/airplay/throttle.lua` | rate limits for log lines and volume requests (pure) |
| `stereoLink/net.lua` | local addresses, picking the adapter the phone is on |
| `stereoLink/preferences.lua` | settings defaults and validation (pure) |
| `stereoLink/dev/fakeSender.lua` | test tone and hostile requests through the AirPlay path (not in the release zip) |
| `stereoLink/testRunner.lua`, `testlib.lua`, `tests/` | in-game tests for the pure modules (not in the release zip) |
| `ui/modModules/stereoLink/stereoLink.js` | UI entry point, message handling |
| `ui/modModules/stereoLink/player.js` | jitter buffer, decoding, Web Audio |
| `ui/modModules/stereoLink/crypto.js` | RSA and AES |
| `ui/modModules/stereoLink/airplay.js` | AirPlay requests the UI answers: challenge signature, AES key |
| `ui/modModules/stereoLink/alac.js` | Apple Lossless decoder (LGPL, from FFmpeg) |
| `ui/modModules/stereoLink/headUnit.js` | the on-screen head unit |
| `ui/modModules/stereoLink/strings.js` | the texts on the screen |
| `ui/modModules/stereoLink/tests/run.js` | UI tests (decoder, crypto, player) |
| `ui/modules/apps/StereoLink/` | optional UI app with the same screen |

Settings are stored in `<user folder>/settings/stereoLink.json`: `name` (what the phone
shows), `power`, `carVolume` (the mod's overall level), `fullSoundOutside` (outside cameras
sound like the cabin), `pauseWithEngine` (play/pause follows the engine) and `mac` (a random id generated on first start).

The settings panel changes options through one call, `stereoLink.uiSetOption(key, value)`.
`preferences.lua` lists the options with their type and default (`OPTIONS`); anything else is
refused, and the state sends their values to the screen as `options`. A new checkbox is an entry
in `OPTIONS`, one in `SETTINGS` in `headUnit.js` and its label in `strings.js`.
