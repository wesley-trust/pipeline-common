param(
  [Parameter(Mandatory = $true)][ValidateSet('validate', 'whatif', 'deploy')][string]$Action,
  [Parameter(Mandatory = $true)][ValidateSet('resourceGroup', 'subscription', 'managementGroup', 'tenant')][string]$Scope,
  [string]$ResourceGroupName = '',
  [string]$Location = '',
  [Parameter(Mandatory = $true)][string]$Template,
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
if ($ParametersFile) { $paramArgs += '-p'; $paramArgs += "@$ParametersFile" }

switch ($Scope) {
  'resourceGroup' {
    if (-not $ResourceGroupName) { throw 'ResourceGroupName is required for resourceGroup scope' }
    if ($Action -eq 'whatif') {
      az deployment group what-if -g $ResourceGroupName -l $Location -f $Template @paramArgs $AdditionalParameters | Tee-Object -FilePath $OutFile
    }
    else {
      $modeArgs = @(); if ($Mode) { $modeArgs += '--mode'; $modeArgs += $Mode }
      az deployment group create -g $ResourceGroupName -l $Location -f $Template @paramArgs $modeArgs $AdditionalParameters
    }
  }
  'subscription' {
    if ($Action -eq 'whatif') {
      az deployment sub what-if -l $Location -f $Template @paramArgs $AdditionalParameters | Tee-Object -FilePath $OutFile
    }
    else {
      $modeArgs = @(); if ($Mode) { $modeArgs += '--mode'; $modeArgs += $Mode }
      az deployment sub create -l $Location -f $Template @paramArgs $modeArgs $AdditionalParameters
    }
  }
  'managementGroup' {
    if (-not $ManagementGroupId) { throw 'ManagementGroupId is required for managementGroup scope' }
    if ($Action -eq 'whatif') {
      az deployment mg what-if -m $ManagementGroupId -l $Location -f $Template @paramArgs $AdditionalParameters | Tee-Object -FilePath $OutFile
    }
    else {
      $modeArgs = @(); if ($Mode) { $modeArgs += '--mode'; $modeArgs += $Mode }
      az deployment mg create -m $ManagementGroupId -l $Location -f $Template @paramArgs $modeArgs $AdditionalParameters
    }
  }
  'tenant' {
    if ($Action -eq 'whatif') {
      az deployment tenant what-if -l $Location -f $Template @paramArgs $AdditionalParameters | Tee-Object -FilePath $OutFile
    }
    else {
      $modeArgs = @(); if ($Mode) { $modeArgs += '--mode'; $modeArgs += $Mode }
      az deployment tenant create -l $Location -f $Template @paramArgs $modeArgs $AdditionalParameters
    }
  }
}
