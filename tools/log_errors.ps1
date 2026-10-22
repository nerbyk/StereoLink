param(
  # Regex of the marker line; only lines after its LAST occurrence are inspected.
  # Put a marker first, e.g. via MCP run_lua: log('I', 'stereoLink', 'GATE ' .. os.time())
  [Alias('Marker')][string]$After = 'activateMod',
  [int]$Max = 80,
  # Only lines that mention our mod (stereoLink / stereo_link).
  [switch]$OursOnly,
  [string]$Log = (Join-Path $env:LOCALAPPDATA 'BeamNG\BeamNG.drive\current\beamng.log')
)
# Unique warnings/errors in beamng.log after the last line matching $After.
$lines = Get-Content $Log
$start = 0
for ($i = $lines.Count - 1; $i -ge 0; $i--) { if ($lines[$i] -match $After) { $start = $i; break } }
$seen = @{}
$out = @()
for ($i = $start; $i -lt $lines.Count; $i++) {
  $l = $lines[$i]
  if ($l -notmatch '\|(E|W)\|' -and $l -notmatch 'Exception|attempt to|stack traceback') { continue }
  if ($l -match 'ActionMap::addBinding|onFileChanged|Stack Traceback|<< END <<') { continue }
  if ($OursOnly -and $l -notmatch 'stereoLink|stereo_link') { continue }
  $key = ($l -replace '^\s*[\d.]+\|', '') -replace '0x[0-9a-f]+', 'X' -replace '\d+', 'N'
  if ($seen.ContainsKey($key)) { $seen[$key]++; continue }
  $seen[$key] = 1
  $out += $l.Substring(0, [Math]::Min(300, $l.Length))
}
"lines from start: $($lines.Count - $start), unique issues: $($out.Count)"
$out | Select-Object -First $Max
