param(
  [string]$RootPath,
  [string[]]$Patterns
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Test-Path -Path $RootPath)) {
  throw "RootPath not found: $RootPath"
}

foreach ($Pattern in $Patterns) {
  $glob = Join-Path -Path $RootPath -ChildPath $Pattern
  $matches = Get-ChildItem -Path $glob -File -Recurse -ErrorAction SilentlyContinue
  if (-not $matches) {
    throw "No files matched token target pattern: $Pattern under $RootPath"
  }
  else {
    $matchCount = ($matches | Measure-Object).Count
    Write-Information -InformationAction Continue -MessageData "Pattern '$Pattern' matched $matchCount file(s)."
  }
}
Write-Information -InformationAction Continue -MessageData "Token target patterns validated."
