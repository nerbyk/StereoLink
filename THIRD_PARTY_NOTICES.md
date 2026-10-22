# Third-party notices

## FFmpeg ALAC decoder

`mod/ui/modModules/stereoLink/alac.js` is a JavaScript port of `libavcodec/alac.c` and
`libavcodec/alacdsp.c` from [FFmpeg](https://ffmpeg.org/).

Copyright (c) 2005 David Hammerton and the FFmpeg developers.

This file is free software; you can redistribute it and/or modify it under the terms of the
GNU Lesser General Public License as published by the Free Software Foundation; either
version 2.1 of the License, or (at your option) any later version. It is distributed in the
hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. The full license text is in
[LICENSES/LGPL-2.1.txt](LICENSES/LGPL-2.1.txt) (in the release zip: `mod_info/stereo_link/LGPL-2.1.txt`).

The file is shipped as readable source, so you can change it and use your version with the mod.

## AirPort Express RSA key

`mod/ui/modModules/stereoLink/crypto.js` contains the RSA private key of the Apple AirPort
Express, extracted and published by James Laird in 2011 for the original
[shairport](https://github.com/abrasive/shairport) and used since then by open source AirPlay
receivers such as [shairport-sync](https://github.com/mikebrady/shairport-sync). AirPlay
senders require a receiver to prove it holds this key.

## Trademarks

AirPlay, iPhone, iPad and Mac are trademarks of Apple Inc. This project is not affiliated
with, endorsed by or sponsored by Apple. BeamNG.drive is a trademark of BeamNG GmbH; this is
an unofficial community mod.

## Test fixtures

`tools/fetch-fixtures.ps1` downloads `luckynight.m4a` and `luckynight.flac` from the
[FFmpeg samples collection](https://samples.ffmpeg.org/A-codecs/lossless/) for local testing.
They are not part of this repository or the release.
