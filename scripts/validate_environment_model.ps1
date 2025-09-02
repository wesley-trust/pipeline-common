param(
  [Parameter(Mandatory=$true)][Hashtable[]]$Environments
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$classes = @('development','test','acceptance','production')
$preprod = $Environments | Where-Object { $_.class -eq 'acceptance' }
$prod = $Environments | Where-Object { $_.class -eq 'production' }
if ($preprod.Count -gt 1) { throw 'At most one acceptance environment allowed.' }
if ($prod.Count -gt 1) { throw 'At most one production environment allowed.' }

foreach ($env in $Environments) {
  if (-not $classes.Contains([string]$env.class)) {
    throw "Invalid class '$($env.class)' for environment '$($env.name)'."
  }
}

# Optional: basic ordering check if dependsOn provided
foreach ($env in $Environments) {
  if ($env.dependsOn) {
    $dep = $Environments | Where-Object { $_.name -eq $env.dependsOn }
    if (-not $dep) { throw "dependsOn references unknown environment: $($env.dependsOn) for '$($env.name)'" }
  }
}

Write-Host 'Environment model validation passed.'

