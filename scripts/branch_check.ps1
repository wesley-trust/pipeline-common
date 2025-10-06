param(
  [string]$AllowedBranchesJson = ''
)

$AllowedBranchesJson

$AllowedBranchesJson | ConvertFrom-Json

break

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$branchFull = $env:BUILD_SOURCEBRANCH
$branchName = $env:BUILD_SOURCEBRANCHNAME
if (-not $branchFull) { Write-Information -InformationAction Continue -MessageData 'No branch variable found'; exit 0 }

function ConvertTo-NormalizedList {
  param([object[]]$Items)
  if (-not $Items) { return @() }
  return $Items |
  ForEach-Object { if ($null -eq $_) { '' } else { $_.ToString() } } |
  ForEach-Object { $_.Trim() } |
  Where-Object { $_ -ne '' }
}

$fromJson = @()
if ((-not $AllowedBranches) -and (-not $fromCsv) -and -not [string]::IsNullOrWhiteSpace($AllowedBranchesJson)) {
  try {
    $parsed = $AllowedBranchesJson | ConvertFrom-Json -ErrorAction Stop
    if ($parsed -is [Array]) {
      $fromJson = $parsed | ForEach-Object { ($_ ?? '').ToString() }
    }
    elseif ($parsed) {
      $fromJson = @($parsed.ToString())
    }
  }
  catch {
    Write-Warning -Message "Failed to parse AllowedBranchesJson: $($_.Exception.Message)"
  }
}

$AllowedBranches = ConvertTo-NormalizedList -Items @($AllowedBranches + $fromCsv + $fromJson)

if (-not $AllowedBranches -or $AllowedBranches.Count -eq 0) {
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
    if (Test-BranchPattern -Text $branchFull -Pattern $p) { $allowed = $true; break }
    #if (Test-BranchPattern -Text $branchName -Pattern $p -or Test-BranchPattern -Text $branchFull -Pattern $p) { $allowed = $true; break }
  }
}

if (-not $allowed) {
  Write-Error "Branch '$branchName' is not permitted. Allowed: $($AllowedBranches -join ', ')"
  exit 1
}
else {
  Write-Information -InformationAction Continue -MessageData "Branch '$branchName' permitted."
}
