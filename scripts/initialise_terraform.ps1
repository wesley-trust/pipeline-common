param([Parameter(Mandatory=$true)][string]$Version)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Write-Host "Installing Terraform $Version"
$os = $PSStyle.Platform
if ($IsWindows) { $platform = 'windows_amd64' }
elseif ($IsLinux) { $platform = 'linux_amd64' }
elseif ($IsMacOS) { $platform = 'darwin_amd64' } else { throw 'Unsupported OS' }

$url = "https://releases.hashicorp.com/terraform/$Version/terraform_${Version}_${platform}.zip"
$zip = Join-Path $env:Agent_TempDirectory "terraform.zip"
Invoke-WebRequest -Uri $url -OutFile $zip
$dest = if ($IsWindows) { 'C:/hostedtoolcache/terraform' } else { '/usr/local/bin' }
if ($IsWindows) {
  Expand-Archive -Path $zip -DestinationPath $env:Agent_TempDirectory -Force
  Copy-Item -Path (Join-Path $env:Agent_TempDirectory 'terraform.exe') -Destination $dest -Force
} else {
  Expand-Archive -Path $zip -DestinationPath $env:Agent_TempDirectory -Force
  sudo cp "$env:Agent_TempDirectory/terraform" "$dest/terraform"
  sudo chmod +x "$dest/terraform"
}
terraform -version

