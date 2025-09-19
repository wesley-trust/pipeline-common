#requires -Version 7.0
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Ensure-Module {
    param(
        [Parameter(Mandatory)]
        [string]$ModuleName,
        [string]$MinimumVersion = $null
    )

    $moduleParams = @{ Name = $ModuleName; ListAvailable = $true }
    $existing = Get-Module @moduleParams | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $existing -or ($MinimumVersion -and ([version]$existing.Version -lt [version]$MinimumVersion))) {
        $installParams = @{ Name = $ModuleName; Scope = 'CurrentUser'; Force = $true }
        if ($MinimumVersion) {
            $installParams.MinimumVersion = $MinimumVersion
        }

        Install-Module @installParams
    }

    if ($MinimumVersion) {
        Import-Module -Name $ModuleName -MinimumVersion $MinimumVersion -ErrorAction Stop
    }
    else {
        Import-Module -Name $ModuleName -ErrorAction Stop
    }
}

Ensure-Module -ModuleName 'Pester' -MinimumVersion '5.0.0'
Ensure-Module -ModuleName 'powershell-yaml'

$script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).ProviderPath
$script:templatesRoot = Join-Path $repoRoot 'templates'
$script:scriptsRoot = Join-Path $repoRoot 'scripts'
$script:examplesRoot = Resolve-Path (Join-Path $repoRoot '..' 'pipeline-examples') -ErrorAction SilentlyContinue
$script:pipelineDispatcherRepo = $null
$script:previewConfig = $null

$configPath = Join-Path $repoRoot 'config/azdo-preview.config.psd1'
if (Test-Path -Path $configPath) {
    try {
        $script:previewConfig = Import-PowerShellDataFile -Path $configPath
    }
    catch {
        $message = 'Failed to load preview config from {0}: {1}' -f $configPath, $_
        Write-Warning $message
    }
}

function Get-PreviewConfigValue {
    param(
        [Parameter(Mandatory)]
        [string]$Key
    )

    if ($script:previewConfig -and $script:previewConfig.ContainsKey($Key)) {
        return $script:previewConfig[$Key]
    }

    return $null
}

function Test-HasAzDoPat {
    $pat = [Environment]::GetEnvironmentVariable('AZURE_DEVOPS_EXT_PAT')
    if (-not [string]::IsNullOrWhiteSpace($pat)) {
        return $true
    }

    $pat = [Environment]::GetEnvironmentVariable('AZDO_PERSONAL_ACCESS_TOKEN')
    if (-not [string]::IsNullOrWhiteSpace($pat)) {
        return $true
    }

    $patStore = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.pipeline-common/azdo_pat'
    return Test-Path -Path $patStore
}

function Get-TemplateReferences {
    param(
        [Parameter(Mandatory)]
        [string]$FilePath
    )

    $content = Get-Content -Path $FilePath -Raw
    $lines = $content -split "`n"
    $references = @()

    for ($index = 0; $index -lt $lines.Length; $index++) {
        $line = $lines[$index]
        $trimmed = $line.Trim()

        if ($trimmed.StartsWith('#')) {
            continue
        }

        $match = [regex]::Match($line, 'template:\s+["\'']?([^"\'']+?)["\'']?(\s|$)')
        if (-not $match.Success) {
            continue
        }

        $value = $match.Groups[1].Value.Trim()
        if ($value -match '\${{') { continue }
        if ($value -match '\$\(') { continue }
        if (-not $value) { continue }

        $references += [pscustomobject]@{
            RawValue  = $value
            Line      = $index + 1
            FilePath  = $FilePath
        }
    }

    return $references
}

function Resolve-TemplatePath {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Reference
    )

    $pathPart = $Reference.RawValue.Split('@')[0]
    $sourceDirectory = Split-Path -Path $Reference.FilePath

    if ([System.IO.Path]::IsPathRooted($pathPart)) {
        return $pathPart
    }

    $candidate = Join-Path -Path $sourceDirectory -ChildPath $pathPart
    $fullPath = [System.IO.Path]::GetFullPath($candidate)
    return $fullPath
}

