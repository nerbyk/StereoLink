# StereoLink

An AirPlay 1 (RAOP) audio receiver that runs inside BeamNG.drive, written in the game's Lua and
its UI JavaScript. An iPhone streams to it like to any AirPlay speaker; the game plays the music
through the car's stereo, with track info, artwork and remote control on an in-game head unit.

Nothing runs outside the game: no helper process, no native code, no extra install on the PC or
the phone. Players download it from the BeamNG repository; this repo is the source.

![Switching tracks: the car and the phone stay in sync](https://i.imgur.com/owOvGpL.gif)

## How it works

BeamNG gives mods two sandboxes, and each can do only half of an AirPlay receiver:

| | Can | Cannot |
|---|---|---|
| GE Lua (LuaJIT) | TCP/UDP sockets via LuaSocket, to private LAN addresses only | multicast sends, processes, FFI, big-integer maths, raw audio out |
| UI (CEF / Chromium) | WebCrypto, BigInt, Web Audio | sockets, Web Workers |

So Lua is the network card and the browser is the sound card:

```
 iPhone ──Wi-Fi──▶  GE Lua                                     UI (CEF)
  mDNS (UDP 5353)   airplay/mdns   unicast answers
  RTSP (TCP 47000)  airplay/raop ──challenge──────────────────▶ crypto.js   RSA sign (AirPort key)
                                 ◀──uiReply────────────────────
                                 ──stream (AES key, fmtp)─────▶ airplay.js  RSA-OAEP unwrap
  RTP  (UDP 47001+)              ──audio packets─────────────▶ player.js   reorder, AES-128-CBC,
                                                                alac.js     ALAC decode, Web Audio
  DACP (HTTP)       airplay/remote ◀──play/pause/next/volume─── headUnit.js the screen
```

| Layer | What the mod does |
|---|---|
| Discovery | mDNS responder for `_raop._tcp`. Multicast sends are blocked in the sandbox, so it answers iOS's unicast-response (QU) queries by unicast |
| Session | RTSP: `OPTIONS` + Apple-Challenge, `ANNOUNCE` (SDP, RSA-wrapped AES key), `SETUP`, `RECORD`, `FLUSH`, `SET_PARAMETER` (volume, DMAP track info, artwork, progress), `TEARDOWN` |
| Audio | RTP, 352-frame ALAC packets, AES-128-CBC; gaps re-requested over the control port; ~0.35 s jitter buffer |
| Remote | DACP over HTTP with the `Active-Remote` token. The port is found by a legacy-unicast SRV query; volume is sent as `volumeup`/`volumedown` presses because iOS acknowledges `dmcp.device-volume` and ignores it |
| Decode | ALAC ported from FFmpeg (LGPL), bit-exact against the FLAC reference |
| Mix | gain and low-pass by camera: cabin, chase camera, on foot; optional pause with the engine (`engineRunning` via `core_vehicleBridge`) |

Details, the message protocol between Lua and the UI and the file map:
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). Adding a source (Android is next):
[docs/ADDING_A_SOURCE.md](docs/ADDING_A_SOURCE.md).

### Untrusted input

Anything on the LAN can talk to the receiver, so the parsers are bounded: RTSP head and body
size, DMAP depth and length, `fmtp` ranges, DNS question count and pointer budget, one
Apple-Challenge per connection. `SETUP` is only accepted from the client that sent `ANNOUNCE`.
`stereoLink_dev_fakeSender.selfCheck()` replays these cases against a running receiver.

## Network

- BeamNG.drive 0.40 on Windows (tested on 0.40.3). The phone and the PC on one LAN; the PC may be
  wired.
- Windows has to call that network **Private**: BeamNG's firewall rule only allows private
  networks. Guest networks with client isolation will not work.
- Ports: UDP 5353 (mDNS, shared), TCP 47000 (RTSP; falls back to 47010, 47020, … and finally an
  ephemeral port), UDP on the next three ports for RTP audio, control and timing (any free port if
  taken), outbound TCP to the phone's DACP port.

## Repository layout

```
mod/                    the mod as the game loads it
  lua/ge/extensions/    stereoLink.lua and stereoLink/ (sources, airplay, pure modules, tests)
  ui/modModules/        stereoLink/ (player, decoder, crypto, head unit, tests)
docs/                   architecture, adding a source
tools/                  link, lint, pack, release, fixtures (PowerShell)
```

## Development

Requires Windows PowerShell and the game. `make` is optional (`winget install ezwinports.make`);
each target runs the script next to it.

```powershell
make link       # junction <user>/mods/unpacked/stereo_link -> this repo's mod/
make lint       # luacheck (downloads luacheck 1.2.0 into tools/bin on first run)
make fixtures   # reference audio for the decoder test
make pack       # dist/stereo_link_<version>.zip from tools/release-files.txt
```

### Tests

Both suites run inside the game. Lua, from the in-game console:

```lua
extensions.load("stereoLink_testRunner"); print(stereoLink_testRunner.runAll())
```

JS, from the UI developer console:

```js
import(location.origin + '/ui/modModules/stereoLink/tests/run.js').then(m => m.runAll()).then(console.log)
```

Without a phone, `stereoLink_dev_fakeSender` streams a test tone through the whole AirPlay path:

```lua
extensions.load("stereoLink_dev_fakeSender"); stereoLink_dev_fakeSender.play(5)
```

State and diagnostics: `dump(stereoLink.debugState())` in Lua, `StereoLink.diagnostics()` in the
UI (queue length, lost and late packets, decode errors), and
`require('stereoLink/airplay/remote').stats()` for the phone remote.

After changing UI files restart the game: reloading the UI in place is unreliable in 0.40.

### Release

The zip holds exactly the files listed in `tools/release-files.txt`; `make pack` prints what it
left out, and a pattern that matches nothing fails the build.

Add a `## x.y.z` section to `CHANGELOG.md`, commit it on `main`, then
`make release VERSION=x.y.z`. That sets the version in `info.json`, commits, tags `vx.y.z` and
pushes; GitHub Actions builds the zip and publishes the release with the changelog section as its
text. `x.y.z-beta.1` becomes a pre-release.

## Support

If it is useful to you, you can
[buy me a beer](https://link.payoneer.com/Token?t=814942C193C2433E8EECA80E0735BECD&src=pl).

## License

MIT, see [LICENSE](LICENSE). The ALAC decoder is a port of FFmpeg and stays under the LGPL 2.1+;
see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Not affiliated with Apple or BeamNG GmbH.
