param(
  [Parameter(Mandatory)][string]$Version,
  [switch]$Push
)
# Cuts a release: sets the version in info.json, commits, tags v<version>.
# With -Push it also pushes main and the tag; GitHub Actions then builds the zip and publishes
# the release with the CHANGELOG section as its text.
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..'))
Push-Location $root
try {
  if ($Version -notmatch '^\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?$') { throw "version '$Version' is not x.y.z" }
  $tag = "v$Version"
  if ((git branch --show-current) -ne 'main') { throw 'release from main' }
  if (git status --porcelain) { throw 'the working tree has uncommitted changes' }
  if (git tag --list $tag) { throw "tag $tag already exists" }
  & ([IO.Path]::Combine($PSScriptRoot, 'release-notes.ps1')) -Version $Version | Out-Null

  & ([IO.Path]::Combine($PSScriptRoot, 'lint.ps1'))
  if ($LASTEXITCODE -ne 0) { throw 'luacheck failed' }

  $infoPath = [IO.Path]::Combine($root, 'mod', 'mod_info', 'stereo_link', 'info.json')
  $info = Get-Content $infoPath -Raw
  $updated = $info -replace '("version_string":\s*")[^"]*(")', "`${1}$Version`${2}"
  if ($updated -ne $info) {
    [IO.File]::WriteAllText($infoPath, $updated)
    git add $infoPath
    git commit -q -m "Release $tag"
    if ($LASTEXITCODE -ne 0) { throw 'commit failed' }
  }
  & ([IO.Path]::Combine($PSScriptRoot, 'pack.ps1'))

  git tag -a $tag -m "StereoLink $Version"
  if ($Push) {
    git push origin main $tag
    if ($LASTEXITCODE -ne 0) { throw 'push failed' }
    "Pushed $tag; the release appears under GitHub Releases once the workflow finishes."
  } else {
    "Tagged $tag locally. Publish with: git push origin main $tag"
  }
} finally {
  Pop-Location
}
