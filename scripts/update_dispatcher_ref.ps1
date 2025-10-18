param(
  [Parameter(Mandatory = $true)][string]$PipelineCommonTag,
  [string]$GitHubRepository = 'wesley-trust/pipeline-dispatcher',
  [string]$BaseBranch = 'main',
  [string]$GitHubToken,
  [string]$GitHubHost = 'https://github.com'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Set-PipelineVariable {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$Value
  )

  Write-Information -InformationAction Continue -MessageData "##vso[task.setvariable variable=$Name]$Value"
}

function Get-GitHubToken {
  param([string]$PreferredHost)

  $envVars = Get-ChildItem Env: | Where-Object { $_.Name -like 'ENDPOINT_AUTH_PARAMETER_*_ACCESSTOKEN' }
  foreach ($var in $envVars) {
    $endpointId = ($var.Name -replace '^ENDPOINT_AUTH_PARAMETER_', '') -replace '_ACCESSTOKEN$', ''
    $urlVar = "ENDPOINT_URL_$endpointId"
    $url = (Get-Item -Path "Env:$urlVar" -ErrorAction SilentlyContinue).Value
    if (-not $url) { continue }
    if ($url.StartsWith($PreferredHost, [System.StringComparison]::OrdinalIgnoreCase)) {
      return $var.Value
    }
  }
  throw "Unable to locate GitHub access token in environment. Provide -GitHubToken explicitly."
}

function Get-GitHubApiBase {
  param(
    [string]$GitHost,
    [string]$Repository
  )
  $uri = [System.Uri]$GitHost
  if ($uri.Host -eq 'github.com') {
    return "https://api.github.com/repos/$Repository"
  }
  else {
    $baseUrl = "{0}://{1}" -f $uri.Scheme, $uri.Host
    if ($uri.Port -and $uri.IsDefaultPort -eq $false) {
      $baseUrl = "{0}:{1}" -f $baseUrl, $uri.Port
    }
    return "$baseUrl/api/v3/repos/$Repository"
  }
}

if (-not $PipelineCommonTag) {
  throw 'PipelineCommonTag must be provided.'
}

if (-not $GitHubToken) {
  $GitHubToken = Get-GitHubToken -PreferredHost $GitHubHost
}

$targetRef = if ($PipelineCommonTag.StartsWith('refs/', [System.StringComparison]::OrdinalIgnoreCase)) {
  $PipelineCommonTag
}
else {
  "refs/tags/$PipelineCommonTag"
}

$apiBase = Get-GitHubApiBase -GitHost $GitHubHost -Repository $GitHubRepository 
$headers = @{
  Authorization = "token $GitHubToken"
  'User-Agent'  = 'azure-devops-release'
  Accept        = 'application/vnd.github+json'
}

# Ensure base branch exists and capture its SHA
$baseRef = Invoke-RestMethod -Method Get -Uri "$apiBase/git/ref/heads/$BaseBranch" -Headers $headers
$baseSha = $baseRef.object.sha

# Create working branch
$tagSuffix = ($PipelineCommonTag -replace '^refs/', '' -replace '^tags/', '').Replace('/', '-').Replace(' ', '-').ToLower()
if (-not $tagSuffix) { $tagSuffix = (Get-Date -Format 'yyyyMMddHHmmss') }
$branchName = "update-pipeline-common-$tagSuffix"

function New-Branch {
  param([string]$Name)
  $body = @{ ref = "refs/heads/$Name"; sha = $baseSha } | ConvertTo-Json -Depth 4 -Compress
  Invoke-RestMethod -Method Post -Uri "$apiBase/git/refs" -Headers $headers -ContentType 'application/json' -Body $body | Out-Null
}

try {
  New-Branch -Name $branchName
}
catch {
  if ($_.Exception.Response.StatusCode.value__ -eq 422) {
    $branchName = "${branchName}-$(Get-Date -Format 'yyyyMMddHHmmss')"
    New-Branch -Name $branchName
  }
  else {
    throw
  }
}

$filePath = 'templates/pipeline-common-dispatcher.yml'
$fileResponse = Invoke-RestMethod -Method Get -Uri "$apiBase/contents/$filePath?ref=$branchName" -Headers $headers

$currentContent = [System.Text.Encoding]::UTF8.GetString(
  [System.Convert]::FromBase64String(($fileResponse.content -replace '\s', ''))
)

$updatedContent = $currentContent -replace 'ref:\s*".*"', ('ref: "' + $targetRef + '"')

if ($updatedContent -eq $currentContent) {
  Write-Information -InformationAction Continue -MessageData 'Pipeline dispatcher already references the desired tag. No PR created.'
  return
}

$encodedContent = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($updatedContent))
$commitMessage = "chore: bump pipeline-common to $PipelineCommonTag"
$updateBody = @{
  message = $commitMessage
  content = $encodedContent
  sha     = $fileResponse.sha
  branch  = $branchName
} | ConvertTo-Json -Depth 4 -Compress
Invoke-RestMethod -Method Put -Uri "$apiBase/contents/$filePath" -Headers $headers -ContentType 'application/json' -Body $updateBody | Out-Null

$prTitle = $commitMessage
$prBody = "Automated PR to align pipeline-dispatcher with pipeline-common $PipelineCommonTag."
$prPayload = @{
  title = $prTitle
  head  = $branchName
  base  = $BaseBranch
  body  = $prBody
} | ConvertTo-Json -Depth 4 -Compress
$prResponse = Invoke-RestMethod -Method Post -Uri "$apiBase/pulls" -Headers $headers -ContentType 'application/json' -Body $prPayload

Set-PipelineVariable -Name 'DispatcherPrNumber' -Value ($prResponse.number.ToString())
Set-PipelineVariable -Name 'DispatcherPrUrl' -Value $prResponse.html_url

Write-Information -InformationAction Continue -MessageData "Opened pull request #$($prResponse.number) to update pipeline-common ref."
Write-Information -InformationAction Continue -MessageData "PR URL: $($prResponse.html_url)"