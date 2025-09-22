#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$Organization = $env:AZDO_ORG_SERVICE_URL,
    [Parameter(Mandatory = $false)]
    [string]$Project = $env:AZDO_PROJECT,
    [Parameter(Mandatory = $false)]
    [string]$SelfRef = $env:AZDO_SELF_REF,
    [Parameter(Mandatory = $false)]
    [string]$PipelineCommonRef = $env:AZDO_PIPELINE_COMMON_REF,
    [Parameter(Mandatory = $false)]
    [string]$PipelineDispatcherRef = $env:AZDO_PIPELINE_DISPATCHER_REF,
    [Parameter(Mandatory = $false)]
    [int[]]$PipelineIds,
    [switch]$Passthru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$configPath = Join-Path $repoRoot 'config/azdo-preview.config.psd1'
function Get-RepoHeadRef {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [string]$Fallback = 'refs/heads/main'
    )

    try {
        $git = Get-Command git -ErrorAction Stop
    }
    catch {
        return $Fallback
    }

    try {
        $symbolicRef = & $git.Path -C $Path symbolic-ref --quiet HEAD 2>$null
        if ($LASTEXITCODE -eq 0 -and $symbolicRef) {
            return $symbolicRef.Trim()
        }
    }
    catch {
        $symbolicRef = $null
    }

    try {
        $branchName = & $git.Path -C $Path rev-parse --abbrev-ref HEAD 2>$null
        if ($LASTEXITCODE -eq 0 -and $branchName -and $branchName -ne 'HEAD') {
            return "refs/heads/$branchName"
        }
    }
    catch {
        $branchName = $null
    }

    return $Fallback
}
if (Test-Path -Path $configPath) {
    $config = Import-PowerShellDataFile -Path $configPath
    if (-not $Organization -and $config.OrganizationUrl) { $Organization = $config.OrganizationUrl }
    if (-not $Project -and $config.Project) { $Project = $config.Project }
    if (-not $SelfRef -and $config.SelfRef) { $SelfRef = $config.SelfRef }
    if (-not $PipelineCommonRef -and $config.PipelineCommonRef) { $PipelineCommonRef = $config.PipelineCommonRef }
    if (-not $PipelineDispatcherRef -and $config.PipelineDispatcherRef) { $PipelineDispatcherRef = $config.PipelineDispatcherRef }
    if ((-not $PipelineIds -or $PipelineIds.Count -eq 0) -and $config.PipelineIds) { $PipelineIds = $config.PipelineIds }
}

if (-not $SelfRef) { $SelfRef = Get-RepoHeadRef -Path $repoRoot }
if (-not $PipelineCommonRef) { $PipelineCommonRef = $SelfRef }
if (-not $PipelineDispatcherRef) { $PipelineDispatcherRef = 'refs/heads/main' }

if ([string]::IsNullOrEmpty($Organization)) { throw 'Set AZDO_ORG_SERVICE_URL or pass -Organization.' }
if ([string]::IsNullOrEmpty($Project)) { throw 'Set AZDO_PROJECT or pass -Project.' }

if (-not $PipelineIds -or $PipelineIds.Count -eq 0) {
    $envValue = [Environment]::GetEnvironmentVariable('AZDO_PIPELINE_IDS')
    if (-not [string]::IsNullOrEmpty($envValue)) {
        $PipelineIds = $envValue.Split(',', [System.StringSplitOptions]::RemoveEmptyEntries) | ForEach-Object { [int]$_ }
    }
}

if (-not $PipelineIds -or $PipelineIds.Count -eq 0) {
    throw 'Provide -PipelineIds, set AZDO_PIPELINE_IDS, or populate config/azdo-preview.config.psd1 (e.g. 132).'
}

$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $scriptDirectory
$patStorePath = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.pipeline-common/azdo_pat'

function Get-AzDoPat {
    $patValue = $env:AZURE_DEVOPS_EXT_PAT
    if (-not $patValue) {
        $patValue = $env:AZDO_PERSONAL_ACCESS_TOKEN
    }
    if ($patValue) {
        return $patValue
    }

    if (Test-Path -Path $patStorePath) {
        try {
            $storedValue = Get-Content -Path $patStorePath -Raw
            if ($storedValue) {
                try {
                    $secure = ConvertTo-SecureString -String $storedValue -ErrorAction Stop
                    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
                    try {
                        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
                    }
                    finally {
                        if ($ptr -ne [IntPtr]::Zero) {
                            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
                        }
                    }
                }
                catch {
                    return $storedValue
                }
            }
        }
        catch {
            $warnMessage = 'Unable to read cached PAT from {0}: {1}' -f $patStorePath, $_
            Write-Warning $warnMessage
        }
    }

    return $null
}

