param(
  [Parameter(Mandatory=$true)][string]$TestsPath,
  [Parameter(Mandatory=$true)][string]$ResultsFile,
  [string]$ResultsFormat = 'NUnitXml'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
  if (-not (Get-Module -ListAvailable -Name Pester)) {
    Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted
    Install-Module Pester -Scope CurrentUser -Force
  }
  Import-Module Pester

  $dir = Split-Path -Path $ResultsFile -Parent
  if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

  Invoke-Pester -Path $TestsPath -OutputFormat $ResultsFormat -OutputFile $ResultsFile -EnableExit
}
catch {
  Write-Error $_
  throw
}

