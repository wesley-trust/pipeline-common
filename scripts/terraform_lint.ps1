param(
  [string]$WorkDir = '.'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Set-Location $WorkDir
terraform init -backend=false
terraform fmt -check -recursive
terraform validate
Write-Information -InformationAction Continue -MessageData "Terraform lint/validate passed."

