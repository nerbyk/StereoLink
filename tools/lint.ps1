# Static check of the mod's Lua with luacheck (config: .luacheckrc in the repo root).
# Usage: powershell -NoProfile -File tools/lint.ps1 [paths...]   (default: mod/lua mod/scripts)
# luacheck.exe (standalone, lunarmodules v1.2.0) lives in tools/bin; downloaded once if missing.
param([string[]]$Paths = @("mod/lua", "mod/scripts"))

$root = Split-Path $PSScriptRoot -Parent
$exe = Join-Path $PSScriptRoot "bin/luacheck.exe"
if (-not (Test-Path $exe)) {
  New-Item -ItemType Directory -Force (Split-Path $exe) | Out-Null
  Invoke-WebRequest -Uri "https://github.com/lunarmodules/luacheck/releases/download/v1.2.0/luacheck.exe" -OutFile $exe -UseBasicParsing
}

Push-Location $root
try {
  & $exe @Paths --codes --no-color --config (Join-Path $root ".luacheckrc")
  exit $LASTEXITCODE
} finally {
  Pop-Location
}
