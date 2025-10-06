param(
  [string]$AllowedBranchesJson = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$branchFull = $env:BUILD_SOURCEBRANCH
$branchName = $env:BUILD_SOURCEBRANCHNAME
if (-not $branchFull) { Write-Information -InformationAction Continue -MessageData 'No branch variable found'; exit 0 }

$AllowedBranches = $AllowedBranchesJson | ConvertFrom-Json -ErrorAction Stop

if (!$AllowedBranches) {
  Write-Information -InformationAction Continue -MessageData "No branch restrictions configured."
  exit 0
}

function Test-BranchPattern {
  param(
    [string]$Text,
    [string]$Pattern
  )
  $regex = '^' + [Regex]::Escape($Pattern).Replace('\*', '.*') + '$'
  return [Regex]::IsMatch($Text, $regex)
}

$allowed = $false

# Immediate allow if wildcard present
if ($AllowedBranches -contains '*') {
  $allowed = $true
}
else {
  foreach ($p in $AllowedBranches) {
    if (Test-BranchPattern -Text $branchName -Pattern $p -or Test-BranchPattern -Text $branchFull -Pattern $p) { $allowed = $true; break }
  }
}

if (-not $allowed) {
  Write-Error "Branch '$branchName' is not permitted. Allowed: $($AllowedBranches -join ', ')"
  exit 1
}
else {
  Write-Information -InformationAction Continue -MessageData "Branch '$branchName' permitted."
}
