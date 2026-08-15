param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("Debug", "Release")]
  [string]$Configuration,
  [Parameter(Mandatory = $true)]
  [string]$EvidencePath,
  [switch]$ProvisionDisposableUserTrust,
  [ValidatePattern('^[0-9a-fA-F]{64}$')]
  [string]$ExpectedSignerCertificateSha256,
  [string]$ExpectedSignerPublisher
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "windows_smoke_profile_cleanup.ps1")

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
if ($ProvisionDisposableUserTrust) {
  if ([string]::IsNullOrWhiteSpace($ExpectedSignerCertificateSha256) -or
      [string]::IsNullOrWhiteSpace($ExpectedSignerPublisher)) {
    throw "Disposable CurrentUser trust requires the expected certificate SHA-256 and publisher."
  }
} elseif (-not [string]::IsNullOrWhiteSpace($ExpectedSignerCertificateSha256) -or
    -not [string]::IsNullOrWhiteSpace($ExpectedSignerPublisher)) {
  throw "Expected signer identity requires -ProvisionDisposableUserTrust."
}

$smokeRunId = [Guid]::NewGuid().ToString("N")
$configurationToken = $Configuration.Substring(0, 1).ToLowerInvariant()
$smokeRoot = Join-Path $env:RUNNER_TEMP "duf-$configurationToken-$smokeRunId"
$install = Join-Path $smokeRoot "install"
$installedApp = Join-Path $install "desktop_updater_example.exe"
$installedHelper = Join-Path $install "desktop_updater_install_helper.exe"
$smokeRunner = Join-Path $smokeRoot "updater_smoke.exe"
$smokeTrustCertificate = Join-Path $smokeRoot "disposable-user-trust.cer"
$runnerWorkingDirectory = $smokeRoot
$capturedDiagnostics = Join-Path $smokeRoot "helper-diagnostics.jsonl"
$runnerOut = Join-Path $smokeRoot "runner.out"
$runnerErr = Join-Path $smokeRoot "runner.err"
$smokeUser = $null
$smokeUserCreated = $false
$smokeUserProfile = $null
$smokeLocalAppData = $null
$userTemp = $null
$smokeProcess = $null
$helperEventStart = Get-Date
$prelaunchAcls = @()
$smokeSucceeded = $false
$primaryFailure = $null
$disposableTrustStores = @()
$disposableSignerCertificateSha256 = $null
$disposableSignerSelfSigned = $false

$smokeRootFullPath = [IO.Path]::GetFullPath($smokeRoot)
$smokeRootWithSeparator = "$smokeRootFullPath$([IO.Path]::DirectorySeparatorChar)"
$evidenceBase = [IO.Path]::GetFullPath($EvidencePath)
if (
  [StringComparer]::OrdinalIgnoreCase.Equals($evidenceBase, $smokeRootFullPath) -or
  $evidenceBase.StartsWith($smokeRootWithSeparator, [StringComparison]::OrdinalIgnoreCase)
) {
  throw "Windows Flutter smoke evidence path must be outside the disposable smoke root."
}
$evidenceRoot = Join-Path $evidenceBase $smokeRunId
if (Test-Path -LiteralPath $evidenceRoot) {
  throw "Unique Windows Flutter smoke evidence path already exists: $evidenceRoot"
}

function ConvertTo-WindowsSmokeEvidenceText {
  param([AllowNull()][string]$Text)

  if ($null -eq $Text) {
    return $null
  }

  $redacted = $Text
  $redacted = [regex]::Replace(
    $redacted,
    '(?im)("(?:[^"\\]|\\.)*(?:token|nonce|password|secret)(?:[^"\\]|\\.)*"\s*:\s*")[^"]*(")',
    '$1[redacted]$2'
  )
  $redacted = [regex]::Replace(
    $redacted,
    '(?im)(--(?:ready-token|recovery-ready-nonce|request-nonce|nonce)(?:\s+|=))(?:(?:"[^"]*")|\S+)',
    '$1[redacted]'
  )
  $redacted = [regex]::Replace(
    $redacted,
    '(?i)\\\\\.\\pipe\\desktop-updater-[A-Za-z0-9_-]+',
    '\\.\pipe\desktop-updater-[redacted]'
  )
  $redacted = [regex]::Replace(
    $redacted,
    '(?i)(https?://(?:127\.0\.0\.1|localhost):\d+/)[A-Za-z0-9_=\-]+/?',
    '$1[redacted]/'
  )
  return [regex]::Replace(
    $redacted,
    '(?i)([\\/](?:PortableLaunch)[\\/])[A-Za-z0-9_-]{16,}',
    '$1[redacted]'
  )
}

