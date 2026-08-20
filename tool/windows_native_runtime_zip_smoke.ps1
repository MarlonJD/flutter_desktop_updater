[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string] $PackageVersion,
  [Parameter(Mandatory = $true)]
  [string] $PackagePath,
  [Parameter(Mandatory = $true)]
  [string] $PackageSource,
  [string] $SmokeRoot = (Join-Path $env:RUNNER_TEMP 'native-runtime-windows-zip'),
  [string] $SigningRoot = (Join-Path $env:RUNNER_TEMP 'native-runtime-windows-zip-signing'),
  [string] $SigntoolPath,
  [ValidatePattern('^[0-9A-Fa-f]{40}$')]
  [string] $SigningCertificateSha1,
  [ValidatePattern('^[0-9A-Fa-f]{64}$')]
  [string] $SigningCertificateSha256,
  [string] $SigningPublisher,
  [string] $SigningCertificatePath,
  [int] $Port = 43892
)

$ErrorActionPreference = 'Stop'
$ConfirmPreference = 'None'
. (Join-Path $PSScriptRoot 'windows_smoke_profile_cleanup.ps1')
. (Join-Path $PSScriptRoot 'windows_process_tree_cleanup.ps1')

function Assert-ZipSmokeRoot([string] $Root) {
  $resolved = [IO.Path]::GetFullPath($Root)
  $runnerTemp = [IO.Path]::GetFullPath([string]$env:RUNNER_TEMP)
  $prefix = $runnerTemp.TrimEnd([IO.Path]::DirectorySeparatorChar) +
    [IO.Path]::DirectorySeparatorChar
  if (-not $resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or
      [IO.Path]::GetFileName($resolved) -notmatch '^native-runtime-windows-zip(?:-[0-9a-f]{32})?$') {
    throw "Refusing unexpected Windows ZIP smoke root: $resolved"
  }
  if (Test-Path -LiteralPath $resolved) {
    $item = Get-Item -LiteralPath $resolved -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw "Windows ZIP smoke root is a reparse point: $resolved"
    }
  }
}

