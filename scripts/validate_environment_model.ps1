param(
  [Parameter(
    Mandatory = $true
  )]
  [string]
  $EnvironmentsJson,
  [bool]
  $EnableProduction = $false
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

# Enforce acceptance when production is enabled
if ($EnableProduction) {
  if ($production.Count -eq 0) {
    throw 'enableProduction is true but no production environment is defined.'
  }

  if ([System.Convert]::ToBoolean($production[0].skipEnvironment)) {
    throw "Production environment '$($production[0].name)' cannot be skipped when enableProduction is true."
  }

  if ($acceptance.Count -eq 0) {
    throw 'An acceptance environment must be defined when enableProduction is true.'
  }

  if ([System.Convert]::ToBoolean($acceptance[0].skipEnvironment)) {
    throw "Acceptance environment '$($acceptance[0].name)' cannot be skipped when enableProduction is true."
  }
}

Write-Host 'Environment model validation passed.'
