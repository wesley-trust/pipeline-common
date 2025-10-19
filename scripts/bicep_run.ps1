param(
  [Parameter(Mandatory = $true)][ValidateSet('validate', 'whatif', 'deploy')][string]$Action,
  [Parameter(Mandatory = $true)][ValidateSet('resourceGroup', 'subscription', 'managementGroup', 'tenant')][string]$Scope,
  [string]$Name = '',
  [string]$ResourceGroupName = '',
  [string]$Location = '',
  [Parameter(Mandatory = $true)][string]$Template,
  [string]$ParametersPath = '',
  [string]$AdditionalParameters = '',
  [string]$ManagementGroupId = '',
  [string]$SubscriptionId = '',
  [string]$OutFile = 'whatif.txt',
  [string]$StackOutFile = 'stack.csv',
  [ValidateSet('incremental', 'complete')][string]$Mode = '',
  [ValidateSet('incremental', 'complete', '')][string]$ModeOverride = '',
  [object]$AllowDeleteOnUnmanage = $false,
  [object]$CleanupStack = $false
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Functions
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
    [string]$Identifier,
    [string]$Name
  )

  if ([string]::IsNullOrWhiteSpace($Identifier)) {
    throw 'Identifier is required to compute the stack name.'
  }
  $parts = @($Prefix, $Identifier)

  if (-not [string]::IsNullOrWhiteSpace($Name)) {
    $sanitisedName = $Name.Trim()
    if ($sanitisedName -and -not $sanitisedName.Equals($Identifier, [System.StringComparison]::OrdinalIgnoreCase)) {
      $parts += $sanitisedName
    }
  }

  # Build raw name; remove spaces around parts but don't alter valid characters
  $raw = ($parts -join '-').Trim()

  # Allow: letters, digits, underscore, hyphen, dot, parentheses
  $sanitised = ($raw -replace '[^-\w\._\(\)]', '-').Trim('-')
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

