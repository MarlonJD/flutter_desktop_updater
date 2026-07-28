[CmdletBinding()]
param(
  [string] $IsccPath,
  [switch] $KeepArtifacts
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-YamlSingleQuoted([string] $Value) {
  return "'" + $Value.Replace("'", "''") + "'"
}

function Invoke-Checked(
  [string] $FilePath,
  [string[]] $ArgumentList,
  [string] $WorkingDirectory
) {
  Push-Location $WorkingDirectory
  try {
    & $FilePath @ArgumentList | Out-Host
    if ($LASTEXITCODE -ne 0) {
      throw "$FilePath failed with exit code $LASTEXITCODE."
    }
  } finally {
    Pop-Location
  }
}

function Wait-Until(
  [scriptblock] $Condition,
  [int] $TimeoutSeconds,
  [string] $FailureMessage
) {
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  do {
    if (& $Condition) {
      return
    }
    Start-Sleep -Milliseconds 250
  } while ((Get-Date) -lt $deadline)
  throw $FailureMessage
}

function Assert-FileText([string] $Path, [string] $Expected) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "Expected file is missing: $Path"
  }
  $actual = (Get-Content -Raw -LiteralPath $Path).Trim()
  if ($actual -ne $Expected) {
    throw "Expected '$Expected' in $Path, found '$actual'."
  }
}

