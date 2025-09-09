param(
  [Parameter(
    Mandatory = $true
  )]
  [string]
  $EnvironmentsJson
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Allowed Classes
$classes = @('development', 'test', 'acceptance', 'production')

# Convert back to object
$Environments = $EnvironmentsJson | ConvertFrom-Json

# Identify Acceptance Environment
$acceptance = $Environments | Where-Object { $_.class -eq 'acceptance' }

# Identify Production Environment
$production = $Environments | Where-Object { $_.class -eq 'production' }

# Check class environment count
if ($acceptance.Count -gt 1) {
  throw 'At most one acceptance environment allowed.' 
}
if ($production.Count -gt 1) {
  throw 'At most one production environment allowed.'
}

# Check for valid class
foreach ($Environment in $Environments) {
  if ($Environment.class -notin $classes) {
    throw "Invalid class '$($Environment.class)' for environment '$($Environment.name)'."
  }
}

Write-Host 'Environment model validation passed.'