function Get-ErrorContent {
    param(
        [Parameter(Mandatory)]
        $ErrorRecord
    )

    $responseContent = ''
    $response = $ErrorRecord.Exception.Response
    if ($response -is [System.Net.Http.HttpResponseMessage]) {
        try {
            $responseContent = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        }
        catch { $responseContent = $_.Exception.Message }
    }
    elseif ($response) {
        try {
            $stream = $response.GetResponseStream()
            if ($stream) {
                $reader = New-Object System.IO.StreamReader($stream)
                $responseContent = $reader.ReadToEnd()
            }
        }
        catch { $responseContent = $_.Exception.Message }
    }

    return $responseContent
}

$pat = Get-AzDoPat
if (-not $pat) {
    throw 'Azure DevOps PAT not found. Set AZURE_DEVOPS_EXT_PAT or AZDO_PERSONAL_ACCESS_TOKEN, or rerun scripts/set_azdo_pat.ps1.'
}

$authHeader = 'Basic {0}' -f ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(':' + $pat)))

$results = @()
foreach ($pipelineId in $PipelineIds) {
    $body = [ordered]@{
        previewRun = $true
        resources  = @{
            repositories = @{
                self = @{ refName = $SelfRef }
                PipelineCommon = @{ type = 'git'; name = 'wesley-trust/pipeline-common'; refName = $PipelineCommonRef }
                PipelineDispatcher = @{ type = 'git'; name = 'wesley-trust/pipeline-dispatcher'; refName = $PipelineDispatcherRef }
            }
        }
    }

    $tempFile = New-TemporaryFile
    try {
        $body | ConvertTo-Json -Depth 20 | Set-Content -Path $tempFile -Encoding utf8

        $orgBase = $Organization.TrimEnd('/')
        $previewUrl = "$orgBase/$Project/_apis/pipelines/$pipelineId/runs?api-version=7.1-preview.1"
        $jsonBody = Get-Content -Path $tempFile -Raw

        try {
            $preview = Invoke-RestMethod -Method Post -Uri $previewUrl -Headers @{ Authorization = $authHeader } -ContentType 'application/json' -Body $jsonBody
        }
        catch {
            $errorMessage = $_
            $responseContent = Get-ErrorContent $_
            $message = 'Azure DevOps preview failed for pipeline id {0}: {1} {2}' -f $pipelineId, $errorMessage, $responseContent
            throw $message
        }
        $status = 'Success'
        $issues = @()
        $propertyNames = $preview.PSObject.Properties.Name

        if ($propertyNames -contains 'preview') {
            $previewBlock = $preview.preview
            if ($previewBlock) {
                $previewProps = $previewBlock.PSObject.Properties.Name
                if ($previewProps -contains 'validationIssues' -and $previewBlock.validationIssues) {
                    $status = 'ValidationFailed'
                    $issues = @($previewBlock.validationIssues)
                }
                elseif ($previewProps -contains 'validationErrors' -and $previewBlock.validationErrors) {
                    $status = 'ValidationFailed'
                    $issues = @($previewBlock.validationErrors)
                }
            }
        }
        elseif ($propertyNames -contains 'validationIssues' -and $preview.validationIssues) {
            $status = 'ValidationFailed'
            $issues = @($preview.validationIssues)
        }

        if (($issues.Count -eq 0) -and ($propertyNames -contains 'errors') -and $preview.errors) {
            $status = 'ValidationFailed'
            $issues = @($preview.errors)
        }

        if ($issues.Count -gt 0) {
            $results += [pscustomobject]@{
                PipelineId = $pipelineId
                Status     = $status
                Issues     = $issues
            }
        }
        else {
            $results += [pscustomobject]@{
                PipelineId = $pipelineId
                Status     = $status
                Issues     = @()
            }
        }
    }
    finally {
        Remove-Item -Path $tempFile -ErrorAction SilentlyContinue
    }
}

$failed = $results | Where-Object { $_.Status -ne 'Success' }
if ($failed) {
    $failed | ForEach-Object {
        $message = if ($_.Issues -and $_.Issues.Count) { $_.Issues } else { 'Unknown error' }
        Write-Error "Pipeline preview failed for id $($_.PipelineId): $message"
    }
    exit 1
}

if ($Passthru) {
    return $results
}
