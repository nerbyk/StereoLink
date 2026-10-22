# Downloads the ALAC reference fixture used by the UI codec tests: the same track encoded as
# ALAC (m4a) and FLAC, from the FFmpeg sample collection. Not committed (see .gitignore).
$ErrorActionPreference = 'Stop'
$dir = Join-Path $PSScriptRoot '..\mod\ui\modModules\stereoLink\tests\fixtures'
New-Item -ItemType Directory -Force $dir | Out-Null
foreach ($name in 'luckynight.m4a', 'luckynight.flac') {
  $target = Join-Path $dir $name
  if (Test-Path $target) { "have $name"; continue }
  Invoke-WebRequest -Uri "https://samples.ffmpeg.org/A-codecs/lossless/$name" -OutFile $target -UseBasicParsing
  "downloaded $name"
}
