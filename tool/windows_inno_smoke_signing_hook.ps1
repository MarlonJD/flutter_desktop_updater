[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RequiredEnvironment([string] $Name) {
  $value = [Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrWhiteSpace($value)) {
    throw "$Name is required by the Windows Inno smoke signing hook."
  }
  return $value.Trim()
}

function Get-CertificateSha256(
  [Security.Cryptography.X509Certificates.X509Certificate2] $Certificate
) {
  $digest = [Security.Cryptography.SHA256]::HashData($Certificate.RawData)
  return [Convert]::ToHexString($digest).ToLowerInvariant()
}

function Assert-SignedBySmokeCertificate(
  [string] $Path,
  [string] $ExpectedSha1,
  [string] $ExpectedSha256,
  [string] $ExpectedPublisher
) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "Windows Inno smoke signing input is missing: $Path"
  }
  $signature = Get-AuthenticodeSignature -FilePath $Path
  if ($signature.Status -ne [Management.Automation.SignatureStatus]::Valid -or
      $null -eq $signature.SignerCertificate) {
    throw "Windows Inno smoke signature is not trusted: ${Path}: $($signature.Status)"
  }
  $certificate = $signature.SignerCertificate
  if ($certificate.Thumbprint -ne $ExpectedSha1 -or
      (Get-CertificateSha256 $certificate) -ne $ExpectedSha256 -or
      $certificate.GetNameInfo(
        [Security.Cryptography.X509Certificates.X509NameType]::SimpleName,
        $false
      ) -ne $ExpectedPublisher) {
    throw "Windows Inno smoke signer identity changed: $Path"
  }
}

function Invoke-SmokeSign(
  [string] $Path,
  [string] $Signtool,
  [string] $ExpectedSha1,
  [string] $ExpectedSha256,
  [string] $ExpectedPublisher
) {
  & $Signtool sign /fd SHA256 /s My /sha1 $ExpectedSha1 $Path | Out-Host
  if ($LASTEXITCODE -ne 0) {
    throw "signtool failed for $Path with exit code $LASTEXITCODE."
  }
  Assert-SignedBySmokeCertificate `
    $Path $ExpectedSha1 $ExpectedSha256 $ExpectedPublisher
}

if ($env:OS -ne 'Windows_NT') {
  throw 'Windows Inno smoke signing requires Windows.'
}
if ($PSVersionTable.PSVersion.Major -lt 7) {
  throw 'Windows Inno smoke signing requires PowerShell 7 or newer.'
}

$phase = Get-RequiredEnvironment 'DESKTOP_UPDATER_HOOK_PHASE'
$platform = Get-RequiredEnvironment 'DESKTOP_UPDATER_PLATFORM'
if ($platform -ne 'windows') {
  throw "Windows Inno smoke signing rejected platform $platform."
}

$signtool = [IO.Path]::GetFullPath(
  (Get-RequiredEnvironment 'DESKTOP_UPDATER_SMOKE_SIGNTOOL_PATH')
)
$certificateSha1 = (
  Get-RequiredEnvironment 'DESKTOP_UPDATER_SMOKE_SIGNING_CERTIFICATE_SHA1'
).ToUpperInvariant()
$certificateSha256 = (
  Get-RequiredEnvironment 'DESKTOP_UPDATER_SMOKE_SIGNING_CERTIFICATE_SHA256'
).ToLowerInvariant()
$publisher = Get-RequiredEnvironment 'DESKTOP_UPDATER_SMOKE_SIGNING_PUBLISHER'
if ($certificateSha1 -notmatch '^[0-9A-F]{40}$' -or
    $certificateSha256 -notmatch '^[0-9a-f]{64}$') {
  throw 'Windows Inno smoke certificate fingerprints are invalid.'
}
if (-not (Test-Path -LiteralPath $signtool -PathType Leaf)) {
  throw "signtool.exe is missing: $signtool"
}

if ($phase -eq 'postPackage') {
  $artifact = [IO.Path]::GetFullPath(
    (Get-RequiredEnvironment 'DESKTOP_UPDATER_ARTIFACT_FILE')
  )
  Invoke-SmokeSign `
    $artifact $signtool $certificateSha1 $certificateSha256 $publisher
  Write-Host "Signed protected Windows Inno smoke artifact: $artifact"
  exit 0
}
if ($phase -ne 'prePackage') {
  throw "Unsupported Windows Inno smoke hook phase: $phase"
}

$projectRoot = [IO.Path]::GetFullPath(
  (Get-RequiredEnvironment 'DESKTOP_UPDATER_PROJECT_ROOT')
)
$repositoryRoot = [IO.Path]::GetFullPath((Split-Path $projectRoot -Parent))
$appRoot = [IO.Path]::GetFullPath(
  (Get-RequiredEnvironment 'DESKTOP_UPDATER_APP_PATH')
)
$packageId = Get-RequiredEnvironment 'DESKTOP_UPDATER_PACKAGE_ID'
$releaseKeyId = Get-RequiredEnvironment 'DESKTOP_UPDATER_SMOKE_RELEASE_KEY_ID'
$releasePublicKey = `
  Get-RequiredEnvironment 'DESKTOP_UPDATER_SMOKE_RELEASE_PUBLIC_KEY'
$installRoot = [IO.Path]::GetFullPath(
  (Get-RequiredEnvironment 'DESKTOP_UPDATER_SMOKE_INSTALL_ROOT')
)
$protectedHelperInstallDir = [IO.Path]::GetFullPath(
  (Get-RequiredEnvironment 'DESKTOP_UPDATER_PROTECTED_HELPER_INSTALL_DIR')
)
$applicationExecutable = `
  Get-RequiredEnvironment 'DESKTOP_UPDATER_SMOKE_APPLICATION_EXECUTABLE'
