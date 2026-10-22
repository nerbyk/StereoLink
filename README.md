# StereoLink for BeamNG.drive

Play music from your iPhone through your car's head unit in BeamNG.drive. Get in, open the
AirPlay menu on the phone, pick **BeamNG**, and whatever you are listening to plays in the game,
with the track and cover art on the car's screen.

No extra software on the PC and nothing to install on the phone. The mod is the AirPlay speaker.

[Русская версия](README.ru.md)

<!-- screenshots: docs/images/head-unit.png, docs/images/airplay-menu.png -->

## Features

- Works with the AirPlay menu built into iOS, so any app that plays audio works.
- Compact head unit with title, artist, cover art and progress.
- Previous / play-pause / next on the screen control the phone.
- Sounds like a car stereo: clear in the cabin, muffled from the chase camera, quiet when you
  walk away. Playing in third person? One checkbox gives you the full sound outside the car.
- One volume, the phone's: the screen shows it, and the mouse wheel or `−`/`+` on the screen move
  the phone's slider. The phone's own buttons work as well.
- The screen shows up only while you are in a car. Drag it anywhere, or minimize it to a small pill.
- English and Russian, following the game language.

## Requirements

- BeamNG.drive 0.40 on Windows (tested on 0.40.3).
- An iPhone or iPad on the **same Wi-Fi network** as the PC. The PC itself
  can be on a cable.
- The network set to **Private** in Windows (see below). Guest networks that isolate devices
  will not work.

Android is not supported yet; it is the next thing on the list.

## Install

1. Download `stereo_link_<version>.zip` from [Releases](../../releases).
2. Put the zip, without unpacking it, into
   `%LOCALAPPDATA%\BeamNG\BeamNG.drive\current\mods`.
3. Start the game. The first time, Windows may ask whether BeamNG.drive can use the network:
   allow it on **private networks**.

### Make your Wi-Fi a private network

Windows only lets games accept connections from the local network when it is marked as
private, which is the normal setting for a home network.

*Settings → Network & Internet → Wi-Fi (or Ethernet) → your network → Network profile type →
Private.*

## Use

1. Get in any car. The head unit appears at the bottom of the screen.
2. On the iPhone open **Control Center**, tap the **AirPlay** icon on the music tile and choose
   **BeamNG**.
3. Play music. If the screen asks for it, click it once: the game only enables browser sound
   after a click.

| Action | How |
|---|---|
| Previous / pause / next | buttons on the screen |
| Volume | `−` / `+` next to the number, or the mouse wheel over the screen; the phone's slider follows |
| Move the screen | drag it |
| Minimize / restore | the `–` button / click the pill |
| Turn the receiver off | the power button |
| Settings | the gear button; the arrow brings the player back |

You can also add the screen as a regular UI app: *UI Apps → StereoLink*.

### Settings

The gear on the screen opens:

- **Full sound outside the car**: from the outside cameras the music plays as loud and clear as
  in the cabin, for driving in third person. On foot it stays quiet. Off by default.
- **Overall volume**: the mod's own level, on top of the game's master volume.

Everything is stored in
`%LOCALAPPDATA%\BeamNG\BeamNG.drive\current\settings\stereoLink.json`:

| Key | Meaning |
|---|---|
| `name` | the name shown in the AirPlay menu (default `BeamNG`) |
| `carVolume` | overall level of the mod's sound, `0`–`1` (the screen sets the phone volume) |
| `fullSoundOutside` | full sound outside the car, `true` / `false` (default `false`) |
| `power` | whether the receiver starts with the game |
| `mac` | random id of this receiver, generated on first start |

Edit the file only with the game closed; the screen saves its settings itself.

## Troubleshooting

**"BeamNG" does not show up in the AirPlay menu.**
Check that the phone and the PC are on the same network and that Windows calls it Private. Close
the AirPlay menu and open it again: the phone looks for speakers right when the menu opens. If the
head unit says that it sees no phones, Windows is still blocking the game: look for
*BeamNG.drive* in *Windows Defender Firewall → Allow an app through firewall* and tick **Private**.
A VPN on the phone or the PC can also hide the two from each other.

**Connected, but no sound.**
Click the head unit once. Check the in-game master volume and the volume on the screen: at 0 the
phone is muted.

**The sound stutters.**
Usually weak Wi-Fi on the phone's side. Moving closer to the router helps; 5 GHz is better than
2.4 GHz.

**The music stops when I alt-tab.**
The game pauses its interface while it is minimized. Keep it in the foreground or windowed.

**The previous / pause / next buttons do nothing.**
The first press after connecting can take a second while the game finds the phone's remote
control. If they never react, the phone did not share it: use the controls on the phone. The
volume on the screen still works then, but only in the game; the phone's slider stays put.

## How it works

BeamNG lets mod Lua open network sockets but not play raw audio; its interface browser can play
audio but cannot open sockets. So the Lua side implements the AirPlay receiver (discovery,
RTSP, RTP) and passes the encrypted packets to the browser, which decrypts them, decodes Apple
Lossless and plays them through Web Audio. Details in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Development

Requires Windows PowerShell and the game. `make` is optional (`winget install ezwinports.make`);
each target runs the script next to it.

```powershell
make link       # tools/link.ps1: junction mods/unpacked/stereo_link -> this repo's mod/
make lint       # tools/lint.ps1: luacheck (downloads luacheck 1.2.0 into tools/bin on first run)
make fixtures   # tools/fetch-fixtures.ps1: reference audio for the decoder test
make pack       # tools/pack.ps1: dist/stereo_link_<version>.zip
```

The release zip holds exactly the files listed in `tools/release-files.txt`; a new Lua or JS
file has to be added there, and `make pack` lists everything it left out.

To release, add a `## x.y.z` section to `CHANGELOG.md`, commit it on `main`, then
`make release VERSION=x.y.z`. That sets the version in `info.json`, commits, tags `vx.y.z` and
pushes; GitHub Actions builds the zip and publishes the release with the changelog section as its
text. A version like `1.1.0-beta.1` becomes a pre-release.

Tests run inside the game. From the in-game Lua console:

```lua
extensions.load("stereoLink_testRunner"); print(stereoLink_testRunner.runAll())
```

and from the UI's developer console (or any tool that evaluates JS in the game UI):

```js
import(location.origin + '/ui/modModules/stereoLink/tests/run.js').then(m => m.runAll()).then(console.log)
```

To see what the mod thinks is going on, run `dump(stereoLink.debugState())` in the Lua
console; the player's side (queue, lost and late packets, errors) is `StereoLink.diagnostics()`
in the UI console.

No phone at hand? `stereoLink_dev_fakeSender` streams a test tone through the whole AirPlay
path:

```lua
extensions.load("stereoLink_dev_fakeSender"); stereoLink_dev_fakeSender.play(5)
```

After changing UI files restart the game: reloading the UI in place is unreliable in 0.40.

Want to add another way to connect a phone, Android in particular? Start with
[docs/ADDING_A_SOURCE.md](docs/ADDING_A_SOURCE.md).

## License

MIT, see [LICENSE](LICENSE). The ALAC decoder is a port of FFmpeg and stays under the LGPL 2.1+;
see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Not affiliated with Apple or BeamNG GmbH.
