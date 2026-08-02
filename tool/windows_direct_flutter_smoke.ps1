param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("Debug", "Release")]
  [string]$Configuration,
  [Parameter(Mandatory = $true)]
  [string]$DiagnosticsPath
)

$ErrorActionPreference = "Stop"

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$exampleRoot = Join-Path $repositoryRoot "example"
$runnerRoot = Join-Path $exampleRoot "build/windows/x64/runner/$Configuration"
$app = Join-Path $runnerRoot "desktop_updater_example.exe"
$helper = Join-Path $runnerRoot "desktop_updater_install_helper.exe"
if (-not (Test-Path -LiteralPath $app -PathType Leaf)) {
  throw "Windows $Configuration Flutter smoke app is missing: $app"
}
if (-not (Test-Path -LiteralPath $helper -PathType Leaf)) {
  throw "Windows $Configuration Flutter smoke helper is missing: $helper"
}

$smokeRoot = Join-Path $env:RUNNER_TEMP "flutter-windows-update-smoke-$($Configuration.ToLowerInvariant())"
$install = Join-Path $smokeRoot "install"
$smokeRunner = Join-Path $smokeRoot "updater_smoke.exe"
$capturedDiagnostics = Join-Path $smokeRoot "helper-diagnostics.jsonl"
$runnerOut = Join-Path $smokeRoot "runner.out"
$runnerErr = Join-Path $smokeRoot "runner.err"
$smokeUser = $null
$smokeUserCreated = $false

Remove-Item -LiteralPath $smokeRoot -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $smokeRoot -Force | Out-Null
Copy-Item -LiteralPath $runnerRoot -Destination $install -Recurse -Force

Push-Location $exampleRoot
try {
  & dart compile exe tool/updater_smoke.dart -o $smokeRunner
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} finally {
  Pop-Location
}

