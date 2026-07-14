param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("Unprivileged", "Elevated")]
  [string]$Mode,
  [string]$BuildDirectory = "windows/native/build"
)

$ErrorActionPreference = "Stop"
$build = (Resolve-Path -LiteralPath $BuildDirectory).Path
$helper = Join-Path $build "Release/desktop_updater_install_helper.exe"
if (-not (Test-Path -LiteralPath $helper -PathType Leaf)) {
  throw "desktop_updater_install_helper.exe is missing from the Release build."
}

if ($Mode -eq "Unprivileged") {
  & $helper --version
  if ($LASTEXITCODE -ne 0) {
    throw "The fixed helper executable failed its version probe."
  }
  $output = & ctest --test-dir $build -C Release -R "(WindowsHelperAuth|WindowsFileTransaction|WindowsCrashRecovery)" --output-on-failure --no-tests=error 2>&1
  $exitCode = $LASTEXITCODE
  $output | ForEach-Object { Write-Host $_ }
  if ($exitCode -ne 0) { exit $exitCode }
  if (($output -join "`n") -match "No tests were found") {
    throw "Windows helper smoke registered zero trust/recovery tests."
  }
  exit 0
}

$signature = Get-AuthenticodeSignature -LiteralPath $helper
if ($signature.Status -ne "Valid") {
  throw "Elevated smoke requires a valid Authenticode-signed fixed helper."
}
if ($env:DESKTOP_UPDATER_ALLOW_INTERACTIVE_UAC_SMOKE -ne "1") {
  throw "Set DESKTOP_UPDATER_ALLOW_INTERACTIVE_UAC_SMOKE=1 on an interactive Windows host."
}

$process = Start-Process -FilePath $helper -ArgumentList "--version" -Verb RunAs -Wait -PassThru
if ($process.ExitCode -ne 0) {
  throw "Signed elevated helper probe failed with exit code $($process.ExitCode)."
}
