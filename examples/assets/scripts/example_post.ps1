param(
  [string]$EnvName = ''
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Write-Host "[example_post] Running for environment: $EnvName"
Write-Host "Goodbye from example_post.ps1"

