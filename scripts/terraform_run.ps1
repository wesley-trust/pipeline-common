param(
  [Parameter(Mandatory = $true)][ValidateSet('validate', 'plan', 'apply')][string]$Action,
  [Parameter(Mandatory = $true)][string]$WorkDir,
  [string]$EnvironmentName = '',
  [string]$VarFilesString = '',
  [string]$PlanFile = 'tfplan'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Set-Location $WorkDir

if ($Action -eq 'validate') {
  terraform init -backend=false
  terraform validate
  exit 0
}

terraform init

if ($EnvironmentName) {
  try {
    terraform workspace new $EnvironmentName | Out-Null
  }
  catch {
    if ($_.Exception.Message -notmatch 'already exists') {
      throw $_
    }
  }
  terraform workspace select $EnvironmentName
}

$tfArgs = @()
$VarFiles = @()
if ($VarFilesString) { $VarFiles = $VarFilesString -split ';' }
foreach ($f in $VarFiles) {
  if ($f) { $tfArgs += "-var-file=$f" }
}

switch ($Action) {
  'plan' {
    Write-Verbose ("Terraform plan output file: {0}" -f $PlanFile)
    terraform plan -out=$PlanFile @tfArgs
  }
  'apply' { terraform apply -auto-approve @tfArgs }
}
