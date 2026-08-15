[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string] $PackagePath,

  [Parameter(Mandatory = $true)]
  [string] $PackageSource,

  [Parameter(Mandatory = $true)]
  [string] $ProjectPath,

  [Parameter(Mandatory = $true)]
  [string] $LaneRoot,

  [Parameter(Mandatory = $true)]
  [string] $OutputPath,

  [Parameter(Mandatory = $true)]
  [string] $PackageVersion,

  [ValidateSet("win-x64", "win-arm64")]
  [string] $RuntimeIdentifier = "win-x64"
)

$ErrorActionPreference = "Stop"

$package = (Resolve-Path -LiteralPath $PackagePath).Path
$packageSource = (Resolve-Path -LiteralPath $PackageSource).Path
$project = (Resolve-Path -LiteralPath $ProjectPath).Path
$projectDirectory = Split-Path -Parent $project

Remove-Item -LiteralPath $LaneRoot -Recurse -Force -ErrorAction SilentlyContinue
foreach ($staleRoot in @(
  (Join-Path $projectDirectory "obj"),
  (Join-Path $projectDirectory "bin")
)) {
  Remove-Item -LiteralPath $staleRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$packages = Join-Path $LaneRoot "packages"
$obj = (Join-Path $LaneRoot "obj") + [IO.Path]::DirectorySeparatorChar
New-Item -ItemType Directory -Path $packages, $obj, $OutputPath -Force |
  Out-Null

dotnet restore $project `
  --source $packageSource `
  --packages $packages `
  --ignore-failed-sources `
  --no-cache `
  "-p:NuGetAudit=false" `
  "-p:DesktopUpdaterNativeRuntimeIdentifier=$RuntimeIdentifier" `
  "-p:DesktopUpdaterNativeVersion=$PackageVersion" `
  "-p:RestorePackagesPath=$packages" `
  "-p:BaseIntermediateOutputPath=$obj" `
  "-p:MSBuildProjectExtensionsPath=$obj"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

dotnet build $project `
  --configuration Release `
  --no-restore `
  --output $OutputPath `
  "-p:NuGetAudit=false" `
  "-p:DesktopUpdaterNativeRuntimeIdentifier=$RuntimeIdentifier" `
  "-p:DesktopUpdaterNativeVersion=$PackageVersion" `
  "-p:RestorePackagesPath=$packages" `
  "-p:BaseIntermediateOutputPath=$obj" `
  "-p:MSBuildProjectExtensionsPath=$obj"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Add-Type -AssemblyName System.IO.Compression.FileSystem
$entryNames = @(
  "runtimes/$RuntimeIdentifier/native/desktop_updater_native.dll",
  "runtimes/$RuntimeIdentifier/native/desktop_updater_runtime.dll",
  "runtimes/$RuntimeIdentifier/native/desktop_updater_install_helper.exe",
  "runtimes/$RuntimeIdentifier/native/desktop_updater_helper_policy.json"
)
$expectedHashes = @{}
$archive = [System.IO.Compression.ZipFile]::OpenRead($package)
try {
  foreach ($entryName in $entryNames) {
    $entry = $archive.GetEntry($entryName)
    if ($null -eq $entry) {
      throw "Candidate NuGet package is missing $entryName"
    }
    $stream = $entry.Open()
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
      $hash = $sha256.ComputeHash($stream)
      $expectedHashes[[IO.Path]::GetFileName($entryName)] =
        ([BitConverter]::ToString($hash)).Replace("-", "").ToLowerInvariant()
    } finally {
      $sha256.Dispose()
      $stream.Dispose()
    }
  }
} finally {
  $archive.Dispose()
}

foreach ($fileName in $expectedHashes.Keys) {
  $normalizedSuffix = "/runtimes/$RuntimeIdentifier/native/$fileName"
  $resolvedDlls = @(
    Get-ChildItem -LiteralPath $packages -Recurse -File |
      Where-Object {
        $_.FullName.Replace("\", "/").EndsWith(
          $normalizedSuffix,
          [StringComparison]::OrdinalIgnoreCase)
      }
  )
  if ($resolvedDlls.Count -ne 1) {
    throw "Expected exactly one resolved $fileName, found $($resolvedDlls.Count)."
  }

  $resolvedDll = $resolvedDlls[0].FullName
  $outputDll = Join-Path $OutputPath $fileName
  if (-not (Test-Path -LiteralPath $outputDll -PathType Leaf)) {
    throw "Packaged consumer output is missing $outputDll"
  }

  $resolvedHash = (Get-FileHash -LiteralPath $resolvedDll -Algorithm SHA256).Hash.ToLowerInvariant()
  $outputHash = (Get-FileHash -LiteralPath $outputDll -Algorithm SHA256).Hash.ToLowerInvariant()
  $expectedHash = $expectedHashes[$fileName]
  if ($resolvedHash -ne $expectedHash) {
    throw "Resolved package $fileName does not match the candidate NuGet entry."
  }
  if ($outputHash -ne $expectedHash) {
    throw "Consumer output $fileName does not match the candidate NuGet entry."
  }
}

Write-Host "Verified isolated package restore and native/helper/policy hashes for $ProjectPath"