function Read-WindowsSmokeSharedText {
  param(
    [string]$Path,
    [int]$MaximumBytes = 262144
  )

  $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
  $stream = [IO.FileStream]::new(
    $Path,
    [IO.FileMode]::Open,
    [IO.FileAccess]::Read,
    $share
  )
  try {
    $initialLength = $stream.Length
    $bytesToRead = [int][Math]::Min([long]$MaximumBytes, $initialLength)
    $buffer = [byte[]]::new($bytesToRead)
    $offset = 0
    while ($offset -lt $bytesToRead) {
      $received = $stream.Read($buffer, $offset, $bytesToRead - $offset)
      if ($received -eq 0) { break }
      $offset += $received
    }
    $text = [Text.UTF8Encoding]::new($false, $false).GetString($buffer, 0, $offset)
    if ($initialLength -gt $MaximumBytes) {
      $text += "`n[evidence truncated at $MaximumBytes bytes]"
    }
    return ConvertTo-WindowsSmokeEvidenceText $text
  } finally {
    $stream.Dispose()
  }
}

function Get-WindowsSmokeAclSnapshot {
  param(
    [string]$Label,
    [AllowNull()][string]$Path
  )

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return [PSCustomObject]@{
      error = "path unavailable"
      label = $Label
      owner = $null
      sddl = $null
    }
  }
  try {
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    return [PSCustomObject]@{
      error = $null
      label = $Label
      owner = ConvertTo-WindowsSmokeEvidenceText $acl.Owner
      sddl = ConvertTo-WindowsSmokeEvidenceText $acl.Sddl
    }
  } catch {
    return [PSCustomObject]@{
      error = ConvertTo-WindowsSmokeEvidenceText $_.Exception.Message
      label = $Label
      owner = $null
      sddl = $null
    }
  }
}

function Get-WindowsSmokeTopLevelEntries {
  param([AllowNull()][string]$Root)

  if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root -PathType Container)) {
    return @()
  }
  return @(
    Get-ChildItem -LiteralPath $Root -Force -ErrorAction Stop |
      ForEach-Object {
        [PSCustomObject]@{
          attributes = $_.Attributes.ToString()
          lastWriteTimeUtc = $_.LastWriteTimeUtc.ToString("o")
          length = if ($_.PSIsContainer) { $null } else { $_.Length }
          name = ConvertTo-WindowsSmokeEvidenceText $_.Name
          type = if ($_.PSIsContainer) { "directory" } else { "file" }
        }
      }
  )
}

function ConvertTo-WindowsSmokeComparablePath {
  param(
    [AllowNull()]
    [AllowEmptyString()]
    [string]$Path
  )

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $null
  }

  $candidate = $Path.Trim()
  if ($candidate.StartsWith("\\?\UNC\", [StringComparison]::OrdinalIgnoreCase)) {
    $candidate = "\\$($candidate.Substring(8))"
  } elseif ($candidate.StartsWith("\\?\", [StringComparison]::OrdinalIgnoreCase)) {
    $candidate = $candidate.Substring(4)
  }

  try {
    return [IO.Path]::GetFullPath($candidate)
  } catch {
    return $null
  }
}

function Stop-WindowsSmokeRelaunchProcess {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ExecutablePath
  )

  $expectedPath = ConvertTo-WindowsSmokeComparablePath $ExecutablePath
  if ([string]::IsNullOrWhiteSpace($expectedPath)) {
    throw "Windows smoke relaunch executable path is invalid: $ExecutablePath"
  }
  $targetName = [IO.Path]::GetFileName($expectedPath).Replace("'", "''")
  for ($attempt = 0; $attempt -lt 20; $attempt++) {
    $remaining = @(
      Get-CimInstance Win32_Process -Filter "Name='$targetName'" |
        Where-Object {
          -not [string]::IsNullOrWhiteSpace($_.ExecutablePath) -and
          (ConvertTo-WindowsSmokeComparablePath $_.ExecutablePath) -eq $expectedPath
        }
    )
    if ($remaining.Count -eq 0) {
      return
    }
    foreach ($process in $remaining) {
      & taskkill.exe /F /T /PID $process.ProcessId 2>$null | Out-Null
    }
    [System.Threading.Thread]::Sleep(100)
  }
  throw "Windows smoke relaunch process remained after elevated cleanup: $ExecutablePath"
}