function ConvertTo-BooleanValue {
  [CmdletBinding()]
  param (
    [parameter(
      Mandatory = $true,
      ValueFromPipeLineByPropertyName = $true,
      ValueFromPipeline = $true
    )]
    [string]$Value
  )

  process {
    if ($null -eq $Value) {
      return $false
    }

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

    throw 'Must be a boolean-compatible value (true/false, 1/0).'
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

# Get Object Id
$ServiceConnectionObjectId = $(az ad sp show --id $(az account show --query user.name -o tsv) --query id -o tsv)

$paramArgs = @()
if ($ParametersPath) {
  $paramArgs += '--parameters'
  $paramArgs += $ParametersPath
}
$additionalParamArgs = ConvertTo-ArgumentList -Raw $AdditionalParameters

# Set variables for optional toggles
$allowDelete = $false
$allowDelete = ConvertTo-BooleanValue -Value $AllowDeleteOnUnmanage
$cleanupStack = ConvertTo-BooleanValue -Value $CleanupStack

if ([string]::IsNullOrWhiteSpace($Name)) {
  switch ($Scope) {
    'resourceGroup' { $Name = $ResourceGroupName }
    'subscription' {
      if ($ResourceGroupName) {
        $Name = $ResourceGroupName
      }
      elseif ($Template) {
        $Name = [System.IO.Path]::GetFileNameWithoutExtension($Template)
      }
    }
    'managementGroup' { $Name = $ManagementGroupId }
    'tenant' {
      if ($Template) {
        $Name = [System.IO.Path]::GetFileNameWithoutExtension($Template)
      }
    }
  }
}

if ([string]::IsNullOrWhiteSpace($Name)) {
  throw 'Name is required to compute the stack name.'
}

switch ($Scope) {
  'resourceGroup' {
    if (-not $ResourceGroupName) { throw 'ResourceGroupName is required for resourceGroup scope' }
    
    $StackName = Get-StackName -Prefix 'ds' -Identifier $ResourceGroupName -Name $Name

    if ($Action -eq 'whatif') {     
      if ($cleanupStack) {
        $actionDescription = if ($allowDelete) { 'delete all managed resources' } else { 'detach resources from the stack' }
        $message = "CleanupStack is enabled. Deploy stage will skip Bicep deployment and delete the resource group stack '$StackName' in '$ResourceGroupName' to $actionDescription."
        Write-Information -InformationAction Continue -MessageData $message | Tee-Object -FilePath $OutFile

        $stackExists = az stack group list --resource-group $ResourceGroupName --query "[?name=='$StackName']" --only-show-errors

        if ($stackExists -and $stackExists -ne '[]') {
          $stack = az stack group show `
            --name $StackName `
            --resource-group $ResourceGroupName `
            --only-show-errors `
            --output json | ConvertFrom-Json

          if ($stack -and $stack.resources) {
            $plannedAction = if ($allowDelete) { 'Delete' } else { 'Detach' }
            $resourceSummaries = foreach ($stackResource in $stack.resources) {
              [PSCustomObject]@{
                ResourceId    = $stackResource.id
                CurrentStatus = $stackResource.status
                PlannedAction = $plannedAction
                DenyStatus    = $stackResource.denyStatus
              }
            }

            if ($resourceSummaries) {
              $resourceSummaries | Export-Csv -Path $StackOutFile -NoTypeInformation
              $summaryLines = $resourceSummaries | ForEach-Object { "${plannedAction}: $($_.ResourceId)" }
              if ($summaryLines) {
                Add-Content -Path $OutFile -Value $summaryLines -Encoding utf8
              }
            }
            else {
              "Stack contains no tracked resources; nothing to $actionDescription." | Tee-Object -FilePath $StackOutFile
            }
          }
          else {
            "Unable to retrieve stack inventory; Azure CLI returned no resources." | Tee-Object -FilePath $StackOutFile
          }
        }
        else {
          "CleanupStack is enabled but stack '$StackName' was not found." | Tee-Object -FilePath $StackOutFile
          Add-Content -Path $OutFile -Value "Stack '$StackName' not found; nothing to delete." -Encoding utf8
        }

        return
      }

      $ResourceGroupExists = az group exists --name $ResourceGroupName | ConvertTo-BooleanValue

      if ($ResourceGroupExists) {

        az deployment group what-if --resource-group $ResourceGroupName --template-file $Template @paramArgs @additionalParamArgs --mode $Mode --only-show-errors | Tee-Object -FilePath $OutFile

        $StackExists = az stack group list --resource-group $ResourceGroupName --query "[?name=='$StackName']"

        if ($StackExists -ne "[]") {
          
          # Check against deployment stack
          Write-Information -InformationAction Continue -MessageData "Checking What-If Resources against Deployment Stack Resources" 

          $WhatIf = az deployment group what-if --resource-group $ResourceGroupName --template-file $Template @paramArgs @additionalParamArgs --mode $Mode --result-format ResourceIdOnly --only-show-errors --no-pretty-print | ConvertFrom-Json
      
          if ($WhatIf) {

            $Stack = az stack group show `
              --name $StackName `
              --resource-group $ResourceGroupName `
              --only-show-errors `
              --output json | ConvertFrom-Json

            if ($Stack.resources) {
              $StackResources = foreach ($Change in $whatIf.changes) {

                $Resource = [ordered]@{
                  ResourceId                 = $Change.resourceId
                  ChangeType                 = $Change.ChangeType
                  StackResource              = "N/A"
                  StackDenyStatus            = "N/A"
                  StackActionOnUnmanage      = "N/A"
                  StackAllowDeleteOnUnmanage = "N/A"
                  allowDelete                = "N/A"
                }
                
                if ($Change.resourceId -in $Stack.resources.id) {
                  $StackResource = $null
                  $StackResource = $Stack.resources | Where-Object { $_.id -eq $Change.resourceId }
                  
                  $Resource.StackResource = $StackResource.status
                  $Resource.StackDenyStatus = $StackResource.denyStatus
                  $Resource.StackApplyToChildScopes = $stack.denySettings.applyToChildScopes
                  $Resource.StackActionOnUnmanage = $stack.actionOnUnmanage.resources
                  $Resource.StackAllowDeleteOnUnmanage = $allowDelete
                }

                [pscustomobject]$Resource
              }
              if ($StackResources) {
                Write-Information -InformationAction Continue -MessageData "Exporting Analysis of What-If Resources against Deployment Stack Resources" 
                Write-Information -InformationAction Continue -MessageData "Analysis is limited to the Resources exposed in the What-If and so may be incomplete" 
                $StackResources | Export-Csv -Path $StackOutFile
              }
              else {
                Write-Warning "What-If returned no resource changes; exporting Deployment Stack inventory instead."

                if ($Stack.resources) {
                  $FallbackResources = foreach ($StackResource in $Stack.resources) {
                    
                    [PSCustomObject]@{
                      ResourceId                 = $StackResource.id
                      ChangeType                 = "NotReportedByWhatIf"
                      StackResource              = $StackResource.status
                      StackDenyStatus            = $StackResource.denyStatus
                      StackActionOnUnmanage      = $stack.actionOnUnmanage.resources
                      StackAllowDeleteOnUnmanage = $allowDelete
                    }
                  }

                  if ($FallbackResources) {
                    Write-Information -InformationAction Continue -MessageData "Exporting Deployment Stack inventory as a fallback"
                    $FallbackResources | Export-Csv -Path $StackOutFile
                  }
                  else {
                    Write-Warning "Deployment Stack did not return any resources to export"
                  }
                }
                else {
                  Write-Warning "Deployment Stack did not return any resources to export"
                }
              }
            }
            else {
              Write-Output "No Deployment Stack Resources to check against" | Tee-Object -FilePath $StackOutFile
            }
          }
          else {
            Write-Information -InformationAction Continue -MessageData "No What-If Resources to check against"
          }
        }
        else {
          Write-Output "No Deployment Stack exists to check against" | Tee-Object -FilePath $StackOutFile
        }
      }
      else {
        Write-Output "What-If cannot be generated, the Resource Group must first be created" | Tee-Object -FilePath $OutFile
        Write-Output "Stack cannot be checked due to no Resource Group existing" | Tee-Object -FilePath $StackOutFile
      }
    }
    else {
      if ($cleanupStack) {
        $stackExists = az stack group list --resource-group $ResourceGroupName --query "[?name=='$StackName']" --only-show-errors

        if ($stackExists -and $stackExists -ne '[]') {
          $deleteArgs = @(
            'stack', 'group', 'delete',
            '--name', $StackName,
            '--resource-group', $ResourceGroupName,
            '--yes',
            '--only-show-errors'
          )

          if ($SubscriptionId) { $deleteArgs += @('--subscription', $SubscriptionId) }

          $actionOnUnmanage = if ($allowDelete) { 'deleteAll' } else { 'detachAll' }
          $deleteArgs += @('--action-on-unmanage', $actionOnUnmanage)

          $actionDescription = if ($allowDelete) { 'delete all managed resources' } else { 'detach resources from the stack' }
          $message = "CleanupStack is enabled. Deploy stage will skip Bicep deployment and delete the resource group stack '$StackName' in '$ResourceGroupName' to $actionDescription."
          Write-Information -InformationAction Continue -MessageData $message

          az @deleteArgs
        }
        else {
          Write-Information -InformationAction Continue -MessageData "Cleanup skipped; resource group stack '$StackName' not found."
        }

        return
      }

      $stackCommandBase = @(
        'stack', 'group', 'create',
        '--name', $StackName,
        '--resource-group', $ResourceGroupName,
        '--template-file', $Template,
        '--deny-settings-mode', 'DenyWriteAndDelete',
        '--deny-settings-excluded-principals', $ServiceConnectionObjectId,
        '--deny-settings-excluded-actions', 'Microsoft.Resources/subscriptions/resourceGroups/write',
        '--deny-settings-apply-to-child-scopes',
        '--only-show-errors'
      )

      $stackCommandBase += $paramArgs
      $stackCommandBase += $additionalParamArgs
      if ($SubscriptionId) { $stackCommandBase += @('--subscription', $SubscriptionId) }

      if (-not (az group exists --name $ResourceGroupName | ConvertTo-BooleanValue)) {
        Write-Error "Unable to deploy as Resource Group '$ResourceGroupName' does not exist"
        return
      }

      Invoke-StackDeployment -BaseArgs $stackCommandBase -AllowDelete:$allowDelete
    }
  }
  'subscription' {
    if (-not $Location) { throw 'Location is required for subscription scope' }
    
    $StackName = Get-StackName -Prefix 'ds-sub' -Identifier $ResourceGroupName
    
    if ($Action -eq 'whatif') {
      if ($cleanupStack) {
        $actionDescription = if ($allowDelete) { 'delete all managed resources' } else { 'detach resources from the stack' }
        $message = "CleanupStack is enabled. Deploy stage will skip Bicep deployment and delete the subscription stack '$StackName' to $actionDescription."
        Write-Information -InformationAction Continue -MessageData $message | Tee-Object -FilePath $OutFile

        $stackExists = az stack sub list --query "[?name=='$StackName']" --only-show-errors

        if ($stackExists -and $stackExists -ne '[]') {
          $stack = az stack sub show `
            --name $StackName `
            --only-show-errors `
            --output json | ConvertFrom-Json

          if ($stack -and $stack.resources) {
            $plannedAction = if ($allowDelete) { 'Delete' } else { 'Detach' }
            $resourceSummaries = foreach ($stackResource in $stack.resources) {
              [PSCustomObject]@{
                ResourceId    = $stackResource.id
                CurrentStatus = $stackResource.status
                PlannedAction = $plannedAction
                DenyStatus    = $stackResource.denyStatus
              }
            }

            if ($resourceSummaries) {
              $resourceSummaries | Export-Csv -Path $StackOutFile -NoTypeInformation
              $summaryLines = $resourceSummaries | ForEach-Object { "${plannedAction}: $($_.ResourceId)" }
              if ($summaryLines) {
                Add-Content -Path $OutFile -Value $summaryLines -Encoding utf8
              }
            }
            else {
              "Stack contains no tracked resources; nothing to $actionDescription." | Tee-Object -FilePath $StackOutFile
            }
          }
          else {
            "Unable to retrieve stack inventory; Azure CLI returned no resources." | Tee-Object -FilePath $StackOutFile
          }
        }
        else {
          "CleanupStack is enabled but stack '$StackName' was not found." | Tee-Object -FilePath $StackOutFile
          Add-Content -Path $OutFile -Value "Stack '$StackName' not found; nothing to delete." -Encoding utf8
        }

        return
      }

      az deployment sub what-if --location $Location --template-file $Template @paramArgs @additionalParamArgs --only-show-errors | Tee-Object -FilePath $OutFile

      $ResourceGroupExists = az group exists --name $ResourceGroupName | ConvertTo-BooleanValue

      if ($ResourceGroupExists) {
        
        $StackExists = az stack sub list --query "[?name=='$StackName']"

        if ($StackExists -ne "[]") {
          # Check against deployment stack
          Write-Information -InformationAction Continue -MessageData "Checking What-If Resources against Deployment Stack Resources" 
      
          $WhatIf = az deployment sub what-if --location $Location --template-file $Template @paramArgs @additionalParamArgs --result-format ResourceIdOnly --only-show-errors --no-pretty-print | ConvertFrom-Json

          if ($WhatIf) {
            $Stack = az stack sub show `
              --name $StackName `
              --only-show-errors `
              --output json | ConvertFrom-Json

            if ($Stack.resources) {
              $StackResources = foreach ($Change in $whatIf.changes) {

                $Resource = [ordered]@{
                  ResourceId                 = $Change.resourceId
                  ChangeType                 = $Change.ChangeType
                  StackResource              = "N/A"
                  StackDenyStatus            = "N/A"
                  StackActionOnUnmanage      = "N/A"
                  StackAllowDeleteOnUnmanage = "N/A"
                  allowDelete                = "N/A"
                }
            
                if ($Change.resourceId -in $Stack.resources.id) {
                  $StackResource = $null
                  $StackResource = $Stack.resources | Where-Object { $_.id -eq $Change.resourceId }
                  
                  $Resource.StackResource = $StackResource.status
                  $Resource.StackDenyStatus = $StackResource.denyStatus
                  $Resource.StackApplyToChildScopes = $stack.denySettings.applyToChildScopes
                  $Resource.StackActionOnUnmanage = $stack.actionOnUnmanage.resourceGroups
                  $Resource.StackAllowDeleteOnUnmanage = $allowDelete
                }

                [pscustomobject]$Resource
              }
              if ($StackResources) {
                Write-Information -InformationAction Continue -MessageData "Exporting Analysis of What-If Resources against Deployment Stack Resources" 
                Write-Information -InformationAction Continue -MessageData "Analysis is limited to the Resources exposed in the What-If and so may be incomplete" 
                $StackResources | Export-Csv -Path $StackOutFile
              }
              else {
                Write-Warning "What-If returned no resource changes; exporting Deployment Stack inventory instead."

                if ($Stack.resources) {
                  $FallbackResources = foreach ($StackResource in $Stack.resources) {
                    
                    [PSCustomObject]@{
                      ResourceId                 = $StackResource.id
                      ChangeType                 = "NotReportedByWhatIf"
                      StackResource              = $StackResource.status
                      StackDenyStatus            = $StackResource.denyStatus
                      StackActionOnUnmanage      = $stack.actionOnUnmanage.resourceGroups
                      StackAllowDeleteOnUnmanage = $allowDelete
                    }
                  }

                  if ($FallbackResources) {
                    Write-Information -InformationAction Continue -MessageData "Exporting Deployment Stack inventory as a fallback"
                    $FallbackResources | Export-Csv -Path $StackOutFile
                  }
                  else {
                    Write-Warning "Deployment Stack did not return any resources to export"
                  }
                }
                else {
                  Write-Warning "Deployment Stack did not return any resources to export"
                }
              }
            }
            else {
              Write-Output "No Deployment Stack Resources to check against" | Tee-Object -FilePath $StackOutFile
            }
          }
          else {
            Write-Information -InformationAction Continue -MessageData "No What-If Resources to check against"
          }
        }
        else {
          Write-Output "No Deployment Stack exists to check against" | Tee-Object -FilePath $StackOutFile
        }
      }
      else {
        Write-Output "Stack cannot be checked due to no Resource Group existing" | Tee-Object -FilePath $StackOutFile
      }
    }
    else {
      if ($cleanupStack) {
        $stackExists = az stack sub list --query "[?name=='$StackName']" --only-show-errors

        if ($stackExists -and $stackExists -ne '[]') {
          $deleteArgs = @(
            'stack', 'sub', 'delete',
            '--name', $StackName,
            '--yes',
            '--only-show-errors'
          )

          if ($SubscriptionId) { $deleteArgs += @('--subscription', $SubscriptionId) }

          $actionOnUnmanage = if ($allowDelete) { 'deleteAll' } else { 'detachAll' }
          
          $deleteArgs += @('--action-on-unmanage', $actionOnUnmanage)

          $actionDescription = if ($allowDelete) { 'delete all managed resources' } else { 'detach resources from the stack' }
          $message = "CleanupStack is enabled. Deploy stage will skip Bicep deployment and delete the subscription stack '$StackName' to $actionDescription."
          Write-Information -InformationAction Continue -MessageData $message
          
          az @deleteArgs
        }
        else {
          Write-Information -InformationAction Continue -MessageData "Cleanup skipped; subscription stack '$StackName' not found."
        }

        return
      }

      $stackCommandBase = @(
        'stack', 'sub', 'create',
        '--name', $StackName,
        '--location', $Location,
        '--template-file', $Template,
        '--deny-settings-mode', 'DenyWriteAndDelete',
        '--deny-settings-excluded-principals', $ServiceConnectionObjectId,
        #'--deny-settings-excluded-actions', 'Microsoft.Resources/subscriptions/resourceGroups/write',
        '--only-show-errors'
      )

      $stackCommandBase += $paramArgs
      $stackCommandBase += $additionalParamArgs
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
      $StackName = Get-StackName -Prefix 'ds-mg' -Identifier $ManagementGroupId -Name $Name
      $stackCommandBase = @(
        'stack', 'mg', 'create',
        '--name', $StackName,
        '--management-group-id', $ManagementGroupId,
        '--location', $Location,
        '--template-file', $Template,
        '--deny-settings-mode', 'DenyWriteAndDelete',
        '--deny-settings-excluded-principals', $ServiceConnectionObjectId,
        '--deny-settings-excluded-actions', 'Microsoft.Resources/subscriptions/resourceGroups/write',
        '--only-show-errors'
      )

      $stackCommandBase += $paramArgs
      $stackCommandBase += $additionalParamArgs
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
