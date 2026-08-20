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
. (Join-Path $PSScriptRoot "windows_process_tree_cleanup.ps1")

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
$smokeRootOwnershipMarker = Join-Path $smokeRoot ".desktop_updater_smoke_run.json"
$install = Join-Path $smokeRoot "install"
$installedApp = Join-Path $install "desktop_updater_example.exe"
$installedHelper = Join-Path $install "desktop_updater_install_helper.exe"
$smokeRunner = Join-Path $smokeRoot "updater_smoke.exe"
$smokeTrustCertificate = Join-Path $smokeRoot "disposable-user-trust.cer"
$runnerWorkingDirectory = $smokeRoot
$capturedDiagnostics = Join-Path $smokeRoot "helper-diagnostics.jsonl"
$standardUserFilesystemEvidencePath = Join-Path $smokeRoot "standard-user-filesystem-evidence.json"
$standardUserFilesystemProbePath = Join-Path $smokeRoot "standard-user-filesystem-probe.ps1"
$standardUserFilesystemProbeOut = Join-Path $smokeRoot "standard-user-filesystem-probe.out"
$standardUserFilesystemProbeErr = Join-Path $smokeRoot "standard-user-filesystem-probe.err"
$runnerOut = Join-Path $smokeRoot "runner.out"
$runnerErr = Join-Path $smokeRoot "runner.err"
$markerPath = Join-Path $smokeRoot "smoke-marker.txt"
$smokeUser = $null
$smokeUserCreated = $false
$smokeUserProfile = $null
$smokeLocalAppData = $null
$userTemp = $null
$smokeProcess = $null
$smokeRunnerTimeoutSeconds = 180
$standardUserFilesystemEvidence = $null
$helperEventStart = Get-Date
$prelaunchAcls = @()
$smokeSucceeded = $false
$primaryFailure = $null
$disposableTrustStores = @()
$disposableSignerCertificateSha256 = $null
$disposableSignerSelfSigned = $false
$expectedSmokeVersion = "2.7.1"
$expectedAppSha256 = (Get-FileHash -LiteralPath $app -Algorithm SHA256).Hash.ToLowerInvariant()
$expectedHelperSha256 = (Get-FileHash -LiteralPath $helper -Algorithm SHA256).Hash.ToLowerInvariant()

function Get-WindowsSmokeCertificateSha256([byte[]] $RawData) {
  $algorithm = [Security.Cryptography.SHA256]::Create()
  try {
    return (
      [BitConverter]::ToString($algorithm.ComputeHash($RawData)) -replace '-', ''
    ).ToLowerInvariant()
  } finally {
    $algorithm.Dispose()
  }
}
$helperEventBaselineRecordId = 0

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

function Assert-WindowsSmokeOwnedRoot {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Root,
    [switch]$SkipNestedReparseCheck
  )

  $resolvedRoot = [IO.Path]::GetFullPath($Root)
  $runnerTemp = [IO.Path]::GetFullPath([string]$env:RUNNER_TEMP)
  $runnerTempPrefix = $runnerTemp.TrimEnd(
    [IO.Path]::DirectorySeparatorChar
  ) + [IO.Path]::DirectorySeparatorChar
  if (-not $resolvedRoot.StartsWith(
      $runnerTempPrefix,
      [StringComparison]::OrdinalIgnoreCase
    ) -or [IO.Path]::GetFileName($resolvedRoot) -notmatch '^duf-[dr]-[0-9a-f]{32}$') {
    throw "Refusing cleanup outside the task-scoped Windows smoke root: $resolvedRoot"
  }
  $parent = Get-Item -LiteralPath (Split-Path $resolvedRoot -Parent) -Force
  $rootItem = Get-Item -LiteralPath $resolvedRoot -Force
  if (($parent.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
      ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "Refusing cleanup through a reparse-point smoke root: $resolvedRoot"
  }
  $marker = Join-Path $resolvedRoot ".desktop_updater_smoke_run.json"
  if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) {
    throw "Task-owned Windows smoke marker is missing: $marker"
  }
  $markerDocument = Get-Content -Raw -LiteralPath $marker | ConvertFrom-Json
  $expectedRunId = [IO.Path]::GetFileName($resolvedRoot) -replace '^duf-[dr]-', ''
  $expectedOwnerSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  if ([string]$markerDocument.runId -ne $expectedRunId -or
      [string]$markerDocument.configuration -notin @('Debug', 'Release') -or
      [string]$markerDocument.ownerSid -ne $expectedOwnerSid) {
    throw "Windows smoke ownership marker does not match $resolvedRoot"
  }
  if (-not $SkipNestedReparseCheck) {
    $nestedReparse = @(
      Get-ChildItem -LiteralPath $resolvedRoot -Recurse -Force -ErrorAction Stop |
        Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 }
    )
    if ($nestedReparse.Count -ne 0) {
      throw "Refusing recursive cleanup with nested reparse points: $resolvedRoot"
    }
  }
}

