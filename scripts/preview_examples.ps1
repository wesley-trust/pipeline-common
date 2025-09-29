#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$Organization = $env:AZDO_ORG_SERVICE_URL,
    [string]$Project = $env:AZDO_PROJECT,
    [string]$ExamplesBranch = $env:AZDO_EXAMPLES_BRANCH,
    [string]$PipelineCommonRef = $env:AZDO_PIPELINE_COMMON_REF,
    [string]$PipelineDispatcherRef = $env:AZDO_PIPELINE_DISPATCHER_REF,
    [int]$PreviewPipelineId,
    [string[]]$Pipelines,
    [hashtable[]]$PipelineDefinitions
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
    if (-not $PipelineDefinitions -and $config.ContainsKey('PipelineDefinitions')) { $PipelineDefinitions = $config.PipelineDefinitions }
}

$pipelineCommonHead = Get-RepoHeadRef -Path $repoRoot
if (-not $PipelineCommonRef) {
    $PipelineCommonRef = $pipelineCommonHead
}
elseif ($PipelineCommonRef -eq 'refs/heads/main' -and $pipelineCommonHead -and $pipelineCommonHead -ne 'refs/heads/main') {
    $PipelineCommonRef = $pipelineCommonHead
}

$examplesRepoPath = $null
try {
    $examplesRepoPath = (Resolve-Path (Join-Path $repoRoot '..' 'pipeline-examples')).ProviderPath
}
catch {
    $examplesRepoPath = $null
}

if (-not $ExamplesBranch) {
    if ($examplesRepoPath) {
        $examplesHead = Get-RepoHeadRef -Path $examplesRepoPath
        if ($examplesHead) {
            $ExamplesBranch = $examplesHead
        }
    }
}

if (-not $ExamplesBranch) {
    $ExamplesBranch = 'refs/heads/main'
}
elseif ($examplesRepoPath -and $ExamplesBranch -eq 'refs/heads/main') {
    $examplesHead = Get-RepoHeadRef -Path $examplesRepoPath
    if ($examplesHead -and $examplesHead -ne 'refs/heads/main') {
        $ExamplesBranch = $examplesHead
    }
}

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

function Get-NormalizedRelativePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    $normalized = $Path -replace '\\', '/'
    $normalized = $normalized.Trim()
    $normalized = $normalized.Trim('/')
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return $null
    }

    return $normalized.ToLowerInvariant()
}

function Get-DefaultParameterSet {
    param(
        [string]$Name = 'default'
    )

    return [pscustomobject]@{
        Name               = $Name
        TemplateParameters = $null
        Variables          = $null
    }
}

function ConvertTo-PipelineDefinition {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Definition
    )

    $id = $null
    foreach ($key in @('PipelineId', 'Id')) {
        if ($Definition.ContainsKey($key) -and $Definition[$key]) {
            $id = [int]$Definition[$key]
            break
        }
    }

    $name = $null
    foreach ($key in @('Name', 'DisplayName')) {
        if ($Definition.ContainsKey($key) -and $Definition[$key]) {
            $name = [string]$Definition[$key]
            break
        }
    }

    $path = $null
    foreach ($key in @('PipelinePath', 'Path', 'File')) {
        if ($Definition.ContainsKey($key) -and $Definition[$key]) {
            $path = [string]$Definition[$key]
            break
        }
    }

    $parameterSets = @()
    if ($Definition.ContainsKey('ParameterSets') -and $Definition.ParameterSets) {
        foreach ($rawSet in @($Definition.ParameterSets)) {
            if (-not $rawSet) { continue }

            if ($rawSet -is [hashtable]) {
                $setName = $null
                if ($rawSet.ContainsKey('Name') -and $rawSet.Name) {
                    $setName = [string]$rawSet.Name
                }

                $templateParameters = $null
                foreach ($key in @('TemplateParameters', 'templateParameters', 'Parameters')) {
                    if ($rawSet.ContainsKey($key) -and $rawSet[$key]) {
                        $templateParameters = [hashtable]$rawSet[$key]
                        break
                    }
                }

                $variables = $null
                foreach ($key in @('Variables', 'variables')) {
                    if ($rawSet.ContainsKey($key) -and $rawSet[$key]) {
                        $variables = [hashtable]$rawSet[$key]
                        break
                    }
                }

                if (-not $setName) { $setName = 'default' }
                if ($templateParameters -and $templateParameters.Count -eq 0) { $templateParameters = $null }
                if ($variables -and $variables.Count -eq 0) { $variables = $null }

                $parameterSets += [pscustomobject]@{
                    Name               = $setName
                    TemplateParameters = $templateParameters
                    Variables          = $variables
                }
            }
            elseif ($rawSet -is [string]) {
                $parameterSets += [pscustomobject]@{
                    Name               = [string]$rawSet
                    TemplateParameters = $null
                    Variables          = $null
                }
            }
        }
    }

    if ($parameterSets.Count -eq 0) {
        $parameterSets = @(Get-DefaultParameterSet)
    }

    return [pscustomobject]@{
        PipelineId    = $id
        Name          = $name
        PipelinePath  = $path
        ParameterSets = $parameterSets
    }
}

