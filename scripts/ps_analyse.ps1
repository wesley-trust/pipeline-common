param(
  [string]$Path = '.',
  [string[]]$IncludeRules = @(),
  [string[]]$ExcludeRules = @()
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
  Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted
  Install-Module PSScriptAnalyzer -Scope CurrentUser -Force
}
Import-Module PSScriptAnalyzer
$results = Invoke-ScriptAnalyzer -Path $Path -Recurse -Severity Error, Warning -IncludeRule $IncludeRules -ExcludeRule $ExcludeRules
if ($results) {
  $results | Format-Table | Out-String | Write-Host
  if ($results.Severity -contains 'Error') { throw 'PSScriptAnalyzer errors found.' }
}
Write-Host 'PowerShell analysis passed.'

