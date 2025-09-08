param(
  [Parameter(
    Mandatory = $true
  )]
  [string]
  $Name,
  [Parameter(
    Mandatory = $true
  )]
  [string]
  $Class
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Allowed Classes
$classes = @('development', 'test', 'acceptance', 'production')

# Identify Acceptance Environment
$preprod = $Class | Where-Object { $_.class -eq 'acceptance' }

# Identify Production Environment
$prod = $Class | Where-Object { $_.class -eq 'production' }

# Check environment count
if ($preprod.Count -gt 1) { throw 'At most one acceptance environment allowed.' }
if ($prod.Count -gt 1) { throw 'At most one production environment allowed.' }

if ($Environment.class -notin $classes) {
  throw "Invalid class '$($Class)' for environment '$Name'."
}

Write-Host 'Environment model validation passed.'