function Get-UniqueParameterSet {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject[]]$ParameterSets
    )

    $unique = @{}
    $ordered = @()
    foreach ($set in @($ParameterSets)) {
        if (-not $set) { continue }
        $key = if ($set.Name) { $set.Name.ToLowerInvariant() } else { [Guid]::NewGuid().ToString() }
        if (-not $unique.ContainsKey($key)) {
            $unique[$key] = $true
            $ordered += $set
        }
    }

    return $ordered
}

function Get-ParameterSetContext {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Pipeline,
        [string]$RelativePath,
        [pscustomobject]$Definition,
        [pscustomobject]$ParameterSet
    )

    $parts = @()
    if ($Definition -and $Definition.PipelineId) {
        $parts += "pipeline id $($Definition.PipelineId)"
    }
    if ($Definition -and $Definition.Name) {
        $parts += $Definition.Name
    }
    if ($RelativePath) {
        $parts += $RelativePath
    }
    if ($Pipeline) {
        $parts += $Pipeline
    }
    if ($ParameterSet -and $ParameterSet.Name) {
        $parts += "parameter set '$($ParameterSet.Name)'"
    }
    if ($parts.Count -eq 0) {
        return 'pipeline preview'
    }
    return ($parts -join ' / ')
}

$pat = Get-AzDoPat
if (-not $pat) {
    throw 'Azure DevOps PAT not found. Set AZURE_DEVOPS_EXT_PAT or AZDO_PERSONAL_ACCESS_TOKEN, or rerun scripts/set_azdo_pat.ps1.'
}

$authHeader = 'Basic {0}' -f ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(':' + $pat)))

$definitionLookup = @{}
if ($PipelineDefinitions) {
    foreach ($definition in $PipelineDefinitions) {
        if (-not $definition) { continue }
        if ($definition -isnot [hashtable]) { continue }

        $converted = ConvertTo-PipelineDefinition -Definition $definition
        if (-not $converted) { continue }

        $convertedObject = [pscustomobject]@{
            PipelineId    = $converted.PipelineId
            Name          = $converted.Name
            PipelinePath  = $converted.PipelinePath
            ParameterSets = Get-UniqueParameterSet -ParameterSets $converted.ParameterSets
        }

        $candidateKeys = @()
        if ($convertedObject.PipelinePath) {
            $candidateKeys += $convertedObject.PipelinePath
            $candidateKeys += (Join-Path 'pipeline-examples' $convertedObject.PipelinePath)
        }

        if ($examplesRepoPath -and $convertedObject.PipelinePath) {
            $fullCandidate = Join-Path $examplesRepoPath $convertedObject.PipelinePath
            try {
                $relativeToExamples = [System.IO.Path]::GetRelativePath($examplesRepoPath, $fullCandidate)
                if ($relativeToExamples) {
                    $candidateKeys += $relativeToExamples
                }
            }
            catch {
                Write-Verbose ("Unable to build pipeline path relative to examples repository for '{0}': {1}" -f $convertedObject.PipelinePath, $_.Exception.Message)
            }

            try {
                $relativeToRepoCandidate = [System.IO.Path]::GetRelativePath($repoRoot, $fullCandidate)
                if ($relativeToRepoCandidate) {
                    $candidateKeys += $relativeToRepoCandidate
                }
            }
            catch {
                Write-Verbose ("Unable to build pipeline path relative to current repository for '{0}': {1}" -f $convertedObject.PipelinePath, $_.Exception.Message)
            }
        }

        $normalizedKeys = @()
        foreach ($key in $candidateKeys) {
            $normalized = Get-NormalizedRelativePath -Path $key
            if ($normalized) { $normalizedKeys += $normalized }
        }
        $normalizedKeys = $normalizedKeys | Sort-Object -Unique

        if ($normalizedKeys.Count -eq 0) { continue }

        foreach ($key in $normalizedKeys) {
            if ($definitionLookup.ContainsKey($key)) {
                $existing = $definitionLookup[$key]
                $existing.ParameterSets = Get-UniqueParameterSet -ParameterSets @($existing.ParameterSets + $convertedObject.ParameterSets)
                if (-not $existing.PipelineId -and $convertedObject.PipelineId) { $existing.PipelineId = $convertedObject.PipelineId }
                if (-not $existing.Name -and $convertedObject.Name) { $existing.Name = $convertedObject.Name }
                if (-not $existing.PipelinePath -and $convertedObject.PipelinePath) { $existing.PipelinePath = $convertedObject.PipelinePath }
            }
            else {
                $definitionLookup[$key] = [pscustomobject]@{
                    PipelineId    = $convertedObject.PipelineId
                    Name          = $convertedObject.Name
                    PipelinePath  = $convertedObject.PipelinePath
                    ParameterSets = $convertedObject.ParameterSets
                }
            }
        }
    }
}