function Repair-WindowsSmokeCleanupAccess {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Root
  )

  if (-not (Test-Path -LiteralPath $Root)) {
    return
  }

  # A protected child can deny the recursive preflight before its own ACL is
  # repaired. Validate the task-owned root identity first, then walk one
  # directory at a time. Each child is checked for reparse status before it is
  # opened or repaired, and the full reparse guard runs again before removal.
  Assert-WindowsSmokeOwnedRoot -Root $Root -SkipNestedReparseCheck
  function Visit-WindowsSmokeCleanupDirectory {
    param(
      [Parameter(Mandatory = $true)]
      [string]$Path
    )

    $children = $null
    try {
      $children = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop)
    } catch {
      & takeown.exe /F $Path | Out-Null
      if ($LASTEXITCODE -ne 0) {
        throw "Windows smoke cleanup could not take ownership of $Path."
      }
      & icacls.exe $Path /grant '*S-1-5-32-544:(OI)(CI)F' /C | Out-Null
      if ($LASTEXITCODE -ne 0) {
        throw "Windows smoke cleanup could not grant Administrators access to $Path."
      }
      & icacls.exe $Path /grant '*S-1-5-18:(OI)(CI)F' /C | Out-Null
      if ($LASTEXITCODE -ne 0) {
        throw "Windows smoke cleanup could not grant SYSTEM access to $Path."
      }
      $children = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop)
    }

    foreach ($child in $children) {
      if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing recursive cleanup with nested reparse point: $($child.FullName)"
      }
      if ($child.PSIsContainer) {
        Visit-WindowsSmokeCleanupDirectory -Path $child.FullName
      }
    }
  }
  Visit-WindowsSmokeCleanupDirectory -Path $Root
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
  Assert-WindowsSmokeOwnedRoot -Root $Root
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
  $collectionWarnings = [Collections.Generic.List[string]]::new()
  foreach ($rawOutput in @($profileProbeOut, $profileProbeErr, $runnerOut, $runnerErr)) {
    if (-not (Test-Path -LiteralPath $rawOutput -PathType Leaf)) {
      continue
    }
    try {
      Copy-Item -LiteralPath $rawOutput `
        -Destination (Join-Path $evidenceRoot (
          "raw-" + [IO.Path]::GetFileName($rawOutput)
        )) -Force -ErrorAction Stop
    } catch {
      $collectionErrors.Add(
        (ConvertTo-WindowsSmokeEvidenceText "raw launch evidence copy: $($_.Exception.Message)")
      ) | Out-Null
    }
  }

  $eventRecords = @()
  try {
    $eventRecords = @(
      Get-WinEvent -FilterHashtable @{
        LogName = "Application"
        ProviderName = "DesktopUpdater.InstallHelper.ProtocolV1"
        StartTime = $helperEventStart
      } -ErrorAction Stop |
        Where-Object {
          $null -eq $_.RecordId -or
          [long]$_.RecordId -gt $helperEventBaselineRecordId
        } |
        Sort-Object TimeCreated, RecordId
    )
  } catch {
    $providerEventError = ConvertTo-WindowsSmokeEvidenceText $_.Exception.Message
    try {
      $eventRecords = @(
        Get-WinEvent -FilterHashtable @{
          LogName = "Application"
          StartTime = $helperEventStart
        } -ErrorAction Stop |
          Where-Object {
            $_.ProviderName -eq "DesktopUpdater.InstallHelper.ProtocolV1" -and
            ($null -eq $_.RecordId -or
              [long]$_.RecordId -gt $helperEventBaselineRecordId)
          } |
          Sort-Object TimeCreated, RecordId
      )
      $collectionWarnings.Add(
        "provider-filtered event log unavailable; fallback event query used: $providerEventError"
      ) | Out-Null
    } catch {
      $collectionErrors.Add(
        "provider-filtered event log: $providerEventError"
      ) | Out-Null
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

  $diagnosticEvents = @()
  $lifecycleEvents = @()
  $relaunchEvidenceObserved = $false
  $diagnosticGateFailures = [Collections.Generic.List[string]]::new()
  if (-not (Test-Path -LiteralPath $capturedDiagnostics -PathType Leaf)) {
    $collectionErrors.Add("helper diagnostics log is missing") | Out-Null
  } else {
    foreach ($line in @(Get-Content -LiteralPath $capturedDiagnostics -ErrorAction Stop)) {
      $normalizedLine = $line.Trim()
      if ([string]::IsNullOrWhiteSpace($normalizedLine)) {
        continue
      }
      if ($normalizedLine -match '^event=(checking|downloading|installing)$') {
        $lifecycleEvents += $Matches[1]
        continue
      }
      if ($normalizedLine -eq 'event=relaunch') {
        $relaunchEvidenceObserved = $true
        continue
      }
      if ($normalizedLine -match '^event=failed:') {
        $diagnosticGateFailures.Add(
          "Dart lifecycle failure event observed: $normalizedLine"
        ) | Out-Null
        continue
      }
      try {
        $diagnosticEvents += ,($normalizedLine | ConvertFrom-Json)
      } catch {
        $collectionErrors.Add(
          (ConvertTo-WindowsSmokeEvidenceText "helper diagnostics JSON: $($_.Exception.Message)")
        ) | Out-Null
      }
    }
  }
  $expectedLifecycleEvents = @("checking", "downloading", "installing")
  $lifecycleOrderMatches = $lifecycleEvents.Count -eq $expectedLifecycleEvents.Count
  if ($lifecycleOrderMatches) {
    for ($index = 0; $index -lt $expectedLifecycleEvents.Count; $index++) {
      if ([string]$lifecycleEvents[$index] -ne $expectedLifecycleEvents[$index]) {
        $lifecycleOrderMatches = $false
        break
      }
    }
  }
  if (-not $lifecycleOrderMatches) {
    $diagnosticGateFailures.Add(
      "helper lifecycle events did not match the expected ordered sequence"
    ) | Out-Null
  }
  $expectedDiagnosticEvents = @(
    'helper scheduled'
    'backup start'
    'move start'
    'cleanup success'
  )
  $diagnosticCursor = -1
  foreach ($expectedEvent in $expectedDiagnosticEvents) {
    $found = $false
    for ($index = $diagnosticCursor + 1; $index -lt $diagnosticEvents.Count; $index++) {
      if ([string]$diagnosticEvents[$index].event -eq $expectedEvent) {
        $diagnosticCursor = $index
        $found = $true
        break
      }
    }
    if (-not $found) {
      $diagnosticGateFailures.Add(
        "helper diagnostics missing ordered event: $expectedEvent"
      ) | Out-Null
    }
  }
  $failureEvents = @(
    $events | Where-Object {
      [int]$_.id -ge 1047 -and [int]$_.id -le 1059
    }
  )
  if ($failureEvents.Count -ne 0) {
    $diagnosticGateFailures.Add(
      "helper failure event IDs observed: $(@($failureEvents.id) -join ',')"
    ) | Out-Null
  }

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

  $standardUserFilesystemEvidence = $null
  if (-not (Test-Path -LiteralPath $standardUserFilesystemEvidencePath -PathType Leaf)) {
    $collectionErrors.Add("standard-user filesystem evidence is missing") | Out-Null
  } else {
    try {
      $candidateFilesystemEvidence = Get-Content -Raw `
        -LiteralPath $standardUserFilesystemEvidencePath -ErrorAction Stop |
        ConvertFrom-Json
      if ($null -eq $candidateFilesystemEvidence -or
          $null -eq $candidateFilesystemEvidence.filesystem) {
        throw "standard-user filesystem evidence document is incomplete"
      }
      if ($null -eq $smokeUser -or
          [string]$candidateFilesystemEvidence.userSid -ne $smokeUser.SID.Value) {
        throw "standard-user filesystem evidence SID does not match the disposable user"
      }
      $probeErrors = @(
        $candidateFilesystemEvidence.errors |
          Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
      )
      if ($probeErrors.Count -ne 0) {
        throw "standard-user filesystem probe reported errors: $($probeErrors -join '; ')"
      }
      $standardUserFilesystemEvidence = $candidateFilesystemEvidence
    } catch {
      $collectionErrors.Add(
        (ConvertTo-WindowsSmokeEvidenceText "standard-user filesystem evidence: $($_.Exception.Message)")
      ) | Out-Null
    }
  }

  $recoveryActive = $activeProcesses.Count -ne 0 -or @(
    $tasks | Where-Object { $_.state -eq "Running" }
  ).Count -ne 0
  $filesystem = [PSCustomObject]@{
    diagnosticsExists = Test-Path -LiteralPath $capturedDiagnostics -PathType Leaf
    installExists = $null
    sentinelExists = $null
    expectedVersion = $expectedSmokeVersion
    installedVersion = $null
    expectedAppSha256 = $expectedAppSha256
    installedAppSha256 = $null
    expectedHelperSha256 = $expectedHelperSha256
    installedHelperSha256 = $null
    marker = $null
    recoveryRootExists = $false
    skippedReason = if ($recoveryActive) { "helper-or-recovery-active" } else { $null }
    topLevelSmokeEntries = @()
    topLevelUserTempEntries = @()
  }
  $recoveryRecords = @()
  if (-not $recoveryActive) {
    if ($null -ne $standardUserFilesystemEvidence) {
      $probeFilesystem = $standardUserFilesystemEvidence.filesystem
      $filesystem.installExists = $probeFilesystem.installExists
      $filesystem.sentinelExists = $probeFilesystem.sentinelExists
      $filesystem.installedVersion = $probeFilesystem.installedVersion
      $filesystem.installedAppSha256 = $probeFilesystem.installedAppSha256
      $filesystem.installedHelperSha256 = $probeFilesystem.installedHelperSha256
      $filesystem.marker = $probeFilesystem.marker
      $filesystem.recoveryRootExists = $probeFilesystem.recoveryRootExists
      $recoveryRecords = @(
        $standardUserFilesystemEvidence.recoveryRecords |
          Where-Object { $null -ne $_ }
      )
    } else {
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
        $versionPath = Join-Path $install ".desktop_updater_smoke_version.txt"
        if (Test-Path -LiteralPath $versionPath -PathType Leaf) {
          $filesystem.installedVersion = (Get-Content -Raw -LiteralPath $versionPath).Trim()
        }
        $installedAppPath = Join-Path $install "desktop_updater_example.exe"
        $installedHelperPath = Join-Path $install "desktop_updater_install_helper.exe"
        if (Test-Path -LiteralPath $installedAppPath -PathType Leaf) {
          $filesystem.installedAppSha256 = (
            Get-FileHash -LiteralPath $installedAppPath -Algorithm SHA256
          ).Hash.ToLowerInvariant()
        }
        if (Test-Path -LiteralPath $installedHelperPath -PathType Leaf) {
          $filesystem.installedHelperSha256 = (
            Get-FileHash -LiteralPath $installedHelperPath -Algorithm SHA256
          ).Hash.ToLowerInvariant()
        }
        if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
          $filesystem.marker = (Get-Content -Raw -LiteralPath $markerPath).Trim()
        }
      } catch {
        $collectionErrors.Add(
          (ConvertTo-WindowsSmokeEvidenceText "version/hash/stage probe: $($_.Exception.Message)")
        ) | Out-Null
      }
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

    if ($null -eq $standardUserFilesystemEvidence -and
        -not [string]::IsNullOrWhiteSpace($smokeLocalAppData)) {
      $recoveryRoot = Join-Path $smokeLocalAppData "desktop_updater_portable_transactions_v1"
      try {
        if (Test-Path -LiteralPath $recoveryRoot -PathType Container) {
          $filesystem.recoveryRootExists = $true
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
          $filesystem.recoveryRootExists = $false
        }
      } catch {
        $collectionErrors.Add(
          (ConvertTo-WindowsSmokeEvidenceText "recovery records: $($_.Exception.Message)")
        ) | Out-Null
      }
    }
  }

  $activeRecoveryRecords = @(
    foreach ($recoveryRecord in $recoveryRecords) {
      if ($null -eq $recoveryRecord.content) {
        $recoveryRecord
        continue
      }
      $leafName = Split-Path -Leaf ([string]$recoveryRecord.relativePath)
      try {
        $recordDocument = [string]$recoveryRecord.content | ConvertFrom-Json
        if ($leafName -eq "record.json") {
          if ([string]$recordDocument.recordState -notin @("completed", "rolledBack") -or
              [string]$recordDocument.relaunchState -notin @("launched", "notRequested")) {
            $recoveryRecord
          }
        } elseif ($leafName -eq "resolver_claim.json") {
          if ([string]$recordDocument.state -ne "consumed") {
            $recoveryRecord
          }
        } elseif ($leafName -in @("record.next", "resolver_claim.next", "locator.next")) {
          $recoveryRecord
        } elseif ($leafName -ne "locator.json") {
          $recoveryRecord
        }
      } catch {
        $recoveryRecord
      }
    }
  )

  $hardEvidenceFailures = [Collections.Generic.List[string]]::new()
  foreach ($collectionError in $collectionErrors) {
    $hardEvidenceFailures.Add("collection error: $collectionError") | Out-Null
  }
  if ($activeProcesses.Count -ne 0) {
    $hardEvidenceFailures.Add("unexpected active process evidence") | Out-Null
  }
  if (@($tasks | Where-Object { $_.state -eq "Running" }).Count -ne 0) {
    $hardEvidenceFailures.Add("unexpected active scheduled task evidence") | Out-Null
  }
  if (-not $filesystem.diagnosticsExists) {
    $hardEvidenceFailures.Add("helper diagnostics file is missing") | Out-Null
  }
  if (-not $relaunchEvidenceObserved) {
    $hardEvidenceFailures.Add("Dart relaunch evidence event is missing") | Out-Null
  }
  if (-not $filesystem.installExists -or -not $filesystem.sentinelExists) {
    $hardEvidenceFailures.Add("installed payload or sentinel evidence is missing") | Out-Null
  }
  if ($filesystem.installedVersion -ne $expectedSmokeVersion) {
    $hardEvidenceFailures.Add(
      "expected version $expectedSmokeVersion, observed $($filesystem.installedVersion)"
    ) | Out-Null
  }
  if ($filesystem.installedAppSha256 -ne $expectedAppSha256) {
    $hardEvidenceFailures.Add("installed app hash does not match the signed source app") | Out-Null
  }
  if ($filesystem.installedHelperSha256 -ne $expectedHelperSha256) {
    $hardEvidenceFailures.Add("installed helper hash does not match the signed source helper") | Out-Null
  }
  if ($filesystem.marker -ne "installing") {
    $hardEvidenceFailures.Add("install stage marker is not installing") | Out-Null
  }
  if ($activeRecoveryRecords.Count -ne 0) {
    $hardEvidenceFailures.Add("active recovery state remained after controller cleanup") | Out-Null
  }
  foreach ($diagnosticGateFailure in $diagnosticGateFailures) {
    $hardEvidenceFailures.Add($diagnosticGateFailure) | Out-Null
  }

  $report = [PSCustomObject]@{
    activeProcesses = $activeProcesses
    applicationEventBaselineRecordId = $helperEventBaselineRecordId
    capturedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    collectionErrors = @($collectionErrors)
    collectionWarnings = @($collectionWarnings)
    configuration = $Configuration
    events = $events
    diagnosticEvents = $diagnosticEvents
    filesystem = $filesystem
    hardEvidenceGate = [PSCustomObject]@{
      passed = $hardEvidenceFailures.Count -eq 0
      failures = @($hardEvidenceFailures)
    }
    helperEventStartUtc = $helperEventStart.ToUniversalTime().ToString("o")
    lifecycleEvents = $lifecycleEvents
    relaunchEvidenceObserved = $relaunchEvidenceObserved
    prelaunchAcls = $prelaunchAcls
    primaryFailure = ConvertTo-WindowsSmokeEvidenceText $primaryFailure
    recoveryRecords = $recoveryRecords
    runId = $smokeRunId
    runner = [PSCustomObject]@{
      exitCode = if ($null -ne $smokeProcess) { $smokeProcess.ExitCode } else { $null }
      processId = $outerRunnerProcessId
      timeoutSeconds = $smokeRunnerTimeoutSeconds
      workingDirectory = ConvertTo-WindowsSmokeEvidenceText $runnerWorkingDirectory
    }
    schemaVersion = 1
    standardUserFilesystemEvidence = $standardUserFilesystemEvidence
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
      [PSCustomObject]@{ name = "helper-diagnostics.jsonl"; path = $capturedDiagnostics },
      [PSCustomObject]@{ name = "standard-user-filesystem-evidence.json"; path = $standardUserFilesystemEvidencePath },
      [PSCustomObject]@{ name = "standard-user-filesystem-probe.out"; path = $standardUserFilesystemProbeOut },
      [PSCustomObject]@{ name = "standard-user-filesystem-probe.err"; path = $standardUserFilesystemProbeErr }
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
  if ($hardEvidenceFailures.Count -ne 0) {
    throw "Windows $Configuration Flutter smoke hard evidence gate failed: $($hardEvidenceFailures -join '; ')"
  }
}

