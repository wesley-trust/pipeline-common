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
  [ValidateSet('incremental', 'complete', '')][string]$ModeOverride = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

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
if ($ParametersFile) { $ParametersFile = $ParametersRoot + $ParametersFile; $paramArgs += '--parameters'; $paramArgs += "$ParametersFile" }

switch ($Scope) {
  'resourceGroup' {
    if (-not $ResourceGroupName) { throw 'ResourceGroupName is required for resourceGroup scope' }
    if ($Action -eq 'whatif') {
      if ($AdditionalParameters) {
        az deployment group what-if --resource-group $ResourceGroupName --template-file $Template @paramArgs $AdditionalParameters --only-show-errors | Tee-Object -FilePath $OutFile
      }
      else {
        az deployment group what-if --resource-group $ResourceGroupName --template-file $Template @paramArgs --only-show-errors | Tee-Object -FilePath $OutFile
      }
    }
    else {
      $modeArgs = @(); if ($Mode) { $modeArgs += '--mode'; $modeArgs += $Mode }
      if ($AdditionalParameters) {
        az deployment group create --resource-group $ResourceGroupName --template-file $Template @paramArgs $AdditionalParameters $modeArgs --only-show-errors
      }
      else {
        az deployment group create --resource-group $ResourceGroupName --template-file $Template @paramArgs $modeArgs --only-show-errors
      }
    }
  }
  'subscription' {
    if ($Action -eq 'whatif') {
      if ($AdditionalParameters) {
        az deployment sub what-if --location $Location --template-file $Template @paramArgs $AdditionalParameters --only-show-errors | Tee-Object -FilePath $OutFile
      }
      else {
        az deployment sub what-if --location $Location --template-file $Template @paramArgs --only-show-errors | Tee-Object -FilePath $OutFile
      }
    }
    else {
      if ($AdditionalParameters) {
        az deployment sub create --location $Location --template-file $Template @paramArgs $AdditionalParameters --only-show-errors
      }
      else {
        az deployment sub create --location $Location --template-file $Template @paramArgs --only-show-errors
      }
    }
  }
  'managementGroup' {
    if (-not $ManagementGroupId) { throw 'ManagementGroupId is required for managementGroup scope' }
    if ($Action -eq 'whatif') {
      az deployment mg what-if -m $ManagementGroupId --location $Location --template-file $Template @paramArgs $AdditionalParameters | Tee-Object -FilePath $OutFile
    }
    else {
      az deployment mg create -m $ManagementGroupId --location $Location --template-file $Template @paramArgs $AdditionalParameters
    }
  }
  'tenant' {
    if ($Action -eq 'whatif') {
      az deployment tenant what-if --location $Location --template-file $Template @paramArgs $AdditionalParameters | Tee-Object -FilePath $OutFile
    }
    else {
      az deployment tenant create --location $Location --template-file $Template @paramArgs $AdditionalParameters
    }
  }
}
