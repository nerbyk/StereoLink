param([Parameter(Mandatory)][string]$Version)
# Prints the CHANGELOG.md section of one version, used as the GitHub release text.
$ErrorActionPreference = 'Stop'
$lines = Get-Content ([IO.Path]::Combine($PSScriptRoot, '..', 'CHANGELOG.md'))
$start = [array]::IndexOf($lines, "## $Version")
if ($start -lt 0) { throw "CHANGELOG.md has no '## $Version' section" }
$section = $lines[($start + 1)..($lines.Count - 1)] | ForEach-Object -Begin { $done = $false } -Process {
  if ($_ -match '^## ') { $done = $true }
  if (-not $done) { $_ }
}
($section -join "`n").Trim()