$results = @()
foreach ($pipeline in $Pipelines) {
    $yamlContent = Get-Content -Path $pipeline -Raw

    $candidatePaths = @()
    if ($examplesRepoPath) {
        try {
            $relativeToExamples = [System.IO.Path]::GetRelativePath($examplesRepoPath, $pipeline)
            if ($relativeToExamples) {
                $candidatePaths += $relativeToExamples
            }
        }
        catch {
            Write-Verbose ("Unable to compute candidate path relative to examples repository for '{0}': {1}" -f $pipeline, $_.Exception.Message)
        }
    }

    try {
        $relativeToRepo = [System.IO.Path]::GetRelativePath($repoRoot, $pipeline)
        if ($relativeToRepo) {
            $candidatePaths += $relativeToRepo
        }
    }
    catch {
        Write-Verbose ("Unable to compute candidate path relative to current repository for '{0}': {1}" -f $pipeline, $_.Exception.Message)
    }

    $candidatePaths += $pipeline

    $normalizedCandidates = @()
    foreach ($candidate in $candidatePaths) {
        $normalizedCandidate = Get-NormalizedRelativePath -Path $candidate
        if ($normalizedCandidate) {
            $normalizedCandidates += $normalizedCandidate
        }
    }
    $normalizedCandidates = $normalizedCandidates | Sort-Object -Unique

    $definition = $null
    foreach ($candidateKey in $normalizedCandidates) {
        if ($definitionLookup.ContainsKey($candidateKey)) {
            $definition = $definitionLookup[$candidateKey]
            break
        }
    }

    $relativePath = $null
    if ($examplesRepoPath) {
        try {
            $relativePath = [System.IO.Path]::GetRelativePath($examplesRepoPath, $pipeline)
        }
        catch {
            Write-Verbose ("Unable to compute relative path for '{0}' within examples repository: {1}" -f $pipeline, $_.Exception.Message)
        }
    }
    if (-not $relativePath -and $normalizedCandidates.Count -gt 0) {
        $relativePath = $normalizedCandidates[0]
    }

    $parameterSets = @()
    if ($definition -and $definition.ParameterSets) {
        $parameterSets = $definition.ParameterSets
    }
    if (-not $parameterSets -or $parameterSets.Count -eq 0) {
        $parameterSets = @(Get-DefaultParameterSet)
    }

    foreach ($parameterSet in $parameterSets) {
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

        if ($parameterSet.TemplateParameters -and $parameterSet.TemplateParameters.Count -gt 0) {
            $payload.templateParameters = $parameterSet.TemplateParameters
        }
        if ($parameterSet.Variables -and $parameterSet.Variables.Count -gt 0) {
            $payload.variables = $parameterSet.Variables
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
                $message = 'Azure DevOps preview failed for {0}: {1} {2}' -f (Get-ParameterSetContext -Pipeline $pipeline -RelativePath $relativePath -Definition $definition -ParameterSet $parameterSet), $errorMessage, $responseContent
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
                    elseif ($previewProps -contains 'errors' -and $previewBlock.errors) {
                        $status = 'ValidationFailed'
                        $errors = @($previewBlock.errors)
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
                Pipeline     = $pipeline
                RelativePath = $relativePath
                Definition   = $definition
                ParameterSet = $parameterSet
                Status       = $status
                Errors       = $errors
            }
        }
        finally {
            Remove-Item -Path $payloadFile -ErrorAction SilentlyContinue
        }
    }
}

$failed = $results | Where-Object { $_.Status -ne 'Success' }
if ($failed) {
    $failed | ForEach-Object {
        $message = $_.Errors
        if (-not $message) { $message = 'Unknown error' }
        $parameterSetContext = if ($_.ParameterSet) { $_.ParameterSet } else { Get-DefaultParameterSet }
        Write-Error "Pipeline preview failed for $(Get-ParameterSetContext -Pipeline $_.Pipeline -RelativePath $_.RelativePath -Definition $_.Definition -ParameterSet $parameterSetContext): $message"
    }
    exit 1
}

return $results
