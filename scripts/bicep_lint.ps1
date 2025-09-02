param(
  [string]$SearchPath = '.'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
az bicep install | Out-Null
az bicep version | Out-Null
$files = Get-ChildItem -Path $SearchPath -Recurse -Include *.bicep
foreach ($f in $files) {
  Write-Host "Linting $($f.FullName)"
  az bicep build --file "$($f.FullName)" | Out-Null
}
Write-Host 'Bicep lint passed.'