if ([IO.Path]::GetFileName($applicationExecutable) -ne $applicationExecutable -or
    [IO.Path]::GetExtension($applicationExecutable) -ne '.exe') {
  throw 'DESKTOP_UPDATER_SMOKE_APPLICATION_EXECUTABLE must be an exe leaf.'
}

$applicationPath = Join-Path $appRoot $applicationExecutable
$helperPath = Join-Path $appRoot 'desktop_updater_install_helper.exe'
Invoke-SmokeSign `
  $applicationPath $signtool $certificateSha1 $certificateSha256 $publisher
Invoke-SmokeSign `
  $helperPath $signtool $certificateSha1 $certificateSha256 $publisher

$helperSha256 = (
  Get-FileHash -LiteralPath $helperPath -Algorithm SHA256
).Hash.ToLowerInvariant()
$policyId = Get-RequiredEnvironment 'DESKTOP_UPDATER_SMOKE_POLICY_ID'
$helperServiceId = `
  Get-RequiredEnvironment 'DESKTOP_UPDATER_SMOKE_HELPER_SERVICE_ID'
$policy = [ordered]@{
  policyVersion = 1
  policyId = $policyId
  applicationPackageId = $packageId
  helperServiceId = $helperServiceId
  allowedApplicationSigner = [ordered]@{
    kind = 'authenticodePublisher'
    value = $publisher
  }
  allowedHelperSigner = [ordered]@{
    kind = 'authenticodePublisher'
    value = $publisher
  }
  allowedTargetClasses = @('applicationDirectory')
  allowedInstallRoots = @($installRoot, $protectedHelperInstallDir)
  releaseRootPublicKeys = @(
    [ordered]@{
      keyId = $releaseKeyId
      algorithm = 'ed25519'
      publicKeyBase64 = $releasePublicKey
    }
  )
  allowedStrategies = @(
    [ordered]@{
      strategy = 'verifiedInstallerHandoff'
      provider = 'windowsInno'
    }
  )
  minimumHelperProtocolVersion = 1
}

$hookTempRoot = Join-Path (
  Get-RequiredEnvironment 'DESKTOP_UPDATER_SMOKE_HOOK_TEMP_ROOT'
) ('policy-' + [Guid]::NewGuid().ToString('N'))
$policySource = Join-Path $hookTempRoot 'policy.source.json'
$policyDigest = Join-Path $hookTempRoot 'policy.sha256'
$policyOutput = Join-Path $appRoot 'desktop_updater_helper_policy.json'
New-Item -ItemType Directory -Path $hookTempRoot | Out-Null
try {
  [IO.File]::WriteAllText(
    $policySource,
    ($policy | ConvertTo-Json -Depth 8),
    [Text.UTF8Encoding]::new($false)
  )
  Push-Location $repositoryRoot
  try {
    $generatorArguments = @(
      'run'
      'tool/generate_native_install_helper_policy.dart'
      '--config'
      $policySource
      '--output'
      $policyOutput
      '--digest-output'
      $policyDigest
      '--expected-package-id'
      $packageId
    )
    & dart @generatorArguments | Out-Host
    if ($LASTEXITCODE -ne 0) {
      throw "Helper policy generator failed with exit code $LASTEXITCODE."
    }
  } finally {
    Pop-Location
  }
  if (-not (Test-Path -LiteralPath $policyOutput -PathType Leaf) -or
      -not (Test-Path -LiteralPath $policyDigest -PathType Leaf)) {
    throw 'Windows Inno smoke helper policy output is incomplete.'
  }
  $canonicalDigest = (Get-Content -Raw -LiteralPath $policyDigest).Trim()
  $policyBytes = [IO.File]::ReadAllBytes($policyOutput)
  if ($policyBytes.Length -lt 2 -or
      $policyBytes[$policyBytes.Length - 1] -ne 0x0A) {
    throw 'Windows Inno smoke helper policy is missing its canonical LF terminator.'
  }
  $canonicalPolicyBytes = [byte[]]::new($policyBytes.Length - 1)
  [Buffer]::BlockCopy(
    $policyBytes,
    0,
    $canonicalPolicyBytes,
    0,
    $canonicalPolicyBytes.Length
  )
  $actualDigest = [Convert]::ToHexString(
    [Security.Cryptography.SHA256]::HashData($canonicalPolicyBytes)
  ).ToLowerInvariant()
  if ($canonicalDigest -ne $actualDigest) {
    throw 'Windows Inno smoke helper canonical policy bytes changed after generation.'
  }
} finally {
  if (Test-Path -LiteralPath $hookTempRoot -PathType Container) {
    Remove-Item -LiteralPath $hookTempRoot -Recurse -Force
  }
}

Write-Host "Signed protected Windows app/helper and sealed policy for $packageId."
Write-Host "Protected helper generation: $protectedHelperInstallDir"
