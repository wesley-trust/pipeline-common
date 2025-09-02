param(
  [string]$WorkDir = '.'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Set-Location $WorkDir
terraform init -backend=false
terraform fmt -check -recursive
terraform validate
Write-Host 'Terraform lint/validate passed.'

