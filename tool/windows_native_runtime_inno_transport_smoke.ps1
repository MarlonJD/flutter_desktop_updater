[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string] $PackageVersion,
  [Parameter(Mandatory = $true)]
  [string] $PackagePath,
  [Parameter(Mandatory = $true)]
  [string] $PackageSource,
  [Parameter(Mandatory = $true)]
  [string] $IsccPath,
  [Parameter(Mandatory = $true)]
  [string] $SigntoolPath,
  [string] $PfxPath,
  [string] $PfxPassword,
  [ValidatePattern('^[0-9A-Fa-f]{40}$')]
  [string] $SigningCertificateSha1,
  [ValidatePattern('^[0-9A-Fa-f]{64}$')]
  [string] $SigningCertificateSha256,
  [string] $SigningPublisher,
  [string] $SmokeRoot = (Join-Path $env:RUNNER_TEMP 'native-runtime-windows-inno'),
  [int] $Port = 43895
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'windows_process_tree_cleanup.ps1')

function Assert-X64Tool([string] $Path, [string] $Name) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "$Name is missing: $Path"
  }
  if ($Name -eq 'signtool.exe' -and
      [IO.Path]::GetFileName([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))) -ne 'x64') {
    throw "Refusing non-x64 SignTool: $Path"
  }
}

Assert-X64Tool $IsccPath 'ISCC.exe'
Assert-X64Tool $SigntoolPath 'signtool.exe'
if ([string]::IsNullOrWhiteSpace($PfxPath) -and
    [string]::IsNullOrWhiteSpace($SigningCertificateSha1)) {
  throw 'Signed Inno runtime smoke requires either a PFX or a CurrentUser certificate thumbprint.'
}
$usePfx = -not [string]::IsNullOrWhiteSpace($PfxPath)
if ($usePfx -and -not [string]::IsNullOrWhiteSpace($SigningCertificateSha1)) {
  throw 'Signed Inno runtime smoke received both PFX and CurrentUser signing identities.'
}
if ($usePfx -and -not (Test-Path -LiteralPath $PfxPath -PathType Leaf)) {
  throw "Signed Inno runtime smoke PFX is missing: $PfxPath"
}
if (-not $usePfx -and
    ([string]::IsNullOrWhiteSpace($SigningCertificateSha256) -or
     [string]::IsNullOrWhiteSpace($SigningPublisher))) {
  throw 'CurrentUser Inno runtime smoke signing requires SHA-1, DER SHA-256, and publisher.'
}

function Get-CertificateSha256(
  [Security.Cryptography.X509Certificates.X509Certificate2] $Certificate
) {
  return [Convert]::ToHexString(
    [Security.Cryptography.SHA256]::HashData($Certificate.RawData)
  ).ToLowerInvariant()
}

function Assert-AuthenticodeIdentity([string] $Path) {
  $signature = Get-AuthenticodeSignature -LiteralPath $Path
  if ($signature.Status -ne [Management.Automation.SignatureStatus]::Valid -or
      $null -eq $signature.SignerCertificate) {
    throw "Inno installer Authenticode verification failed: $($signature.Status)"
  }
  if (-not [string]::IsNullOrWhiteSpace($SigningCertificateSha1) -and
      $signature.SignerCertificate.Thumbprint.ToUpperInvariant() -ne
        $SigningCertificateSha1.ToUpperInvariant()) {
    throw "Inno installer signer SHA-1 does not match: $Path"
  }
  if (-not [string]::IsNullOrWhiteSpace($SigningCertificateSha256) -and
      (Get-CertificateSha256 $signature.SignerCertificate) -ne
        $SigningCertificateSha256.ToLowerInvariant()) {
    throw "Inno installer signer DER SHA-256 does not match: $Path"
  }
  if (-not [string]::IsNullOrWhiteSpace($SigningPublisher) -and
      $signature.SignerCertificate.GetNameInfo(
        [Security.Cryptography.X509Certificates.X509NameType]::SimpleName,
        $false
      ) -ne $SigningPublisher) {
    throw "Inno installer signer publisher does not match: $Path"
  }
  return $signature
}

