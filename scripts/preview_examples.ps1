#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$Organization = $env:AZDO_ORG_SERVICE_URL,
    [string]$Project = $env:AZDO_PROJECT,
    [string]$ExamplesBranch = $env:AZDO_EXAMPLES_BRANCH,
    [string]$PipelineCommonRef = $env:AZDO_PIPELINE_COMMON_REF,
    [string]$PipelineDispatcherRef = $env:AZDO_PIPELINE_DISPATCHER_REF,
    [int]$PreviewPipelineId,
    [string[]]$Pipelines
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
    if (-not $ExamplesBranch -and $config.ExamplesBranch) { $ExamplesBranch = $config.ExamplesBranch }
    if (-not $PipelineCommonRef -and $config.PipelineCommonRef) { $PipelineCommonRef = $config.PipelineCommonRef }
    if (-not $PipelineDispatcherRef -and $config.PipelineDispatcherRef) { $PipelineDispatcherRef = $config.PipelineDispatcherRef }
    if (-not $PreviewPipelineId -and $config.PreviewPipelineId) { $PreviewPipelineId = [int]$config.PreviewPipelineId }
    if (-not $PreviewPipelineId -and $config.PipelineIds) { $PreviewPipelineId = [int]$config.PipelineIds[0] }
}

if (-not $ExamplesBranch) { $ExamplesBranch = 'refs/heads/main' }
if (-not $PipelineCommonRef) { $PipelineCommonRef = Get-RepoHeadRef -Path $repoRoot }
if (-not $PipelineDispatcherRef) { $PipelineDispatcherRef = 'refs/heads/main' }

if (-not $Organization) { throw 'Set AZDO_ORG_SERVICE_URL or pass -Organization.' }
if (-not $Project) { throw 'Set AZDO_PROJECT or pass -Project.' }
if (-not $PreviewPipelineId) {
    $envPreview = [Environment]::GetEnvironmentVariable('AZDO_PREVIEW_PIPELINE_ID')
    if ($envPreview) { $PreviewPipelineId = [int]$envPreview }
}
if (-not $PreviewPipelineId) {
    throw 'Provide -PreviewPipelineId, set AZDO_PREVIEW_PIPELINE_ID, or add PreviewPipelineId/PipelineIds to config/azdo-preview.config.psd1.'
}

if (-not $Pipelines) {
    $defaultRoot = Resolve-Path (Join-Path (Split-Path -Parent $PSScriptRoot) '../pipeline-examples/examples/consumer') -ErrorAction Stop
    $Pipelines = Get-ChildItem -Path $defaultRoot.ProviderPath -Filter '*.pipeline.yml' -Recurse -File | Select-Object -ExpandProperty FullName
}

if (-not $Pipelines) {
    throw 'No pipeline files were discovered. Pass paths explicitly with -Pipelines.'
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
foreach ($pipeline in $Pipelines) {
    $yamlContent = Get-Content -Path $pipeline -Raw
    $payload = [ordered]@{
        previewRun = $true
        resources  = @{
            repositories = @{
                self = @{ refName = $ExamplesBranch }
                PipelineCommon = @{ type = 'git'; name = 'wesley-trust/pipeline-common'; refName = $PipelineCommonRef }
                PipelineDispatcher = @{ type = 'git'; name = 'wesley-trust/pipeline-dispatcher'; refName = $PipelineDispatcherRef }
            }
        }
        yamlOverride = $yamlContent
    }

    $payloadFile = New-TemporaryFile
    try {
        $payload | ConvertTo-Json -Depth 20 | Set-Content -Path $payloadFile -Encoding utf8

        $orgBase = $Organization.TrimEnd('/')
        $previewUrl = "$orgBase/$Project/_apis/pipelines/$PreviewPipelineId/runs?api-version=7.1-preview.1"
        $jsonBody = Get-Content -Path $payloadFile -Raw

        try {
            $preview = Invoke-RestMethod -Method Post -Uri $previewUrl -Headers @{ Authorization = $authHeader } -ContentType 'application/json' -Body $jsonBody
        }
        catch {
            $errorMessage = $_
            $responseContent = Get-ErrorContent $_
            $message = 'Azure DevOps preview failed for {0}: {1} {2}' -f $pipeline, $errorMessage, $responseContent
            throw $message
        }
        $status = 'Success'
        $errors = @()
        $propertyNames = $preview.PSObject.Properties.Name

        if ($propertyNames -contains 'preview') {
            $previewBlock = $preview.preview
            if ($previewBlock) {
                $previewProps = $previewBlock.PSObject.Properties.Name
                if ($previewProps -contains 'validationIssues' -and $previewBlock.validationIssues) {
                    $status = 'ValidationFailed'
                    $errors = @($previewBlock.validationIssues)
                }
                elseif ($previewProps -contains 'validationErrors' -and $previewBlock.validationErrors) {
                    $status = 'ValidationFailed'
                    $errors = @($previewBlock.validationErrors)
                }
            }
        }
        elseif ($propertyNames -contains 'validationIssues' -and $preview.validationIssues) {
            $status = 'ValidationFailed'
            $errors = @($preview.validationIssues)
        }
        elseif ($propertyNames -contains 'errors' -and $preview.errors) {
            $status = 'ValidationFailed'
            $errors = @($preview.errors)
        }

        $results += [pscustomobject]@{
            Pipeline = $pipeline
            Status   = $status
            Errors   = $errors
        }
    }
    finally {
        Remove-Item -Path $payloadFile -ErrorAction SilentlyContinue
    }
}

$failed = $results | Where-Object { $_.Status -ne 'Success' }
if ($failed) {
    $failed | ForEach-Object {
        $message = $_.Errors
        if (-not $message) { $message = 'Unknown error' }
        Write-Error "Pipeline preview failed for $($_.Pipeline): $message"
    }
    exit 1
}

return $results
