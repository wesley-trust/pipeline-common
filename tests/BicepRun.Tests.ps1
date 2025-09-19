Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
  $script:RepoRoot = Split-Path -Parent $PSScriptRoot
  $script:ScriptPathUnderTest = Join-Path $script:RepoRoot 'scripts/bicep_run.ps1'
}

Describe 'bicep_run.ps1 stack orchestration' {
  BeforeEach {
    $script:AzCalls = @()

    function global:az {
      param(
        [Parameter(ValueFromRemainingArguments = $true)][object[]]$Arguments
      )

      $script:AzCalls += ,@($Arguments)
    }
  }

  AfterEach {
    if (Test-Path function:\az) {
      Remove-Item function:\az -Force
    }
  }

  It 'uses detachAll by default for resource group deployments' {
    . $script:ScriptPathUnderTest -Action 'deploy' -Scope 'resourceGroup' -ResourceGroupName 'rg-test' -Template 'template.bicep'

    $script:AzCalls | Should -HaveCount 1
    $call = $script:AzCalls[0]
    $nameIndex = [Array]::IndexOf($call, '--name')
    $nameIndex | Should -BeGreaterOrEqual 0
    $call[$nameIndex + 1] | Should -Be 'ds-rg-test'
    $index = [Array]::IndexOf($call, '--action-on-unmanage')
    $index | Should -BeGreaterOrEqual 0
    $call[$index + 1] | Should -Be 'detachAll'
  }

  It 'temporarily enables deleteAll when requested' {
    . $script:ScriptPathUnderTest -Action 'deploy' -Scope 'resourceGroup' -ResourceGroupName 'rg-test' -Template 'template.bicep' -AllowDeleteOnUnmanage 'True'

    $script:AzCalls | Should -HaveCount 2

    $initial = $script:AzCalls[0]
    $initialIndex = [Array]::IndexOf($initial, '--action-on-unmanage')
    $initial[$initialIndex + 1] | Should -Be 'deleteAll'

    $reset = $script:AzCalls[1]
    $resetIndex = [Array]::IndexOf($reset, '--action-on-unmanage')
    $reset[$resetIndex + 1] | Should -Be 'detachAll'
  }

  It 'passes additional parameters without losing spacing' {
    $additional = "--parameters foo=bar --description `"space preserved`""

    . $script:ScriptPathUnderTest -Action 'deploy' -Scope 'subscription' -Location 'westeurope' -Template 'template.bicep' -ResourceGroupName 'rg-sub-test' -AdditionalParameters $additional

    $script:AzCalls | Should -HaveCount 1
    $call = $script:AzCalls[0]

    $call | Should -Contain '--parameters'
    $call | Should -Contain 'foo=bar'
    $call | Should -Contain '--description'
    $call[$call.IndexOf('--description') + 1] | Should -Be 'space preserved'
    $call[$call.IndexOf('--name') + 1] | Should -Be 'ds-sub-rg-sub-test'
  }

  It 'parses single-quoted additional parameters correctly' {
    $additional = "--parameters name='value with ''quotes''' --tag single"

    . $script:ScriptPathUnderTest -Action 'deploy' -Scope 'resourceGroup' -ResourceGroupName 'rg-test' -Template 'template.bicep' -AdditionalParameters $additional

    $script:AzCalls | Should -HaveCount 1
    $call = $script:AzCalls[0]

    $call | Should -Contain "name=value with 'quotes'"
    $call | Should -Contain '--tag'
    $call[$call.IndexOf('--tag') + 1] | Should -Be 'single'
    $call[$call.IndexOf('--name') + 1] | Should -Be 'ds-rg-test'
  }

  It 'resets stack when deleteAll is enabled at management group scope' {
    . $script:ScriptPathUnderTest -Action 'deploy' -Scope 'managementGroup' -Location 'westeurope' -ManagementGroupId 'mg-test' -Template 'template.bicep' -AllowDeleteOnUnmanage 'true'

    $script:AzCalls | Should -HaveCount 2
    $script:AzCalls | ForEach-Object { $_ | Should -Contain '--management-group-id' }
  }

  It 'passes through subscription id and issues reset when delete is enabled' {
    . $script:ScriptPathUnderTest -Action 'deploy' -Scope 'subscription' -Location 'westeurope' -Template 'template.bicep' -ResourceGroupName 'rg-sub-test' -AllowDeleteOnUnmanage '1'

    $script:AzCalls | Should -HaveCount 2
    foreach ($call in $script:AzCalls) {
      $call[$call.IndexOf('--name') + 1] | Should -Be 'ds-sub-rg-sub-test'
    }
  }

  It 'rejects allowDeleteOnUnmanage for tenant scope' {
    { . $script:ScriptPathUnderTest -Action 'deploy' -Scope 'tenant' -Location 'westeurope' -Template 'template.bicep' -AllowDeleteOnUnmanage 'true' } | Should -Throw -ErrorId *
  }

  It 'allows tenant deployments when delete toggle is disabled' {
    . $script:ScriptPathUnderTest -Action 'deploy' -Scope 'tenant' -Location 'westeurope' -Template 'template.bicep'

    $script:AzCalls | Should -HaveCount 1
    $call = $script:AzCalls[0]
    $call | Should -Contain 'tenant'
  }
}