function Sign-AndVerify([string] $Path) {
  if ($usePfx) {
    & $SigntoolPath sign /fd SHA256 /f $PfxPath /p $PfxPassword $Path
  } else {
    & $SigntoolPath sign /fd SHA256 /sha1 $SigningCertificateSha1 $Path
  }
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  return (Assert-AuthenticodeIdentity $Path)
}
New-Item -ItemType Directory -Path $SmokeRoot -Force | Out-Null
$build = Join-Path $SmokeRoot 'build'
$safeRoot = Join-Path $env:LOCALAPPDATA (
  'desktop-updater-native-inno-{0}' -f [Guid]::NewGuid().ToString('N')
)
$install = Join-Path $safeRoot 'install'
$payload = Join-Path $safeRoot 'payload'
$runtimeRoot = Join-Path $safeRoot 'runtime'
$safeRootCreated = $false
$server = $null
$ready = Join-Path $SmokeRoot 'ready.json'
$cleanupFailures = [Collections.Generic.List[string]]::new()

try {
  if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    throw 'Windows Inno runtime smoke requires the owner LocalAppData root.'
  }
  New-Item -ItemType Directory -Path @($safeRoot, $install, $payload, $runtimeRoot) -Force | Out-Null
  $safeRootCreated = $true
  $repoRoot = Split-Path $PSScriptRoot -Parent
  & (Join-Path $PSScriptRoot 'verify_windows_nuget_consumer.ps1') `
    -PackagePath (Resolve-Path -LiteralPath $PackagePath).Path `
    -PackageSource (Resolve-Path -LiteralPath $PackageSource).Path `
    -ProjectPath (Join-Path $repoRoot 'example/native/windows-dotnet-runtime/DesktopUpdater.RuntimeCompile.csproj') `
    -LaneRoot $SmokeRoot -OutputPath $build -PackageVersion $PackageVersion
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  foreach ($destinationRoot in @($install, $payload)) {
    Get-ChildItem -LiteralPath $build -Force |
      ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $destinationRoot -Recurse -Force
      }
  }
  '2.7.0' | Set-Content (Join-Path $install 'version.txt')
  '2.7.1' | Set-Content (Join-Path $payload 'version.txt')
  $installedIdentity = '{"packageId":"com.example.native-runtime-smoke","schemaVersion":1}'
  foreach ($root in @($install, $payload)) {
    $installedIdentity | Set-Content -LiteralPath (Join-Path $root '.desktop_updater_install_identity.json') -NoNewline -Encoding utf8
    $caller = Join-Path $root 'DesktopUpdater.RuntimeCompile.exe'
    $helper = Join-Path $root 'desktop_updater_install_helper.exe'
    $callerSha256 = (Get-FileHash -LiteralPath $caller -Algorithm SHA256).Hash.ToLowerInvariant()
    $helperSha256 = (Get-FileHash -LiteralPath $helper -Algorithm SHA256).Hash.ToLowerInvariant()
    $portablePolicy = [ordered]@{
      allowedApplicationSigner = [ordered]@{ kind = 'sha256'; value = $callerSha256 }
      allowedHelperSigner = [ordered]@{ kind = 'sha256'; value = $helperSha256 }
      allowedInstallRoots = @()
      allowedStrategies = @([ordered]@{ provider = 'platformDirectory'; strategy = 'directoryReplace' })
      allowedTargetClasses = @('sameUserWritable')
      applicationPackageId = 'com.example.native-runtime-smoke'
      helperServiceId = 'com.example.desktop-updater.helper'
      minimumHelperProtocolVersion = 1
      policyId = 'com.example.desktop-updater.portable'
      policyVersion = 1
      releaseRootPublicKeys = @([ordered]@{
        algorithm = 'ed25519'
        keyId = 'native-runtime-smoke-stable'
        publicKeyBase64 = 'uvxxvq06xeS2PpyCFu5xo0quxlci7tvKcotOmzzM45Y='
      })
    }
    $canonicalPolicy = $portablePolicy | ConvertTo-Json -Compress -Depth 8
    [IO.File]::WriteAllText((Join-Path $root 'desktop_updater_helper_policy.json'), $canonicalPolicy, [Text.UTF8Encoding]::new($false))
  }
  $iss = Join-Path $SmokeRoot 'runtime-smoke.iss'
  @(
    '[Setup]'
    'AppId=NativeRuntimeSmoke'
    'AppName=NativeRuntimeSmoke'
    'AppVersion=2.7.1'
    'DefaultDirName={autopf}\NativeRuntimeSmoke'
    "OutputDir=$SmokeRoot"
    'OutputBaseFilename=native-runtime-smoke'
    'Uninstallable=no'
    'PrivilegesRequired=lowest'
    'ArchitecturesAllowed=x64compatible'
    '[Files]'
    "Source: `"$payload\*`"; DestDir: `"{app}`"; Flags: ignoreversion recursesubdirs createallsubdirs"
  ) | Set-Content -LiteralPath $iss -Encoding UTF8
  & $IsccPath $iss
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  $installer = Join-Path $SmokeRoot 'native-runtime-smoke.exe'
  $signature = Sign-AndVerify $installer
  $publisher = Get-CertificateSha256 $signature.SignerCertificate
  $installedExecutable = Join-Path $payload 'DesktopUpdater.RuntimeCompile.exe'
  $server = Start-Process dart -ArgumentList @(
    'run', 'tool/native_runtime_smoke_server.dart', '--artifact', $installer,
    '--artifact-kind', 'innoInstaller', '--platform', 'windows', '--package-id',
    'com.example.native-runtime-smoke', '--app-name', 'NativeRuntimeSmoke',
    '--publisher-thumbprint', $publisher, '--installed-executable', $installedExecutable,
    '--installed-executable-relative-path', 'DesktopUpdater.RuntimeCompile.exe',
    '--ready-file', $ready, '--port', "$Port"
  ) -PassThru
  for ($attempt = 0; $attempt -lt 60; $attempt++) {
    if (Test-Path -LiteralPath $ready) {
      try { Invoke-WebRequest -UseBasicParsing "http://127.0.0.1:$Port/health" | Out-Null; break } catch {}
    }
    Start-Sleep -Milliseconds 250
  }
  Invoke-WebRequest -UseBasicParsing "http://127.0.0.1:$Port/health" | Out-Null
  $serverInfo = Get-Content -Raw $ready | ConvertFrom-Json
  $env:DESKTOP_UPDATER_SMOKE_SKIP_RELAUNCH = '1'
  $runtime = Join-Path $install 'DesktopUpdater.RuntimeCompile.exe'
  & $runtime --smoke --app-archive-url $serverInfo.appArchiveUrl --public-key-base64 $serverInfo.publicKeyBase64 --package-id 'com.example.native-runtime-smoke' --smoke-root $runtimeRoot --diagnostics-log (Join-Path $runtimeRoot 'helper-diagnostics.jsonl')
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  $versionPath = Join-Path $install 'version.txt'
  for ($attempt = 0; $attempt -lt 240; $attempt++) {
    if ((Test-Path -LiteralPath $versionPath) -and (Get-Content -Raw $versionPath).Trim() -eq '2.7.1') { break }
    Start-Sleep -Milliseconds 250
  }
  if ((Get-Content -Raw $versionPath).Trim() -ne '2.7.1') { throw 'Windows Inno runtime smoke did not install version 2.7.1.' }
  $diagnostics = Get-Content -Raw (Join-Path $SmokeRoot 'helper-diagnostics.jsonl')
  if ($diagnostics -notmatch '"event":"inno authenticode verified"' -or
      $diagnostics -notmatch '"event":"inno installer success"') {
    throw 'Windows Inno runtime smoke diagnostics are incomplete.'
  }
} finally {
  if ($null -ne $server) {
    try {
      if (-not $server.HasExited -and (Test-Path -LiteralPath $ready)) {
        $serverInfo = Get-Content -Raw $ready | ConvertFrom-Json
        Invoke-WebRequest -UseBasicParsing -Method Post `
          "http://127.0.0.1:$Port/shutdown?token=$($serverInfo.shutdownToken)" |
          Out-Null
      }
    } catch {}
    try {
      Stop-ExactProcessTree $server.Id 'native_runtime_smoke_server.dart'
    } catch {
      $cleanupFailures.Add("server cleanup: $($_.Exception.Message)") | Out-Null
    }
  }
  if ($safeRootCreated -and (Test-Path -LiteralPath $safeRoot)) {
    try { Remove-Item -LiteralPath $safeRoot -Recurse -Force -ErrorAction Stop } catch { $cleanupFailures.Add("safe root cleanup: $($_.Exception.Message)") | Out-Null }
  }
  if (Test-Path -LiteralPath $SmokeRoot) {
    try { Remove-Item -LiteralPath $SmokeRoot -Recurse -Force -ErrorAction Stop } catch { $cleanupFailures.Add("root cleanup: $($_.Exception.Message)") | Out-Null }
  }
}
if ($cleanupFailures.Count -ne 0) { throw "Windows Inno runtime smoke cleanup failed: $($cleanupFailures -join '; ')" }
Write-Host 'Windows unprivileged Inno transport smoke passed.'
