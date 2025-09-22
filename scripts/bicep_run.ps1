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
  [string]$StackOutFile = 'stack.txt',
  [ValidateSet('incremental', 'complete')][string]$Mode = '',
  [ValidateSet('incremental', 'complete', '')][string]$ModeOverride = '',
  [object]$AllowDeleteOnUnmanage = $false
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

  if ([string]::IsNullOrWhiteSpace($Identifier)) {
    throw 'Identifier is required to compute the stack name.'
  }

  $raw = "$Prefix-$Identifier"

  $sanitised = ($raw -replace '[^a-zA-Z0-9-]', '-').Trim('-')
  if (-not $sanitised) { $sanitised = $Prefix }
  if ($sanitised.Length -gt 90) {
    $sanitised = $sanitised.Substring(0, 90).Trim('-')
    if (-not $sanitised) { $sanitised = $Prefix }
  }

  return $sanitised
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

function ConvertTo-BooleanValue {
  param($Value)

  switch ($Value) {
    { $_ -is [bool] } { return $_ }
    { $_ -is [int] } { return [bool]$_ }
    { $_ -is [string] } {
      $normalized = $_.Trim()
      if ($normalized -match '^(?i:true|1)$') { return $true }
      if ($normalized -match '^(?i:false|0)$') { return $false }
      break
    }
  }

  throw 'AllowDeleteOnUnmanage must be a boolean-compatible value (true/false, 1/0).'
}

$allowDelete = ConvertTo-BooleanValue -Value $AllowDeleteOnUnmanage

