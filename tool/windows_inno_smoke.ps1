param([string]$DiagnosticsPath)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($env:OS -ne 'Windows_NT') {
  throw 'The Inno installation regression requires Windows.'
}
if ($PSVersionTable.PSEdition -ne 'Desktop') {
  throw 'Run this fixture with Windows PowerShell (powershell.exe).'
}
$compiler = (Get-Command iscc -ErrorAction Stop).Source
$fixtureCompiler = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'csc.exe'
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$pluginSource = [IO.File]::ReadAllText((Join-Path $repository 'windows\desktop_updater_plugin.cpp'))
if ([string]::IsNullOrWhiteSpace($DiagnosticsPath)) {
  $DiagnosticsPath = Join-Path $repository 'reports\windows-inno-update-smoke-diagnostics.jsonl'
}
$DiagnosticsPath = [IO.Path]::GetFullPath($DiagnosticsPath)
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($DiagnosticsPath)) | Out-Null
[IO.File]::WriteAllText($DiagnosticsPath, '')

function Assert-That([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
}

function Wait-Until([string]$Description, [scriptblock]$Condition, [int]$Seconds = 20) {
  $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
  while (-not (& $Condition)) {
    if ([DateTime]::UtcNow -ge $deadline) { throw "Timed out waiting for $Description." }
    Start-Sleep -Milliseconds 100
  }
}

# Decode the production C++ string literals, including its real wait, cleanup,
# Authenticode, argument forwarding, exit-code handling, and relaunch code.
function Get-GeneratedBlock([string]$FirstMarker, [string]$NextMarker) {
  $first = $pluginSource.IndexOf($FirstMarker, [StringComparison]::Ordinal)
  Assert-That ($first -ge 0) "Missing generated script marker: $FirstMarker"
  $next = $pluginSource.IndexOf($NextMarker, $first, [StringComparison]::Ordinal)
  Assert-That ($next -gt $first) "Missing generated script end: $NextMarker"
  $start = $pluginSource.LastIndexOf("`n", $first) + 1
  $end = $pluginSource.LastIndexOf("`n", $next)
  $block = $pluginSource.Substring($start, $end - $start)
  $literals = [regex]::Matches($block, '(?m)^\s*<< ("(?:[^"\\]|\\.)*")\r?$')
  Assert-That ($literals.Count -gt 0) 'No generated PowerShell literals found.'
  return (($literals | ForEach-Object { $_.Groups[1].Value | ConvertFrom-Json }) -join '')
}

$fixtureId = [Guid]::NewGuid().ToString('N')
$root = Join-Path ([IO.Path]::GetTempPath()) "desktop_updater_inno_smoke $fixtureId"
$target = Join-Path $root ('Installed App ' + [char]0x5e94 + [char]0x7528)
$unrelated = Join-Path $root 'Unrelated App'
$payload = Join-Path $root 'New Payload'
$stage = Join-Path $root 'Staged Installer'
$setupOutput = Join-Path $root 'Setup Output'
$installerLogName = "desktop_updater_inno_smoke_$fixtureId.log"
$installerLog = Join-Path ([IO.Path]::GetTempPath()) $installerLogName
$ownedProcesses = New-Object 'System.Collections.Generic.List[System.Diagnostics.Process]'
$oldEnvironment = @{}
$utf8 = New-Object Text.UTF8Encoding($true)
$cleanupErrors = New-Object 'System.Collections.Generic.List[string]'

function Start-OwnedProcess([string]$Executable, [string[]]$Arguments) {
  $quoted = @($Arguments | ForEach-Object { '"' + $_ + '"' })
  $process = Start-Process -FilePath $Executable -ArgumentList $quoted -PassThru
  $null = $process.Handle
  $ownedProcesses.Add($process)
  return $process
}

function Set-FixtureEnvironment([string]$Name, [string]$Value) {
  $oldEnvironment[$Name] = [Environment]::GetEnvironmentVariable($Name, 'Process')
  [Environment]::SetEnvironmentVariable($Name, $Value, 'Process')
}

try {
  foreach ($directory in @($target, $unrelated, $payload, $stage, $setupOutput)) {
    [IO.Directory]::CreateDirectory($directory) | Out-Null
  }
  $oldExecutable = Join-Path $target 'flutter_client.exe'
  $newExecutable = Join-Path $payload 'flutter_client.exe'
  $otherExecutable = Join-Path $unrelated 'flutter_client.exe'
  # Compile out of process so the test harness never loads or locks the EXE.
  & $fixtureCompiler '/nologo' '/target:winexe' "/out:$oldExecutable" `
    '/reference:System.Windows.Forms.dll' '/reference:System.Drawing.dll' `
    (Join-Path $repository 'test\fixtures\windows_inno\locking_app.cs')
  Assert-That ($LASTEXITCODE -eq 0) 'Locking application compilation failed.'
  & $fixtureCompiler '/nologo' '/target:winexe' "/out:$newExecutable" `
    (Join-Path $repository 'test\fixtures\windows_inno\updated_app.cs')
  Assert-That ($LASTEXITCODE -eq 0) 'Updated application compilation failed.'
  Copy-Item -LiteralPath $oldExecutable -Destination $otherExecutable
  $oldHash = (Get-FileHash -LiteralPath $oldExecutable -Algorithm SHA256).Hash
  $newHash = (Get-FileHash -LiteralPath $newExecutable -Algorithm SHA256).Hash
  Assert-That ($oldHash -ne $newHash) 'Fixture executables must differ.'

  $installerScript = Join-Path $root 'fixture.iss'
  [IO.File]::WriteAllText($installerScript, @"
[Setup]
AppId=desktop_updater_inno_smoke_$fixtureId
AppName=desktop_updater Inno regression
AppVersion=2.0.0
DefaultDirName=$target
OutputDir=$setupOutput
OutputBaseFilename=fixture-setup
PrivilegesRequired=lowest
Uninstallable=no
UsePreviousAppDir=no
DisableStartupPrompt=yes
DisableDirPage=yes
DisableProgramGroupPage=yes
CloseApplications=yes
RestartApplications=no
[Files]
Source: "$newExecutable"; DestDir: "{app}"; Flags: ignoreversion
"@, $utf8)
  & $compiler '/Q' $installerScript
  Assert-That ($LASTEXITCODE -eq 0) 'Inno fixture compilation failed.'
  $installer = Join-Path $setupOutput 'fixture-setup.exe'

  $blockingReady = Join-Path $root 'blocking.ready'
  $otherReady = Join-Path $root 'unrelated.ready'
  $blockingProcess = Start-OwnedProcess $oldExecutable @('--locker', $blockingReady)
  $unrelatedProcess = Start-OwnedProcess $otherExecutable @('--locker', $otherReady)
  Wait-Until 'both locking processes' {
    (Test-Path -LiteralPath $blockingReady) -and (Test-Path -LiteralPath $otherReady)
  }
  Wait-Until 'visible application windows' {
    $blockingProcess.Refresh()
    $unrelatedProcess.Refresh()
    $blockingProcess.MainWindowHandle -ne [IntPtr]::Zero -and
      $unrelatedProcess.MainWindowHandle -ne [IntPtr]::Zero
  }

  # Prove the original failure against the same real installer and locked EXE.
  $baselineLog = "$DiagnosticsPath.baseline.log"
  $baseline = Start-OwnedProcess $installer @(
    '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/LOGCLOSEAPPLICATIONS',
    "/DIR=$target", "/LOG=$baselineLog"
  )
  Assert-That ($baseline.WaitForExit(60000)) 'Baseline installer did not exit.'
  Assert-That ($baseline.ExitCode -ne 0) 'Ordinary closure unexpectedly updated the locked fixture.'
  Assert-That ((Get-FileHash -LiteralPath $oldExecutable -Algorithm SHA256).Hash -eq $oldHash) `
    'The failed baseline changed the installed executable.'
  Assert-That (-not $blockingProcess.HasExited) 'Baseline unexpectedly terminated the blocking instance.'
  Assert-That ([IO.File]::ReadAllText($baselineLog).Contains('Some applications could not be shut down')) `
    'The baseline did not reproduce the reported application shutdown failure.'
  Write-Host "Verified baseline: ordinary closure failed with exit code $($baseline.ExitCode)."

  $callerReady = Join-Path $root 'caller.ready'
  $callerExit = Join-Path $root 'caller.exit'
  $callerProcess = Start-OwnedProcess $oldExecutable @('--caller', $callerReady, $callerExit)
  Wait-Until 'initiating process' { Test-Path -LiteralPath $callerReady }
  Copy-Item -LiteralPath $installer -Destination (Join-Path $stage 'installer.exe')
  $descriptor = @{
    install = @{
      strategy = 'innoInstaller'
      inno = @{
        silentArgs = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/LOGCLOSEAPPLICATIONS')
        inheritInstallDirectory = $true
        relaunchAfterInstall = $true
        logFileName = $installerLogName
        authenticode = @{ required = $false }
      }
    }
  }
  [IO.File]::WriteAllText((Join-Path $stage '.desktop_updater_release_manifest.json'),
    ($descriptor | ConvertTo-Json -Depth 8), $utf8)
  $proof = Join-Path $root 'relaunch.proof'
  Set-FixtureEnvironment 'DESKTOP_UPDATER_INNO_SMOKE_PROOF' $proof
  Set-FixtureEnvironment 'DESKTOP_UPDATER_INNO_SMOKE_CALLER' ([string]$callerProcess.Id)
  Set-FixtureEnvironment 'DESKTOP_UPDATER_INNO_SMOKE_STAGE' $stage
  Set-FixtureEnvironment 'DESKTOP_UPDATER_INNO_SMOKE_TARGET' $target
  Set-FixtureEnvironment 'DESKTOP_UPDATER_INNO_SMOKE_DIAGNOSTICS' $DiagnosticsPath

  $helper = Join-Path $root 'generated helper.ps1'
  $helperSource = @'
$ErrorActionPreference = 'Stop'
$scriptSelf = $PSCommandPath
$pidToWait = [int]$env:DESKTOP_UPDATER_INNO_SMOKE_CALLER
$staging = $env:DESKTOP_UPDATER_INNO_SMOKE_STAGE
$target = $env:DESKTOP_UPDATER_INNO_SMOKE_TARGET
$exe = Join-Path $target 'flutter_client.exe'
$diagnosticsLog = $env:DESKTOP_UPDATER_INNO_SMOKE_DIAGNOSTICS
$skipRelaunch = ''

'@
  $helperSource += Get-GeneratedBlock 'function Write-DiagnosticsEvent' `
    'if (-not [string]::IsNullOrWhiteSpace($elevationReason))'
  $helperSource += Get-GeneratedBlock "Write-DiagnosticsEvent 'helper scheduled'" `
    'function Get-NormalizedDirectory'
  $helperSource += Get-GeneratedBlock 'function Remove-StagingDirectoryWithRetry' `
    'if (-not [string]::IsNullOrWhiteSpace($staging))'
  $helperSource += @'
$descriptor = Get-Content -LiteralPath (Join-Path $staging '.desktop_updater_release_manifest.json') -Raw | ConvertFrom-Json
Invoke-InnoInstallerUpdate $descriptor
'@
  [IO.File]::WriteAllText($helper, $helperSource, $utf8)
  $helperProcess = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
    '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $helper + '"')
  ) -PassThru -RedirectStandardOutput "$DiagnosticsPath.helper.stdout.log" `
    -RedirectStandardError "$DiagnosticsPath.helper.stderr.log"
  $null = $helperProcess.Handle
  $ownedProcesses.Add($helperProcess)
  Wait-Until 'helper waiting for the initiating process' {
    [IO.File]::ReadAllText($DiagnosticsPath).Contains('waiting for parent process')
  }
  Assert-That (-not $callerProcess.HasExited) 'The initiating process exited before the wait was checked.'
  Assert-That (-not [IO.File]::ReadAllText($DiagnosticsPath).Contains('inno installer start')) `
    'The installer started before its initiating process exited.'
  [IO.File]::WriteAllText($callerExit, 'exit normally')
  Assert-That ($callerProcess.WaitForExit(10000)) 'The initiating process did not exit.'
  Assert-That ($helperProcess.WaitForExit(90000)) 'The real Inno update did not finish.'
  Assert-That ($helperProcess.ExitCode -eq 0) `
    "The generated helper failed; inspect $DiagnosticsPath.helper.stderr.log and the installer log."
  Wait-Until 'updated application relaunch' { Test-Path -LiteralPath $proof }
  Assert-That ([IO.File]::ReadAllText($proof) -eq 'updated application relaunched') 'Unexpected relaunch proof.'
  Assert-That ((Get-FileHash -LiteralPath $oldExecutable -Algorithm SHA256).Hash -eq $newHash) `
    'The installed executable does not match the new payload.'
  Assert-That ($blockingProcess.WaitForExit(10000)) 'The blocking instance is still running.'
  Assert-That (-not $unrelatedProcess.HasExited) 'A same-named application outside the install directory was closed.'
  Assert-That (-not (Test-Path -LiteralPath $stage)) 'The successful helper did not clean up staging.'
  Assert-That (-not (Test-Path -LiteralPath $helper)) 'The successful helper did not remove its script.'
  Write-Host 'Verified real Inno update: parent exit, blocking instance closure, replacement, relaunch, and unrelated-instance preservation.'
} finally {
  foreach ($process in $ownedProcesses) {
    try {
      if (-not $process.HasExited) {
        $cleanup = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\taskkill.exe') `
          -ArgumentList @('/PID', [string]$process.Id, '/T', '/F') -PassThru -Wait -NoNewWindow
        if (-not $process.WaitForExit(10000)) { throw "Fixture process $($process.Id) did not stop." }
      }
      $process.Dispose()
    } catch {
      $cleanupErrors.Add($_.Exception.Message)
    }
  }
  try {
    if (Test-Path -LiteralPath $installerLog) {
      Copy-Item -LiteralPath $installerLog -Destination "$DiagnosticsPath.installer.log" -Force
      Remove-Item -LiteralPath $installerLog -Force
    }
  } catch {
    $cleanupErrors.Add($_.Exception.Message)
  }
  foreach ($name in $oldEnvironment.Keys) {
    [Environment]::SetEnvironmentVariable($name, $oldEnvironment[$name], 'Process')
  }
  try {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
  } catch {
    $cleanupErrors.Add($_.Exception.Message)
  }
  if ($cleanupErrors.Count -gt 0) { throw ($cleanupErrors -join "`n") }
}
