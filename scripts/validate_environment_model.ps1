param(
  [Parameter(
    Mandatory = $true
  )]
  [string]
  $Environments
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Allowed Classes
$classes = @('development', 'test', 'acceptance', 'production')

# Identify Acceptance Environment
$acceptance = $Environments | Where-Object { $Environments.class -eq 'acceptance' }

# Identify Production Environment
$production = $Class | Where-Object { $Environments.class -eq 'production' }

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