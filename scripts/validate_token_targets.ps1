param(
  [string]$RootPath,
  [string[]]$Patterns
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Test-Path -Path $RootPath)) {
  throw "RootPath not found: $RootPath"
}

foreach ($p in $Patterns) {
  $glob = Join-Path -Path $RootPath -ChildPath $p
  $matches = Get-ChildItem -Path $glob -File -Recurse -ErrorAction SilentlyContinue
  if (-not $matches) {
    throw "No files matched token target pattern: $p under $RootPath"
  } else {
    Write-Host "Pattern '$p' matched $($matches.Count) file(s)."
  }
}
Write-Host 'Token target patterns validated.'

