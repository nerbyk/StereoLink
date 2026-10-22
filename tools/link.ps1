param(
  [string]$ModsDir = (Join-Path $env:LOCALAPPDATA 'BeamNG\BeamNG.drive\current\mods\unpacked')
)
# Creates the directory junction <user>\mods\unpacked\stereo_link -> <repo>\mod,
# so the game loads the mod straight from this checkout.
# Refuses if the target exists and is anything other than that junction.
# After linking: full game restart (hot reload of mods is unreliable).
$ErrorActionPreference = 'Stop'
$source = (Resolve-Path (Join-Path $PSScriptRoot '..\mod')).Path.TrimEnd('\')
$link = Join-Path $ModsDir 'stereo_link'
if (-not (Test-Path $ModsDir)) { throw "Mods folder not found: $ModsDir" }

if (Test-Path -LiteralPath $link) {
  $item = Get-Item -LiteralPath $link -Force
  $isJunction = $item.LinkType -eq 'Junction'
  $target = if ($isJunction) { (@($item.Target)[0]) -replace '^\\\\\?\\', '' } else { $null }
  if ($isJunction -and $target -and ($target.TrimEnd('\') -ieq $source)) {
    "Already linked: $link -> $source"
    exit 0
  }
  $what = if ($isJunction) { "a junction to '$target'" } else { "a $($item.GetType().Name) (not a junction)" }
  Write-Error "Refusing: $link already exists and is $what. Remove or rename it manually if it should be replaced."
  exit 1
}

New-Item -ItemType Junction -Path $link -Target $source | Out-Null
"Linked: $link -> $source"
"Restart the game fully to load the mod."
