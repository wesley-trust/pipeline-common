param(
  [Parameter(
    Mandatory = $true
  )]
  [Hashtable[]]
  $Environment
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Allowed Classes
$classes = @('development', 'test', 'acceptance', 'production')

# Identify Acceptance Environment
$preprod = $Environment | Where-Object { $_.class -eq 'acceptance' }

# Identify Production Environment
$prod = $Environment | Where-Object { $_.class -eq 'production' }

# Check environment count
if ($preprod.Count -gt 1) { throw 'At most one acceptance environment allowed.' }
if ($prod.Count -gt 1) { throw 'At most one production environment allowed.' }

if ($Environment.class -notin $classes) {
  throw "Invalid class '$($env.class)' for environment '$($env.name)'."
}

Write-Host 'Environment model validation passed.'