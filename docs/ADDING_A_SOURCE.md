# Adding a source

A *source* is anything that can deliver music to the head unit. AirPlay is the only one today;
an Android source is the next one planned. Sources share one small interface, so the Lua head
unit does not change when a new one is added. The UI changes only where the source needs
something new from it: a codec, a request (see "Asking the UI") or a connect hint.

## Where it lives

```
mod/lua/ge/extensions/stereoLink.lua          head unit: settings, state, UI bridge
mod/lua/ge/extensions/stereoLink/sources/     one file per source (airplay.lua)
mod/lua/ge/extensions/stereoLink/airplay/     AirPlay internals (dns, mdns, rtsp, raop, remote, volume)
mod/lua/ge/extensions/stereoLink/net.lua      local address helpers shared by sources
mod/ui/modModules/stereoLink/player.js        decoding and Web Audio playback
mod/ui/modModules/stereoLink/airplay.js       AirPlay requests the UI answers (RSA work)
mod/ui/modModules/stereoLink/i18n.js          connect hints, `hint_<source id>`
```

A new source gets `sources/<name>.lua` plus, if it needs more than a couple of hundred lines,
its own folder next to `airplay/`. Register it in the `SOURCES` list at the top of
`stereoLink.lua`.

## The interface

```lua
local M = { id = 'android', label = 'Android' }

-- host: callbacks into the head unit (below). options: {mac = '0211AABBCCDD', name = 'BeamNG'}
-- Returns true, or false and a message the player can read. A new name in the settings means
-- stop() and start() again.
function M.start(host, options) end
function M.stop() end
function M.update() end                -- every frame; never block

function M.control(command) end        -- 'playpause' | 'next' | 'prev'
function M.canControl() end            -- greys out the buttons when false
function M.setVolume(volume) end       -- optional: the volume set in the game, 0..1; true if the phone was told
function M.status() end                -- {sawNetwork = true} once any phone traffic was seen
function M.release() end               -- optional: another source took the head unit over
function M.uiReply(id, value) end      -- optional, see "Asking the UI" below
```

The head unit hands every source a `host` table:

| Callback | When |
|---|---|
| `host.onSession({device = 'Pixel 8'})` | a phone connected (`device` is optional); call it before track info, it marks the head unit connected |
| `host.onSession(nil, reason)` | it went away |
| `host.toUi(message)` | send something to the player (see below) |
| `host.onVolume(volume)` | the phone's own volume as its slider position, `0..1` (see "Volume") |
| `host.onTrack({title, artist, album})` | track info |
| `host.onCover(dataUri)` | artwork as a `data:` URI, or `nil` |
| `host.onProgress(position, duration)` | seconds |

Only one source owns the player at a time. A source takes it over by sending a `stream` message
(or by calling `host.onSession(info)`, whichever comes first); the last one to do so wins. From
then on the head unit drops audio, flush, teardown, volume, track, cover and progress from every
other source, so a replaced source cannot disturb the new stream. The replaced source gets
`release()` if it has one and should let its phone go there; its later `onSession(nil)` is
ignored. Requests to the UI (such as AirPlay's challenge) pass from any source, because a phone
has to be answered before it can take over. If the UI reloads, the head unit resends the last stream without
its id; the UI does not answer it.

### Volume

The head unit shows one volume: the phone's. It is a slider position, `0..1`, the same scale in
both directions; `0` is mute. The head unit squares it into the player's gain, so a source does
not deal with loudness curves.

- The phone moved its slider: call `host.onVolume(volume)`.
- The player turned the wheel or pressed `−`/`+` on the screen: the head unit applies the new
  volume at once and calls `setVolume(volume)` on the source that owns the player. Pass it on to
  the phone and return `true`, or return `false` when there is no way to. Without `setVolume`
  the change stays a volume of the game only and the phone's slider does not move.
- `setVolume` comes once per wheel notch; rate limiting the requests to the phone is up to the
  source (AirPlay sends at most five a second, the last value always goes out).
- A phone usually answers a change by reporting its new volume. Reports that arrive within a
  second of a change from the game are held back and only the last of them is applied, so the
  echoes of older wheel positions do not pull the number on the screen back.

## Talking to the player

Audio never goes through the head unit's state; a source sends it straight to the UI with
`host.toUi`. The player understands these messages:

| Message | Meaning |
|---|---|
| `{type = 'stream', id, codec, fmtp, aesKey, aesIv}` | a stream starts; answered with `uiReply(id, 'ok')` |
| `{type = 'audio', packets = {{seq, base64}, ...}}` | RTP-style packets, `seq` is 16 bit |
| `{type = 'flush'}` | drop everything queued (pause, seek) |
| `{type = 'teardown'}` | the stream ended |

`codec` is `'alac'` today. A new codec means a new decoder next to `alac.js` and a branch in
`Player.start` / `Player.decode`. `Player.start` takes the AES key and IV already unwrapped
(`{codec, fmtp, key, iv}`, `key` may be a promise); unwrapping is source-specific. The game's browser can also decode whole files itself with
`decodeAudioData` (FLAC is confirmed by the tests; check other formats before relying on them),
which is the easy route for a DLNA-style source that receives whole tracks.

### Asking the UI

The Lua side has no big integer maths, so AirPlay asks the UI to do its RSA work: it sends a
message with an `id`. The head unit stamps every message with the source id, the UI answers
through `stereoLink.uiReply(sourceId, id, value)`, and the head unit hands the reply to that
source's `uiReply(id, value)`. Ids only need to be unique within one source.

On the UI side requests are a table in `stereoLink.js` (`requests[type]`: what to run and what to
answer if it throws); AirPlay's live in `airplay.js`. A new kind of request is one entry there.

The connect hint on the idle screen comes from `state.sources`: one line per running source,
text from the i18n key `hint_<id>` (falls back to the source's `label`).

## What the game allows

BeamNG runs mod Lua in a sandbox. Verified on 0.40:

- no processes, no `ffi` calls into Windows, no Bluetooth;
- TCP and UDP servers are fine; sending is allowed only to private LAN addresses
  (192.168.x.x, 10.x.x.x, 172.16-31.x.x) and the subnet broadcast address;
- multicast sending is refused (receiving works), which is why the mDNS responder answers by
  unicast;
- the UI browser has Web Audio, WebCrypto and BigInt, but no Web Workers;
- UI messages stop while the game window is minimized.

## Ideas for Android

Android has no AirPlay and the game cannot touch Bluetooth, so the phone has to stream over
Wi-Fi with something it already has:

- **DLNA / UPnP renderer.** Apps like BubbleUPnP or the "cast" button in many players can send
  music to a DLNA renderer. That needs SSDP discovery (multicast again, so the same unicast
  trick as mDNS), a small UPnP/SOAP control server and HTTP downloads of the track, which the
  browser can decode.
- **AirPlay sender apps for Android** (AirMusic and similar) speak the same protocol as an
  iPhone and should work with the existing AirPlay source; not tested yet.

## Testing a source

- Pure logic (parsers, packet builders) goes in modules without sockets and gets test cases in
  `lua/ge/extensions/stereoLink/tests/` (see `README.md`, "Development").
- `stereoLink_dev_fakeSender` plays a test tone through the AirPlay path without a phone;
  a similar helper for a new source saves a lot of round trips.