switch ($Scope) {
  'resourceGroup' {
    if (-not $ResourceGroupName) { throw 'ResourceGroupName is required for resourceGroup scope' }
    if ($Action -eq 'whatif') {
      az deployment group what-if --resource-group $ResourceGroupName --template-file $Template @paramArgs @additionalParamArgs --only-show-errors | Tee-Object -FilePath $OutFile
      
      # Check against deployment stack
      Write-Information -InformationAction Continue -MessageData "Checking What-If Resources against Deployment Stack Resources" 
      
      $WhatIf = az deployment group what-if --resource-group $ResourceGroupName --template-file $Template @paramArgs @additionalParamArgs --only-show-errors --no-pretty-print | ConvertFrom-Json
      
      if ($WhatIf) {
        # $Stack = az stack group show `
        #   --name (Get-StackName -Prefix 'ds' -Identifier $ResourceGroupName) `
        #   --resource-group $ResourceGroupName `
        #   --only-show-errors `
        #   --output json 2>$null | ConvertFrom-Json 

        # $Stack = az stack group show `
        #   --name (Get-StackName -Prefix 'ds' -Identifier $ResourceGroupName) `
        #   --resource-group $ResourceGroupName `
        #   --only-show-errors `
        #   --output json | ConvertFrom-Json

        az stack group show `
          --name (Get-StackName -Prefix 'ds' -Identifier $ResourceGroupName) `
          --resource-group $ResourceGroupName `
          --only-show-errors `
          --output json

        break

        if ($Stack) {
          $ManagedResources = foreach ($Change in $whatIf.changes) {

            $Resource = @{}
            $Resource.Add("ResourceId", $Change.resourceId)
            $Resource.Add("ChangeType", $Change.ChangeType)
            
            if ($Change.resourceId -in $Stack.resources.id) {
              $Resource.Add("ManagedResource", $true)
            }
            else {
              $Resource.Add("ManagedResource", $false)
            }
          }
          if ($ManagedResources) {
            $ManagedResources | Tee-Object -FilePath $StackOutFile | Format-Table -AutoSize
          }
        }
        else {
          Write-Information -InformationAction Continue -MessageData "No Deployment Stack Resources to check against" 
        }
      }
      else {
        Write-Information -InformationAction Continue -MessageData "No What-If Resources to check against" 
      }
    }
    else {
      $stackCommandBase = @(
        'stack', 'group', 'create',
        '--name', (Get-StackName -Prefix 'ds' -Identifier $ResourceGroupName),
        '--resource-group', $ResourceGroupName,
        '--template-file', $Template
        '--deny-settings-mode', 'denyDelete'
        '--deny-settings-apply-to-child-scopes'
        '--only-show-errors'
      )

      $stackCommandBase += $paramArgs
      $stackCommandBase += $additionalParamArgs
      #$stackCommandBase += @('--deny-settings-mode', 'denyDelete', '--only-show-errors')
      if ($SubscriptionId) { $stackCommandBase += @('--subscription', $SubscriptionId) }

      Invoke-StackDeployment -BaseArgs $stackCommandBase -AllowDelete:$allowDelete
    }
  }
  'subscription' {
    if (-not $Location) { throw 'Location is required for subscription scope' }
    if ($Action -eq 'whatif') {
      az deployment sub what-if --location $Location --template-file $Template @paramArgs @additionalParamArgs --only-show-errors | Tee-Object -FilePath $OutFile
    
      # Check against deployment stack
      $WhatIf = az deployment sub what-if --location $Location --template-file $Template @paramArgs @additionalParamArgs --only-show-errors --no-pretty-print | ConvertFrom-Json

      if ($WhatIf) {
        $WhatIfChanges = $whatIf.changes
      }
      
      if ($WhatIfChanges) {
        Write-Information -InformationAction Continue -MessageData "Checking What-If Resources against Deployment Stack Resources" 
        $Stack = az stack sub show `
          --name (Get-StackName -Prefix 'ds-sub' -Identifier $ResourceGroupName) `
          --only-show-errors `
          --output json 2>$null | ConvertFrom-Json
      
        if ($Stack) {
          $StackResourceIds = $Stack.resources.id
        }

        if ($StackResourceIds) {
          $ManagedResources = foreach ($Change in $WhatIfChanges) {

            $Resource = @{}
            $Resource.Add("ResourceId", $Change.resourceId)
            $Resource.Add("ChangeType", $Change.ChangeType)
            
            if ($Change.resourceId -in $StackResourceIds -and $Change.ChangeType -ne "Ignore") {
              $Resource.Add("ManagedResource", $true)
            }

            else {
              $Resource.Add("ManagedResource", $false)
            }
          }
        }
        if ($ManagedResources) {
          $ManagedResources | Tee-Object -FilePath $StackOutFile | Format-Table -AutoSize
        }
        else {
          Write-Information -InformationAction Continue -MessageData "No Deployment Stack Resources to check against" 
        }
      }
    }
    else {
      $stackIdentifier = if (-not [string]::IsNullOrWhiteSpace($ResourceGroupName)) {
        $ResourceGroupName
      }
      elseif (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) {
        $SubscriptionId
      }
      else {
        throw 'Either ResourceGroupName or SubscriptionId is required to compute the stack name for subscription scope.'
      }

      $stackCommandBase = @(
        'stack', 'sub', 'create',
        '--name', (Get-StackName -Prefix 'ds-sub' -Identifier $stackIdentifier),
        '--location', $Location,
        '--template-file', $Template
        '--deny-settings-mode', 'denyDelete'
        '--only-show-errors'
      )

      $stackCommandBase += $paramArgs
      $stackCommandBase += $additionalParamArgs
      #$stackCommandBase += @('--deny-settings-mode', 'denyDelete', '--only-show-errors')
      if ($SubscriptionId) { $stackCommandBase += @('--subscription', $SubscriptionId) }

      Invoke-StackDeployment -BaseArgs $stackCommandBase -AllowDelete:$allowDelete
    }
  }
  'managementGroup' {
    if (-not $ManagementGroupId) { throw 'ManagementGroupId is required for managementGroup scope' }
    if (-not $Location) { throw 'Location is required for managementGroup scope' }
    if ($Action -eq 'whatif') {
      az deployment mg what-if -m $ManagementGroupId --location $Location --template-file $Template @paramArgs @additionalParamArgs | Tee-Object -FilePath $OutFile    
    }
    else {
      $stackIdentifier = if (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) {
        $SubscriptionId
      }
      elseif (-not [string]::IsNullOrWhiteSpace($ManagementGroupId)) {
        $ManagementGroupId
      }
      else {
        throw 'Either ManagementGroupId or SubscriptionId is required to compute the stack name for management group scope.'
      }

      $stackCommandBase = @(
        'stack', 'mg', 'create',
        '--name', (Get-StackName -Prefix 'ds-mg' -Identifier $ManagementGroupId),
        '--management-group-id', $ManagementGroupId,
        '--location', $Location,
        '--template-file', $Template
        '--deny-settings-mode', 'denyDelete'
        '--only-show-errors'
      )

      $stackCommandBase += $paramArgs
      $stackCommandBase += $additionalParamArgs
      #$stackCommandBase += @('--deny-settings-mode', 'denyDelete', '--only-show-errors')
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
        throw 'AllowDeleteOnUnmanage is not known to be supported for tenant deployments. If this is now supported, this script will need to be updated.'
      }

      az deployment tenant create --location $Location --template-file $Template @paramArgs @additionalParamArgs
    }
  }
}
