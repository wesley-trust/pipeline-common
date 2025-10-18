param(
  [string]$ReleaseNotesFile
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

try {
  $sourcesRoot = $Env:BUILD_SOURCESDIRECTORY
  if ([string]::IsNullOrWhiteSpace($sourcesRoot)) {
    throw 'BUILD_SOURCESDIRECTORY is not defined.'
  }

  $repoPath = Join-Path -Path $sourcesRoot -ChildPath 'self'
  if (-not (Test-Path -Path $repoPath -PathType Container)) {
    $repoPath = $sourcesRoot
  }

  Set-Location -Path $repoPath

  git config user.email "noreply@wesleytrust.com"
  git config user.name "Wesley Trust"

  git fetch --tags --prune --force | Out-Null
  try {
    git fetch --prune --unshallow | Out-Null
  }
  catch {
    Write-Information -InformationAction Continue -MessageData 'Repository already contains full history.'
  }

  $commitMessage = (git log -1 --format=%B | Out-String).Trim()
  if ([string]::IsNullOrWhiteSpace($commitMessage)) {
    throw 'Latest commit message could not be determined.'
  }

  $latestTag = 'v0.0.0'
  try {
    $latestTag = (git describe --tags --abbrev=0).Trim()
  }
  catch {
    Write-Information -InformationAction Continue -MessageData 'No existing tags detected. Starting from v0.0.0.'
  }

  if ($latestTag -notmatch '^v(\d+)\.(\d+)\.(\d+)$') {
    $latestTag = 'v0.0.0'
  }

  $headCommit = (git rev-parse HEAD).Trim()
  $latestTagCommit = ''
  if ($latestTag -ne 'v0.0.0') {
    try {
      $latestTagCommit = (git rev-list -n 1 $latestTag).Trim()
    }
    catch {
      Write-Information -InformationAction Continue -MessageData "Unable to resolve commit for tag $latestTag. Proceeding with new release."
    }
  }

  if ($latestTagCommit -eq $headCommit -and $latestTag -ne 'v0.0.0') {
    Write-Information -InformationAction Continue -MessageData "Latest tag $latestTag already points to HEAD ($headCommit). Skipping release creation."
    Set-PipelineVariable -Name 'ReleaseSkip' -Value 'true'
    Set-PipelineVariable -Name 'ReleaseTag' -Value $latestTag
    Set-PipelineVariable -Name 'ReleaseTitle' -Value "Release $latestTag"

    if ([string]::IsNullOrWhiteSpace($ReleaseNotesFile)) {
      $ReleaseNotesFile = Join-Path -Path $repoPath -ChildPath 'release/release-notes.md'
    }

    $releaseNotesDirectory = Split-Path -Path $ReleaseNotesFile -Parent
    if (-not (Test-Path -Path $releaseNotesDirectory -PathType Container)) {
      New-Item -ItemType Directory -Path $releaseNotesDirectory -Force | Out-Null
    }

    $notesContent = $commitMessage.Trim()
    Set-Content -Path $ReleaseNotesFile -Value $notesContent -Encoding UTF8
    Set-PipelineVariable -Name 'ReleaseNotesFile' -Value $ReleaseNotesFile
    Set-PipelineVariable -Name 'ReleaseNotes' -Value $notesContent
    Write-Information -InformationAction Continue -MessageData "##vso[build.updatebuildnumber]$latestTag"
    return
  }

  $firstLine = ($commitMessage -split "`n")[0].Trim()
  $bump = 'patch'
  if ($commitMessage -match 'BREAKING CHANGE') {
    $bump = 'major'
  }
  elseif ($firstLine -match '^[a-zA-Z]+(\([^)]+\))?!:') {
    $bump = 'major'
  }
  elseif ($firstLine -match '^feat(\([^)]+\))?:') {
    $bump = 'minor'
  }

  Write-Information -InformationAction Continue -MessageData "Semantic version bump detected: $bump"

  $null = $latestTag -match '^v(\d+)\.(\d+)\.(\d+)$'
  $major = [int]$Matches[1]
  $minor = [int]$Matches[2]
  $patch = [int]$Matches[3]

  switch ($bump) {
    'major' {
      $major++
      $minor = 0
      $patch = 0
    }
    'minor' {
      $minor++
      $patch = 0
    }
    default {
      $patch++
    }
  }

  $newTag = "v$major.$minor.$patch"
  Write-Information -InformationAction Continue -MessageData "Latest tag: $latestTag"
  Write-Information -InformationAction Continue -MessageData "New tag: $newTag"

  Set-PipelineVariable -Name 'ReleaseSkip' -Value 'false'

  $existingTag = (git tag -l $newTag)
  if (-not [string]::IsNullOrWhiteSpace($existingTag)) {
    Write-Information -InformationAction Continue -MessageData "Tag $newTag already exists. Skipping creation."
    Set-PipelineVariable -Name 'ReleaseSkip' -Value 'true'
  }
  else {
    git tag $newTag
    git push origin $newTag | Out-Null
    Write-Information -InformationAction Continue -MessageData "Created and pushed tag $newTag."
  }

  if ([string]::IsNullOrWhiteSpace($ReleaseNotesFile)) {
    $ReleaseNotesFile = Join-Path -Path $repoPath -ChildPath 'release/release-notes.md'
  }

  $releaseNotesDirectory = Split-Path -Path $ReleaseNotesFile -Parent
  if (-not (Test-Path -Path $releaseNotesDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $releaseNotesDirectory -Force | Out-Null
  }

  $notesContent = $commitMessage.Trim()
  Set-Content -Path $ReleaseNotesFile -Value $notesContent -Encoding UTF8

  Set-PipelineVariable -Name 'ReleaseTag' -Value $newTag
  Set-PipelineVariable -Name 'ReleaseTitle' -Value "Release $newTag"
  Set-PipelineVariable -Name 'ReleaseNotesFile' -Value $ReleaseNotesFile
  Set-PipelineVariable -Name 'ReleaseNotes' -Value $notesContent

  Write-Information -InformationAction Continue -MessageData "##vso[build.updatebuildnumber]$newTag"
}
catch {
  Write-Error $_
  throw
}
