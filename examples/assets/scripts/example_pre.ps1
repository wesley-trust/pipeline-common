param(
  [string]$EnvName = ''
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Write-Host "[example_pre] Running for environment: $EnvName"
Write-Host "Hello from example_pre.ps1"