function Resolve-Iscc([string] $ExplicitPath) {
  $discoveredIscc = Get-Command iscc.exe -ErrorAction SilentlyContinue
  $candidates = @(
    $ExplicitPath,
    $(if ($discoveredIscc) { $discoveredIscc.Source }),
    'C:\Program Files (x86)\Inno Setup 6\ISCC.exe',
    'C:\Program Files\Inno Setup 6\ISCC.exe'
  ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
  $resolved = $candidates |
    Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
    Select-Object -First 1
  if (-not $resolved) {
    throw 'Inno Setup Compiler is required for the local Windows Inno smoke.'
  }
  return [IO.Path]::GetFullPath($resolved)
}

function Publish-SmokeVersion(
  [string] $ExampleRoot,
  [string] $TempRoot,
  [string] $ResolvedIscc,
  [string] $Version,
  [string] $BuildNumber
) {
  $versionRoot = Join-Path $TempRoot "version-$Version"
  $outputRoot = Join-Path $versionRoot 'publish'
  $sentinelRoot = Join-Path $versionRoot 'sentinel'
  New-Item -ItemType Directory -Force -Path $sentinelRoot | Out-Null
  $sentinel = Join-Path $sentinelRoot `
    'desktop_updater_inno_smoke_version.txt'
  Set-Content -LiteralPath $sentinel -Value $Version -Encoding UTF8NoBOM

  $configPath = Join-Path $versionRoot 'desktop_updater.yaml'
  $yamlOutput = ConvertTo-YamlSingleQuoted $outputRoot
  $yamlIscc = ConvertTo-YamlSingleQuoted $ResolvedIscc
  $yamlSentinel = ConvertTo-YamlSingleQuoted $sentinel
  @"
updates:
  baseUrl: https://updates.invalid/
  output: $yamlOutput

windows:
  installer:
    kind: inno
    mode: generated
    isccPath: $yamlIscc
    outputBaseName: desktop-updater-inno-smoke-$Version
    appId: com.openai.desktop-updater.inno-smoke
    publisher: desktop_updater smoke
    privilegesRequired: lowest
    requiresElevation: never
    architecturesAllowed: x64compatible
    architecturesInstallIn64BitMode: x64compatible
    silentArgs:
      - /VERYSILENT
      - /SUPPRESSMSGBOXES
      - /NORESTART

additionalFiles:
  - source: $yamlSentinel
    destination: .
    platforms: [windows]
"@ | Set-Content -LiteralPath $configPath -Encoding UTF8NoBOM

  Invoke-Checked 'dart' @(
    'run',
    'desktop_updater:release',
    'publish',
    '--platform',
    'windows',
    '--config',
    $configPath,
    '--version',
    $Version,
    '--build-number',
    $BuildNumber
  ) $ExampleRoot

  $manifestPath = Join-Path $outputRoot '.desktop_updater_publish.json'
  $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
  $artifactPath = Join-Path $outputRoot (
    ([string] $manifest.artifact.path).Replace(
      '/',
      [IO.Path]::DirectorySeparatorChar
    )
  )
  $releasePath = Join-Path $outputRoot (
    ([string] $manifest.release.path).Replace(
      '/',
      [IO.Path]::DirectorySeparatorChar
    )
  )
  if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
    throw "Published installer is missing: $artifactPath"
  }
  if (-not (Test-Path -LiteralPath $releasePath -PathType Leaf)) {
    throw "Published release descriptor is missing: $releasePath"
  }
  return [pscustomobject]@{
    Version = $Version
    ArtifactPath = $artifactPath
    ReleasePath = $releasePath
  }
}

function Invoke-InstalledAppUpdate(
  [string] $ExecutablePath,
  [string] $StagingPath,
  [string] $MarkerPath,
  [string] $DiagnosticsPath
) {
  $startInfo = [Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $ExecutablePath
  $startInfo.WorkingDirectory = Split-Path $ExecutablePath -Parent
  $startInfo.UseShellExecute = $false
  $startInfo.Environment['DESKTOP_UPDATER_SMOKE_STAGING'] = $StagingPath
  $startInfo.Environment['DESKTOP_UPDATER_SMOKE_MARKER'] = $MarkerPath
  $startInfo.Environment['DESKTOP_UPDATER_SMOKE_DIAGNOSTICS_LOG'] =
    $DiagnosticsPath
  $startInfo.Environment['DESKTOP_UPDATER_SMOKE_SKIP_RELAUNCH'] = '1'

  $process = [Diagnostics.Process]::Start($startInfo)
  try {
    Wait-Until {
      (Test-Path -LiteralPath $MarkerPath -PathType Leaf) -and
      ((Get-Content -Raw -LiteralPath $MarkerPath).Trim() -eq 'installing')
    } 30 'Installed app did not reach the Inno install handoff.'

    if (-not $process.WaitForExit(30000)) {
      $process.Kill($true)
      throw 'Installed app did not exit after scheduling the Inno update.'
    }
    if ($process.ExitCode -ne 0) {
      throw "Installed app exited with code $($process.ExitCode)."
    }
  } finally {
    if (-not $process.HasExited) {
      $process.Kill($true)
    }
    $process.Dispose()
  }
}

if ($env:OS -ne 'Windows_NT') {
  throw 'Windows Inno smoke requires Windows.'
}
if ($PSVersionTable.PSVersion.Major -lt 7) {
  throw 'Windows Inno smoke requires PowerShell 7 or newer.'
}

$repoRoot = Split-Path $PSScriptRoot -Parent
$exampleRoot = Join-Path $repoRoot 'example'
$resolvedIscc = Resolve-Iscc $IsccPath
$reportsRoot = Join-Path $repoRoot 'reports'
$diagnostics = Join-Path $reportsRoot `
  'windows-inno-update-smoke-diagnostics.jsonl'
New-Item -ItemType Directory -Force -Path $reportsRoot | Out-Null
Remove-Item -LiteralPath $diagnostics -Force -ErrorAction SilentlyContinue

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) (
  'desktop_updater_inno_smoke_' + [Guid]::NewGuid().ToString('N')
)
$installRoot = Join-Path $tempRoot 'installed'
$stagingRoot = Join-Path $tempRoot 'stage'
$markerPath = Join-Path $tempRoot 'marker.txt'
$installedExe = Join-Path $installRoot 'desktop_updater_example.exe'
$installedSentinel = Join-Path $installRoot `
  'desktop_updater_inno_smoke_version.txt'
$installationStarted = $false
$uninstallCompleted = $false

New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

try {
  $version1 = Publish-SmokeVersion `
    $exampleRoot $tempRoot $resolvedIscc '9.9.8' '998'
  $installationStarted = $true
  Invoke-Checked $version1.ArtifactPath @(
    '/VERYSILENT',
    '/SUPPRESSMSGBOXES',
    '/NORESTART',
    "/DIR=$installRoot"
  ) $repoRoot

  if (-not (Test-Path -LiteralPath $installedExe -PathType Leaf)) {
    throw "Version 1 executable was not installed: $installedExe"
  }
  Assert-FileText $installedSentinel '9.9.8'
  if (-not (Get-ChildItem -LiteralPath $installRoot -Filter 'unins*.exe')) {
    throw 'Version 1 did not create an Inno uninstaller.'
  }

  $version2 = Publish-SmokeVersion `
    $exampleRoot $tempRoot $resolvedIscc '9.9.9' '999'
  New-Item -ItemType Directory -Force -Path $stagingRoot | Out-Null
  Copy-Item -LiteralPath $version2.ArtifactPath `
    -Destination (Join-Path $stagingRoot 'installer.exe')
  Copy-Item -LiteralPath $version2.ReleasePath `
    -Destination (Join-Path $stagingRoot `
      '.desktop_updater_release_manifest.json')

  Invoke-InstalledAppUpdate `
    $installedExe $stagingRoot $markerPath $diagnostics

  Wait-Until {
    (Test-Path -LiteralPath $installedSentinel -PathType Leaf) -and
    ((Get-Content -Raw -LiteralPath $installedSentinel).Trim() -eq '9.9.9')
  } 90 'Version 2 sentinel was not installed.'
  Wait-Until {
    -not (Test-Path -LiteralPath $stagingRoot)
  } 30 'Inno staging directory was not cleaned.'
  Wait-Until {
    if (-not (Test-Path -LiteralPath $diagnostics -PathType Leaf)) {
      return $false
    }
    $log = Get-Content -Raw -LiteralPath $diagnostics
    return $log.Contains('inno manifest loaded') -and
      $log.Contains('inno installer start') -and
      $log.Contains('inno installer success')
  } 90 'Inno helper diagnostics did not reach success.'

  $uninstaller = Get-ChildItem -LiteralPath $installRoot `
    -Filter 'unins*.exe' |
    Sort-Object Name |
    Select-Object -First 1
  if (-not $uninstaller) {
    throw 'Inno uninstaller is missing after the update.'
  }
  Invoke-Checked $uninstaller.FullName @(
    '/VERYSILENT',
    '/SUPPRESSMSGBOXES',
    '/NORESTART'
  ) $repoRoot
  $uninstallCompleted = $true

  Wait-Until {
    -not (Test-Path -LiteralPath $installedExe) -and
    -not (Test-Path -LiteralPath $installedSentinel)
  } 60 'Inno uninstall did not remove the version 2 payload.'
  Wait-Until {
    -not (Test-Path -LiteralPath $installRoot)
  } 30 'Inno uninstaller did not finish cleaning the install directory.'
} finally {
  if ($installationStarted -and -not $uninstallCompleted -and
      (Test-Path -LiteralPath $installRoot -PathType Container)) {
    $cleanupUninstaller = Get-ChildItem -LiteralPath $installRoot `
      -Filter 'unins*.exe' -ErrorAction SilentlyContinue |
      Sort-Object Name |
      Select-Object -First 1
    if ($cleanupUninstaller) {
      Invoke-Checked $cleanupUninstaller.FullName @(
        '/VERYSILENT',
        '/SUPPRESSMSGBOXES',
        '/NORESTART'
      ) $repoRoot
      Wait-Until {
        -not (Test-Path -LiteralPath $installRoot)
      } 30 'Cleanup uninstaller did not finish cleaning the install directory.'
    }
  }

  if ($KeepArtifacts) {
    Write-Host "Keeping Windows Inno smoke files: $tempRoot"
  } else {
    $resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
    $systemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if (-not $resolvedTemp.StartsWith(
      $systemTemp,
      [StringComparison]::OrdinalIgnoreCase
    )) {
      throw "Refusing to clean path outside system temp: $resolvedTemp"
    }
    if ([IO.Path]::GetFileName($resolvedTemp) -notlike
        'desktop_updater_inno_smoke_*') {
      throw "Refusing to clean unexpected temp path: $resolvedTemp"
    }
    if (Test-Path -LiteralPath $resolvedTemp) {
      Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
    }
  }
}

Write-Host 'Windows Inno install/update/uninstall smoke passed.'
Write-Host "Diagnostics: $diagnostics"
