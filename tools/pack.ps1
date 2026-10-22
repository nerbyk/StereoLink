param(
  [string]$OutDir = [IO.Path]::Combine($PSScriptRoot, '..', 'dist'),
  [string]$List = [IO.Path]::Combine($PSScriptRoot, 'release-files.txt')
)
# Packs the files named in tools/release-files.txt into dist/stereo_link_<version>.zip.
# The zip uses forward slashes and explicit directory entries: without directory entries the
# game does not mount the archive.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$root = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..'))
$modDir = [IO.Path]::Combine($root, 'mod')

function ConvertTo-Regex([string]$glob) {
  $escaped = [regex]::Escape($glob) -replace '\\\*\\\*', '.*' -replace '\\\*', '[^/]*'
  return "^$escaped$"
}

$modFiles = Get-ChildItem $modDir -Recurse -File | ForEach-Object {
  $_.FullName.Substring($modDir.Length + 1).Replace('\', '/')
}

# zip path -> file on disk
$entries = [ordered]@{}
foreach ($line in Get-Content $List) {
  $line = $line.Trim()
  if ($line -eq '' -or $line.StartsWith('#')) { continue }
  if ($line -match '^(.+?)\s*=>\s*(.+)$') {
    $path = [IO.Path]::Combine($root, $Matches[1])
    if (-not (Test-Path $path -PathType Leaf)) { throw "release-files.txt: $($Matches[1]) not found" }
    $entries[$Matches[2]] = $path
    continue
  }
  $pattern = ConvertTo-Regex $line
  $matched = @($modFiles | Where-Object { $_ -match $pattern })
  if ($matched.Count -eq 0) { throw "release-files.txt: '$line' matches no file in mod/" }
  foreach ($rel in $matched) { $entries[$rel] = [IO.Path]::Combine($modDir, $rel) }
}

$info = Get-Content ([IO.Path]::Combine($modDir, 'mod_info', 'stereo_link', 'info.json')) -Raw | ConvertFrom-Json
New-Item -ItemType Directory -Force $OutDir | Out-Null
$destination = [IO.Path]::GetFullPath([IO.Path]::Combine($OutDir, "stereo_link_$($info.version_string).zip"))
if (Test-Path $destination) { Remove-Item $destination -Force }

$folders = [Collections.Generic.SortedSet[string]]::new()
foreach ($rel in $entries.Keys) {
  $parts = $rel.Split('/')
  for ($i = 1; $i -lt $parts.Count; $i++) { [void]$folders.Add(($parts[0..($i - 1)] -join '/') + '/') }
}

$fs = [IO.File]::Open($destination, 'CreateNew')
$zip = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create)
try {
  foreach ($folder in $folders) { [void]$zip.CreateEntry($folder) }
  foreach ($rel in ($entries.Keys | Sort-Object)) {
    [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $entries[$rel], $rel, [IO.Compression.CompressionLevel]::Optimal)
  }
} finally {
  $zip.Dispose(); $fs.Dispose()
}

$leftOut = @($modFiles | Where-Object { -not $entries.Contains($_) })
"$($entries.Count) files -> $destination"
if ($leftOut.Count -gt 0) { "left out of the release ($($leftOut.Count)): " + (($leftOut | ForEach-Object { $_.Split('/')[-1] } | Select-Object -Unique) -join ', ') }