function Repair-WindowsSmokeCleanupAccess {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Root
  )

  if (-not (Test-Path -LiteralPath $Root)) {
    return
  }
  & takeown.exe /F $Root /R /D Y | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "Windows smoke cleanup could not take ownership of $Root."
  }
  & icacls.exe $Root /reset /T /C | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "Windows smoke cleanup could not reset permissions for $Root."
  }
  & icacls.exe $Root /grant '*S-1-5-32-544:(OI)(CI)F' /T /C | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "Windows smoke cleanup could not grant Administrators access to $Root."
  }
  & icacls.exe $Root /grant '*S-1-5-18:(OI)(CI)F' /T /C | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "Windows smoke cleanup could not grant SYSTEM access to $Root."
  }
}

function Remove-WindowsSmokeRootWithRetry {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Root
  )

  Repair-WindowsSmokeCleanupAccess -Root $Root
  for ($attempt = 0; $attempt -lt 24; $attempt++) {
    try {
      Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction Stop
      return
    } catch {
      if ($attempt -eq 23) {
        throw
      }
      Start-Sleep -Milliseconds 250
    }
  }
}

function Save-WindowsFlutterSmokeEvidence {
  New-Item -ItemType Directory -Path $evidenceRoot -Force | Out-Null
  $collectionErrors = [Collections.Generic.List[string]]::new()

  $eventRecords = @()
  try {
    $eventRecords = @(
      Get-WinEvent -FilterHashtable @{
        LogName = "Application"
        ProviderName = "DesktopUpdater.InstallHelper.ProtocolV1"
        StartTime = $helperEventStart
      } -ErrorAction Stop |
        Sort-Object TimeCreated, RecordId
    )
  } catch {
    $collectionErrors.Add(
      (ConvertTo-WindowsSmokeEvidenceText "provider-filtered event log: $($_.Exception.Message)")
    ) | Out-Null
    try {
      $eventRecords = @(
        Get-WinEvent -FilterHashtable @{
          LogName = "Application"
          StartTime = $helperEventStart
        } -ErrorAction Stop |
          Where-Object { $_.ProviderName -eq "DesktopUpdater.InstallHelper.ProtocolV1" } |
          Sort-Object TimeCreated, RecordId
      )
    } catch {
      $collectionErrors.Add(
        (ConvertTo-WindowsSmokeEvidenceText "fallback event log: $($_.Exception.Message)")
      ) | Out-Null
    }
  }
  $events = @(
    foreach ($eventRecord in $eventRecords) {
      [PSCustomObject]@{
        id = $eventRecord.Id
        level = $eventRecord.LevelDisplayName
        processId = $eventRecord.ProcessId
        properties = @(
          $eventRecord.Properties |
            ForEach-Object { ConvertTo-WindowsSmokeEvidenceText ([string]$_.Value) }
        )
        recordId = $eventRecord.RecordId
        timestampUtc = $eventRecord.TimeCreated.ToUniversalTime().ToString("o")
      }
    }
  )

  $tasks = @()
  if ($null -ne $smokeUser) {
    $taskErrors = @()
    $smokeUserIdentifiers = @(
      $smokeUser.SID.Value,
      $smokeUser.Name,
      "$env:COMPUTERNAME\$($smokeUser.Name)"
    )
    $taskCandidates = @(
      Get-ScheduledTask -TaskName "DesktopUpdater-Portable-*" -ErrorAction SilentlyContinue -ErrorVariable +taskErrors |
        Where-Object {
          $principalUserId = [string]$_.Principal.UserId
          @(
            $smokeUserIdentifiers |
              Where-Object {
                [StringComparer]::OrdinalIgnoreCase.Equals($_, $principalUserId)
              }
          ).Count -ne 0
        }
    )
    foreach ($taskError in $taskErrors) {
      $collectionErrors.Add(
        (ConvertTo-WindowsSmokeEvidenceText "scheduled tasks: $($taskError.Exception.Message)")
      ) | Out-Null
    }
    $tasks = @(
      foreach ($task in $taskCandidates) {
        try {
          $taskInfo = Get-ScheduledTaskInfo -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction Stop
          [PSCustomObject]@{
            lastRunTimeUtc = if ($null -ne $taskInfo.LastRunTime) { $taskInfo.LastRunTime.ToUniversalTime().ToString("o") } else { $null }
            lastTaskResult = $taskInfo.LastTaskResult
            principalUserId = ConvertTo-WindowsSmokeEvidenceText $task.Principal.UserId
            state = $task.State.ToString()
            taskName = ConvertTo-WindowsSmokeEvidenceText $task.TaskName
            taskPath = ConvertTo-WindowsSmokeEvidenceText $task.TaskPath
          }
        } catch {
          $collectionErrors.Add(
            (ConvertTo-WindowsSmokeEvidenceText "scheduled task $($task.TaskName): $($_.Exception.Message)")
          ) | Out-Null
        }
      }
    )
  }

  $eventProcessIds = @(
    $events |
      ForEach-Object { $_.processId } |
      Where-Object { $null -ne $_ -and $_ -gt 0 } |
      Sort-Object -Unique
  )
  $outerRunnerProcessId = if ($null -ne $smokeProcess) { $smokeProcess.Id } else { $null }
  $processErrors = @()
  $activeProcesses = @(
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue -ErrorVariable +processErrors |
      Where-Object {
        $eventProcessIds -contains $_.ProcessId -or
        ($null -ne $outerRunnerProcessId -and $_.ParentProcessId -eq $outerRunnerProcessId)
      } |
      ForEach-Object {
        [PSCustomObject]@{
          creationDate = if ($null -ne $_.CreationDate) { $_.CreationDate.ToUniversalTime().ToString("o") } else { $null }
          name = ConvertTo-WindowsSmokeEvidenceText $_.Name
          parentProcessId = $_.ParentProcessId
          processId = $_.ProcessId
        }
      }
  )
  foreach ($processError in $processErrors) {
    $collectionErrors.Add(
      (ConvertTo-WindowsSmokeEvidenceText "processes: $($processError.Exception.Message)")
    ) | Out-Null
  }

  $recoveryActive = $activeProcesses.Count -ne 0 -or @(
    $tasks | Where-Object { $_.state -eq "Running" }
  ).Count -ne 0
  $filesystem = [PSCustomObject]@{
    diagnosticsExists = Test-Path -LiteralPath $capturedDiagnostics -PathType Leaf
    installExists = $null
    sentinelExists = $null
    skippedReason = if ($recoveryActive) { "helper-or-recovery-active" } else { $null }
    topLevelSmokeEntries = @()
    topLevelUserTempEntries = @()
  }
  $recoveryRecords = @()
  if (-not $recoveryActive) {
    try {
      $filesystem.installExists = Test-Path -LiteralPath $install -PathType Container
    } catch {
      $filesystem.installExists = $null
      $collectionErrors.Add(
        (ConvertTo-WindowsSmokeEvidenceText "install directory probe: $($_.Exception.Message)")
      ) | Out-Null
    }
    try {
      $filesystem.sentinelExists = Test-Path -LiteralPath (Join-Path $install "desktop_updater_smoke.txt") -PathType Leaf
    } catch {
      $filesystem.sentinelExists = $null
      $collectionErrors.Add(
        (ConvertTo-WindowsSmokeEvidenceText "install sentinel probe: $($_.Exception.Message)")
      ) | Out-Null
    }
    try {
      $filesystem.topLevelSmokeEntries = @(Get-WindowsSmokeTopLevelEntries $smokeRoot)
    } catch {
      $collectionErrors.Add(
        (ConvertTo-WindowsSmokeEvidenceText "smoke root metadata: $($_.Exception.Message)")
      ) | Out-Null
    }
    try {
      $filesystem.topLevelUserTempEntries = @(Get-WindowsSmokeTopLevelEntries $userTemp)
    } catch {
      $collectionErrors.Add(
        (ConvertTo-WindowsSmokeEvidenceText "user temp metadata: $($_.Exception.Message)")
      ) | Out-Null
    }

    if (-not [string]::IsNullOrWhiteSpace($smokeLocalAppData)) {
      $recoveryRoot = Join-Path $smokeLocalAppData "desktop_updater_portable_transactions_v1"
      try {
        if (Test-Path -LiteralPath $recoveryRoot -PathType Container) {
          $recoveryNames = @(
            "record.json",
            "record.next",
            "resolver_claim.json",
            "resolver_claim.next",
            "locator.json",
            "locator.next"
          )
          $recoveryFiles = @(
            Get-ChildItem -LiteralPath $recoveryRoot -File -Recurse -Depth 3 -Force -ErrorAction Stop |
              Where-Object { $recoveryNames -contains $_.Name } |
              Select-Object -First 32
          )
          $recoveryRecords = @(
            foreach ($recoveryFile in $recoveryFiles) {
              try {
                if ($recoveryFile.Length -gt 1048576) {
                  throw "recovery record exceeds 1048576 bytes"
                }
                [PSCustomObject]@{
                  content = Read-WindowsSmokeSharedText -Path $recoveryFile.FullName -MaximumBytes 1048576
                  error = $null
                  relativePath = ".../$($recoveryFile.Name)"
                }
              } catch {
                [PSCustomObject]@{
                  content = $null
                  error = ConvertTo-WindowsSmokeEvidenceText $_.Exception.Message
                  relativePath = ".../$($recoveryFile.Name)"
                }
              }
            }
          )
        } else {
          $collectionErrors.Add("recovery records: root absent or inaccessible") | Out-Null
        }
      } catch {
        $collectionErrors.Add(
          (ConvertTo-WindowsSmokeEvidenceText "recovery records: $($_.Exception.Message)")
        ) | Out-Null
      }
    }
  }

  $report = [PSCustomObject]@{
    activeProcesses = $activeProcesses
    capturedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    collectionErrors = @($collectionErrors)
    configuration = $Configuration
    events = $events
    filesystem = $filesystem
    helperEventStartUtc = $helperEventStart.ToUniversalTime().ToString("o")
    prelaunchAcls = $prelaunchAcls
    primaryFailure = ConvertTo-WindowsSmokeEvidenceText $primaryFailure
    recoveryRecords = $recoveryRecords
    runId = $smokeRunId
    runner = [PSCustomObject]@{
      exitCode = if ($null -ne $smokeProcess) { $smokeProcess.ExitCode } else { $null }
      processId = $outerRunnerProcessId
      workingDirectory = ConvertTo-WindowsSmokeEvidenceText $runnerWorkingDirectory
    }
    schemaVersion = 1
    standardUser = if ($null -ne $smokeUser) {
      [PSCustomObject]@{
        sid = $smokeUser.SID.Value
        signerCertificateSha256 = $disposableSignerCertificateSha256
        trustStores = @($disposableTrustStores)
      }
    } else {
      $null
    }
    tasks = $tasks
  }
  $report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $evidenceRoot "report.json") -Encoding utf8

  foreach ($textArtifact in @(
      [PSCustomObject]@{ name = "runner.out"; path = $runnerOut },
      [PSCustomObject]@{ name = "runner.err"; path = $runnerErr },
      [PSCustomObject]@{ name = "helper-diagnostics.jsonl"; path = $capturedDiagnostics }
    )) {
    if (Test-Path -LiteralPath $textArtifact.path -PathType Leaf) {
      try {
        [IO.File]::WriteAllText(
          (Join-Path $evidenceRoot $textArtifact.name),
          (Read-WindowsSmokeSharedText $textArtifact.path),
          [Text.UTF8Encoding]::new($false)
        )
      } catch {
        Write-Warning (ConvertTo-WindowsSmokeEvidenceText "Windows smoke evidence text copy failed: $($_.Exception.Message)")
      }
    }
  }
}

