param(
  [string]
  $VariableRoot = 'vars',
  [Parameter(Mandatory = $true)]
  [string]
  $EnvironmentsJson,
  [string]
  $VariablesConfigJson
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-PropertyValue {
  param(
    [object]$Source,
    [string]$Name
  )

  if ($null -eq $Source -or [string]::IsNullOrEmpty($Name)) {
    return $null
  }

  if ($Source -is [System.Collections.IDictionary]) {
    if ($Source.Contains($Name)) {
      return $Source[$Name]
    }
    if ($Source.ContainsKey($Name)) {
      return $Source[$Name]
    }
  }

  $property = $Source.PSObject.Properties | Where-Object { $_.Name -eq $Name }
  if ($property) {
    return $property.Value
  }

  return $null
}

function Get-IncludeFlag {
  param(
    [object]$Environment,
    [object]$GlobalConfig,
    [string]$FlagName,
    [bool]$Default = $true
  )

  $value = $null

  $envVariables = Get-PropertyValue -Source $Environment -Name 'variables'
  if ($null -eq $value -and $null -ne $envVariables) {
    $value = Get-PropertyValue -Source $envVariables -Name $FlagName
  }

  if ($null -eq $value -and $null -ne $GlobalConfig) {
    $value = Get-PropertyValue -Source $GlobalConfig -Name $FlagName
  }

  if ($null -eq $value) {
    return $Default
  }

  try {
    return [System.Convert]::ToBoolean($value)
  }
  catch {
    return $Default
  }
}

function Test-VariableFile {
  param(
    [string]$Path,
    [string]$Description
  )

  if (Test-Path -Path $Path) {
    Write-Information -InformationAction Continue -MessageData "Found: $Description ($Path)"
  }
  else {
    Write-Warning -Message "variables file not found: $Description ($Path)"
  }
}

$globalVariables = $null
if (-not [string]::IsNullOrWhiteSpace($VariablesConfigJson) -and $VariablesConfigJson -ne 'null') {
  try {
    $globalVariables = $VariablesConfigJson | ConvertFrom-Json -Depth 10
  }
  catch {
    Write-Warning -Message "Unable to parse VariablesConfigJson. Using defaults. Error: $_"
    $globalVariables = $null
  }
}

if ($null -eq $globalVariables) {
  $globalVariables = [pscustomobject]@{}
}

$environments = @()
if (-not [string]::IsNullOrWhiteSpace($EnvironmentsJson)) {
    $deserialized = $EnvironmentsJson | ConvertFrom-Json -Depth 10
    if ($null -ne $deserialized) {
      if ($deserialized -is [System.Collections.IEnumerable] -and $deserialized -isnot [string]) {
        $environments = @($deserialized)
      }
      else {
        $environments = @($deserialized)
      }
    }
}

$environments = $environments | Where-Object { $_ -ne $null }

$includeCommon = Get-IncludeFlag -Environment $null -GlobalConfig $globalVariables -FlagName 'includeCommon'
if ($includeCommon) {
  $commonPath = Join-Path -Path $VariableRoot -ChildPath 'common.yml'
  Test-VariableFile -Path $commonPath -Description 'common variables'
}
else {
  Write-Information -InformationAction Continue -MessageData 'Skipping common variables include (disabled by configuration).'
}

$candidateRegions = @()
foreach ($env in $environments) {
  $primaryRegion = Get-PropertyValue -Source $env -Name 'primaryRegion'
  if ($primaryRegion) { $candidateRegions += $primaryRegion }

  $secondaryRegions = Get-PropertyValue -Source $env -Name 'secondaryRegions'
  if ($secondaryRegions) { $candidateRegions += $secondaryRegions }

  $drRegion = Get-PropertyValue -Source $env -Name 'drRegion'
  if ($drRegion) { $candidateRegions += $drRegion }
}

$uniqueRegions = @()
if ($candidateRegions) {
  $uniqueRegions = $candidateRegions | ForEach-Object { $_ } | Where-Object { $_ } | Sort-Object -Unique
}

$includeRegionOnly = Get-IncludeFlag -Environment $null -GlobalConfig $globalVariables -FlagName 'includeRegionOnly'
if ($includeRegionOnly -and $uniqueRegions.Count -gt 0) {
  foreach ($region in $uniqueRegions) {
    $regionPath = Join-Path -Path $VariableRoot -ChildPath ("regions/{0}.yml" -f $region)
    Test-VariableFile -Path $regionPath -Description "region variables for '$region'"
  }
}
elseif (-not $includeRegionOnly) {
  Write-Information -InformationAction Continue -MessageData 'Skipping region-only variables include (disabled by configuration).'
}

foreach ($env in $environments) {
  $envName = Get-PropertyValue -Source $env -Name 'name'
  if (-not $envName) {
    Write-Warning -Message 'Encountered environment without a name. Skipping include validation for this entry.'
    continue
  }

  $envInclude = Get-IncludeFlag -Environment $env -GlobalConfig $globalVariables -FlagName 'includeEnv'
  if ($envInclude) {
    $envPath = Join-Path -Path $VariableRoot -ChildPath ("environments/{0}/common.yml" -f $envName)
    Test-VariableFile -Path $envPath -Description "environment variables for '$envName'"
  }
  else {
    Write-Information -InformationAction Continue -MessageData "Skipping environment variables for '$envName' (disabled by configuration)."
  }

  $envRegionInclude = Get-IncludeFlag -Environment $env -GlobalConfig $globalVariables -FlagName 'includeEnvRegion'
  if (-not $envRegionInclude) {
    Write-Information -InformationAction Continue -MessageData "Skipping env-region variables for '$envName' (disabled by configuration)."
    continue
  }

  $envRegions = @()
  $primaryEnvRegion = Get-PropertyValue -Source $env -Name 'primaryRegion'
  if ($primaryEnvRegion) { $envRegions += $primaryEnvRegion }

  $secondaryEnvRegions = Get-PropertyValue -Source $env -Name 'secondaryRegions'
  if ($secondaryEnvRegions) { $envRegions += $secondaryEnvRegions }

  $drEnvRegion = Get-PropertyValue -Source $env -Name 'drRegion'
  if ($drEnvRegion) { $envRegions += $drEnvRegion }

  $envRegions = $envRegions | ForEach-Object { $_ } | Where-Object { $_ } | Sort-Object -Unique

  foreach ($region in $envRegions) {
    $envRegionPath = Join-Path -Path $VariableRoot -ChildPath ("environments/{0}/regions/{1}.yml" -f $envName, $region)
    Test-VariableFile -Path $envRegionPath -Description "env-region variables for '$envName'/'$region'"
  }
}

Write-Information -InformationAction Continue -MessageData 'Variable include preflight completed.'
