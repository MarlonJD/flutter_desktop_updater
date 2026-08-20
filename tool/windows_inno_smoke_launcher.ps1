[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string] $IsccPath,
  [Parameter(Mandatory)]
  [string] $SigntoolPath,
  [Parameter(Mandatory)]
  [ValidatePattern('^[0-9A-Fa-f]{40}$')]
  [string] $SigningCertificateSha1,
  [Parameter(Mandatory)]
  [ValidatePattern('^[0-9A-Fa-f]{64}$')]
  [string] $SigningCertificateSha256,
  [Parameter(Mandatory)]
  [string] $SigningPublisher,
  [Parameter(Mandatory)]
  [ValidateSet('x64', 'arm64')]
  [string] $Architecture,
  [Parameter(Mandatory)]
  [string] $EvidenceRootPath,
  [Parameter(Mandatory)]
  [string] $PackageIdPrefix,
  [Parameter(Mandatory)]
  [string] $AppIdPrefix,
  [Parameter(Mandatory)]
  [string] $InstallerPublisher,
  [Parameter(Mandatory)]
  [string] $InstallRootPrefix,
  [ValidatePattern('^[0-9A-Fa-f]{32}$')]
  [string] $ReplayRunToken,
  [switch] $KeepArtifacts
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$pwsh = Get-Command pwsh.exe -CommandType Application -ErrorAction Stop
$smokeScript = (Resolve-Path -LiteralPath (
  Join-Path $PSScriptRoot 'windows_inno_smoke.ps1'
)).Path
$arguments = @(
  '-NoLogo',
  '-NoProfile',
  '-NonInteractive',
  '-ExecutionPolicy', 'Bypass',
  '-File', ('"' + $smokeScript + '"'),
  '-IsccPath', ('"' + $IsccPath + '"'),
  '-SigntoolPath', ('"' + $SigntoolPath + '"'),
  '-SigningCertificateSha1', $SigningCertificateSha1,
  '-SigningCertificateSha256', $SigningCertificateSha256,
  '-SigningPublisher', ('"' + $SigningPublisher + '"'),
  '-Architecture', $Architecture,
  '-EvidenceRootPath', ('"' + $EvidenceRootPath + '"'),
  '-PackageIdPrefix', $PackageIdPrefix,
  '-AppIdPrefix', $AppIdPrefix,
  '-InstallerPublisher', ('"' + $InstallerPublisher + '"'),
  '-InstallRootPrefix', $InstallRootPrefix
)
if (-not [string]::IsNullOrWhiteSpace($ReplayRunToken)) {
  $arguments += @('-ReplayRunToken', $ReplayRunToken)
}
if ($KeepArtifacts) {
  $arguments += '-KeepArtifacts'
}

$process = Start-Process -FilePath $pwsh.Source -ArgumentList $arguments `
  -Verb RunAs -Wait -PassThru
$process.Refresh()
exit $process.ExitCode