try {
  if (Test-Path -LiteralPath $smokeRoot) {
    throw "Unique Windows Flutter smoke root already exists: $smokeRoot"
  }
  New-Item -ItemType Directory -Path $smokeRoot -Force | Out-Null
  Copy-Item -LiteralPath $runnerRoot -Destination $install -Recurse -Force

  if ($ProvisionDisposableUserTrust) {
    $signatures = @(
      Get-AuthenticodeSignature -LiteralPath $app
      Get-AuthenticodeSignature -LiteralPath $helper
    )
    $signerCertificates = [Collections.Generic.List[object]]::new()
    foreach ($signature in $signatures) {
      if ($signature.Status -ne 'Valid' -or
          $null -eq $signature.SignerCertificate) {
        throw "Disposable CurrentUser trust refuses an invalid source signature."
      }
      $signerCertificates.Add($signature.SignerCertificate) | Out-Null
    }
    $certificateHashes = @(
      $signerCertificates |
        ForEach-Object {
          [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData($_.RawData)
          ).ToLowerInvariant()
        }
    )
    $expectedCertificateHash = `
      $ExpectedSignerCertificateSha256.ToLowerInvariant()
    if ($certificateHashes.Count -ne 2 -or
        $certificateHashes[0] -ne $expectedCertificateHash -or
        $certificateHashes[1] -ne $expectedCertificateHash) {
      throw "Disposable CurrentUser trust signer certificate SHA-256 changed."
    }
    foreach ($certificate in $signerCertificates) {
      $publisher = $certificate.GetNameInfo(
        [Security.Cryptography.X509Certificates.X509NameType]::SimpleName,
        $false
      )
      if ($publisher -ne $ExpectedSignerPublisher) {
        throw "Disposable CurrentUser trust signer publisher changed."
      }
    }
    $signerCertificate = $signerCertificates[0]
    if ($signerCertificate.HasPrivateKey) {
      throw "Disposable CurrentUser trust must export only a public certificate."
    }
    $disposableSignerCertificateSha256 = $expectedCertificateHash
    $disposableSignerSelfSigned = `
      $signerCertificate.Subject -eq $signerCertificate.Issuer
    $disposableTrustStores = @('TrustedPublisher')
    if ($disposableSignerSelfSigned) {
      $disposableTrustStores = @('Root', 'TrustedPublisher')
    }
    [IO.File]::WriteAllBytes(
      $smokeTrustCertificate,
      $signerCertificate.Export(
        [Security.Cryptography.X509Certificates.X509ContentType]::Cert
      )
    )
  }

  Push-Location $exampleRoot
  try {
    & dart compile exe tool/updater_smoke.dart -o $smokeRunner
    if ($LASTEXITCODE -ne 0) {
      throw "Windows Flutter smoke runner compilation failed with code $LASTEXITCODE."
    }
  } finally {
    Pop-Location
  }

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

  $smokeCredential = [System.Management.Automation.PSCredential]::new(
    "$env:COMPUTERNAME\$smokeUserName",
    $smokePassword
  )
  $profilesDirectory = [Environment]::ExpandEnvironmentVariables(
    (Get-ItemProperty -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList" -Name ProfilesDirectory).ProfilesDirectory
  )
  $smokeUserProfile = Join-Path $profilesDirectory $smokeUserName
  $smokeLocalAppData = Join-Path $smokeUserProfile "AppData\Local"
  $userTemp = Join-Path $smokeLocalAppData "Temp"
  $provisionTrustToken = if ($ProvisionDisposableUserTrust) { "1" } else { "0" }
  $selfSignedTrustToken = if ($disposableSignerSelfSigned) { "1" } else { "0" }
  $trustCertificatePath = if ($ProvisionDisposableUserTrust) {
    $smokeTrustCertificate
  } else {
    ""
  }
  $trustCertificateSha256 = if ($ProvisionDisposableUserTrust) {
    $disposableSignerCertificateSha256
  } else {
    ""
  }
  $trustCertificatePublisher = if ($ProvisionDisposableUserTrust) {
    $ExpectedSignerPublisher
  } else {
    ""
  }
  $smokeEnvironment = @{
    APPDATA = Join-Path $smokeUserProfile "AppData\Roaming"
    DESKTOP_UPDATER_SMOKE_EXPECTED_LOCALAPPDATA = $smokeLocalAppData
    DESKTOP_UPDATER_SMOKE_EXPECTED_SIGNER_SHA256 = $trustCertificateSha256
    DESKTOP_UPDATER_SMOKE_EXPECTED_SIGNER_PUBLISHER = $trustCertificatePublisher
    DESKTOP_UPDATER_SMOKE_PROVISION_USER_TRUST = $provisionTrustToken
    DESKTOP_UPDATER_SMOKE_SIGNED_HELPER = $installedHelper
    DESKTOP_UPDATER_SMOKE_SIGNER_SELF_SIGNED = $selfSignedTrustToken
    DESKTOP_UPDATER_SMOKE_TRUST_CERTIFICATE = $trustCertificatePath
    HOME = $smokeUserProfile
    HOMEDRIVE = Split-Path -Qualifier $smokeUserProfile
    HOMEPATH = $smokeUserProfile.Substring((Split-Path -Qualifier $smokeUserProfile).Length)
    LOCALAPPDATA = $smokeLocalAppData
    DESKTOP_UPDATER_SMOKE_EXTERNAL_RELAUNCH_CLEANUP = "1"
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
    '$tempPath = Join-Path $localAppData "Temp"'
    '[IO.Directory]::CreateDirectory($tempPath) | Out-Null'
    'if ($env:DESKTOP_UPDATER_SMOKE_PROVISION_USER_TRUST -eq "1") {'
    '  $certificatePath = $env:DESKTOP_UPDATER_SMOKE_TRUST_CERTIFICATE'
    '  $expectedCertificateSha256 = $env:DESKTOP_UPDATER_SMOKE_EXPECTED_SIGNER_SHA256'
    '  $expectedPublisher = $env:DESKTOP_UPDATER_SMOKE_EXPECTED_SIGNER_PUBLISHER'
    '  $signedHelper = $env:DESKTOP_UPDATER_SMOKE_SIGNED_HELPER'
    '  $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new($certificatePath)'
    '  try {'
    '    if ($certificate.HasPrivateKey) {'
    '      throw "Disposable trust certificate unexpectedly contains a private key."'
    '    }'
    '    $certificateSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($certificate.RawData)).ToLowerInvariant()'
    '    $publisher = $certificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)'
    '    if ($certificateSha256 -ne $expectedCertificateSha256 -or $publisher -ne $expectedPublisher) {'
    '      throw "Disposable trust certificate identity changed."'
    '    }'
    '    $storeNames = @("TrustedPublisher")'
    '    if ($env:DESKTOP_UPDATER_SMOKE_SIGNER_SELF_SIGNED -eq "1") {'
    '      $storeNames = @("Root", "TrustedPublisher")'
    '    }'
    '    foreach ($storeName in $storeNames) {'
    '      $certutilOutput = & certutil.exe -user -f -addstore $storeName $certificatePath 2>&1'
    '      if ($LASTEXITCODE -ne 0) {'
    '        throw "certutil failed to add disposable CurrentUser trust to $storeName`: $certutilOutput"'
    '      }'
    '    }'
    '    $helperSignature = Get-AuthenticodeSignature -LiteralPath $signedHelper'
    '    if ($helperSignature.Status -ne "Valid" -or $null -eq $helperSignature.SignerCertificate) {'
    '      throw "Disposable user does not trust the signed helper."'
    '    }'
    '    $helperCertificateSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($helperSignature.SignerCertificate.RawData)).ToLowerInvariant()'
    '    $helperPublisher = $helperSignature.SignerCertificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)'
    '    if ($helperCertificateSha256 -ne $expectedCertificateSha256 -or $helperPublisher -ne $expectedPublisher) {'
    '      throw "Disposable user trusted an unexpected helper signer."'
    '    }'
    '  } finally {'
    '    $certificate.Dispose()'
    '  }'
    '}'
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
    foreach ($profileOutputPath in @($profileProbeOut, $profileProbeErr)) {
      if (Test-Path -LiteralPath $profileOutputPath -PathType Leaf) {
        Write-Host (Read-WindowsSmokeSharedText $profileOutputPath)
      }
    }
    if ($profileProbeProcess.ExitCode -ne 0) {
      throw "Windows Flutter smoke could not initialize LocalAppData for the standard user."
    }
    if (-not (Test-Path -LiteralPath $userTemp -PathType Container)) {
      throw "Windows Flutter smoke could not initialize its standard-user TEMP."
    }
    $prelaunchAcls = @(
      Get-WindowsSmokeAclSnapshot -Label "smokeRoot" -Path $smokeRoot
      Get-WindowsSmokeAclSnapshot -Label "install" -Path $install
      Get-WindowsSmokeAclSnapshot -Label "smokeLocalAppData" -Path $smokeLocalAppData
    )
    $helperEventStart = Get-Date
    # Keeping the outer sentinel waiter inside $install pins that directory on
    # Windows and prevents the helper from atomically replacing it after exit.
    $smokeProcess = Start-Process -FilePath $smokeRunner -ArgumentList @(
      "--app", $installedApp,
      "--diagnostics-log", $capturedDiagnostics
    ) -Credential $smokeCredential -LoadUserProfile -Environment $smokeEnvironment -WorkingDirectory $runnerWorkingDirectory -RedirectStandardOutput $runnerOut -RedirectStandardError $runnerErr -PassThru
  } finally {
    $env:TEMP = $originalTemp
    $env:TMP = $originalTmp
  }
  if (-not $smokeProcess.HasExited) {
    Wait-Process -Id $smokeProcess.Id -ErrorAction Stop | Out-Null
  }
  $smokeProcess.Refresh()
  foreach ($runnerOutputPath in @($runnerOut, $runnerErr)) {
    if (Test-Path -LiteralPath $runnerOutputPath -PathType Leaf) {
      Write-Host (Read-WindowsSmokeSharedText $runnerOutputPath)
    }
  }
  if ($smokeProcess.ExitCode -ne 0) {
    throw "Windows $Configuration Flutter smoke standard-user runner exited with code $($smokeProcess.ExitCode)."
  }
  if (-not (Test-Path -LiteralPath $capturedDiagnostics -PathType Leaf)) {
    throw "Windows $Configuration Flutter smoke diagnostics are unavailable."
  }
  Save-WindowsFlutterSmokeEvidence
  $smokeSucceeded = $true
} catch {
  $primaryFailure = $_.Exception.ToString()
  throw
} finally {
  if (-not $smokeSucceeded) {
    try {
      Save-WindowsFlutterSmokeEvidence
    } catch {
      Write-Warning (ConvertTo-WindowsSmokeEvidenceText "Windows Flutter smoke evidence capture failed: $($_.Exception.Message)")
    }
  }
  $cleanupFailures = [Collections.Generic.List[string]]::new()
  if ($null -ne $smokeProcess) {
    try {
      Stop-WindowsSmokeRelaunchProcess -ExecutablePath $installedApp
    } catch {
      $cleanupMessage = "Windows Flutter smoke relaunch cleanup failed: $($_.Exception.Message)"
      $cleanupFailures.Add($cleanupMessage) | Out-Null
      Write-Warning (ConvertTo-WindowsSmokeEvidenceText $cleanupMessage)
    }
  }
  if ($smokeUserCreated -and $null -ne $smokeUser -and
      -not [string]::IsNullOrWhiteSpace($smokeUserProfile)) {
    try {
      Remove-WindowsSmokeUserProfile `
        -Sid $smokeUser.SID.Value `
        -ExpectedPath $smokeUserProfile
    } catch {
      $cleanupMessage = "Windows Flutter smoke profile cleanup failed: $($_.Exception.Message)"
      $cleanupFailures.Add($cleanupMessage) | Out-Null
      Write-Warning (ConvertTo-WindowsSmokeEvidenceText $cleanupMessage)
    }
  }
  if ($smokeUserCreated) {
    try {
      Remove-LocalUser -Name $smokeUser.Name -ErrorAction Stop
    } catch {
      $cleanupMessage = "Windows Flutter smoke account cleanup failed: $($_.Exception.Message)"
      $cleanupFailures.Add($cleanupMessage) | Out-Null
      Write-Warning (ConvertTo-WindowsSmokeEvidenceText $cleanupMessage)
    }
  }
  if (Test-Path -LiteralPath $smokeRoot) {
    try {
      Remove-WindowsSmokeRootWithRetry -Root $smokeRoot
    } catch {
      $cleanupMessage = "Windows Flutter smoke root cleanup failed: $($_.Exception.Message)"
      $cleanupFailures.Add($cleanupMessage) | Out-Null
      Write-Warning (ConvertTo-WindowsSmokeEvidenceText $cleanupMessage)
    }
  }
  if (Test-Path -LiteralPath $smokeRoot) {
    $cleanupMessage = "Windows Flutter smoke root remains after cleanup: $smokeRoot"
    $cleanupFailures.Add($cleanupMessage) | Out-Null
    Write-Warning (ConvertTo-WindowsSmokeEvidenceText $cleanupMessage)
  }
  if ($smokeSucceeded -and $cleanupFailures.Count -ne 0) {
    throw "Windows Flutter smoke succeeded but cleanup failed."
  }
}
