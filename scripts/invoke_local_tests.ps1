#requires -Version 7.0
[CmdletBinding()]
param(
    [switch]$Passthru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $scriptDirectory
$testsPath = Join-Path $repoRoot 'tests'
$configPath = Join-Path $repoRoot 'config/azdo-preview.config.psd1'
$resultsPath = Join-Path $repoRoot 'testResults.xml'

if (-not (Test-Path -Path $testsPath)) {
    throw "Tests folder not found at $testsPath"
}

if (Test-Path -Path $configPath) {
    $config = Import-PowerShellDataFile -Path $configPath
    if ($config.OrganizationUrl -and -not $env:AZDO_ORG_SERVICE_URL) {
        $env:AZDO_ORG_SERVICE_URL = $config.OrganizationUrl
    }
    if ($config.Project -and -not $env:AZDO_PROJECT) {
        $env:AZDO_PROJECT = $config.Project
    }
    if ($config.PipelineIds -and -not $env:AZDO_PIPELINE_IDS) {
        $env:AZDO_PIPELINE_IDS = ($config.PipelineIds -join ',')
    }
    if ($config.PipelineCommonRef -and -not $env:AZDO_PIPELINE_COMMON_REF) {
        $env:AZDO_PIPELINE_COMMON_REF = $config.PipelineCommonRef
    }
    if ($config.PipelineDispatcherRef -and -not $env:AZDO_PIPELINE_DISPATCHER_REF) {
        $env:AZDO_PIPELINE_DISPATCHER_REF = $config.PipelineDispatcherRef
    }
    if ($config.ExamplesBranch -and -not $env:AZDO_EXAMPLES_BRANCH) {
        $env:AZDO_EXAMPLES_BRANCH = $config.ExamplesBranch
    }
}

$moduleCandidates = Get-Module -Name 'Pester' -ListAvailable | Sort-Object Version -Descending
if (-not $moduleCandidates -or ([version]$moduleCandidates[0].Version -lt [version]'5.0.0')) {
    Install-Module -Name 'Pester' -Scope CurrentUser -Force -MinimumVersion '5.0.0'
    $moduleCandidates = Get-Module -Name 'Pester' -ListAvailable | Sort-Object Version -Descending
}
Import-Module Pester -MinimumVersion 5.0.0 -ErrorAction Stop

$invokeParams = @{ Path = $testsPath; CI = $true }
if (Test-Path -Path $resultsPath) {
    Remove-Item -Path $resultsPath -Force
}
if ($env:TF_BUILD) {
    $invokeParams.OutputFormat = 'NUnitXml'
    $invokeParams.OutputFile = $resultsPath
}
if ($Passthru) {
    $invokeParams.PassThru = $true
}

$results = Invoke-Pester @invokeParams

if ($Passthru) {
    return $results
}

if ($env:TF_BUILD -and (Test-Path -Path $resultsPath)) {
    Write-Host "##vso[results.publish type=NUnit;runTitle=PipelineCommon Validation;resultFiles=$resultsPath]"
}