function Resolve-X64Signtool([string] $ExplicitPath) {
  $candidates = @(
    $ExplicitPath,
    @(Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\signtool.exe" -ErrorAction SilentlyContinue |
      Sort-Object FullName -Descending | ForEach-Object FullName)
  ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
  foreach ($candidate in $candidates) {
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
    $leaf = [IO.Path]::GetFileName([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($candidate)))
    if ($leaf -ne 'x64') {
      throw "Refusing non-x64 SignTool: $candidate"
    }
    return [IO.Path]::GetFullPath($candidate)
  }
  throw 'x64 signtool.exe was not found for hosted Windows ZIP smoke.'
}

function Get-CertificateSha256(
  [Security.Cryptography.X509Certificates.X509Certificate2] $Certificate
) {
  return [Convert]::ToHexString(
    [Security.Cryptography.SHA256]::HashData($Certificate.RawData)
  ).ToLowerInvariant()
}

function Assert-AuthenticodeIdentity([string] $binary) {
  $signature = Get-AuthenticodeSignature -FilePath $binary
  if ($signature.Status -ne [Management.Automation.SignatureStatus]::Valid -or
      $null -eq $signature.SignerCertificate) {
    throw "Hosted Windows ZIP smoke failed to trust ${binary}: $($signature.Status)"
  }
  if (-not [string]::IsNullOrWhiteSpace($SigningCertificateSha1) -and
      $signature.SignerCertificate.Thumbprint.ToUpperInvariant() -ne
        $SigningCertificateSha1.ToUpperInvariant()) {
    throw "Hosted Windows ZIP smoke signer SHA-1 does not match: $binary"
  }
  if (-not [string]::IsNullOrWhiteSpace($SigningCertificateSha256) -and
      (Get-CertificateSha256 $signature.SignerCertificate) -ne
        $SigningCertificateSha256.ToLowerInvariant()) {
    throw "Hosted Windows ZIP smoke signer DER SHA-256 does not match: $binary"
  }
  if (-not [string]::IsNullOrWhiteSpace($SigningPublisher) -and
      $signature.SignerCertificate.GetNameInfo(
        [Security.Cryptography.X509Certificates.X509NameType]::SimpleName,
        $false
      ) -ne $SigningPublisher) {
    throw "Hosted Windows ZIP smoke signer publisher does not match: $binary"
  }
  return $signature
}

function Sign-AndVerify([string] $binary) {
  if ($usePfx) {
    & $signtool sign /fd SHA256 /f $pfx /p $pfxPassword $binary
  } else {
    & $signtool sign /fd SHA256 /sha1 $SigningCertificateSha1 $binary
  }
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  Assert-AuthenticodeIdentity $binary | Out-Null
}

Assert-ZipSmokeRoot $SmokeRoot
New-Item -ItemType Directory -Path $SmokeRoot -Force | Out-Null
$build = Join-Path $SmokeRoot 'build'
$hostInstall = Join-Path $SmokeRoot 'install'
$hostPayload = Join-Path $SmokeRoot 'payload'
$install = $hostInstall
$payload = $hostPayload
$packageSource = (Resolve-Path -LiteralPath $PackageSource).Path
$package = (Resolve-Path -LiteralPath $PackagePath).Path
$signtool = Resolve-X64Signtool $SigntoolPath
$pfx = Join-Path $SigningRoot 'hosted-smoke.pfx'
$pfxPassword = 'desktop-updater-hosted-smoke-only'
$usePfx = Test-Path -LiteralPath $pfx -PathType Leaf
$hasCurrentUserIdentity = -not [string]::IsNullOrWhiteSpace($SigningCertificateSha1)
if ($usePfx -and $hasCurrentUserIdentity) {
  throw 'Hosted Windows ZIP smoke received both PFX and CurrentUser signing identities.'
}
if (-not $usePfx -and -not $hasCurrentUserIdentity) {
  throw 'Hosted Windows ZIP smoke requires either the CI PFX or a CurrentUser certificate thumbprint.'
}
if ($hasCurrentUserIdentity -and
    ([string]::IsNullOrWhiteSpace($SigningCertificateSha256) -or
     [string]::IsNullOrWhiteSpace($SigningPublisher))) {
  throw 'CurrentUser ZIP smoke signing requires SHA-1, DER SHA-256, and publisher.'
}
$trustCertificateSource = $SigningCertificatePath
$provisionDisposableUserTrust = -not [string]::IsNullOrWhiteSpace($trustCertificateSource)
$trustCertificateSha256 = $SigningCertificateSha256
$trustCertificatePublisher = $SigningPublisher
if ($hasCurrentUserIdentity -and -not $provisionDisposableUserTrust) {
  throw 'CurrentUser ZIP smoke requires a public certificate for disposable-user trust.'
}
if ($provisionDisposableUserTrust) {
  if (-not (Test-Path -LiteralPath $trustCertificateSource -PathType Leaf)) {
    throw "ZIP smoke disposable-user trust certificate is missing: $trustCertificateSource"
  }
  $trustCertificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new(
    (Resolve-Path -LiteralPath $trustCertificateSource).Path
  )
  try {
    if ($trustCertificate.HasPrivateKey) {
      throw 'ZIP smoke disposable-user trust certificate unexpectedly contains a private key.'
    }
    $sourceCertificateSha256 = Get-CertificateSha256 $trustCertificate
    $sourceCertificatePublisher = $trustCertificate.GetNameInfo(
      [Security.Cryptography.X509Certificates.X509NameType]::SimpleName,
      $false
    )
    if ([string]::IsNullOrWhiteSpace($trustCertificateSha256)) {
      $trustCertificateSha256 = $sourceCertificateSha256
    }
    if ([string]::IsNullOrWhiteSpace($trustCertificatePublisher)) {
      $trustCertificatePublisher = $sourceCertificatePublisher
    }
    if ($sourceCertificateSha256 -ne $trustCertificateSha256.ToLowerInvariant() -or
        $sourceCertificatePublisher -ne $trustCertificatePublisher) {
      throw 'ZIP smoke disposable-user trust certificate identity changed.'
    }
  } finally {
    $trustCertificate.Dispose()
  }
}
$server = $null
$smokeUser = $null
$smokeUserCreated = $false
$ready = Join-Path $SmokeRoot 'ready.json'
$cleanupFailures = [Collections.Generic.List[string]]::new()

try {
  & (Join-Path $PSScriptRoot 'verify_windows_nuget_consumer.ps1') `
    -PackagePath $package -PackageSource $packageSource `
    -ProjectPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'example/native/windows-dotnet-runtime/DesktopUpdater.RuntimeCompile.csproj') `
    -LaneRoot $SmokeRoot -OutputPath $build -PackageVersion $PackageVersion
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  Write-Host 'Hosted Windows ZIP smoke runtime consumer is ready.'
  foreach ($binary in @(
      (Join-Path $build 'DesktopUpdater.RuntimeCompile.exe'),
      (Join-Path $build 'desktop_updater_install_helper.exe')
    )) {
    Sign-AndVerify $binary
  }
  Write-Host 'Hosted Windows ZIP smoke signing trust is ready.'
  $smokeTrustCertificate = $null
  if ($provisionDisposableUserTrust) {
    $smokeTrustCertificate = Join-Path $SmokeRoot 'disposable-user-trust.cer'
    $publicTrustCertificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new(
      (Resolve-Path -LiteralPath $trustCertificateSource).Path
    )
    try {
      [IO.File]::WriteAllBytes($smokeTrustCertificate, $publicTrustCertificate.RawData)
    } finally {
      $publicTrustCertificate.Dispose()
    }
  }
  Copy-Item -LiteralPath $build -Destination $install -Recurse
  Copy-Item -LiteralPath $build -Destination $payload -Recurse
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
  $artifact = Join-Path $SmokeRoot 'update.zip'
  Compress-Archive -Path (Join-Path $payload '*') -DestinationPath $artifact
  $serverOut = Join-Path $SmokeRoot 'server.out'
  $serverErr = Join-Path $SmokeRoot 'server.err'
  $server = Start-Process dart -ArgumentList @(
    'run', 'tool/native_runtime_smoke_server.dart', '--artifact', $artifact,
    '--artifact-kind', 'zip', '--platform', 'windows', '--package-id',
    'com.example.native-runtime-smoke', '--app-name', 'NativeRuntimeSmoke',
    '--ready-file', $ready, '--port', "$Port"
  ) -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr -PassThru
  for ($attempt = 0; $attempt -lt 60; $attempt++) {
    if (Test-Path -LiteralPath $ready) {
      try { Invoke-WebRequest -UseBasicParsing "http://127.0.0.1:$Port/health" | Out-Null; break } catch {}
    }
    Start-Sleep -Milliseconds 250
  }
  if (-not (Test-Path -LiteralPath $ready)) {
    Get-Content $serverOut, $serverErr -ErrorAction SilentlyContinue
    throw 'Native runtime ZIP server did not start.'
  }
  Invoke-WebRequest -UseBasicParsing "http://127.0.0.1:$Port/health" | Out-Null
  $serverInfo = Get-Content -Raw $ready | ConvertFrom-Json
  $env:DESKTOP_UPDATER_SMOKE_SKIP_RELAUNCH = '1'
  $helperEventProvider = 'DesktopUpdater.InstallHelper.ProtocolV1'
  $diagnosticsPath = Join-Path $SmokeRoot 'helper-diagnostics.jsonl'
  $smokeUserName = "duzip$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
  $smokePassword = ConvertTo-SecureString "Du!9$([Guid]::NewGuid().ToString('N'))" -AsPlainText -Force
  $smokeUser = New-LocalUser -Name $smokeUserName -Password $smokePassword -AccountNeverExpires -PasswordNeverExpires -UserMayNotChangePassword
  $smokeUserCreated = $true
  $users = Get-LocalGroup -SID 'S-1-5-32-545'
  if (@(Get-LocalGroupMember -Group $users.Name | Where-Object { $_.SID.Value -eq $smokeUser.SID.Value }).Count -eq 0) {
    Add-LocalGroupMember -Group $users.Name -Member $smokeUser
  }
  $administrators = Get-LocalGroup -SID 'S-1-5-32-544'
  if (@(Get-LocalGroupMember -Group $administrators.Name | Where-Object { $_.SID.Value -eq $smokeUser.SID.Value }).Count -ne 0) {
    throw 'Hosted Windows ZIP smoke account unexpectedly has administrator authority.'
  }
  & icacls.exe $SmokeRoot /grant:r "*$($smokeUser.SID.Value):(OI)(CI)F" /T /C | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'Hosted Windows ZIP smoke account could not own its disposable lane.' }
  & icacls.exe $SmokeRoot /grant "*$($smokeUser.SID.Value):F" /C | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'Hosted Windows ZIP smoke account could not read its disposable lane root.' }
  $smokeCredential = [Management.Automation.PSCredential]::new("$env:COMPUTERNAME\$smokeUserName", $smokePassword)
  $profilesDirectory = [Environment]::ExpandEnvironmentVariables((Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -Name ProfilesDirectory).ProfilesDirectory)
  $smokeUserProfile = Join-Path $profilesDirectory $smokeUserName
  $smokeLocalAppData = Join-Path $smokeUserProfile 'AppData\Local'
  $userTemp = Join-Path $smokeLocalAppData 'Temp'
  $userSmokeRoot = Join-Path $smokeLocalAppData ("desktop-updater-native-zip-{0}" -f [Guid]::NewGuid().ToString('N'))
  $userInstall = Join-Path $userSmokeRoot 'install'
  $userPayload = Join-Path $userSmokeRoot 'payload'
  $userRuntimeRoot = Join-Path $userSmokeRoot 'runtime'
  $smokeEnvironment = @{
    APPDATA = Join-Path $smokeUserProfile 'AppData\Roaming'
    DESKTOP_UPDATER_SMOKE_EXPECTED_LOCALAPPDATA = $smokeLocalAppData
    DESKTOP_UPDATER_SMOKE_EXPECTED_SIGNER_SHA256 = $trustCertificateSha256
    DESKTOP_UPDATER_SMOKE_EXPECTED_SIGNER_PUBLISHER = $trustCertificatePublisher
    DESKTOP_UPDATER_SMOKE_PROVISION_USER_TRUST = if ($provisionDisposableUserTrust) { '1' } else { '0' }
    DESKTOP_UPDATER_SMOKE_SIGNED_HELPER = Join-Path $hostInstall 'desktop_updater_install_helper.exe'
    DESKTOP_UPDATER_SMOKE_TRUST_CERTIFICATE = $smokeTrustCertificate
    DESKTOP_UPDATER_SMOKE_USER_ROOT = $userSmokeRoot
    DESKTOP_UPDATER_SMOKE_USER_INSTALL = $userInstall
    DESKTOP_UPDATER_SMOKE_USER_PAYLOAD = $userPayload
    DESKTOP_UPDATER_SMOKE_USER_RUNTIME = $userRuntimeRoot
    DESKTOP_UPDATER_SMOKE_USER_TEMP = $userTemp
    DESKTOP_UPDATER_SMOKE_SKIP_RELAUNCH = '1'
    HOME = $smokeUserProfile
    HOMEDRIVE = Split-Path -Qualifier $smokeUserProfile
    HOMEPATH = $smokeUserProfile.Substring((Split-Path -Qualifier $smokeUserProfile).Length)
    LOCALAPPDATA = $smokeLocalAppData
    TEMP = $userTemp
    TMP = $userTemp
    USERDOMAIN = $env:COMPUTERNAME
    USERNAME = $smokeUserName
    USERPROFILE = $smokeUserProfile
  }
  $helperEventStart = Get-Date
  $runtimeOut = Join-Path $SmokeRoot 'runtime.out'
  $runtimeErr = Join-Path $SmokeRoot 'runtime.err'
  # Keep the generated script in the exact ACL-scoped smoke root. The
  # disposable profile does not exist until -LoadUserProfile creates it.
  $profileProbePath = Join-Path $SmokeRoot 'profile-probe.ps1'
[IO.File]::WriteAllText($profileProbePath, @'
$ErrorActionPreference = 'Stop'
function Get-DesktopUpdaterSha256([byte[]] $RawData) {
  $algorithm = [Security.Cryptography.SHA256]::Create()
  try {
    return ([BitConverter]::ToString($algorithm.ComputeHash($RawData)) -replace '-', '').ToLowerInvariant()
  } finally {
    $algorithm.Dispose()
  }
}
$localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData, [Environment+SpecialFolderOption]::Create)
if ([string]::IsNullOrWhiteSpace($localAppData) -or
    -not [StringComparer]::OrdinalIgnoreCase.Equals([IO.Path]::GetFullPath($localAppData), [IO.Path]::GetFullPath($env:DESKTOP_UPDATER_SMOKE_EXPECTED_LOCALAPPDATA))) {
  throw 'LocalApplicationData resolved outside the standard-user profile.'
}
[IO.Directory]::CreateDirectory($localAppData) | Out-Null
foreach ($path in @(
  $env:DESKTOP_UPDATER_SMOKE_USER_ROOT,
  $env:DESKTOP_UPDATER_SMOKE_USER_INSTALL,
  $env:DESKTOP_UPDATER_SMOKE_USER_PAYLOAD,
  $env:DESKTOP_UPDATER_SMOKE_USER_RUNTIME,
  $env:DESKTOP_UPDATER_SMOKE_USER_TEMP
)) {
  [IO.Directory]::CreateDirectory($path) | Out-Null
}
if ($env:DESKTOP_UPDATER_SMOKE_PROVISION_USER_TRUST -eq '1') {
  $certificatePath = $env:DESKTOP_UPDATER_SMOKE_TRUST_CERTIFICATE
  $expectedCertificateSha256 = $env:DESKTOP_UPDATER_SMOKE_EXPECTED_SIGNER_SHA256
  $expectedPublisher = $env:DESKTOP_UPDATER_SMOKE_EXPECTED_SIGNER_PUBLISHER
  $signedHelper = $env:DESKTOP_UPDATER_SMOKE_SIGNED_HELPER
  $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new($certificatePath)
  try {
    if ($certificate.HasPrivateKey) {
      throw 'ZIP smoke disposable trust certificate unexpectedly contains a private key.'
    }
    $certificateSha256 = Get-DesktopUpdaterSha256 $certificate.RawData
    $publisher = $certificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)
    if ($certificateSha256 -ne $expectedCertificateSha256 -or $publisher -ne $expectedPublisher) {
      throw 'ZIP smoke disposable trust certificate identity changed.'
    }
    foreach ($storeName in @('Root', 'TrustedPublisher')) {
      $certutilOutput = & certutil.exe -user -f -addstore $storeName $certificatePath 2>&1
      if ($LASTEXITCODE -ne 0) {
        throw "certutil failed to add ZIP smoke disposable CurrentUser trust to $storeName`: $certutilOutput"
      }
    }
    $helperSignature = Get-AuthenticodeSignature -LiteralPath $signedHelper
    if ($helperSignature.Status -ne 'Valid' -or $null -eq $helperSignature.SignerCertificate) {
      throw 'ZIP smoke disposable user does not trust the signed helper.'
    }
    $helperCertificateSha256 = Get-DesktopUpdaterSha256 $helperSignature.SignerCertificate.RawData
    $helperPublisher = $helperSignature.SignerCertificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)
    if ($helperCertificateSha256 -ne $expectedCertificateSha256 -or $helperPublisher -ne $expectedPublisher) {
      throw 'ZIP smoke disposable user trusted an unexpected helper signer.'
    }
  } finally {
    $certificate.Dispose()
  }
}
Write-Output 'Hosted Windows ZIP smoke LocalAppData is ready.'
'@, [Text.UTF8Encoding]::new($false))
  # The owner/high driver may be hosted from a private AppData path that the
  # disposable standard user cannot execute. Use a system-owned Windows
  # PowerShell host for both generated standard-user probes.
  $profileProbeShell = Join-Path $env:SystemRoot `
    'System32\WindowsPowerShell\v1.0\powershell.exe'
  if (-not (Test-Path -LiteralPath $profileProbeShell -PathType Leaf)) {
    throw "Windows ZIP smoke profile probe host is missing: $profileProbeShell"
  }
  $profileProbeArguments = @(
    '-NoLogo',
    '-NoProfile',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    $profileProbePath
  )
  $profileProbeParameters = @{
    FilePath = $profileProbeShell
    ArgumentList = $profileProbeArguments
    Credential = $smokeCredential
    LoadUserProfile = $true
    Environment = $smokeEnvironment
    WorkingDirectory = $SmokeRoot
    Wait = $true
    PassThru = $true
  }
  if ($provisionDisposableUserTrust) {
    # The Root import is an explicit manual Windows Security Warning gate.
    # Keep the standard-user PowerShell window visible so the owner can make
    # that decision; never accept it from the harness.
    $profileProbeParameters.WindowStyle = [Diagnostics.ProcessWindowStyle]::Normal
  } else {
    $profileProbeParameters.ArgumentList = @(
      '-NoLogo',
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      $profileProbePath
    )
  }
  $profileProbe = Start-Process @profileProbeParameters
  if ($profileProbe.ExitCode -ne 0) { throw 'Hosted Windows ZIP smoke could not initialize LocalAppData for the standard user.' }
  Write-Host 'Hosted Windows ZIP smoke LocalAppData is ready.'
  $install = $userInstall
  $payload = $userPayload
  $runtimeRoot = $userRuntimeRoot
  foreach ($sourceRoot in @($hostInstall, $hostPayload)) {
    $destinationRoot = if ($sourceRoot -eq $hostInstall) { $install } else { $payload }
    Get-ChildItem -LiteralPath $sourceRoot -Force |
      ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $destinationRoot -Recurse -Force
      }
  }
  $diagnosticsPath = Join-Path $userSmokeRoot 'helper-diagnostics.jsonl'
  $originalTemp = $env:TEMP; $originalTmp = $env:TMP
  try {
    $env:TEMP = $userTemp; $env:TMP = $userTemp
    $runtimeProcess = Start-Process -FilePath (Join-Path $install 'DesktopUpdater.RuntimeCompile.exe') -ArgumentList @(
      '--smoke', '--app-archive-url', $serverInfo.appArchiveUrl, '--public-key-base64', $serverInfo.publicKeyBase64,
      '--package-id', 'com.example.native-runtime-smoke', '--smoke-root', $runtimeRoot, '--diagnostics-log', $diagnosticsPath
    ) -Credential $smokeCredential -LoadUserProfile -Environment $smokeEnvironment -WorkingDirectory $install -RedirectStandardOutput $runtimeOut -RedirectStandardError $runtimeErr -Wait -PassThru
  } finally { $env:TEMP = $originalTemp; $env:TMP = $originalTmp }
  Get-Content $runtimeOut, $runtimeErr -ErrorAction SilentlyContinue
  if ($runtimeProcess.ExitCode -ne 0) { throw "Hosted Windows ZIP smoke standard-user runtime exited with code $($runtimeProcess.ExitCode)." }
  $stagingRoot = Join-Path $runtimeRoot 'staging'
  $postSmokeStatePath = Join-Path $userSmokeRoot 'post-smoke-state.json'
  $postSmokePath = Join-Path $userSmokeRoot 'post-smoke-verify.ps1'
  # Portable restage deliberately protects the replacement tree for SYSTEM
  # and the standard-user caller only. Keep filesystem assertions under that
  # same caller identity; the runner must inspect protocol evidence separately.
  $smokeEnvironment.DESKTOP_UPDATER_SMOKE_INSTALL = $install
  $smokeEnvironment.DESKTOP_UPDATER_SMOKE_STAGING = $stagingRoot
  $smokeEnvironment.DESKTOP_UPDATER_SMOKE_VERIFY_OUT = $postSmokeStatePath
  [IO.File]::WriteAllText($postSmokePath, @'
$ErrorActionPreference = 'Stop'
$versionFile = Join-Path $env:DESKTOP_UPDATER_SMOKE_INSTALL 'version.txt'
$stagingRoot = $env:DESKTOP_UPDATER_SMOKE_STAGING
$versionReady = $false; $stagingClean = $false
for ($attempt = 0; $attempt -lt 600; $attempt++) {
  $versionReady = (Test-Path -LiteralPath $versionFile) -and ((Get-Content -Raw $versionFile).Trim() -eq '2.7.1')
  $stagingClean = (Test-Path -LiteralPath $stagingRoot -PathType Container) -and (@(Get-ChildItem -LiteralPath $stagingRoot -Force).Count -eq 0)
  if ($versionReady -and $stagingClean) { break }
  Start-Sleep -Milliseconds 250
}
[ordered]@{ versionReady = $versionReady; stagingClean = $stagingClean } | ConvertTo-Json -Compress | Set-Content -LiteralPath $env:DESKTOP_UPDATER_SMOKE_VERIFY_OUT -Encoding utf8
if (-not $versionReady) { throw 'Standard-user ZIP smoke did not observe version 2.7.1.' }
if (-not $stagingClean) { throw 'Standard-user ZIP smoke observed an owned staging child.' }
'@, [Text.UTF8Encoding]::new($false))
  $postSmoke = Start-Process -FilePath $profileProbeShell -ArgumentList @(
    '-NoLogo',
    '-NoProfile',
    '-NonInteractive',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    $postSmokePath
  ) -Credential $smokeCredential -LoadUserProfile -Environment $smokeEnvironment -WorkingDirectory $userSmokeRoot -Wait -PassThru
  if ($postSmoke.ExitCode -ne 0) { throw "Hosted Windows ZIP smoke standard-user filesystem verification exited with code $($postSmoke.ExitCode)." }
  $postState = Get-Content -Raw -LiteralPath $postSmokeStatePath | ConvertFrom-Json
  $versionReady = [bool]$postState.versionReady
  $stagingClean = [bool]$postState.stagingClean
  $moveComplete = $false; $cleanupComplete = $false
  for ($attempt = 0; $attempt -lt 600; $attempt++) {
    $helperEvents = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; StartTime = $helperEventStart } -ErrorAction SilentlyContinue | Where-Object { $_.ProviderName -eq $helperEventProvider })
    $moveComplete = @($helperEvents | Where-Object { $_.Id -eq 1008 }).Count -gt 0
    $cleanupComplete = @($helperEvents | Where-Object { $_.Id -eq 1014 }).Count -gt 0
    if ($versionReady -and $stagingClean -and $moveComplete -and $cleanupComplete) { break }
    Start-Sleep -Milliseconds 250
  }
  if (-not $versionReady -or -not $stagingClean -or -not $moveComplete -or -not $cleanupComplete) {
    throw 'Windows ZIP runtime smoke helper/version/staging evidence is incomplete.'
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
  if ($smokeUserCreated) {
    try { Remove-WindowsSmokeUserProfile -Sid $smokeUser.SID.Value -ExpectedPath $smokeUserProfile } catch { $cleanupFailures.Add("profile cleanup: $($_.Exception.Message)") | Out-Null }
    try { Remove-LocalUser -Name $smokeUser.Name -ErrorAction Stop } catch { $cleanupFailures.Add("account cleanup: $($_.Exception.Message)") | Out-Null }
  }
  if (Test-Path -LiteralPath $SmokeRoot) {
    try { Remove-Item -LiteralPath $SmokeRoot -Recurse -Force -ErrorAction Stop } catch { $cleanupFailures.Add("root cleanup: $($_.Exception.Message)") | Out-Null }
  }
}
if ($cleanupFailures.Count -ne 0) { throw "Windows ZIP smoke cleanup failed: $($cleanupFailures -join '; ')" }
Write-Host 'Hosted Windows ZIP runtime smoke passed.'
