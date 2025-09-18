param(
  [string]$DefaultPoolName = '',
  [string]$DefaultPoolVmImage = '',
  [Parameter()][Hashtable[]]$EnvPools = @()
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($DefaultPoolName -and $DefaultPoolVmImage) {
  throw 'defaultPool cannot define both name and vmImage. Choose one.'
}

foreach ($p in $EnvPools) {
  $envName = [string]$p.envName
  $name = [string]$p.name
  $vmImage = [string]$p.vmImage
  if ($name -and $vmImage) {
    throw "Environment '$envName' pool cannot define both name and vmImage. Choose one."
  }
}
Write-Information -InformationAction Continue -MessageData "Pool configuration validated successfully."
