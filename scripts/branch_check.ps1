param(
  [string[]]$AllowedBranches = @(),
  [string]$AllowedBranchesCsv = '',
  [string]$AllowedBranchesJson = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$branchFull = $env:BUILD_SOURCEBRANCH
$branchName = $env:BUILD_SOURCEBRANCHNAME
if (-not $branchFull) { Write-Information -InformationAction Continue -MessageData 'No branch variable found'; exit 0 }

function Normalise-List([object[]]$items) {
  if (-not $items) { return @() }
  return $items |
  ForEach-Object { if ($null -eq $_) { '' } else { $_.ToString() } } |
  ForEach-Object { $_.Trim() } |
  Where-Object { $_ -ne '' }
}

$fromCsv = @()
if ((-not $AllowedBranches) -and -not [string]::IsNullOrWhiteSpace($AllowedBranchesCsv)) {
  $fromCsv = $AllowedBranchesCsv -split ',' | ForEach-Object { ($_ ?? '').Trim().Trim('\'',''\"') }
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

$AllowedBranches = Normalise-List -items @($AllowedBranches + $fromCsv + $fromJson)

if (-not $AllowedBranches -or $AllowedBranches.Count -eq 0) {
  Write-Information -InformationAction Continue -MessageData "No branch restrictions configured."
  exit 0
}

function Match-Pattern($text, $pattern) {
  $regex = '^' + [Regex]::Escape($pattern).Replace('\*', '.*') + '$'
  return [Regex]::IsMatch($text, $regex)
}

$allowed = $false

# Immediate allow if wildcard present
if ($AllowedBranches -contains '*') {
  $allowed = $true
}
else {
  foreach ($p in $AllowedBranches) {
    if (Match-Pattern $branchName $p -or Match-Pattern $branchFull $p) { $allowed = $true; break }
  }
}

if (-not $allowed) {
  Write-Error "Branch '$branchName' is not permitted. Allowed: $($AllowedBranches -join ', ')"
  exit 1
}
else {
  Write-Information -InformationAction Continue -MessageData "Branch '$branchName' permitted."
}