try {
  if (Test-Path -LiteralPath $smokeRoot) {
    throw "Unique Windows Flutter smoke root already exists: $smokeRoot"
  }
  New-Item -ItemType Directory -Path $smokeRoot -Force | Out-Null
  [IO.File]::WriteAllText(
    $smokeRootOwnershipMarker,
    (@{
      runId = $smokeRunId
      configuration = $Configuration
      ownerSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
      createdAtUtc = [DateTimeOffset]::UtcNow.ToString("o")
    } | ConvertTo-Json -Compress),
    [Text.UTF8Encoding]::new($false)
  )
  Copy-Item -LiteralPath $runnerRoot -Destination $install -Recurse -Force
  [IO.File]::WriteAllText(
    (Join-Path $install ".desktop_updater_smoke_version.txt"),
    $expectedSmokeVersion + [Environment]::NewLine,
    [Text.UTF8Encoding]::new($false)
  )

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
          Get-WindowsSmokeCertificateSha256 $_.RawData
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
  & icacls.exe $smokeRoot /grant "*$($smokeUser.SID.Value):F" /C | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "Windows Flutter smoke account could not read its disposable lane root."
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
    DESKTOP_UPDATER_SMOKE_EXPECTED_VERSION = $expectedSmokeVersion
    DESKTOP_UPDATER_SMOKE_EXPECTED_SIGNER_SHA256 = $trustCertificateSha256
    DESKTOP_UPDATER_SMOKE_EXPECTED_SIGNER_PUBLISHER = $trustCertificatePublisher
    DESKTOP_UPDATER_SMOKE_EXPECTED_APP_SHA256 = $expectedAppSha256
    DESKTOP_UPDATER_SMOKE_EXPECTED_HELPER_SHA256 = $expectedHelperSha256
    DESKTOP_UPDATER_SMOKE_FILESYSTEM_EVIDENCE = $standardUserFilesystemEvidencePath
    DESKTOP_UPDATER_SMOKE_FILESYSTEM_INSTALL_ROOT = $install
    DESKTOP_UPDATER_SMOKE_FILESYSTEM_RECOVERY_ROOT = Join-Path $smokeLocalAppData "desktop_updater_portable_transactions_v1"
    DESKTOP_UPDATER_SMOKE_MARKER = $markerPath
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
  $startProcessSupportsEnvironment = @(
    (Get-Command -Name Start-Process -ErrorAction Stop).Parameters.Keys
  ) -contains 'Environment'
  function Quote-WindowsSmokePowerShellArgument([string] $Value) {
    return "'" + ($Value -replace "'", "''") + "'"
  }
  function New-WindowsSmokeEnvironmentLauncher(
    [string] $LauncherPath,
    [string] $TargetPath,
    [string[]] $TargetArguments
  ) {
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add('$ErrorActionPreference = "Stop"')
    foreach ($entry in $smokeEnvironment.GetEnumerator()) {
      $lines.Add(
        ('$env:{0} = {1}' -f
          $entry.Key,
          (Quote-WindowsSmokePowerShellArgument ([string]$entry.Value)))
      )
    }
    $lines.Add('$ErrorActionPreference = "Continue"')
    $quotedArgumentArray = @(
      $TargetArguments |
        ForEach-Object {
          Quote-WindowsSmokePowerShellArgument ([string]$_)
        }
    ) -join ', '
    $lines.Add(
      ('$nativeStdoutPath = Join-Path $PSScriptRoot ("launcher-stdout-{0}.out")' -f
        [Guid]::NewGuid().ToString("N"))
    )
    $lines.Add(
      ('$nativeStderrPath = Join-Path $PSScriptRoot ("launcher-stderr-{0}.err")' -f
        [Guid]::NewGuid().ToString("N"))
    )
    $targetPathLiteral = Quote-WindowsSmokePowerShellArgument $TargetPath
    $lines.Add(
      ('$targetProcess = Start-Process -FilePath ' + $targetPathLiteral +
        ' -ArgumentList @(' + $quotedArgumentArray + ') ' +
        '-WorkingDirectory $PSScriptRoot -RedirectStandardOutput ' +
        '$nativeStdoutPath -RedirectStandardError $nativeStderrPath -Wait -PassThru')
    )
    $lines.Add(
      'if (Test-Path -LiteralPath $nativeStdoutPath -PathType Leaf) {' +
      ' Get-Content -LiteralPath $nativeStdoutPath | ForEach-Object {' +
      ' [Console]::Out.WriteLine($_) } }'
    )
    $lines.Add(
      'if (Test-Path -LiteralPath $nativeStderrPath -PathType Leaf) {' +
      ' Get-Content -LiteralPath $nativeStderrPath | ForEach-Object {' +
      ' [Console]::Error.WriteLine($_) } }'
    )
    $lines.Add('$exitCode = $targetProcess.ExitCode')
    $lines.Add('exit $exitCode')
    [IO.File]::WriteAllText(
      $LauncherPath,
      ($lines -join [Environment]::NewLine) + [Environment]::NewLine,
      [Text.UTF8Encoding]::new($false)
    )
  }
  $smokePasswordText = $null
  $profileProbeOut = Join-Path $smokeRoot "profile-probe.out"
  $profileProbeErr = Join-Path $smokeRoot "profile-probe.err"
  $profileProbeScript = @(
    '$ErrorActionPreference = "Stop"'
    'function Get-DesktopUpdaterSha256([byte[]] $RawData) {'
    '  $algorithm = [Security.Cryptography.SHA256]::Create()'
    '  try {'
    '    return ([BitConverter]::ToString($algorithm.ComputeHash($RawData)) -replace "-", "").ToLowerInvariant()'
    '  } finally {'
    '    $algorithm.Dispose()'
    '  }'
    '}'
    'function Assert-DisposableTrustCertificate {'
    '  param('
    '    [Parameter(Mandatory = $true)] [string] $StoreName,'
    '    [Parameter(Mandatory = $true)] [string] $ExpectedSha256,'
    '    [Parameter(Mandatory = $true)] [string] $ExpectedPublisher'
    '  )'
    '  $storePath = "Cert:\CurrentUser\" + $StoreName'
    '  $matches = @('
    '    Get-ChildItem -LiteralPath $storePath -ErrorAction Stop |'
    '      Where-Object {'
    '        (Get-DesktopUpdaterSha256 $_.RawData) -eq $ExpectedSha256 -and'
    '          $_.GetNameInfo('
    '            [Security.Cryptography.X509Certificates.X509NameType]::SimpleName,'
    '            $false'
    '          ) -eq $ExpectedPublisher'
    '      }'
    '  )'
    '  if ($matches.Count -ne 1) {'
    '    throw "disposable CurrentUser trust store postcondition failed for $StoreName."'
    '  }'
    '  if ($matches[0].HasPrivateKey) {'
    '    throw "disposable CurrentUser trust store unexpectedly contains a private key."'
    '  }'
    '}'
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
    '    $certificateSha256 = Get-DesktopUpdaterSha256 $certificate.RawData'
    '    $publisher = $certificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)'
    '    if ($certificateSha256 -ne $expectedCertificateSha256 -or $publisher -ne $expectedPublisher) {'
    '      throw "Disposable trust certificate identity changed."'
    '    }'
    '    $storeNames = @("TrustedPublisher")'
    '    if ($env:DESKTOP_UPDATER_SMOKE_SIGNER_SELF_SIGNED -eq "1") {'
    '      $storeNames = @("Root", "TrustedPublisher")'
    '    }'
    '    foreach ($storeName in $storeNames) {'
    '      $certutilStdoutPath = Join-Path $localAppData ("desktop-updater-certutil-{0}.out" -f [Guid]::NewGuid().ToString("N"))'
    '      $certutilStderrPath = Join-Path $localAppData ("desktop-updater-certutil-{0}.err" -f [Guid]::NewGuid().ToString("N"))'
    '      $certutilProcess = Start-Process -FilePath "certutil.exe" -ArgumentList @('
    '        "-user",'
    '        "-f",'
    '        "-addstore",'
    '        $storeName,'
    '        $certificatePath'
    '      ) -WindowStyle Normal -RedirectStandardOutput $certutilStdoutPath -RedirectStandardError $certutilStderrPath -Wait -PassThru'
    '      $certutilExit = $certutilProcess.ExitCode'
    '      $certutilOutput = @('
    '        Get-Content -LiteralPath $certutilStdoutPath -ErrorAction SilentlyContinue'
    '        Get-Content -LiteralPath $certutilStderrPath -ErrorAction SilentlyContinue'
    '      )'
    '      try {'
    '        Assert-DisposableTrustCertificate -StoreName $storeName -ExpectedSha256 $expectedCertificateSha256 -ExpectedPublisher $expectedPublisher'
    '      } catch {'
    '        if ($certutilExit -ne 0) {'
    '          throw "certutil failed to add disposable CurrentUser trust to $storeName (exit $certutilExit) and the store postcondition was not met`: $certutilOutput"'
    '        }'
    '        throw'
    '      }'
    '      if ($certutilExit -ne 0) {'
    '        Write-Warning "certutil returned exit $certutilExit after the exact disposable CurrentUser trust postcondition passed for $storeName`: $certutilOutput"'
    '      }'
    '      Assert-DisposableTrustCertificate -StoreName $storeName -ExpectedSha256 $expectedCertificateSha256 -ExpectedPublisher $expectedPublisher'
    '    }'
    '    $helperSignature = Get-AuthenticodeSignature -LiteralPath $signedHelper'
    '    if ($helperSignature.Status -ne "Valid" -or $null -eq $helperSignature.SignerCertificate) {'
    '      throw "Disposable user does not trust the signed helper."'
    '    }'
    '    $helperCertificateSha256 = Get-DesktopUpdaterSha256 $helperSignature.SignerCertificate.RawData'
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
  $standardUserFilesystemProbeScript = @(
    '$ErrorActionPreference = "Stop"'
    '$evidencePath = $env:DESKTOP_UPDATER_SMOKE_FILESYSTEM_EVIDENCE'
    '$installRoot = $env:DESKTOP_UPDATER_SMOKE_FILESYSTEM_INSTALL_ROOT'
    '$recoveryRoot = $env:DESKTOP_UPDATER_SMOKE_FILESYSTEM_RECOVERY_ROOT'
    '$markerPath = $env:DESKTOP_UPDATER_SMOKE_MARKER'
    '$recoveryNames = @('
    '  "record.json"'
    '  "record.next"'
    '  "resolver_claim.json"'
    '  "resolver_claim.next"'
    '  "locator.json"'
    '  "locator.next"'
    ')'
    '$errors = [Collections.Generic.List[string]]::new()'
    '$recoveryRecords = [Collections.Generic.List[object]]::new()'
    'function Add-ProbeError([string] $Message) {'
    '  if (-not [string]::IsNullOrWhiteSpace($Message)) {'
    '    $errors.Add($Message) | Out-Null'
    '  }'
    '}'
    'function Get-ProbeSha256([string] $Path) {'
    '  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()'
    '}'
    'function Read-RecoveryDirectory {'
    '  param('
    '    [Parameter(Mandatory = $true)] [string] $Path,'
    '    [Parameter(Mandatory = $true)] [string] $RelativePath,'
    '    [Parameter(Mandatory = $true)] [int] $Depth'
    '  )'
    '  if ($recoveryRecords.Count -ge 32) {'
    '    return'
    '  }'
    '  foreach ($child in @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop)) {'
    '    if ($recoveryRecords.Count -ge 32) {'
    '      return'
    '    }'
    '    if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {'
    '      Add-ProbeError ("recovery tree contains a reparse point: {0}" -f $RelativePath)'
    '      continue'
    '    }'
    '    $childRelativePath = Join-Path $RelativePath $child.Name'
    '    if ($child.PSIsContainer) {'
    '      if ($Depth -lt 3) {'
    '        Read-RecoveryDirectory -Path $child.FullName -RelativePath $childRelativePath -Depth ($Depth + 1)'
    '      }'
    '      continue'
    '    }'
    '    if ($recoveryNames -notcontains $child.Name) {'
    '      continue'
    '    }'
    '    try {'
    '      if ($child.Length -gt 1048576) {'
    '        throw "recovery record exceeds 1048576 bytes"'
    '      }'
    '      $content = [IO.File]::ReadAllText($child.FullName, [Text.UTF8Encoding]::new($false, $false))'
    '      $recoveryRecords.Add([PSCustomObject]@{'
    '        content = $content'
    '        error = $null'
    '        relativePath = $childRelativePath'
    '      }) | Out-Null'
    '    } catch {'
    '      $message = $_.Exception.Message'
    '      $recoveryRecords.Add([PSCustomObject]@{'
    '        content = $null'
    '        error = $message'
    '        relativePath = $childRelativePath'
    '      }) | Out-Null'
    '      Add-ProbeError ("recovery record read: {0}" -f $message)'
    '    }'
    '  }'
    '}'
    '$filesystem = [ordered]@{'
    '  installExists = $false'
    '  sentinelExists = $false'
    '  installedVersion = $null'
    '  installedAppSha256 = $null'
    '  installedHelperSha256 = $null'
    '  marker = $null'
    '  recoveryRootExists = $false'
    '}'
    '$userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value'
    'try {'
    '  if ([string]::IsNullOrWhiteSpace($installRoot)) {'
    '    throw "standard-user install root is unavailable"'
    '  }'
    '  $installItem = Get-Item -LiteralPath $installRoot -Force -ErrorAction Stop'
    '  if (-not $installItem.PSIsContainer) {'
    '    throw "standard-user install root is not a directory"'
    '  }'
    '  $filesystem.installExists = $true'
    '  $sentinelPath = Join-Path $installRoot "desktop_updater_smoke.txt"'
    '  $sentinelItem = Get-Item -LiteralPath $sentinelPath -Force -ErrorAction Stop'
    '  if ($sentinelItem.PSIsContainer) {'
    '    throw "standard-user smoke sentinel is not a file"'
    '  }'
    '  $filesystem.sentinelExists = $true'
    '  $versionPath = Join-Path $installRoot ".desktop_updater_smoke_version.txt"'
    '  $filesystem.installedVersion = (Get-Content -Raw -LiteralPath $versionPath -ErrorAction Stop).Trim()'
    '  $filesystem.installedAppSha256 = Get-ProbeSha256 (Join-Path $installRoot "desktop_updater_example.exe")'
    '  $filesystem.installedHelperSha256 = Get-ProbeSha256 (Join-Path $installRoot "desktop_updater_install_helper.exe")'
    '  $filesystem.marker = (Get-Content -Raw -LiteralPath $markerPath -ErrorAction Stop).Trim()'
    '} catch {'
    '  Add-ProbeError $_.Exception.Message'
    '}'
    'try {'
    '  if (-not [string]::IsNullOrWhiteSpace($recoveryRoot)) {'
    '    try {'
    '      $recoveryItem = Get-Item -LiteralPath $recoveryRoot -Force -ErrorAction Stop'
    '      if (-not $recoveryItem.PSIsContainer) {'
    '        throw "standard-user recovery root is not a directory"'
    '      }'
    '      $filesystem.recoveryRootExists = $true'
    '      Read-RecoveryDirectory -Path $recoveryRoot -RelativePath "..." -Depth 0'
    '    } catch {'
    '      if ($_.Exception.Message -notmatch "Cannot find path|cannot find the path|PathNotFound") {'
    '        Add-ProbeError $_.Exception.Message'
    '      }'
    '    }'
    '  }'
    '} catch {'
    '  Add-ProbeError $_.Exception.Message'
    '}'
    '$document = [ordered]@{'
    '  capturedAtUtc = [DateTimeOffset]::UtcNow.ToString("o")'
    '  userSid = $userSid'
    '  errors = @($errors)'
    '  filesystem = [PSCustomObject]$filesystem'
    '  recoveryRecords = @($recoveryRecords)'
    '}'
    'try {'
    '  $document | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $evidencePath -Encoding utf8 -ErrorAction Stop'
    '} catch {'
    '  Write-Error ("standard-user filesystem evidence write failed: {0}" -f $_.Exception.Message)'
    '  exit 1'
    '}'
    'if ($errors.Count -ne 0) {'
    '  Write-Error ("standard-user filesystem evidence reported errors: {0}" -f ($errors -join "; "))'
    '  exit 1'
    '}'
    'Write-Output "Windows Flutter smoke standard-user filesystem evidence captured."'
    'exit 0'
  ) -join [Environment]::NewLine
  [IO.File]::WriteAllText(
    $standardUserFilesystemProbePath,
    $standardUserFilesystemProbeScript,
    [Text.UTF8Encoding]::new($false)
  )
  # The owner/high driver may be hosted from a private AppData path that the
  # disposable standard user cannot execute. Use the system-owned Windows
  # PowerShell host for the profile/trust probe instead of leaking the driver
  # host path across the account boundary.
  $profileProbeShell = Join-Path $env:SystemRoot `
    'System32\WindowsPowerShell\v1.0\powershell.exe'
  if (-not (Test-Path -LiteralPath $profileProbeShell -PathType Leaf)) {
    throw "Windows PowerShell profile probe host is missing: $profileProbeShell"
  }
  $originalTemp = $env:TEMP
  $originalTmp = $env:TMP
  try {
    $env:TEMP = $userTemp
    $env:TMP = $userTemp
    $profileProbeArguments = @(
      "-NoLogo",
      "-NoProfile"
    )
    if (-not $ProvisionDisposableUserTrust) {
      $profileProbeArguments += "-NonInteractive"
    }
    $profileProbeArguments += @(
      "-ExecutionPolicy",
      "Bypass",
      "-File", $profileProbePath
    )
    $profileProbeLauncherPath = Join-Path $smokeRoot "profile-probe-launcher.ps1"
    $runnerLauncherPath = Join-Path $smokeRoot "runner-launcher.ps1"
    $standardUserFilesystemLauncherPath = Join-Path `
      $smokeRoot "standard-user-filesystem-launcher.ps1"
    if (-not $startProcessSupportsEnvironment) {
      New-WindowsSmokeEnvironmentLauncher `
        -LauncherPath $profileProbeLauncherPath `
        -TargetPath $profileProbeShell `
        -TargetArguments $profileProbeArguments
      New-WindowsSmokeEnvironmentLauncher `
        -LauncherPath $runnerLauncherPath `
        -TargetPath $smokeRunner `
        -TargetArguments @(
          "--app", $installedApp,
          "--diagnostics-log", $capturedDiagnostics
        )
      New-WindowsSmokeEnvironmentLauncher `
        -LauncherPath $standardUserFilesystemLauncherPath `
        -TargetPath $profileProbeShell `
        -TargetArguments @(
          "-NoLogo",
          "-NoProfile",
          "-NonInteractive",
          "-ExecutionPolicy",
          "Bypass",
          "-File", $standardUserFilesystemProbePath
        )
    }
    $profileProbeWindowStyle = if ($ProvisionDisposableUserTrust) {
      [Diagnostics.ProcessWindowStyle]::Normal
    } else {
      [Diagnostics.ProcessWindowStyle]::Hidden
    }
    if ($startProcessSupportsEnvironment) {
      $profileProbeProcess = Start-Process -FilePath $profileProbeShell `
        -ArgumentList $profileProbeArguments `
        -Credential $smokeCredential -LoadUserProfile `
        -Environment $smokeEnvironment -WorkingDirectory $smokeRoot `
        -WindowStyle $profileProbeWindowStyle `
        -RedirectStandardOutput $profileProbeOut `
        -RedirectStandardError $profileProbeErr -Wait -PassThru
    } else {
      $profileProbeProcess = Start-Process -FilePath $profileProbeShell `
        -ArgumentList @(
          "-NoLogo",
          "-NoProfile",
          "-ExecutionPolicy",
          "Bypass",
          "-File", $profileProbeLauncherPath
        ) -Credential $smokeCredential -LoadUserProfile `
        -WorkingDirectory $smokeRoot `
        -WindowStyle $profileProbeWindowStyle `
        -RedirectStandardOutput $profileProbeOut `
        -RedirectStandardError $profileProbeErr -Wait -PassThru
    }
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
    try {
      $applicationBaseline = Get-WinEvent -LogName "Application" -MaxEvents 1 `
        -ErrorAction Stop
      if ($null -eq $applicationBaseline -or
          $null -eq $applicationBaseline.RecordId) {
        throw "Application Event Log baseline did not expose a RecordId."
      }
      $helperEventBaselineRecordId = [long]$applicationBaseline.RecordId
    } catch {
      throw "Application Event Log baseline capture failed: $($_.Exception.Message)"
    }
    # Keeping the outer sentinel waiter inside $install pins that directory on
    # Windows and prevents the helper from atomically replacing it after exit.
    if ($startProcessSupportsEnvironment) {
      $smokeProcess = Start-Process -FilePath $smokeRunner -ArgumentList @(
        "--app", $installedApp,
        "--diagnostics-log", $capturedDiagnostics
      ) -Credential $smokeCredential -LoadUserProfile `
        -Environment $smokeEnvironment -WorkingDirectory $runnerWorkingDirectory `
        -RedirectStandardOutput $runnerOut -RedirectStandardError $runnerErr `
        -PassThru
    } else {
      $smokeProcess = Start-Process -FilePath $profileProbeShell `
        -ArgumentList @(
          "-NoLogo",
          "-NoProfile",
          "-ExecutionPolicy",
          "Bypass",
          "-File", $runnerLauncherPath
        ) -Credential $smokeCredential -LoadUserProfile `
        -WorkingDirectory $runnerWorkingDirectory `
        -RedirectStandardOutput $runnerOut -RedirectStandardError $runnerErr `
        -Wait -PassThru
    }
  } finally {
    $env:TEMP = $originalTemp
    $env:TMP = $originalTmp
  }
  if (-not $smokeProcess.HasExited) {
    Wait-Process -Id $smokeProcess.Id `
      -Timeout $smokeRunnerTimeoutSeconds `
      -ErrorAction Stop | Out-Null
    $smokeProcess.Refresh()
    if (-not $smokeProcess.HasExited) {
      $timedOutProcessId = [int]$smokeProcess.Id
      Stop-ExactProcessTree -RootProcessId $timedOutProcessId
      throw "Windows $Configuration Flutter smoke runner timed out after $smokeRunnerTimeoutSeconds seconds; exact root PID $timedOutProcessId was stopped."
    }
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
  Stop-WindowsSmokeRelaunchProcess -ExecutablePath $installedApp
  if ($startProcessSupportsEnvironment) {
    $standardUserFilesystemProbeProcess = Start-Process `
      -FilePath $profileProbeShell `
      -ArgumentList @(
        "-NoLogo",
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy",
        "Bypass",
        "-File", $standardUserFilesystemProbePath
      ) -Credential $smokeCredential -LoadUserProfile `
      -Environment $smokeEnvironment -WorkingDirectory $smokeRoot `
      -WindowStyle Hidden `
      -RedirectStandardOutput $standardUserFilesystemProbeOut `
      -RedirectStandardError $standardUserFilesystemProbeErr -Wait -PassThru
  } else {
    $standardUserFilesystemProbeProcess = Start-Process `
      -FilePath $profileProbeShell `
      -ArgumentList @(
        "-NoLogo",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File", $standardUserFilesystemLauncherPath
      ) -Credential $smokeCredential -LoadUserProfile `
      -WorkingDirectory $smokeRoot `
      -WindowStyle Hidden `
      -RedirectStandardOutput $standardUserFilesystemProbeOut `
      -RedirectStandardError $standardUserFilesystemProbeErr -Wait -PassThru
  }
  foreach ($filesystemProbeOutputPath in @(
      $standardUserFilesystemProbeOut,
      $standardUserFilesystemProbeErr
    )) {
    if (Test-Path -LiteralPath $filesystemProbeOutputPath -PathType Leaf) {
      Write-Host (Read-WindowsSmokeSharedText $filesystemProbeOutputPath)
    }
  }
  if ($standardUserFilesystemProbeProcess.ExitCode -ne 0) {
    throw "Windows $Configuration Flutter smoke standard-user filesystem evidence probe failed."
  }
  if (-not (Test-Path -LiteralPath $standardUserFilesystemEvidencePath -PathType Leaf)) {
    throw "Windows $Configuration Flutter smoke standard-user filesystem evidence is unavailable."
  }
  $smokeSucceeded = $true
} catch {
  $primaryFailure = $_.Exception.ToString()
  throw
} finally {
  $cleanupFailures = [Collections.Generic.List[string]]::new()
  if ($null -ne $smokeProcess) {
    try {
      $smokeProcess.Refresh()
      if (-not $smokeProcess.HasExited) {
        Stop-ExactProcessTree -RootProcessId ([int]$smokeProcess.Id)
      }
    } catch {
      $cleanupMessage = "Windows Flutter smoke runner process-tree cleanup failed: $($_.Exception.Message)"
      $cleanupFailures.Add($cleanupMessage) | Out-Null
      Write-Warning (ConvertTo-WindowsSmokeEvidenceText $cleanupMessage)
    }
    try {
      Stop-WindowsSmokeRelaunchProcess -ExecutablePath $installedApp
    } catch {
      $cleanupMessage = "Windows Flutter smoke relaunch cleanup failed: $($_.Exception.Message)"
      $cleanupFailures.Add($cleanupMessage) | Out-Null
      Write-Warning (ConvertTo-WindowsSmokeEvidenceText $cleanupMessage)
    }
  }
  $evidenceCaptureFailure = $null
  try {
    # Capture while the owned filesystem still exists, after the relaunch
    # process has been stopped. The later account/profile/root cleanup is
    # recorded separately and cannot erase the primary evidence.
    Save-WindowsFlutterSmokeEvidence
  } catch {
    $evidenceCaptureFailure = $_.Exception.ToString()
    Write-Warning (ConvertTo-WindowsSmokeEvidenceText "Windows Flutter smoke evidence capture failed: $evidenceCaptureFailure")
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
  $smokeUserRemaining = $false
  if ($smokeUserCreated -and $null -ne $smokeUser) {
    $smokeUserRemaining = $null -ne (
      Get-LocalUser -Name $smokeUser.Name -ErrorAction SilentlyContinue
    )
    if ($smokeUserRemaining) {
      $cleanupMessage = "Windows Flutter smoke account remains after cleanup: $($smokeUser.Name)"
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
  New-Item -ItemType Directory -Path $evidenceRoot -Force | Out-Null
  [ordered]@{
    capturedAtUtc = [DateTimeOffset]::UtcNow.ToString("o")
    passed = $cleanupFailures.Count -eq 0
    failures = @($cleanupFailures)
    smokeRootExists = Test-Path -LiteralPath $smokeRoot
    smokeUserRemoved = -not $smokeUserRemaining
  } | ConvertTo-Json -Depth 6 | Set-Content `
    -LiteralPath (Join-Path $evidenceRoot "cleanup.json") -Encoding utf8
  if ($smokeSucceeded -and $cleanupFailures.Count -ne 0) {
    throw "Windows Flutter smoke succeeded but cleanup failed."
  }
  if ($smokeSucceeded -and $null -ne $evidenceCaptureFailure) {
    throw "Windows Flutter smoke succeeded but evidence integrity failed: $evidenceCaptureFailure"
  }
}
