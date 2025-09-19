param(
  [Parameter(Mandatory = $true)][ValidateSet('validate', 'whatif', 'deploy')][string]$Action,
  [Parameter(Mandatory = $true)][ValidateSet('resourceGroup', 'subscription', 'managementGroup', 'tenant')][string]$Scope,
  [string]$ResourceGroupName = '',
  [string]$Location = '',
  [Parameter(Mandatory = $true)][string]$Template,
  [string]$ParametersRoot = '',
  [string]$ParametersFile = '',
  [string]$AdditionalParameters = '',
  [string]$ManagementGroupId = '',
  [string]$SubscriptionId = '',
  [string]$OutFile = 'whatif.txt',
  [ValidateSet('incremental', 'complete')][string]$Mode = '',
  [ValidateSet('incremental', 'complete', '')][string]$ModeOverride = '',
  [bool]$AllowDeleteOnUnmanage = $false
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function ConvertTo-ArgumentList {
  param([string]$Raw)

  if ([string]::IsNullOrWhiteSpace($Raw)) {
    return @()
  }

  $arguments = @()
  $builder = [System.Text.StringBuilder]::new()
  $inSingle = $false
  $inDouble = $false
  $escapeNext = $false

  for ($index = 0; $index -lt $Raw.Length; $index++) {
    $char = $Raw[$index]

    if ($escapeNext) {
      [void]$builder.Append($char)
      $escapeNext = $false
      continue
    }

    if ($inDouble -and $char -eq '\\') {
      $escapeNext = $true
      continue
    }

    if (-not $inSingle -and $char -eq '"') {
      $inDouble = -not $inDouble
      continue
    }

    if (-not $inDouble -and $char -eq "'") {
      if ($inSingle -and ($index + 1) -lt $Raw.Length -and $Raw[$index + 1] -eq "'") {
        [void]$builder.Append("'")
        $index++
        continue
      }

      $inSingle = -not $inSingle
      continue
    }

    if (-not $inSingle -and -not $inDouble -and [char]::IsWhiteSpace($char)) {
      if ($builder.Length -gt 0) {
        $arguments += $builder.ToString()
        $builder.Clear() | Out-Null
      }

      continue
    }

    [void]$builder.Append($char)
  }

  if ($escapeNext) {
    [void]$builder.Append('\\')
  }

  if ($builder.Length -gt 0) {
    $arguments += $builder.ToString()
  }

  return $arguments
}

function Get-StackName {
  param(
    [string]$Prefix,
    [string]$Identifier
  )

  $sanitisedIdentifier = if ([string]::IsNullOrWhiteSpace($Identifier)) { 'default' } else { $Identifier }
  $sanitisedIdentifier = ($sanitisedIdentifier -replace '[^a-zA-Z0-9-]', '-').Trim('-')
  if (-not $sanitisedIdentifier) {
    $sanitisedIdentifier = 'default'
  }

  $name = "$Prefix-$sanitisedIdentifier"
  if ($name.Length -gt 90) {
    $name = $name.Substring(0, 90).Trim('-')
    if (-not $name) {
      $name = $Prefix
    }
  }

  return $name
}

function Invoke-StackDeployment {
  param(
    [string[]]$BaseArgs,
    [bool]$AllowDelete
  )

  $initialAction = if ($AllowDelete) { 'deleteAll' } else { 'detachAll' }
  $initialArgs = $BaseArgs + @('--action-on-unmanage', $initialAction)

  try {
    az @initialArgs
  }
  finally {
    if ($AllowDelete) {
      $resetArgs = $BaseArgs + @('--action-on-unmanage', 'detachAll')
      try {
        az @resetArgs | Out-Null
      }
      catch {
        Write-Warning "Failed to restore action-on-unmanage to detachAll: $($_.Exception.Message)"
      }
    }
  }
}

if ($Action -eq 'validate') {
  az bicep install | Out-Null
  az bicep version | Out-Null
  az bicep build --file "$Template"
  exit 0
}

if ($ModeOverride) {
  $Mode = $ModeOverride
}

$paramArgs = @()
if ($ParametersFile) { $ParametersFile = "$ParametersRoot/$ParametersFile"; $paramArgs += '--parameters'; $paramArgs += "$ParametersFile" }
$additionalParamArgs = ConvertTo-ArgumentList -Raw $AdditionalParameters
$allowDelete = [bool]$AllowDeleteOnUnmanage

switch ($Scope) {
  'resourceGroup' {
    if (-not $ResourceGroupName) { throw 'ResourceGroupName is required for resourceGroup scope' }
    if ($Action -eq 'whatif') {
      az deployment group what-if --resource-group $ResourceGroupName --template-file $Template @paramArgs @additionalParamArgs --only-show-errors | Tee-Object -FilePath $OutFile
    }
    else {
      $stackCommandBase = @(
        'stack', 'group', 'create',
        '--name', (Get-StackName -Prefix 'ds' -Identifier $ResourceGroupName),
        '--resource-group', $ResourceGroupName,
        '--template-file', $Template
      )

      $stackCommandBase += $paramArgs
      $stackCommandBase += $additionalParamArgs
      $stackCommandBase += @('--deny-settings-mode', 'denyDelete', '--only-show-errors')
      if ($SubscriptionId) { $stackCommandBase += @('--subscription', $SubscriptionId) }

      Invoke-StackDeployment -BaseArgs $stackCommandBase -AllowDelete:$allowDelete
    }
  }
  'subscription' {
    if ($Action -eq 'whatif') {
      az deployment sub what-if --location $Location --template-file $Template @paramArgs @additionalParamArgs --only-show-errors | Tee-Object -FilePath $OutFile
    }
    else {
      if (-not $Location) { throw 'Location is required for subscription scope' }

      $stackCommandBase = @(
        'stack', 'sub', 'create',
        '--name', (Get-StackName -Prefix 'ds-sub' -Identifier $SubscriptionId),
        '--location', $Location,
        '--template-file', $Template
      )

      $stackCommandBase += $paramArgs
      $stackCommandBase += $additionalParamArgs
      $stackCommandBase += @('--deny-settings-mode', 'denyDelete', '--only-show-errors')
      if ($SubscriptionId) { $stackCommandBase += @('--subscription', $SubscriptionId) }

      Invoke-StackDeployment -BaseArgs $stackCommandBase -AllowDelete:$allowDelete
    }
  }
  'managementGroup' {
    if (-not $ManagementGroupId) { throw 'ManagementGroupId is required for managementGroup scope' }
    if ($Action -eq 'whatif') {
      az deployment mg what-if -m $ManagementGroupId --location $Location --template-file $Template @paramArgs @additionalParamArgs | Tee-Object -FilePath $OutFile
    }
    else {
      if (-not $Location) { throw 'Location is required for managementGroup scope' }

      $stackCommandBase = @(
        'stack', 'mg', 'create',
        '--name', (Get-StackName -Prefix 'ds-mg' -Identifier $ManagementGroupId),
        '--management-group-id', $ManagementGroupId,
        '--location', $Location,
        '--template-file', $Template
      )

      $stackCommandBase += $paramArgs
      $stackCommandBase += $additionalParamArgs
      $stackCommandBase += @('--deny-settings-mode', 'denyDelete', '--only-show-errors')
      if ($SubscriptionId) { $stackCommandBase += @('--subscription', $SubscriptionId) }

      Invoke-StackDeployment -BaseArgs $stackCommandBase -AllowDelete:$allowDelete
    }
  }
  'tenant' {
    if ($Action -eq 'whatif') {
      az deployment tenant what-if --location $Location --template-file $Template @paramArgs @additionalParamArgs | Tee-Object -FilePath $OutFile
    }
    else {
      if ($AllowDeleteOnUnmanage) {
        throw 'AllowDeleteOnUnmanage is not supported for tenant deployments with the current Azure CLI. Update the CLI once deployment stacks support tenant scope.'
      }

      az deployment tenant create --location $Location --template-file $Template @paramArgs @additionalParamArgs
    }
  }
}
