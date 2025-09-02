param(
  [string[]]$AllowedBranches = @()
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$branchFull = $env:BUILD_SOURCEBRANCH
$branchName = $env:BUILD_SOURCEBRANCHNAME
if (-not $branchFull) { Write-Host 'No branch variable found'; exit 0 }

if (-not $AllowedBranches -or $AllowedBranches.Count -eq 0) {
  Write-Host 'No branch restrictions configured.'
  exit 0
}

function Match-Pattern($text, $pattern) {
  $regex = '^' + [Regex]::Escape($pattern).Replace('\*','.*') + '$'
  return [Regex]::IsMatch($text, $regex)
}

$allowed = $false
foreach ($p in $AllowedBranches) {
  if (Match-Pattern $branchName $p) { $allowed = $true; break }
}

if (-not $allowed) {
  Write-Error "Branch '$branchName' is not permitted. Allowed: $($AllowedBranches -join ', ')"
  exit 1
} else {
  Write-Host "Branch '$branchName' permitted."
}

