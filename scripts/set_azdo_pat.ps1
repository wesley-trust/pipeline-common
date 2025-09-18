#requires -Version 7.0
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $scriptDirectory
$configPath = Join-Path $repoRoot 'config/azdo-preview.config.psd1'
$patStoreDirectory = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.pipeline-common'
$patStorePath = Join-Path $patStoreDirectory 'azdo_pat'

$organization = $env:AZDO_ORG_SERVICE_URL
if (-not $organization -and (Test-Path -Path $configPath)) {
    try {
        $config = Import-PowerShellDataFile -Path $configPath
        if ($config.OrganizationUrl) {
            $organization = $config.OrganizationUrl
        }
    }
    catch {
        $warnMessage = 'Unable to load organization URL from {0}: {1}' -f $configPath, $_
        Write-Warning $warnMessage
    }
}

if (-not $organization) {
    $organization = Read-Host -Prompt 'Enter Azure DevOps organization URL (e.g. https://dev.azure.com/<org>)'
}

if ([string]::IsNullOrWhiteSpace($organization)) {
    throw 'Azure DevOps organization URL is required.'
}

$securePat = Read-Host -Prompt 'Enter Azure DevOps PAT (input hidden)' -AsSecureString
if (-not $securePat -or $securePat.Length -eq 0) {
    throw 'No PAT provided. Aborting.'
}

$plainTextPtr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePat)
$plainText = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($plainTextPtr)

try {
    $azCommand = Get-Command az -ErrorAction Stop
    $azPath = $azCommand.Path

    $env:AZURE_DEVOPS_EXT_PAT = $plainText
    $env:AZDO_PERSONAL_ACCESS_TOKEN = $plainText
    if (-not $env:AZDO_ORG_SERVICE_URL) {
        $env:AZDO_ORG_SERVICE_URL = $organization
    }

    $loginOutput = $plainText | & $azPath devops login --organization $organization 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "az devops login failed: $loginOutput"
    }

    try {
        if (-not (Test-Path -Path $patStoreDirectory)) {
            $null = New-Item -ItemType Directory -Path $patStoreDirectory -Force
        }

        Set-Content -Path $patStorePath -Value $plainText -Encoding utf8 -Force

        try { chmod 600 $patStorePath } catch { }

        Write-Information -InformationAction Continue -MessageData ("Stored Azure DevOps PAT at {0}" -f $patStorePath)
    }
    catch {
        $warnMessage = 'Failed to persist PAT to {0}: {1}' -f $patStorePath, $_
        Write-Warning $warnMessage
    }

    Write-Information -InformationAction Continue -MessageData 'Azure DevOps PAT cached and CLI login completed for this session.'
}
finally {
    if ($plainTextPtr -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($plainTextPtr)
    }
}
