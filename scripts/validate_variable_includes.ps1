param(
  [string]$VariableRoot = 'vars',
  [Parameter()][Hashtable[]]$Environments = @()
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$common = Join-Path -Path $VariableRoot -ChildPath 'common.yml'
if (-not (Test-Path -Path $common)) {
  Write-Warning "variables file not found: $common"
}
else {
  Write-Host "Found: $common"
}

foreach ($env in $Environments) {
  $envFile = Join-Path -Path $VariableRoot -ChildPath ("env/{0}.yml" -f $env.name)
  if (-not (Test-Path -Path $envFile)) {
    Write-Warning "variables file not found for environment '$($env.name)': $envFile"
  }
  else {
    Write-Host "Found: $envFile"
  }
}
Write-Host 'Variable include preflight completed.'