try {
  $smokeUserName = "duflutter$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
  $smokePasswordText = "Du!9$([Guid]::NewGuid().ToString('N'))"
  $smokePassword = ConvertTo-SecureString $smokePasswordText -AsPlainText -Force
  $smokeUser = New-LocalUser -Name $smokeUserName -Password $smokePassword -AccountNeverExpires -PasswordNeverExpires -UserMayNotChangePassword
  $smokeUserCreated = $true
  $users = Get-LocalGroup -SID "S-1-5-32-545"
  $isUser = @(
    Get-LocalGroupMember -Group $users.Name |
      Where-Object { $_.SID.Value -eq $smokeUser.SID.Value }
  ).Count -ne 0
  if (-not $isUser) {
    Add-LocalGroupMember -Group $users.Name -Member $smokeUser
  }
  $administrators = Get-LocalGroup -SID "S-1-5-32-544"
  $isAdministrator = @(
    Get-LocalGroupMember -Group $administrators.Name |
      Where-Object { $_.SID.Value -eq $smokeUser.SID.Value }
  ).Count -ne 0
  if ($isAdministrator) {
    throw "Account unexpectedly has administrator authority."
  }
  & icacls.exe $smokeRoot /grant:r "*$($smokeUser.SID.Value):(OI)(CI)F" /T /C | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "Windows Flutter smoke account could not own its disposable lane."
  }

  $userTemp = Join-Path $smokeRoot "user-temp"
  New-Item -ItemType Directory -Path $userTemp -Force | Out-Null
  $smokeCredential = [System.Management.Automation.PSCredential]::new(
    "$env:COMPUTERNAME\$smokeUserName",
    $smokePassword
  )
  $profilesDirectory = [Environment]::ExpandEnvironmentVariables(
    (Get-ItemProperty -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList" -Name ProfilesDirectory).ProfilesDirectory
  )
  $smokeUserProfile = Join-Path $profilesDirectory $smokeUserName
  $smokeLocalAppData = Join-Path $smokeUserProfile "AppData\Local"
  $smokeEnvironment = @{
    APPDATA = Join-Path $smokeUserProfile "AppData\Roaming"
    DESKTOP_UPDATER_SMOKE_EXPECTED_LOCALAPPDATA = $smokeLocalAppData
    HOME = $smokeUserProfile
    HOMEDRIVE = Split-Path -Qualifier $smokeUserProfile
    HOMEPATH = $smokeUserProfile.Substring((Split-Path -Qualifier $smokeUserProfile).Length)
    LOCALAPPDATA = $smokeLocalAppData
    PATH = $env:PATH
    SystemRoot = $env:SystemRoot
    TEMP = $userTemp
    TMP = $userTemp
    USERDOMAIN = $env:COMPUTERNAME
    USERNAME = $smokeUserName
    USERPROFILE = $smokeUserProfile
    WINDIR = $env:WINDIR
  }
  $smokePasswordText = $null
  $profileProbeOut = Join-Path $smokeRoot "profile-probe.out"
  $profileProbeErr = Join-Path $smokeRoot "profile-probe.err"
  $profileProbeScript = @(
    '$ErrorActionPreference = "Stop"'
    '$localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData, [Environment+SpecialFolderOption]::Create)'
    'if ([string]::IsNullOrWhiteSpace($localAppData)) {'
    '  throw "LocalApplicationData is unavailable."'
    '}'
    '$expectedLocalAppData = $env:DESKTOP_UPDATER_SMOKE_EXPECTED_LOCALAPPDATA'
    'if (-not [StringComparer]::OrdinalIgnoreCase.Equals([IO.Path]::GetFullPath($localAppData), [IO.Path]::GetFullPath($expectedLocalAppData))) {'
    '  throw "LocalApplicationData resolved outside the standard-user profile."'
    '}'
    '[IO.Directory]::CreateDirectory($localAppData) | Out-Null'
    '$probe = Join-Path $localAppData ("desktop-updater-profile-probe-{0}.tmp" -f [Guid]::NewGuid().ToString("N"))'
    'try {'
    '  [IO.File]::WriteAllText($probe, "ready", [Text.UTF8Encoding]::new($false))'
    '} finally {'
    '  Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue'
    '}'
    'Write-Output "Windows Flutter smoke LocalApplicationData is ready."'
  ) -join [Environment]::NewLine
  $profileProbePath = Join-Path $smokeRoot "profile-probe.ps1"
  [IO.File]::WriteAllText(
    $profileProbePath,
    $profileProbeScript,
    [Text.UTF8Encoding]::new($false)
  )
  $profileProbeShell = (Get-Process -Id $PID).Path
  $originalTemp = $env:TEMP
  $originalTmp = $env:TMP
  try {
    $env:TEMP = $userTemp
    $env:TMP = $userTemp
    $profileProbeProcess = Start-Process -FilePath $profileProbeShell -ArgumentList @(
      "-NoLogo",
      "-NoProfile",
      "-NonInteractive",
      "-File", $profileProbePath
    ) -Credential $smokeCredential -LoadUserProfile -Environment $smokeEnvironment -WorkingDirectory $smokeRoot -RedirectStandardOutput $profileProbeOut -RedirectStandardError $profileProbeErr -Wait -PassThru
    Get-Content $profileProbeOut, $profileProbeErr -ErrorAction SilentlyContinue
    if ($profileProbeProcess.ExitCode -ne 0) {
      throw "Windows Flutter smoke could not initialize LocalAppData for the standard user."
    }
    $helperEventStart = Get-Date
    $smokeProcess = Start-Process -FilePath $smokeRunner -ArgumentList @(
      "--app", (Join-Path $install "desktop_updater_example.exe"),
      "--diagnostics-log", $capturedDiagnostics
    ) -Credential $smokeCredential -LoadUserProfile -Environment $smokeEnvironment -WorkingDirectory $install -RedirectStandardOutput $runnerOut -RedirectStandardError $runnerErr -Wait -PassThru
  } finally {
    $env:TEMP = $originalTemp
    $env:TMP = $originalTmp
  }
  Get-Content $runnerOut, $runnerErr -ErrorAction SilentlyContinue
  if ($smokeProcess.ExitCode -ne 0) {
    $helperEvents = @(
      Get-WinEvent -FilterHashtable @{ LogName = "Application"; StartTime = $helperEventStart } -ErrorAction SilentlyContinue |
        Where-Object { $_.ProviderName -eq "DesktopUpdater.InstallHelper.ProtocolV1" }
    )
    foreach ($helperEvent in $helperEvents) {
      Write-Host "Windows helper event $($helperEvent.Id): $($helperEvent.LevelDisplayName)"
    }
    throw "Windows $Configuration Flutter smoke standard-user runner exited with code $($smokeProcess.ExitCode)."
  }
  if (-not (Test-Path -LiteralPath $capturedDiagnostics -PathType Leaf)) {
    throw "Windows $Configuration Flutter smoke diagnostics are unavailable."
  }
  $destination = [IO.Path]::GetFullPath($DiagnosticsPath)
  New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
  Copy-Item -LiteralPath $capturedDiagnostics -Destination $destination -Force
} finally {
  if ($smokeUserCreated) {
    Remove-LocalUser -Name $smokeUser.Name -ErrorAction SilentlyContinue
  }
  Remove-Item -LiteralPath $smokeRoot -Recurse -Force -ErrorAction SilentlyContinue
}