function Get-ScriptReferences {
    param(
        [Parameter(Mandatory)]
        [string]$FilePath
    )

    $content = Get-Content -Path $FilePath -Raw
    $lines = $content -split "`n"
    $references = @()

    for ($index = 0; $index -lt $lines.Length; $index++) {
        $line = $lines[$index]
        $trimmed = $line.Trim()

        if ($trimmed.StartsWith('#')) { continue }

        $match = [regex]::Match($line, 'script:\s+["\'']?([^"\'']+?)["\'']?(\s|$)')
        if (-not $match.Success) { continue }

        $value = $match.Groups[1].Value.Trim()
        if ($value -match '\${{') { continue }
        if ($value -match '\$\(') { continue }
        if ($value -match '^\$') { continue }
        if (-not $value) { continue }

        $references += [pscustomobject]@{
            Script   = $value
            Line     = $index + 1
            FilePath = $FilePath
        }
    }

    return $references
}

Describe 'Pipeline templates' {
    $yamlFiles = Get-ChildItem -Path $templatesRoot -Include '*.yml', '*.yaml' -Recurse -File | Select-Object -ExpandProperty FullName
    $testCases = $yamlFiles | ForEach-Object { @{ Path = $_ } }

    It 'parses <Path>' -TestCases $testCases {
        param($Path)
        {(Get-Content -Path $Path -Raw) | ConvertFrom-Yaml} | Should -Not -Throw
    }
}

Describe 'Template dependencies' {
    $yamlFiles = Get-ChildItem -Path $templatesRoot -Include '*.yml', '*.yaml' -Recurse -File | Select-Object -ExpandProperty FullName
    $cases = foreach ($file in $yamlFiles) {
        $references = Get-TemplateReferences -FilePath $file
        foreach ($reference in $references) {
            $resolved = Resolve-TemplatePath -Reference $reference
            [ordered]@{
                File     = $file
                RawValue = $reference.RawValue
                Resolved = $resolved
                Line     = $reference.Line
            }
        }
    }

    if ($cases) {
        It 'resolves <RawValue> in <File>' -TestCases $cases {
            param($File, $Resolved, $Line)
            $context = '{0}:{1}' -f $File, $Line
            Test-Path -Path $Resolved | Should -BeTrue -Because $context
        }
    }
    else {
        It 'has no static template references' {
            $true | Should -BeTrue
        }
    }
}

Describe 'Template expression directives' {
    $yamlFiles = Get-ChildItem -Path $templatesRoot -Include '*.yml', '*.yaml' -Recurse -File | Select-Object -ExpandProperty FullName
    $violations = foreach ($file in $yamlFiles) {
        $lines = Get-Content -Path $file
        for ($index = 0; $index -lt $lines.Length; $index++) {
            $line = $lines[$index]
            $matches = [regex]::Matches($line, '\${{\s*(if|elseif|else|end)[^}]*}}')
            foreach ($match in $matches) {
                $after = $line.Substring($match.Index + $match.Length)
                if ([string]::IsNullOrWhiteSpace($after)) { continue }

                $trimmed = $after.Trim()
                if (-not $trimmed) { continue }
                if ($trimmed -match '^(:\s*(#.*)?|#.*)$') { continue }

                [ordered]@{
                    File    = $file
                    Line    = $index + 1
                    Snippet = $line.Trim()
                }
            }
        }
    }

    if ($violations) {
        It 'does not embed directive output inside scalar content in <File>:<Line>' -TestCases $violations {
            param($File, $Line, $Snippet)
            $message = '{0}:{1} -> {2}' -f $File, $Line, $Snippet
            $message | Should -BeNullOrEmpty -Because 'directive blocks must occupy the entire value'
        }
    }
    else {
        It 'has no directive formatting violations' {
            $true | Should -BeTrue
        }
    }
}

Describe 'PowerShell script references' {
    $yamlFiles = Get-ChildItem -Path $templatesRoot -Include '*.yml', '*.yaml' -Recurse -File | Select-Object -ExpandProperty FullName
    $cases = foreach ($file in $yamlFiles) {
        $references = Get-ScriptReferences -FilePath $file
        foreach ($reference in $references) {
            [ordered]@{
                File   = $file
                Script = $reference.Script
                Line   = $reference.Line
            }
        }
    }

    if ($cases) {
        It 'resolves script <Script> in <File>' -TestCases $cases {
            param($File, $Script, $Line)
            $fullPath = Join-Path -Path $scriptsRoot -ChildPath $Script
            $context = '{0}:{1}' -f $File, $Line
            Test-Path -Path $fullPath | Should -BeTrue -Because $context
        }
    }
    else {
        It 'has no static script references' {
            $true | Should -BeTrue
        }
    }
}

Describe 'PowerShell analyser' {
    It 'passes PSScriptAnalyzer for scripts/' {
        & (Join-Path $scriptsRoot 'ps_analyse.ps1') -Path $scriptsRoot | Out-Null
    }
}

Describe 'Pipeline examples' {
    It 'pipeline-examples repository is available' {
        $path = Join-Path $repoRoot '..' 'pipeline-examples'
        Test-Path -Path $path | Should -BeTrue -Because 'Clone wesley-trust/pipeline-examples alongside pipeline-common'
    }

    if ($examplesRoot) {
        $exampleYaml = Get-ChildItem -Path $examplesRoot.ProviderPath -Include '*.yml', '*.yaml' -Recurse -File |
            Where-Object { $_.FullName -match 'examples/consumer/.+\.(pipeline|settings)\.yml$' } |
            Select-Object -ExpandProperty FullName

        $cases = $exampleYaml | ForEach-Object { @{ Path = $_ } }
        It 'parses example YAML <Path>' -TestCases $cases {
            param($Path)
            {(Get-Content -Path $Path -Raw) | ConvertFrom-Yaml} | Should -Not -Throw
        }

        $pipelineFiles = $exampleYaml | Where-Object { $_ -match '\.pipeline\.yml$' }
        $settingsFiles = $exampleYaml | Where-Object { $_ -match '\.settings\.yml$' }

        if ($pipelineFiles) {
            It 'pipeline examples extend a local settings file' -TestCases ($pipelineFiles | ForEach-Object { @{ Path = $_ } }) {
                param($Path)
                $yaml = (Get-Content -Path $Path -Raw) | ConvertFrom-Yaml
                $templateValue = $yaml.extends.template
                $templateValue | Should -Not -BeNullOrEmpty -Because "Pipeline $Path must extend a settings file"
                if ($templateValue -match '\${{') {
                    Set-ItResult -Skipped -Because "Pipeline $Path uses dynamic extends template"
                }
                else {
                    $candidate = if ([System.IO.Path]::IsPathRooted($templateValue)) {
                        $templateValue
                    }
                    else {
                        Join-Path -Path (Split-Path $Path) -ChildPath $templateValue
                    }
                    Test-Path -Path $candidate | Should -BeTrue -Because "Extends target $templateValue should exist for $Path"
                }
            }
        }

        if ($settingsFiles) {

            It 'settings files extend pipeline dispatcher template' -TestCases ($settingsFiles | ForEach-Object { @{ Path = $_ } }) {
                param($Path)
                $yaml = (Get-Content -Path $Path -Raw) | ConvertFrom-Yaml
                $yaml.extends.template | Should -Be '/templates/pipeline-dispatcher.yml@PipelineDispatcher'
                $repositories = $yaml.resources.repositories
                $repoAliases = @()
                if ($repositories) {
                    $repoAliases = @($repositories | ForEach-Object { $_.repository })
                }
                $repoAliases | Should -Contain 'PipelineDispatcher' -Because "Settings $Path must declare PipelineDispatcher repository"
            }

            It 'pipeline dispatcher template targets pipeline-common main' {
                $dispatcherRepoVariable = Get-Variable -Name 'pipelineDispatcherRepo' -Scope Script -ErrorAction SilentlyContinue
                $dispatcherRepoValue = if ($dispatcherRepoVariable) { $dispatcherRepoVariable.Value } else { $null }
                if (-not $dispatcherRepoValue) {
                    $git = Get-Command git -ErrorAction Stop
                    $gitExecutable = $git.Path
                    $cacheRoot = Join-Path $repoRoot '.cache'
                    if (-not (Test-Path -Path $cacheRoot)) {
                        $null = New-Item -ItemType Directory -Path $cacheRoot -Force
                    }
                    $targetPath = Join-Path $cacheRoot 'pipeline-dispatcher'
                    if (-not (Test-Path -Path $targetPath)) {
                        $cloneArgs = @('clone', '--depth', '1', 'https://github.com/wesley-trust/pipeline-dispatcher', $targetPath)
                        $cloneOutput = & $gitExecutable @cloneArgs 2>&1
                        if ($LASTEXITCODE -ne 0) {
                            throw "Failed to clone pipeline-dispatcher: $cloneOutput"
                        }
                    }
                    $dispatcherRepoValue = (Resolve-Path $targetPath).ProviderPath
                    Set-Variable -Name 'pipelineDispatcherRepo' -Scope Script -Value $dispatcherRepoValue
                }
                $dispatcherPath = $dispatcherRepoValue
                $dispatcherPath | Should -Not -BeNullOrEmpty -Because 'git clone of wesley-trust/pipeline-dispatcher is required'
                $templatePath = Join-Path $dispatcherPath 'templates/pipeline-dispatcher.yml'
                Test-Path -Path $templatePath | Should -BeTrue -Because 'pipeline-dispatcher must expose templates/pipeline-dispatcher.yml'
                $dispatcherYaml = (Get-Content -Path $templatePath -Raw) | ConvertFrom-Yaml
                $dispatcherYaml.extends.template | Should -Be 'templates/main.yml@PipelineCommon'
            }
        }
    }
}

Describe 'Azure DevOps preview (optional)' {
    It 'previews example pipelines via Azure DevOps' {
        $organizationValue = [Environment]::GetEnvironmentVariable('AZDO_ORG_SERVICE_URL')
        $previewConfig = $null
        $previewConfigVariable = Get-Variable -Name 'previewConfig' -Scope Script -ErrorAction SilentlyContinue
        if ($previewConfigVariable) {
            $previewConfig = $previewConfigVariable.Value
        }
        if ([string]::IsNullOrEmpty($organizationValue)) {
            if ($previewConfig -and $previewConfig.ContainsKey('OrganizationUrl')) {
                $organizationValue = $previewConfig['OrganizationUrl']
            }
        }

        $projectValue = [Environment]::GetEnvironmentVariable('AZDO_PROJECT')
        if ([string]::IsNullOrEmpty($projectValue)) {
            if ($previewConfig -and $previewConfig.ContainsKey('Project')) {
                $projectValue = $previewConfig['Project']
            }
        }

        $patValue = [Environment]::GetEnvironmentVariable('AZURE_DEVOPS_EXT_PAT')
        if ([string]::IsNullOrEmpty($patValue)) {
            $patValue = [Environment]::GetEnvironmentVariable('AZDO_PERSONAL_ACCESS_TOKEN')
        }
        if ([string]::IsNullOrEmpty($patValue)) {
            $patStore = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.pipeline-common/azdo_pat'
            if (Test-Path -Path $patStore) {
                $patValue = 'cached'
            }
        }

        $organizationValue | Should -Not -BeNullOrEmpty -Because 'Set AZDO_ORG_SERVICE_URL or populate config/azdo-preview.config.psd1 with OrganizationUrl.'
        $projectValue | Should -Not -BeNullOrEmpty -Because 'Set AZDO_PROJECT or populate config/azdo-preview.config.psd1 with Project.'
        $patValue | Should -Not -BeNullOrEmpty -Because 'Provide AZURE_DEVOPS_EXT_PAT, AZDO_PERSONAL_ACCESS_TOKEN, or run scripts/set_azdo_pat.ps1 to cache a PAT.'
        $examplesRoot | Should -Not -BeNullOrEmpty -Because 'Clone wesley-trust/pipeline-examples alongside pipeline-common so previews can compile consumer definitions.'

        $scriptPath = Join-Path $repoRoot 'scripts/preview_examples.ps1'
        { & $scriptPath | Out-Null } | Should -Not -Throw
    }
}

Describe 'Azure DevOps pipeline definition preview (optional)' {
    It 'previews configured pipeline definitions via Azure DevOps' {
        $organizationValue = [Environment]::GetEnvironmentVariable('AZDO_ORG_SERVICE_URL')
        $previewConfig = $null
        $previewConfigVariable = Get-Variable -Name 'previewConfig' -Scope Script -ErrorAction SilentlyContinue
        if ($previewConfigVariable) {
            $previewConfig = $previewConfigVariable.Value
        }
        if ([string]::IsNullOrEmpty($organizationValue)) {
            if ($previewConfig -and $previewConfig.ContainsKey('OrganizationUrl')) {
                $organizationValue = $previewConfig['OrganizationUrl']
            }
        }

        $projectValue = [Environment]::GetEnvironmentVariable('AZDO_PROJECT')
        if ([string]::IsNullOrEmpty($projectValue)) {
            if ($previewConfig -and $previewConfig.ContainsKey('Project')) {
                $projectValue = $previewConfig['Project']
            }
        }

        $pipelineIdsEnv = [Environment]::GetEnvironmentVariable('AZDO_PIPELINE_IDS')
        $configPipelineIds = if ($previewConfig -and $previewConfig.ContainsKey('PipelineIds')) { $previewConfig['PipelineIds'] } else { $null }
        $hasPipelineIds = -not [string]::IsNullOrEmpty($pipelineIdsEnv) -or ($configPipelineIds -and $configPipelineIds.Count -gt 0)

        $patValue = [Environment]::GetEnvironmentVariable('AZURE_DEVOPS_EXT_PAT')
        if ([string]::IsNullOrEmpty($patValue)) {
            $patValue = [Environment]::GetEnvironmentVariable('AZDO_PERSONAL_ACCESS_TOKEN')
        }
        if ([string]::IsNullOrEmpty($patValue)) {
            $patStore = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.pipeline-common/azdo_pat'
            if (Test-Path -Path $patStore) {
                $patValue = 'cached'
            }
        }

        $organizationValue | Should -Not -BeNullOrEmpty -Because 'Set AZDO_ORG_SERVICE_URL or populate config/azdo-preview.config.psd1 with OrganizationUrl.'
        $projectValue | Should -Not -BeNullOrEmpty -Because 'Set AZDO_PROJECT or populate config/azdo-preview.config.psd1 with Project.'
        $hasPipelineIds | Should -BeTrue -Because 'Set AZDO_PIPELINE_IDS (e.g. 132) or populate config/azdo-preview.config.psd1 with PipelineIds.'
        $patValue | Should -Not -BeNullOrEmpty -Because 'Provide AZURE_DEVOPS_EXT_PAT, AZDO_PERSONAL_ACCESS_TOKEN, or run scripts/set_azdo_pat.ps1 to cache a PAT.'

        $scriptPath = Join-Path $repoRoot 'scripts/preview_pipeline_definitions.ps1'
        { & $scriptPath | Out-Null } | Should -Not -Throw
    }
}
