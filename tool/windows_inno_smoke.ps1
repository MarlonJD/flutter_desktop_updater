[CmdletBinding()]
param(
  [string] $IsccPath,
  [string] $SigntoolPath,
  [Parameter(Mandatory)]
  [ValidatePattern('^[0-9A-Fa-f]{40}$')]
  [string] $SigningCertificateSha1,
  [Parameter(Mandatory)]
  [ValidatePattern('^[0-9A-Fa-f]{64}$')]
  [string] $SigningCertificateSha256,
  [Parameter(Mandatory)]
  [string] $SigningPublisher,
  [ValidatePattern('^[0-9A-Fa-f]{32}$')]
  [string] $ReplayRunToken,
  [switch] $KeepArtifacts
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-YamlSingleQuoted([string] $Value) {
  return "'" + $Value.Replace("'", "''") + "'"
}

function Invoke-Checked(
  [string] $FilePath,
  [string[]] $ArgumentList,
  [string] $WorkingDirectory
) {
  Push-Location $WorkingDirectory
  try {
    & $FilePath @ArgumentList | Out-Host
    if ($LASTEXITCODE -ne 0) {
      throw "$FilePath failed with exit code $LASTEXITCODE."
    }
  } finally {
    Pop-Location
  }
}

function Wait-Until(
  [scriptblock] $Condition,
  [int] $TimeoutSeconds,
  [string] $FailureMessage
) {
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  do {
    if (& $Condition) {
      return
    }
    Start-Sleep -Milliseconds 250
  } while ((Get-Date) -lt $deadline)
  throw $FailureMessage
}

function ConvertTo-PowerShellSingleQuoted([string] $Value) {
  if ($Value.Contains("`r") -or $Value.Contains("`n")) {
    throw 'Generated launcher values must not contain line breaks.'
  }
  return "'" + $Value.Replace("'", "''") + "'"
}

function ConvertTo-WindowsCommandLineArgument([string] $Value) {
  if ($Value.Contains('"') -or
      $Value.Contains("`r") -or $Value.Contains("`n")) {
    throw 'Generated launcher paths must not contain quotes or line breaks.'
  }
  return '"' + $Value + '"'
}

function Ensure-UnelevatedProcessLauncherType {
  if ($null -eq ('DesktopUpdater.UnelevatedProcess' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;

namespace DesktopUpdater
{
    public static class UnelevatedProcess
    {
        private const uint ProcessQueryLimitedInformation = 0x1000;
        private const uint TokenAssignPrimary = 0x0001;
        private const uint TokenDuplicate = 0x0002;
        private const uint TokenQuery = 0x0008;
        private const uint TokenAdjustDefault = 0x0080;
        private const uint TokenAdjustSessionId = 0x0100;
        private const uint CreateUnicodeEnvironment = 0x00000400;
        private const uint LogonWithProfile = 0x00000001;
        private const uint StartfUseShowWindow = 0x00000001;
        private const ushort SwHide = 0;
        private const string InteractiveDesktop = @"winsta0\default";

        private enum TokenInformationClass
        {
            TokenUser = 1,
            TokenElevationType = 18,
            TokenIntegrityLevel = 25,
        }

        private enum TokenElevationType
        {
            Default = 1,
            Full = 2,
            Limited = 3,
        }

        private enum SecurityImpersonationLevel
        {
            SecurityImpersonation = 2,
        }

        private enum TokenType
        {
            TokenPrimary = 1,
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct StartupInfo
        {
            public uint cb;
            public IntPtr reserved;
            public IntPtr desktop;
            public IntPtr title;
            public uint x;
            public uint y;
            public uint xSize;
            public uint ySize;
            public uint xCountChars;
            public uint yCountChars;
            public uint fillAttribute;
            public uint flags;
            public ushort showWindow;
            public ushort reserved2;
            public IntPtr reserved2Pointer;
            public IntPtr standardInput;
            public IntPtr standardOutput;
            public IntPtr standardError;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct ProcessInformation
        {
            public IntPtr process;
            public IntPtr thread;
            public uint processId;
            public uint threadId;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr OpenProcess(
            uint desiredAccess, bool inheritHandle, int processId);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr handle);

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool OpenProcessToken(
            IntPtr processHandle, uint desiredAccess, out IntPtr tokenHandle);

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool DuplicateTokenEx(
            IntPtr existingToken,
            uint desiredAccess,
            IntPtr tokenAttributes,
            SecurityImpersonationLevel impersonationLevel,
            TokenType tokenType,
            out IntPtr primaryToken);

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool GetTokenInformation(
            IntPtr tokenHandle,
            TokenInformationClass informationClass,
            IntPtr information,
            int informationLength,
            out int returnLength);

        [DllImport("advapi32.dll", SetLastError = true,
            CharSet = CharSet.Unicode)]
        private static extern bool CreateProcessWithTokenW(
            IntPtr token,
            uint logonFlags,
            string applicationName,
            StringBuilder commandLine,
            uint creationFlags,
            IntPtr environment,
            string currentDirectory,
            ref StartupInfo startupInfo,
            out ProcessInformation processInformation);

        [DllImport("userenv.dll", SetLastError = true)]
        private static extern bool CreateEnvironmentBlock(
            out IntPtr environment, IntPtr token, bool inherit);

        [DllImport("userenv.dll", SetLastError = true)]
        private static extern bool DestroyEnvironmentBlock(IntPtr environment);

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern IntPtr GetSidSubAuthorityCount(IntPtr sid);

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern IntPtr GetSidSubAuthority(
            IntPtr sid, uint index);

        private static bool IsMediumToken(IntPtr token, SecurityIdentifier user)
        {
            int size = 0;
            GetTokenInformation(token, TokenInformationClass.TokenElevationType,
                IntPtr.Zero, 0, out size);
            if (size <= 0) return false;
            IntPtr elevation = Marshal.AllocHGlobal(size);
            try
            {
                if (!GetTokenInformation(token,
                        TokenInformationClass.TokenElevationType, elevation,
                        size, out size) ||
                    (TokenElevationType)Marshal.ReadInt32(elevation) !=
                        TokenElevationType.Limited)
                {
                    return false;
                }
            }
            finally
            {
                Marshal.FreeHGlobal(elevation);
            }

            size = 0;
            if (GetTokenInformation(token,
                    TokenInformationClass.TokenIntegrityLevel,
                    IntPtr.Zero, 0, out size) ||
                size <= 0)
            {
                return false;
            }
            IntPtr label = Marshal.AllocHGlobal(size);
            try
            {
                if (!GetTokenInformation(token,
                        TokenInformationClass.TokenIntegrityLevel, label,
                        size, out size))
                {
                    return false;
                }
                IntPtr sid = Marshal.ReadIntPtr(label);
                IntPtr countPointer = GetSidSubAuthorityCount(sid);
                if (countPointer == IntPtr.Zero) return false;
                byte count = Marshal.ReadByte(countPointer);
                if (count == 0) return false;
                IntPtr authority = GetSidSubAuthority(sid, (uint)(count - 1));
                if (authority == IntPtr.Zero) return false;
                int integrity = Marshal.ReadInt32(authority);
                using (WindowsIdentity identity = new WindowsIdentity(token))
                {
                    return integrity >= 0x2000 && integrity < 0x3000 &&
                        user.Equals(identity.User);
                }
            }
            finally
            {
                Marshal.FreeHGlobal(label);
            }
        }

        public static uint Start(
            string applicationPath, string arguments, string workingDirectory)
        {
            if (String.IsNullOrWhiteSpace(applicationPath) ||
                String.IsNullOrWhiteSpace(workingDirectory))
            {
                throw new ArgumentException("Unelevated launch paths are required.");
            }
            SecurityIdentifier currentUser =
                WindowsIdentity.GetCurrent().User;
            int sessionId = Process.GetCurrentProcess().SessionId;
            int lastError = 0;
            foreach (Process explorer in Process.GetProcessesByName("explorer"))
            {
                try
                {
                    if (explorer.SessionId != sessionId) continue;
                    IntPtr process = OpenProcess(
                        ProcessQueryLimitedInformation, false, explorer.Id);
                    if (process == IntPtr.Zero) continue;
                    try
                    {
                        IntPtr token;
                        if (!OpenProcessToken(process,
                                TokenQuery | TokenDuplicate, out token))
                        {
                            lastError = Marshal.GetLastWin32Error();
                            continue;
                        }
                        try
                        {
                            IntPtr primary;
                            if (!DuplicateTokenEx(token,
                                    TokenAssignPrimary | TokenDuplicate |
                                        TokenQuery | TokenAdjustDefault |
                                        TokenAdjustSessionId,
                                    IntPtr.Zero,
                                    SecurityImpersonationLevel.SecurityImpersonation,
                                    TokenType.TokenPrimary,
                                    out primary))
                            {
                                lastError = Marshal.GetLastWin32Error();
                                continue;
                            }
                            try
                            {
                                if (!IsMediumToken(primary, currentUser))
                                {
                                    continue;
                                }
                                IntPtr environment;
                                if (!CreateEnvironmentBlock(
                                        out environment, primary, false))
                                {
                                    lastError = Marshal.GetLastWin32Error();
                                    continue;
                                }
                                try
                                {
                                    StartupInfo startup = new StartupInfo();
                                    startup.cb = (uint)Marshal.SizeOf(
                                        typeof(StartupInfo));
                                    startup.flags = StartfUseShowWindow;
                                    startup.showWindow = SwHide;
                                    startup.desktop = Marshal.StringToHGlobalUni(InteractiveDesktop);
                                    try
                                    {
                                        StringBuilder commandLine = new StringBuilder(
                                            "\"" + applicationPath + "\" " + arguments);
                                        ProcessInformation processInformation;
                                        if (!CreateProcessWithTokenW(
                                                primary,
                                                LogonWithProfile,
                                                applicationPath,
                                                commandLine,
                                                CreateUnicodeEnvironment,
                                                environment,
                                                workingDirectory,
                                                ref startup,
                                                out processInformation))
                                        {
                                            lastError = Marshal.GetLastWin32Error();
                                            continue;
                                        }
                                        CloseHandle(processInformation.thread);
                                        uint processId = processInformation.processId;
                                        CloseHandle(processInformation.process);
                                        return processId;
                                    }
                                    finally
                                    {
                                        Marshal.FreeHGlobal(startup.desktop);
                                    }
                                }
                                finally
                                {
                                    DestroyEnvironmentBlock(environment);
                                }
                            }
                            finally
                            {
                                CloseHandle(primary);
                            }
                        }
                        finally
                        {
                            CloseHandle(token);
                        }
                    }
                    finally
                    {
                        CloseHandle(process);
                    }
                }
                catch (Exception exception)
                {
                    if (exception is Win32Exception win32)
                    {
                        lastError = win32.NativeErrorCode;
                    }
                }
                finally
                {
                    explorer.Dispose();
                }
            }
            throw new Win32Exception(lastError,
                "A same-user medium-integrity Explorer token was not available.");
        }
    }
}
'@
  }
}

function Assert-FileText([string] $Path, [string] $Expected) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "Expected file is missing: $Path"
  }
  $actual = (Get-Content -Raw -LiteralPath $Path).Trim()
  if ($actual -ne $Expected) {
    throw "Expected '$Expected' in $Path, found '$actual'."
  }
}

function Resolve-Iscc([string] $ExplicitPath) {
  $discoveredIscc = Get-Command iscc.exe -ErrorAction SilentlyContinue
  $candidates = @(
    $ExplicitPath,
    $(if ($discoveredIscc) { $discoveredIscc.Source }),
    'C:\Program Files (x86)\Inno Setup 6\ISCC.exe',
    'C:\Program Files\Inno Setup 6\ISCC.exe'
  ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
  $resolved = $candidates |
    Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
    Select-Object -First 1
  if (-not $resolved) {
    throw 'Inno Setup Compiler is required for the Windows Inno smoke.'
  }
  return [IO.Path]::GetFullPath($resolved)
}

function Resolve-Signtool([string] $ExplicitPath) {
  $discovered = Get-Command signtool.exe -ErrorAction SilentlyContinue
  $candidates = @(
    $ExplicitPath
    $(if ($discovered) { $discovered.Source })
    @(Get-ChildItem `
      -Path "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\arm64\signtool.exe" `
      -ErrorAction SilentlyContinue | Sort-Object FullName -Descending |
      ForEach-Object FullName)
    @(Get-ChildItem `
      -Path "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\signtool.exe" `
      -ErrorAction SilentlyContinue | Sort-Object FullName -Descending |
      ForEach-Object FullName)
  ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
  $resolved = $candidates |
    Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
    Select-Object -First 1
  if (-not $resolved) {
    throw 'signtool.exe is required for the signed Windows Inno smoke.'
  }
  return [IO.Path]::GetFullPath($resolved)
}

function Get-CertificateSha256(
  [Security.Cryptography.X509Certificates.X509Certificate2] $Certificate
) {
  $digest = [Security.Cryptography.SHA256]::HashData($Certificate.RawData)
  return [Convert]::ToHexString($digest).ToLowerInvariant()
}

function Assert-SmokeCertificate(
  [string] $ExpectedSha1,
  [string] $ExpectedSha256,
  [string] $ExpectedPublisher
) {
  $myCertificate = Get-Item `
    -LiteralPath "Cert:\CurrentUser\My\$ExpectedSha1" `
    -ErrorAction SilentlyContinue
  if ($null -eq $myCertificate -or -not $myCertificate.HasPrivateKey) {
    throw 'The task-scoped CurrentUser My certificate/private key is missing.'
  }
  if ((Get-CertificateSha256 $myCertificate) -ne $ExpectedSha256 -or
      $myCertificate.GetNameInfo(
        [Security.Cryptography.X509Certificates.X509NameType]::SimpleName,
        $false
      ) -ne $ExpectedPublisher) {
    throw 'The task-scoped signing certificate identity changed.'
  }
  $requiredTrustStores = @('TrustedPublisher')
  if ($myCertificate.Subject -eq $myCertificate.Issuer) {
    $requiredTrustStores += 'Root'
  }
  foreach ($store in $requiredTrustStores) {
    $trusted = Get-Item `
      -LiteralPath "Cert:\CurrentUser\$store\$ExpectedSha1" `
      -ErrorAction SilentlyContinue
    if ($null -eq $trusted -or
        (Get-CertificateSha256 $trusted) -ne $ExpectedSha256) {
      throw "The task-scoped certificate is missing from CurrentUser $store."
    }
  }
}

function Assert-AuthenticodeIdentity(
  [string] $Path,
  [string] $ExpectedSha1,
  [string] $ExpectedSha256,
  [string] $ExpectedPublisher
) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "Signed Windows smoke file is missing: $Path"
  }
  $signature = Get-AuthenticodeSignature -FilePath $Path
  if ($signature.Status -ne [Management.Automation.SignatureStatus]::Valid -or
      $null -eq $signature.SignerCertificate -or
      $signature.SignerCertificate.Thumbprint -ne $ExpectedSha1 -or
      (Get-CertificateSha256 $signature.SignerCertificate) -ne
        $ExpectedSha256 -or
      $signature.SignerCertificate.GetNameInfo(
        [Security.Cryptography.X509Certificates.X509NameType]::SimpleName,
        $false
      ) -ne $ExpectedPublisher) {
    throw "Windows smoke Authenticode identity is invalid: $Path"
  }
}

function Save-ExampleDartPackageMetadata(
  [string] $ExampleRoot,
  [string] $BackupRoot
) {
  $state = @{}
  foreach ($name in @('package_config.json', 'package_graph.json')) {
    $source = Join-Path $ExampleRoot ".dart_tool\$name"
    $backup = Join-Path $BackupRoot $name
    $exists = Test-Path -LiteralPath $source -PathType Leaf
    $state[$name] = $exists
    if ($exists) {
      Copy-Item -LiteralPath $source -Destination $backup -Force
    }
  }
  return $state
}

function Restore-ExampleDartPackageMetadata(
  [string] $ExampleRoot,
  [string] $BackupRoot,
  [hashtable] $State
) {
  foreach ($name in @('package_config.json', 'package_graph.json')) {
    $target = Join-Path $ExampleRoot ".dart_tool\$name"
    if ($State[$name]) {
      $backup = Join-Path $BackupRoot $name
      if (-not (Test-Path -LiteralPath $backup -PathType Leaf)) {
        throw "Dart package metadata backup is missing: $name"
      }
      Copy-Item -LiteralPath $backup -Destination $target -Force
    } elseif (Test-Path -LiteralPath $target -PathType Leaf) {
      Remove-Item -LiteralPath $target -Force
    }
  }
}

function Reset-ExampleWindowsBuild([string] $ExampleRoot) {
  $buildParent = [IO.Path]::GetFullPath(
    (Join-Path $ExampleRoot 'build\windows')
  )
  $buildRoot = [IO.Path]::GetFullPath((Join-Path $buildParent 'x64'))
  $expectedPrefix = $buildParent.TrimEnd(
    [IO.Path]::DirectorySeparatorChar
  ) + [IO.Path]::DirectorySeparatorChar
  if (-not $buildRoot.StartsWith(
      $expectedPrefix,
      [StringComparison]::OrdinalIgnoreCase
    ) -or [IO.Path]::GetFileName($buildRoot) -ne 'x64') {
    throw "Refusing to reset unexpected Flutter build root: $buildRoot"
  }
  if (Test-Path -LiteralPath $buildRoot) {
    Remove-Item -LiteralPath $buildRoot -Recurse -Force
  }
}

function Get-Sha256Utf8([string] $Value) {
  return [Convert]::ToHexString(
    [Security.Cryptography.SHA256]::HashData(
      [Text.Encoding]::UTF8.GetBytes($Value)
    )
  ).ToLowerInvariant()
}

function ConvertTo-WindowsInnoComparablePath {
  param(
    [AllowNull()]
    [AllowEmptyString()]
    [string] $Path
  )

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $null
  }

  $candidate = $Path.Trim()
  if ($candidate.StartsWith('\\?\UNC\', [StringComparison]::OrdinalIgnoreCase)) {
    $candidate = "\\$($candidate.Substring(8))"
  } elseif ($candidate.StartsWith('\\?\', [StringComparison]::OrdinalIgnoreCase)) {
    $candidate = $candidate.Substring(4)
  }

  try {
    return [IO.Path]::GetFullPath($candidate)
  } catch {
    return $null
  }
}

function Read-EndpointRecords([string] $PackageId) {
  $packageHash = Get-Sha256Utf8 $PackageId
  $root = "HKLM:\SOFTWARE\DesktopUpdater\Endpoints\$packageHash"
  if (-not (Test-Path -LiteralPath $root)) {
    return @()
  }
  return @(
    Get-ChildItem -LiteralPath $root | ForEach-Object {
      $bytes = (Get-ItemProperty -LiteralPath $_.PSPath -Name Record).Record
      $json = [Text.Encoding]::UTF8.GetString([byte[]] $bytes)
      $record = $json | ConvertFrom-Json
      if ([string] $record.packageId -ne $PackageId) {
        throw "Protected endpoint package binding changed at $($_.PSPath)."
      }
      $record
    }
  )
}

function Get-OptionalRegistryPropertyValue(
  [psobject] $Record,
  [string] $Name
) {
  if ($null -eq $Record) {
    return $null
  }
  $property = $Record.PSObject.Properties[$Name]
  if ($null -eq $property) {
    return $null
  }
  return $property.Value
}

function Assert-ProtectedHelperGeneration(
  [string] $Path,
  [string] $PackageId,
  [string] $ExpectedSha1,
  [string] $ExpectedSha256,
  [string] $ExpectedPublisher
) {
  $directory = Get-Item -LiteralPath $Path -Force
  if (-not $directory.PSIsContainer -or
      ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "Protected helper generation is not a regular directory: $Path"
  }
  $acl = Get-Acl -LiteralPath $Path
  $ownerSid = ([Security.Principal.NTAccount] $acl.Owner).Translate(
    [Security.Principal.SecurityIdentifier]
  ).Value
  if ($ownerSid -ne 'S-1-5-32-544' -or -not $acl.AreAccessRulesProtected) {
    throw "Protected helper generation owner/DACL is invalid: $Path"
  }
  $helper = Join-Path $Path 'desktop_updater_install_helper.exe'
  $policy = Join-Path $Path 'desktop_updater_helper_policy.json'
  Assert-AuthenticodeIdentity `
    $helper $ExpectedSha1 $ExpectedSha256 $ExpectedPublisher
  $document = Get-Content -Raw -LiteralPath $policy | ConvertFrom-Json
  if ([string] $document.applicationPackageId -ne $PackageId -or
      [string] $document.allowedApplicationSigner.kind -ne
        'authenticodePublisher' -or
      [string] $document.allowedApplicationSigner.value -ne
        $ExpectedPublisher -or
      @($document.allowedStrategies).Count -ne 1 -or
      [string] $document.allowedStrategies[0].strategy -ne
        'verifiedInstallerHandoff' -or
      [string] $document.allowedStrategies[0].provider -ne 'windowsInno') {
    throw "Protected helper policy authority is invalid: $policy"
  }
}

function Get-ExactExecutableProcesses([string] $ExecutablePath) {
  $expected = [IO.Path]::GetFullPath($ExecutablePath)
  $name = [IO.Path]::GetFileName($expected).Replace("'", "''")
  return @(
    Get-CimInstance Win32_Process -Filter "Name='$name'" |
      Where-Object {
        -not [string]::IsNullOrWhiteSpace($_.ExecutablePath) -and
        [IO.Path]::GetFullPath($_.ExecutablePath) -eq $expected
      }
  )
}

function Wait-ForNewExactExecutableProcess(
  [string] $ExecutablePath,
  [int[]] $ExcludedProcessIds,
  [int] $TimeoutSeconds
) {
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  do {
    $candidate = Get-ExactExecutableProcesses $ExecutablePath |
      Where-Object { $ExcludedProcessIds -notcontains [int] $_.ProcessId } |
      Select-Object -First 1
    if ($null -ne $candidate) {
      return $candidate
    }
    Start-Sleep -Milliseconds 250
  } while ((Get-Date) -lt $deadline)
  throw 'The protected Inno transaction did not relaunch the installed app.'
}

function Stop-ExactExecutableProcesses([string] $ExecutablePath) {
  foreach ($process in @(Get-ExactExecutableProcesses $ExecutablePath)) {
    $processId = [int] $process.ProcessId
    try {
      Stop-Process -Id $processId -Force -ErrorAction Stop
    } catch {
      $stillExact = @(
        Get-ExactExecutableProcesses $ExecutablePath |
          Where-Object { [int] $_.ProcessId -eq $processId }
      )
      if ($stillExact.Count -ne 0) {
        throw
      }
    }
    Wait-Process -Id $processId -Timeout 15 `
      -ErrorAction SilentlyContinue
  }
}

function Get-UninstallRecord(
  [string] $PackageId,
  [string] $InstallRoot
) {
  $roots = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
  )
  $matches = @()
  foreach ($root in $roots) {
    if (-not (Test-Path -LiteralPath $root)) {
      continue
    }
    foreach ($key in @(Get-ChildItem -LiteralPath $root)) {
      $record = Get-ItemProperty -LiteralPath $key.PSPath
      $recordPackageId = [string](Get-OptionalRegistryPropertyValue `
        $record 'DesktopUpdaterPackageId')
      $recordInstallLocation = [string](Get-OptionalRegistryPropertyValue `
        $record 'InstallLocation')
      if ($recordPackageId -eq $PackageId -and
          (ConvertTo-WindowsInnoComparablePath $recordInstallLocation) -eq
            (ConvertTo-WindowsInnoComparablePath $InstallRoot)) {
        $matches += [pscustomobject]@{
          KeyPath = $key.PSPath
          Record = $record
        }
      }
    }
  }
  if ($matches.Count -ne 1) {
    throw "Expected one exact Inno uninstall record, found $($matches.Count)."
  }
  return $matches[0]
}

function Remove-BoundedSmokeRootWithRetry([string] $Root) {
  for ($attempt = 0; $attempt -lt 60; $attempt++) {
    try {
      Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction Stop
    } catch {
      if ($attempt -eq 59) {
        throw
      }
      Start-Sleep -Milliseconds 250
      continue
    }
    if (-not (Test-Path -LiteralPath $Root)) {
      return
    }
    if ($attempt -eq 59) {
      throw "Bounded smoke root remained after cleanup: $Root"
    }
    Start-Sleep -Milliseconds 250
  }
}

function Remove-SmokeSystemResidue(
  [string] $PackageId,
  [string] $PolicyId,
  [string] $HelperServiceId,
  [string] $InstallRoot,
  [string[]] $ProtectedHelperInstallDirs
) {
  $failures = [Collections.Generic.List[string]]::new()
  try {
    Stop-ExactExecutableProcesses (Join-Path $InstallRoot 'desktop_updater_example.exe')
  } catch {
    $failures.Add("process cleanup: $($_.Exception.Message)")
  }

  try {
    foreach ($task in @(Get-ScheduledTask -TaskName 'DesktopUpdater-*' `
        -ErrorAction SilentlyContinue)) {
      $actionText = (@($task.Actions) | ForEach-Object {
        "$($_.Execute) $($_.Arguments)"
      }) -join "`n"
      if ($actionText.Contains($PackageId) -or
          $actionText.Contains($InstallRoot) -or
          @($ProtectedHelperInstallDirs | Where-Object {
            $actionText.Contains($_)
          }).Count -gt 0) {
        Unregister-ScheduledTask -TaskName $task.TaskName `
          -TaskPath $task.TaskPath -Confirm:$false
      }
    }
  } catch {
    $failures.Add("scheduled task cleanup: $($_.Exception.Message)")
  }

  try {
    foreach ($root in @(
      'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
      'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )) {
      if (-not (Test-Path -LiteralPath $root)) {
        continue
      }
      foreach ($key in @(Get-ChildItem -LiteralPath $root)) {
        $record = Get-ItemProperty -LiteralPath $key.PSPath
        $recordPackageId = [string](Get-OptionalRegistryPropertyValue `
          $record 'DesktopUpdaterPackageId')
        $recordInstallLocation = [string](Get-OptionalRegistryPropertyValue `
          $record 'InstallLocation')
        if ($recordPackageId -eq $PackageId -and
            (ConvertTo-WindowsInnoComparablePath $recordInstallLocation) -eq
              (ConvertTo-WindowsInnoComparablePath $InstallRoot)) {
          Remove-Item -LiteralPath $key.PSPath -Recurse -Force
        }
      }
    }
  } catch {
    $failures.Add("uninstall registry cleanup: $($_.Exception.Message)")
  }

  try {
    $packageHash = Get-Sha256Utf8 $PackageId
    $endpointPackage =
      "HKLM:\SOFTWARE\DesktopUpdater\Endpoints\$packageHash"
    if (Test-Path -LiteralPath $endpointPackage) {
      Remove-Item -LiteralPath $endpointPackage -Recurse -Force
    }
    $binding = "$PolicyId`n$PackageId`n$HelperServiceId"
    $transactionHash = Get-Sha256Utf8 $binding
    $transactionIndex =
      "HKLM:\SOFTWARE\DesktopUpdater\Transactions\$transactionHash"
    if (Test-Path -LiteralPath $transactionIndex) {
      Remove-Item -LiteralPath $transactionIndex -Recurse -Force
    }
    $transactionEndpoints =
      'HKLM:\SOFTWARE\DesktopUpdater\TransactionEndpoints'
    if (Test-Path -LiteralPath $transactionEndpoints) {
      foreach ($key in @(Get-ChildItem -LiteralPath $transactionEndpoints)) {
        $bytes = (Get-ItemProperty -LiteralPath $key.PSPath `
          -Name Record -ErrorAction SilentlyContinue).Record
        if ($null -eq $bytes) {
          continue
        }
        $record = [Text.Encoding]::UTF8.GetString([byte[]] $bytes) |
          ConvertFrom-Json
        if ([string] $record.packageId -eq $PackageId) {
          Remove-Item -LiteralPath $key.PSPath -Recurse -Force
        }
      }
    }
  } catch {
    $failures.Add("transaction registry cleanup: $($_.Exception.Message)")
  }

  $programFiles = [IO.Path]::GetFullPath(
    [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)
  )
  $programFilesPrefix = $programFiles.TrimEnd(
    [IO.Path]::DirectorySeparatorChar
  ) + [IO.Path]::DirectorySeparatorChar
  foreach ($path in @($ProtectedHelperInstallDirs) + @($InstallRoot)) {
    try {
      $resolved = [IO.Path]::GetFullPath($path)
      $leaf = [IO.Path]::GetFileName($resolved)
      $expectedLeaf = $leaf.StartsWith(
        'DesktopUpdaterHelperGenerationV1--' + $PackageId + '--',
        [StringComparison]::Ordinal
      ) -or $leaf.StartsWith(
        'DesktopUpdaterArm64Readiness-',
        [StringComparison]::Ordinal
      )
      if (-not $resolved.StartsWith(
          $programFilesPrefix,
          [StringComparison]::OrdinalIgnoreCase
        ) -or -not $expectedLeaf) {
        throw "Refusing to clean unexpected Program Files path: $resolved"
      }
      if (Test-Path -LiteralPath $resolved) {
        Remove-BoundedSmokeRootWithRetry $resolved
      }
    } catch {
      $failures.Add("filesystem cleanup for ${path}: $($_.Exception.Message)")
    }
  }
  return @($failures)
}

function Publish-SmokeVersion(
  [string] $ExampleRoot,
  [string] $TempRoot,
  [string] $ResolvedIscc,
  [string] $FeedBaseUrl,
  [string] $WebRoot,
  [string] $KeyProfilePath,
  [string] $Version,
  [string] $BuildNumber,
  [string] $PackageId,
  [string] $AppId,
  [string] $ProtectedHelperInstallDir,
  [string] $InstallRoot,
  [string] $CertificateSha256,
  [string] $SigningHookPath,
  [string] $EvidenceRoot,
  [bool] $InitializeFeed
) {
  $versionRoot = Join-Path $TempRoot "version-$Version"
  $outputRoot = Join-Path $versionRoot 'publish'
  $sentinelRoot = Join-Path $versionRoot 'sentinel'
  New-Item -ItemType Directory -Force -Path $sentinelRoot | Out-Null
  $sentinel = Join-Path $sentinelRoot `
    'desktop_updater_inno_smoke_version.txt'
  Set-Content -LiteralPath $sentinel -Value $Version -Encoding UTF8NoBOM

  $configPath = Join-Path $versionRoot 'desktop_updater.yaml'
  $yamlOutput = ConvertTo-YamlSingleQuoted $outputRoot
  $yamlIscc = ConvertTo-YamlSingleQuoted $ResolvedIscc
  $yamlSentinel = ConvertTo-YamlSingleQuoted $sentinel
  $yamlBaseUrl = ConvertTo-YamlSingleQuoted $FeedBaseUrl
  $yamlAppId = ConvertTo-YamlSingleQuoted $AppId
  $yamlProtectedHelper =
    ConvertTo-YamlSingleQuoted $ProtectedHelperInstallDir
  $repoRoot = Split-Path $ExampleRoot -Parent
  $copyScript = Join-Path $repoRoot `
    'test/e2e/fixtures/upload_commands/copy_updates.dart'
  $copyCommand = 'dart "' + $copyScript + '" unused "' + $WebRoot + '"'
  $yamlCopyCommand = ConvertTo-YamlSingleQuoted $copyCommand
  $hookCommand =
    'pwsh -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' +
    $SigningHookPath + '"'
  $yamlHookCommand = ConvertTo-YamlSingleQuoted $hookCommand
  @"
updates:
  baseUrl: $yamlBaseUrl
  output: $yamlOutput

customCommand:
  command: $yamlCopyCommand

hooks:
  prePackage:
    - command: $yamlHookCommand
      platforms: [windows]
  postPackage:
    - command: $yamlHookCommand
      platforms: [windows]

windows:
  installer:
    kind: inno
    mode: generated
    isccPath: $yamlIscc
    outputBaseName: desktop-updater-inno-smoke-$Version
    appId: $yamlAppId
    publisher: desktop_updater ARM64 local readiness
    privilegesRequired: admin
    protectedHelperInstallDir: $yamlProtectedHelper
    requiresElevation: always
    authenticodeThumbprints:
      - $CertificateSha256
    architecturesAllowed: x64compatible
    architecturesInstallIn64BitMode: x64compatible
    silentArgs:
      - /VERYSILENT
      - /SUPPRESSMSGBOXES
      - /NORESTART

additionalFiles:
  - source: $yamlSentinel
    destination: .
    platforms: [windows]
"@ | Set-Content -LiteralPath $configPath -Encoding UTF8NoBOM

  $env:DESKTOP_UPDATER_PROTECTED_HELPER_INSTALL_DIR =
    $ProtectedHelperInstallDir
  $env:DESKTOP_UPDATER_SMOKE_INSTALL_ROOT = $InstallRoot
  if (-not (Test-Path -LiteralPath $KeyProfilePath -PathType Leaf)) {
    Invoke-Checked 'dart' @(
      'run'
      'desktop_updater:release'
      'keygen'
      '--config'
      $configPath
      '--key-profile'
      $KeyProfilePath
    ) $ExampleRoot
  }

  $keyProfile = Get-Content -Raw -LiteralPath $KeyProfilePath |
    ConvertFrom-Json
  $trustedPublicKeyId = [string] $keyProfile.activeKeyId
  $trustedPublicKey = [string] (
    $keyProfile.publicKeys.PSObject.Properties[$trustedPublicKeyId].Value
  )
  if ([string]::IsNullOrWhiteSpace($trustedPublicKeyId) -or
      [string]::IsNullOrWhiteSpace($trustedPublicKey)) {
    throw 'Release key profile does not contain its active public key.'
  }
  $env:DESKTOP_UPDATER_SMOKE_RELEASE_KEY_ID = $trustedPublicKeyId
  $env:DESKTOP_UPDATER_SMOKE_RELEASE_PUBLIC_KEY = $trustedPublicKey

  Reset-ExampleWindowsBuild $ExampleRoot
  $publishArguments = @(
    'run'
    'desktop_updater:release'
    'publish'
    '--platform'
    'windows'
    '--key-profile'
    $KeyProfilePath
    '--config'
    $configPath
    '--version'
    $Version
    '--build-number'
    $BuildNumber
    '--package-id'
    $PackageId
    '--executable-relative-path'
    'desktop_updater_example.exe'
  )
  if ($InitializeFeed) {
    $publishArguments += '--initialize-feed'
  }
  Invoke-Checked 'dart' $publishArguments $ExampleRoot

  $manifestPath = Join-Path $outputRoot '.desktop_updater_publish.json'
  $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
  $artifactPath = Join-Path $outputRoot (
    ([string] $manifest.artifact.path).Replace(
      '/',
      [IO.Path]::DirectorySeparatorChar
    )
  )
  $releasePath = Join-Path $outputRoot (
    ([string] $manifest.release.path).Replace(
      '/',
      [IO.Path]::DirectorySeparatorChar
    )
  )
  if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf) -or
      -not (Test-Path -LiteralPath $releasePath -PathType Leaf)) {
    throw "Published Windows Inno output is incomplete for $Version."
  }
  Assert-AuthenticodeIdentity `
    $artifactPath $script:certificateSha1 $script:certificateSha256 `
    $script:certificatePublisher

  $release = Get-Content -Raw -LiteralPath $releasePath | ConvertFrom-Json
  $artifactSha256 = (
    Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256
  ).Hash.ToLowerInvariant()
  $builtAppRoot = [IO.Path]::GetFullPath(
    (Join-Path $ExampleRoot 'build\windows\x64\runner\Release')
  )
  $installedApplication = Join-Path $builtAppRoot `
    'desktop_updater_example.exe'
  $installedExecutableSha256 = (
    Get-FileHash -LiteralPath $installedApplication -Algorithm SHA256
  ).Hash.ToLowerInvariant()
  if ([int] $release.schemaVersion -ne 3 -or
      [string] $release.packageId -ne $PackageId -or
      [string] $release.version -ne $Version -or
      [int] $release.buildNumber -ne [int] $BuildNumber -or
      [string] $release.artifact.kind -ne 'innoInstaller' -or
      [string] $release.artifact.sha256 -ne $artifactSha256 -or
      [string] $release.install.strategy -ne 'innoInstaller' -or
      [string] $release.install.inno.requiresElevation -ne 'always' -or
      -not [bool] $release.install.inno.relaunchAfterInstall -or
      [string] $release.install.inno.installedExecutableRelativePath -ne
        'desktop_updater_example.exe' -or
      [string] $release.install.inno.installedExecutableSha256 -ne
        $installedExecutableSha256 -or
      @($release.install.inno.authenticode.sha256Thumbprints).Count -ne 1 -or
      [string] $release.install.inno.authenticode.sha256Thumbprints[0] -ne
        $CertificateSha256) {
    throw "Protected Windows Inno release authority is invalid for $Version."
  }

  Copy-Item -LiteralPath $releasePath `
    -Destination (Join-Path $EvidenceRoot "$Version-release.json") -Force
  $builtPolicy = Join-Path $builtAppRoot `
    'desktop_updater_helper_policy.json'
  Copy-Item -LiteralPath $builtPolicy `
    -Destination (Join-Path $EvidenceRoot "$Version-helper-policy.json") `
    -Force

  return [pscustomobject]@{
    Version = $Version
    BuildNumber = [int] $BuildNumber
    ArtifactPath = $artifactPath
    ArtifactSha256 = $artifactSha256
    ArtifactLength = (Get-Item -LiteralPath $artifactPath).Length
    ReleasePath = $releasePath
    PackageId = [string] $release.packageId
    InstalledExecutableSha256 = $installedExecutableSha256
    TrustedPublicKeyId = $trustedPublicKeyId
    TrustedPublicKey = $trustedPublicKey
  }
}

function Resolve-PreparedSmokeChildPath(
  [string] $Root,
  [string] $RelativePath,
  [string] $Description
) {
  if ([string]::IsNullOrWhiteSpace($RelativePath) -or
      [IO.Path]::IsPathRooted($RelativePath)) {
    throw "Prepared $Description path is invalid."
  }
  $resolvedRoot = [IO.Path]::GetFullPath($Root).TrimEnd(
    [IO.Path]::DirectorySeparatorChar
  ) + [IO.Path]::DirectorySeparatorChar
  $nativeRelative = $RelativePath.Replace(
    '/',
    [IO.Path]::DirectorySeparatorChar
  )
  $candidate = [IO.Path]::GetFullPath((Join-Path $Root $nativeRelative))
  if (-not $candidate.StartsWith(
      $resolvedRoot,
      [StringComparison]::OrdinalIgnoreCase
    )) {
    throw "Prepared $Description path escapes its bounded root."
  }
  return $candidate
}

function Get-PreparedReplayFeedPort([string] $WebRoot) {
  $archivePath = Resolve-PreparedSmokeChildPath `
    $WebRoot 'app-archive.json' 'app archive'
  if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
    throw 'Prepared replay app archive is missing.'
  }

  $archive = Get-Content -Raw -LiteralPath $archivePath | ConvertFrom-Json
  $items = @($archive.items)
  $expectedBuildNumbers = @{
    '3.1.2' = 312
    '3.1.3' = 313
  }
  if ([int] $archive.schemaVersion -ne 3 -or $items.Count -ne 2) {
    throw 'Prepared replay app archive has unexpected contents.'
  }

  $seenVersions = @{}
  $feedPort = $null
  foreach ($item in $items) {
    $version = [string] $item.version
    if (-not $expectedBuildNumbers.ContainsKey($version) -or
        $seenVersions.ContainsKey($version) -or
        [int] $item.buildNumber -ne $expectedBuildNumbers[$version] -or
        [string] $item.platform -cne 'windows') {
      throw 'Prepared replay app archive has unexpected release entries.'
    }
    $seenVersions[$version] = $true

    $releaseUrl = [string] $item.release
    $releaseUri = $null
    if (-not [Uri]::TryCreate(
        $releaseUrl,
        [UriKind]::Absolute,
        [ref] $releaseUri
      ) -or
      $releaseUri.Scheme -cne 'http' -or
      $releaseUri.Host -cne '127.0.0.1' -or
      -not [string]::IsNullOrEmpty($releaseUri.UserInfo) -or
      -not [string]::IsNullOrEmpty($releaseUri.Query) -or
      -not [string]::IsNullOrEmpty($releaseUri.Fragment) -or
      $releaseUri.Port -lt 1 -or
      $releaseUri.Port -gt 65535) {
      throw 'Prepared replay app archive release URL is not bounded loopback.'
    }
    $expectedPath = "/releases/$version/windows/release.json"
    $expectedUrl = "http://127.0.0.1:$($releaseUri.Port)$expectedPath"
    if ($releaseUri.AbsolutePath -cne $expectedPath -or
        $releaseUrl -cne $expectedUrl) {
      throw 'Prepared replay app archive release URL is not canonical.'
    }
    if ($null -eq $feedPort) {
      $feedPort = $releaseUri.Port
    } elseif ($feedPort -ne $releaseUri.Port) {
      throw 'Prepared replay app archive uses inconsistent feed ports.'
    }
  }
  if ($seenVersions.Count -ne $expectedBuildNumbers.Count -or
      $null -eq $feedPort) {
    throw 'Prepared replay app archive is incomplete.'
  }
  return [int] $feedPort
}

function Import-PreparedSmokeVersion(
  [string] $ArtifactRoot,
  [string] $WebRoot,
  [string] $KeyProfilePath,
  [string] $Version,
  [int] $BuildNumber,
  [string] $PackageId,
  [string] $CertificateSha256,
  [string] $EvidenceRoot
) {
  $outputRoot = Join-Path $ArtifactRoot "version-$Version\publish"
  $manifestPath = Join-Path $outputRoot '.desktop_updater_publish.json'
  if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf) -or
      -not (Test-Path -LiteralPath $KeyProfilePath -PathType Leaf)) {
    throw "Prepared Windows Inno metadata is incomplete for $Version."
  }
  $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
  $artifactRelative = [string] $manifest.artifact.path
  $releaseRelative = [string] $manifest.release.path
  $artifactPath = Resolve-PreparedSmokeChildPath `
    $outputRoot $artifactRelative 'artifact'
  $releasePath = Resolve-PreparedSmokeChildPath `
    $outputRoot $releaseRelative 'release'
  $webArtifactPath = Resolve-PreparedSmokeChildPath `
    $WebRoot $artifactRelative 'web artifact'
  $webReleasePath = Resolve-PreparedSmokeChildPath `
    $WebRoot $releaseRelative 'web release'
  foreach ($path in @(
      $artifactPath,
      $releasePath,
      $webArtifactPath,
      $webReleasePath
    )) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
      throw "Prepared Windows Inno file is missing for ${Version}: $path"
    }
  }

  Assert-AuthenticodeIdentity `
    $artifactPath $script:certificateSha1 $script:certificateSha256 `
    $script:certificatePublisher
  $artifactSha256 = (
    Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256
  ).Hash.ToLowerInvariant()
  $artifactLength = (Get-Item -LiteralPath $artifactPath).Length
  $webArtifactSha256 = (
    Get-FileHash -LiteralPath $webArtifactPath -Algorithm SHA256
  ).Hash.ToLowerInvariant()
  $webReleaseSha256 = (
    Get-FileHash -LiteralPath $webReleasePath -Algorithm SHA256
  ).Hash.ToLowerInvariant()
  $releaseSha256 = (
    Get-FileHash -LiteralPath $releasePath -Algorithm SHA256
  ).Hash.ToLowerInvariant()
  if ($webArtifactSha256 -ne $artifactSha256 -or
      $webReleaseSha256 -ne $releaseSha256) {
    throw "Prepared Windows Inno feed bytes changed for $Version."
  }

  $keyProfile = Get-Content -Raw -LiteralPath $KeyProfilePath |
    ConvertFrom-Json
  $trustedPublicKeyId = [string] $keyProfile.activeKeyId
  $trustedPublicKey = [string] (
    $keyProfile.publicKeys.PSObject.Properties[$trustedPublicKeyId].Value
  )
  $release = Get-Content -Raw -LiteralPath $releasePath | ConvertFrom-Json
  $installedExecutableSha256 =
    [string] $release.install.inno.installedExecutableSha256
  if ([string]::IsNullOrWhiteSpace($trustedPublicKeyId) -or
      [string]::IsNullOrWhiteSpace($trustedPublicKey) -or
      [int] $release.schemaVersion -ne 3 -or
      [string] $release.packageId -ne $PackageId -or
      [string] $release.version -ne $Version -or
      [int] $release.buildNumber -ne $BuildNumber -or
      [string] $release.artifact.kind -ne 'innoInstaller' -or
      [string] $release.artifact.sha256 -ne $artifactSha256 -or
      [int64] $release.artifact.length -ne $artifactLength -or
      [string] $release.install.strategy -ne 'innoInstaller' -or
      [string] $release.install.inno.requiresElevation -ne 'always' -or
      -not [bool] $release.install.inno.relaunchAfterInstall -or
      [string] $release.install.inno.installedExecutableRelativePath -ne
        'desktop_updater_example.exe' -or
      $installedExecutableSha256 -notmatch '^[0-9a-f]{64}$' -or
      @($release.install.inno.authenticode.sha256Thumbprints).Count -ne 1 -or
      [string] $release.install.inno.authenticode.sha256Thumbprints[0] -ne
        $CertificateSha256) {
    throw "Prepared Windows Inno release authority is invalid for $Version."
  }

  Copy-Item -LiteralPath $releasePath `
    -Destination (Join-Path $EvidenceRoot "$Version-release.json") -Force
  return [pscustomobject]@{
    Version = $Version
    BuildNumber = $BuildNumber
    ArtifactPath = $artifactPath
    ArtifactSha256 = $artifactSha256
    ArtifactLength = $artifactLength
    ReleasePath = $releasePath
    PackageId = [string] $release.packageId
    InstalledExecutableSha256 = $installedExecutableSha256
    TrustedPublicKeyId = $trustedPublicKeyId
    TrustedPublicKey = $trustedPublicKey
  }
}

function Invoke-InstalledAppUpdate(
  [string] $ExecutablePath,
  [string] $AppArchiveUrl,
  [string] $ExpectedPackageId,
  [string] $TrustedPublicKeyId,
  [string] $TrustedPublicKey,
  [string] $RecoveryStorePath,
  [string] $ControllerTempRoot,
  [string] $MarkerPath,
  [string] $DiagnosticsPath
) {
  New-Item -ItemType Directory -Force -Path $ControllerTempRoot | Out-Null
  $launcherPath = Join-Path `
    $ControllerTempRoot 'desktop_updater_unelevated_launcher.ps1'
  $launcherExitPath = Join-Path `
    $ControllerTempRoot 'desktop_updater_unelevated_launcher.exit-code'
  $launcherProcessIdPath = Join-Path `
    $ControllerTempRoot 'desktop_updater_unelevated_launcher.process-id'
  $launcherErrorPath = Join-Path `
    $ControllerTempRoot 'desktop_updater_unelevated_launcher.error'
  $launcherTokenProofPath = Join-Path `
    $ControllerTempRoot 'desktop_updater_unelevated_launcher.token-proof'
  $launcherLines = @(
    '$ErrorActionPreference = ''Stop'''
    ('$executablePath = ' + (ConvertTo-PowerShellSingleQuoted $ExecutablePath))
    ('$workingDirectory = ' + (
        ConvertTo-PowerShellSingleQuoted (Split-Path $ExecutablePath -Parent)
      ))
    ('$completionPath = ' + (ConvertTo-PowerShellSingleQuoted $launcherExitPath))
    ('$processIdPath = ' + (
        ConvertTo-PowerShellSingleQuoted $launcherProcessIdPath
      ))
    ('$errorPath = ' + (ConvertTo-PowerShellSingleQuoted $launcherErrorPath))
    ('$tokenProofPath = ' + (
        ConvertTo-PowerShellSingleQuoted $launcherTokenProofPath
      ))
  )
  $childEnvironment = [ordered]@{
    'TEMP' = $ControllerTempRoot
    'TMP' = $ControllerTempRoot
    'LOCALAPPDATA' = [Environment]::GetEnvironmentVariable(
      'LOCALAPPDATA',
      [EnvironmentVariableTarget]::Process
    )
    'DESKTOP_UPDATER_PROTECTED_HELPER_INSTALL_DIR' =
      [Environment]::GetEnvironmentVariable(
        'DESKTOP_UPDATER_PROTECTED_HELPER_INSTALL_DIR',
        [EnvironmentVariableTarget]::Process
      )
    'DESKTOP_UPDATER_SMOKE_SIGNTOOL_PATH' =
      [Environment]::GetEnvironmentVariable(
        'DESKTOP_UPDATER_SMOKE_SIGNTOOL_PATH',
        [EnvironmentVariableTarget]::Process
      )
    'DESKTOP_UPDATER_SMOKE_SIGNING_CERTIFICATE_SHA1' =
      [Environment]::GetEnvironmentVariable(
        'DESKTOP_UPDATER_SMOKE_SIGNING_CERTIFICATE_SHA1',
        [EnvironmentVariableTarget]::Process
      )
    'DESKTOP_UPDATER_SMOKE_SIGNING_CERTIFICATE_SHA256' =
      [Environment]::GetEnvironmentVariable(
        'DESKTOP_UPDATER_SMOKE_SIGNING_CERTIFICATE_SHA256',
        [EnvironmentVariableTarget]::Process
      )
    'DESKTOP_UPDATER_SMOKE_SIGNING_PUBLISHER' =
      [Environment]::GetEnvironmentVariable(
        'DESKTOP_UPDATER_SMOKE_SIGNING_PUBLISHER',
        [EnvironmentVariableTarget]::Process
      )
    'DESKTOP_UPDATER_SMOKE_APPLICATION_EXECUTABLE' =
      [Environment]::GetEnvironmentVariable(
        'DESKTOP_UPDATER_SMOKE_APPLICATION_EXECUTABLE',
        [EnvironmentVariableTarget]::Process
      )
    'DESKTOP_UPDATER_SMOKE_RELEASE_KEY_ID' =
      [Environment]::GetEnvironmentVariable(
        'DESKTOP_UPDATER_SMOKE_RELEASE_KEY_ID',
        [EnvironmentVariableTarget]::Process
      )
    'DESKTOP_UPDATER_SMOKE_RELEASE_PUBLIC_KEY' =
      [Environment]::GetEnvironmentVariable(
        'DESKTOP_UPDATER_SMOKE_RELEASE_PUBLIC_KEY',
        [EnvironmentVariableTarget]::Process
      )
    'DESKTOP_UPDATER_SMOKE_POLICY_ID' =
      [Environment]::GetEnvironmentVariable(
        'DESKTOP_UPDATER_SMOKE_POLICY_ID',
        [EnvironmentVariableTarget]::Process
      )
    'DESKTOP_UPDATER_SMOKE_HELPER_SERVICE_ID' =
      [Environment]::GetEnvironmentVariable(
        'DESKTOP_UPDATER_SMOKE_HELPER_SERVICE_ID',
        [EnvironmentVariableTarget]::Process
      )
    'DESKTOP_UPDATER_SMOKE_HOOK_TEMP_ROOT' =
      [Environment]::GetEnvironmentVariable(
        'DESKTOP_UPDATER_SMOKE_HOOK_TEMP_ROOT',
        [EnvironmentVariableTarget]::Process
      )
    'DESKTOP_UPDATER_CONTROLLER_SMOKE' = '1'
    'DESKTOP_UPDATER_APP_ARCHIVE_URL' = $AppArchiveUrl
    'DESKTOP_UPDATER_EXPECTED_PACKAGE_ID' = $ExpectedPackageId
    'DESKTOP_UPDATER_TRUSTED_PUBLIC_KEY_ID' = $TrustedPublicKeyId
    'DESKTOP_UPDATER_TRUSTED_PUBLIC_KEY' = $TrustedPublicKey
    'DESKTOP_UPDATER_RECOVERY_STORE_PATH' = $RecoveryStorePath
    'DESKTOP_UPDATER_SMOKE_MARKER' = $MarkerPath
    'DESKTOP_UPDATER_SMOKE_DIAGNOSTICS_LOG' = $DiagnosticsPath
    'DESKTOP_UPDATER_SMOKE_EXIT_AFTER_FAILURE' = '1'
  }
  foreach ($entry in $childEnvironment.GetEnumerator()) {
    if ($null -eq $entry.Value) {
      $launcherLines += ('$env:' + $entry.Key + ' = $null')
    } else {
      $launcherLines += ('$env:' + $entry.Key + ' = ' + (
          ConvertTo-PowerShellSingleQuoted ([string] $entry.Value)
        ))
    }
  }
  $launcherLines += @(
    '& "$env:SystemRoot\System32\whoami.exe" /groups | Set-Content -LiteralPath $tokenProofPath -Encoding UTF8'
    '$startInfo = [Diagnostics.ProcessStartInfo]::new()'
    '$startInfo.FileName = $executablePath'
    '$startInfo.WorkingDirectory = $workingDirectory'
    '$startInfo.UseShellExecute = $false'
    '$process = $null'
    '$exitCode = 1'
    'try {'
    '  $process = [Diagnostics.Process]::Start($startInfo)'
    '  [IO.File]::WriteAllText($processIdPath, [string] $process.Id, [Text.UTF8Encoding]::new($false))'
    '  $process.WaitForExit()'
    '  $exitCode = $process.ExitCode'
    '} catch {'
    '  [IO.File]::WriteAllText($errorPath, $_.Exception.ToString(), [Text.UTF8Encoding]::new($false))'
    '} finally {'
    '  if ($null -ne $process) { $process.Dispose() }'
    '}'
    '[IO.File]::WriteAllText($completionPath, [string] $exitCode, [Text.UTF8Encoding]::new($false))'
    'exit $exitCode'
  )
  [IO.File]::WriteAllText(
    $launcherPath,
    ($launcherLines -join [Environment]::NewLine),
    [Text.UTF8Encoding]::new($false)
  )
  $unelevatedPowerShell = Join-Path $env:WINDIR `
    'System32\WindowsPowerShell\v1.0\powershell.exe'
  if (-not (Test-Path -LiteralPath $unelevatedPowerShell -PathType Leaf)) {
    throw "Windows PowerShell host is missing: $unelevatedPowerShell"
  }
  Ensure-UnelevatedProcessLauncherType
  $launcherArguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' +
    (ConvertTo-WindowsCommandLineArgument $launcherPath)
  try {
    [DesktopUpdater.UnelevatedProcess]::Start(
      $unelevatedPowerShell,
      $launcherArguments,
      $ControllerTempRoot
    ) | Out-Null
    Wait-Until {
      $markerValue = if (
        Test-Path -LiteralPath $MarkerPath -PathType Leaf
      ) {
        Get-Content -Raw -LiteralPath $MarkerPath
      } else {
        $null
      }
      $null -ne $markerValue -and
      $markerValue.Trim() -eq 'installing'
    } 180 'Installed 3.1.2 app did not reach the protected Inno handoff.'

    Wait-Until {
      Test-Path -LiteralPath $launcherExitPath -PathType Leaf
    } 120 'Installed 3.1.2 app did not exit after committing the update.'
    $exitCode = 0
    $exitText = (Get-Content -Raw -LiteralPath $launcherExitPath).Trim()
    if (-not [int]::TryParse($exitText, [ref] $exitCode)) {
      throw "Installed 3.1.2 launcher wrote an invalid exit code: $exitText"
    }
    $processId = 0
    $processIdText = if (
      Test-Path -LiteralPath $launcherProcessIdPath -PathType Leaf
    ) {
      (Get-Content -Raw -LiteralPath $launcherProcessIdPath).Trim()
    } else {
      ''
    }
    if (-not [int]::TryParse($processIdText, [ref] $processId)) {
      throw "Installed 3.1.2 launcher did not report an app process ID: $processIdText"
    }
    if ($exitCode -ne 0) {
      $launcherError = if (
        Test-Path -LiteralPath $launcherErrorPath -PathType Leaf
      ) {
        (Get-Content -Raw -LiteralPath $launcherErrorPath).Trim()
      } else {
        ''
      }
      $detail = if ([string]::IsNullOrWhiteSpace($launcherError)) {
        ''
      } else {
        " $launcherError"
      }
      throw "Installed 3.1.2 app exited with code $exitCode.$detail"
    }
    return $processId
  } finally {
    if (-not (Test-Path -LiteralPath $launcherExitPath -PathType Leaf)) {
      Stop-ExactExecutableProcesses $ExecutablePath
    }
  }
}

if ($env:OS -ne 'Windows_NT') {
  throw 'Windows Inno smoke requires Windows.'
}
if ($PSVersionTable.PSVersion.Major -lt 7) {
  throw 'Windows Inno smoke requires PowerShell 7 or newer.'
}
$principal = [Security.Principal.WindowsPrincipal]::new(
  [Security.Principal.WindowsIdentity]::GetCurrent()
)
if (-not $principal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
  )) {
  throw 'Windows Inno smoke must run in a signed, UAC-approved administrator process.'
}

$repoRoot = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
$exampleRoot = Join-Path $repoRoot 'example'
$resolvedIscc = Resolve-Iscc $IsccPath
$resolvedSigntool = Resolve-Signtool $SigntoolPath
$script:certificateSha1 = $SigningCertificateSha1.ToUpperInvariant()
$script:certificateSha256 = $SigningCertificateSha256.ToLowerInvariant()
$script:certificatePublisher = $SigningPublisher.Trim()
Assert-SmokeCertificate `
  $script:certificateSha1 $script:certificateSha256 `
  $script:certificatePublisher

$reportsRoot = Join-Path $repoRoot 'reports'
$readinessRoot = Join-Path $reportsRoot `
  'windows-arm64-production-readiness'
$workParent = Join-Path $readinessRoot 'work'
$replayMode = -not [string]::IsNullOrWhiteSpace($ReplayRunToken)
$replayAttemptToken = $null
if ($replayMode) {
  $runToken = $ReplayRunToken.ToLowerInvariant()
  $replayAttemptToken = [Guid]::NewGuid().ToString('N').ToLowerInvariant()
  $artifactRoot = Join-Path $workParent "inno-$runToken"
  $resolvedArtifactRoot = [IO.Path]::GetFullPath($artifactRoot)
  $resolvedWorkParent = [IO.Path]::GetFullPath($workParent).TrimEnd(
    [IO.Path]::DirectorySeparatorChar
  ) + [IO.Path]::DirectorySeparatorChar
  if (-not $resolvedArtifactRoot.StartsWith(
      $resolvedWorkParent,
      [StringComparison]::OrdinalIgnoreCase
    ) -or
      [IO.Path]::GetFileName($resolvedArtifactRoot) -ne "inno-$runToken" -or
      -not (Test-Path -LiteralPath $resolvedArtifactRoot -PathType Container) -or
      ((Get-Item -LiteralPath $resolvedArtifactRoot).Attributes -band
        [IO.FileAttributes]::ReparsePoint)) {
    throw 'Refusing to replay an unexpected Inno work root.'
  }
  $tempLeaf = "ir-$($replayAttemptToken.Substring(0, 8))"
  $evidenceLeaf = "inno-e2e-$runToken-replay-$replayAttemptToken"
} else {
  $runToken = [Guid]::NewGuid().ToString('N').ToLowerInvariant()
  $tempLeaf = "inno-$runToken"
  $evidenceLeaf = "inno-e2e-$runToken"
  $artifactRoot = Join-Path $workParent $tempLeaf
}
$tempRoot = Join-Path $workParent $tempLeaf
$evidenceRoot = Join-Path $readinessRoot $evidenceLeaf
if ((Test-Path -LiteralPath $tempRoot) -or
    (Test-Path -LiteralPath $evidenceRoot)) {
  throw 'Unique Windows Inno runtime or evidence path already exists.'
}
New-Item -ItemType Directory -Path $tempRoot, $evidenceRoot | Out-Null

$programFiles = [IO.Path]::GetFullPath(
  [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)
)
$packageId = "com.openai.desktop-updater.arm64-readiness.$runToken"
$appId = "desktop-updater-arm64-readiness-$runToken"
$policyId = "$packageId.policy.v1"
$helperServiceId = "$packageId.helper.v1"
$installRoot = Join-Path $programFiles "DesktopUpdaterArm64Readiness-$runToken"
$helperInstall312 = Join-Path $programFiles (
  "DesktopUpdaterHelperGenerationV1--$packageId--3.1.2"
)
$helperInstall313 = Join-Path $programFiles (
  "DesktopUpdaterHelperGenerationV1--$packageId--3.1.3"
)
$protectedHelperInstallDirs = @($helperInstall312, $helperInstall313)
$controllerTempRoot = Join-Path $tempRoot 'controller-temp'
$processTempRoot = Join-Path $tempRoot 'process-temp'
$localAppDataRoot = Join-Path $tempRoot 'local-app-data'
$hookTempRoot = Join-Path $tempRoot 'hook-temp'
$markerPath = Join-Path $tempRoot 'marker.txt'
$recoveryStorePath = Join-Path $tempRoot 'pending-install.json'
$diagnosticsPath = Join-Path $tempRoot 'controller-diagnostics.jsonl'
$keyProfilePath = Join-Path $tempRoot 'desktop_updater.keys.json'
$webRoot = Join-Path $tempRoot 'web'
if ($replayMode) {
  $keyProfilePath = Join-Path $artifactRoot 'desktop_updater.keys.json'
  $webRoot = Join-Path $artifactRoot 'web'
}
$installedExe = Join-Path $installRoot 'desktop_updater_example.exe'
$installedSentinel = Join-Path $installRoot `
  'desktop_updater_inno_smoke_version.txt'
$signingHookPath = Join-Path $repoRoot `
  'tool\windows_inno_smoke_signing_hook.ps1'
$feedServer = $null
$installationStarted = $false
$uninstallCompleted = $false
$primaryFailure = $null
$cleanupFailures = @()
$versionEvidence = @()
$relaunchProcessId = $null
$smokeStart = $null
$exampleDartPackageMetadataState = $null

$environmentNames = @(
  'TEMP'
  'TMP'
  'LOCALAPPDATA'
  'DESKTOP_UPDATER_PROTECTED_HELPER_INSTALL_DIR'
  'DESKTOP_UPDATER_SMOKE_SIGNTOOL_PATH'
  'DESKTOP_UPDATER_SMOKE_SIGNING_CERTIFICATE_SHA1'
  'DESKTOP_UPDATER_SMOKE_SIGNING_CERTIFICATE_SHA256'
  'DESKTOP_UPDATER_SMOKE_SIGNING_PUBLISHER'
  'DESKTOP_UPDATER_SMOKE_INSTALL_ROOT'
  'DESKTOP_UPDATER_SMOKE_APPLICATION_EXECUTABLE'
  'DESKTOP_UPDATER_SMOKE_RELEASE_KEY_ID'
  'DESKTOP_UPDATER_SMOKE_RELEASE_PUBLIC_KEY'
  'DESKTOP_UPDATER_SMOKE_POLICY_ID'
  'DESKTOP_UPDATER_SMOKE_HELPER_SERVICE_ID'
  'DESKTOP_UPDATER_SMOKE_HOOK_TEMP_ROOT'
)
$savedEnvironment = @{}
foreach ($name in $environmentNames) {
  $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable(
    $name,
    [EnvironmentVariableTarget]::Process
  )
}
$replaySource = $null
if ($replayMode) {
  $replaySource = $artifactRoot
}

$result = [ordered]@{
  schemaVersion = 1
  status = 'running'
  runToken = $runToken
  sourceVersion = '3.1.2'
  sourceBuildNumber = 312
  targetVersion = '3.1.3'
  targetBuildNumber = 313
  packageId = $packageId
  installRoot = $installRoot
  protectedHelperInstallDirs = $protectedHelperInstallDirs
  certificateSha1 = $script:certificateSha1
  certificateSha256 = $script:certificateSha256
  certificatePublisher = $script:certificatePublisher
  versions = @()
  relaunchProcessId = $null
  helperEventIds = @()
  replayAttemptToken = $replayAttemptToken
  replaySource = $replaySource
  cleanup = 'pending'
  error = $null
}

$runtimeDirectories = @(
  $processTempRoot,
  $localAppDataRoot,
  $hookTempRoot
)
if (-not $replayMode) {
  $runtimeDirectories += $webRoot
}
New-Item -ItemType Directory -Path $runtimeDirectories | Out-Null
[Environment]::SetEnvironmentVariable(
  'TEMP',
  $processTempRoot,
  [EnvironmentVariableTarget]::Process
)
[Environment]::SetEnvironmentVariable(
  'TMP',
  $processTempRoot,
  [EnvironmentVariableTarget]::Process
)
[Environment]::SetEnvironmentVariable(
  'LOCALAPPDATA',
  $localAppDataRoot,
  [EnvironmentVariableTarget]::Process
)
$env:DESKTOP_UPDATER_SMOKE_SIGNTOOL_PATH = $resolvedSigntool
$env:DESKTOP_UPDATER_SMOKE_SIGNING_CERTIFICATE_SHA1 =
  $script:certificateSha1
$env:DESKTOP_UPDATER_SMOKE_SIGNING_CERTIFICATE_SHA256 =
  $script:certificateSha256
$env:DESKTOP_UPDATER_SMOKE_SIGNING_PUBLISHER =
  $script:certificatePublisher
$env:DESKTOP_UPDATER_SMOKE_APPLICATION_EXECUTABLE =
  'desktop_updater_example.exe'
$env:DESKTOP_UPDATER_SMOKE_POLICY_ID = $policyId
$env:DESKTOP_UPDATER_SMOKE_HELPER_SERVICE_ID = $helperServiceId
$env:DESKTOP_UPDATER_SMOKE_HOOK_TEMP_ROOT = $hookTempRoot

try {
  if (-not $replayMode) {
    $exampleDartPackageMetadataState = Save-ExampleDartPackageMetadata `
      $exampleRoot $tempRoot
  }
  if ((Test-Path -LiteralPath $installRoot) -or
      (Test-Path -LiteralPath $helperInstall312) -or
      (Test-Path -LiteralPath $helperInstall313)) {
    throw 'Task-unique Program Files paths unexpectedly exist before smoke.'
  }

  $feedServerOut = Join-Path $tempRoot 'feed-server.out'
  $feedServerErr = Join-Path $tempRoot 'feed-server.err'
  $probePort = 0
  if ($replayMode) {
    $feedPort = Get-PreparedReplayFeedPort $webRoot
    $probePort = $feedPort
  }
  $portProbe = [Net.Sockets.TcpListener]::new(
    [Net.IPAddress]::Loopback,
    $probePort
  )
  try {
    try {
      $portProbe.Start()
    } catch {
      if ($replayMode) {
        throw "Prepared replay feed port $feedPort is unavailable."
      }
      throw
    }
    if (-not $replayMode) {
      $feedPort = ([Net.IPEndPoint] $portProbe.LocalEndpoint).Port
    }
  } finally {
    $portProbe.Stop()
  }
  $feedBaseUrl = "http://127.0.0.1:$feedPort/"
  $dartServerExecutable = (Get-Command 'dart' -ErrorAction Stop).Source
  if ([IO.Path]::GetExtension($dartServerExecutable) -eq '.bat') {
    $dartServerExecutable = Join-Path `
      (Split-Path $dartServerExecutable -Parent) `
      'cache/dart-sdk/bin/dart.exe'
  }
  if (-not (Test-Path -LiteralPath $dartServerExecutable -PathType Leaf)) {
    throw "Dart executable is missing: $dartServerExecutable"
  }
  $feedServer = Start-Process -FilePath $dartServerExecutable -ArgumentList @(
    'run'
    'tool/native_transport_fixture_server.dart'
    '--port'
    $feedPort
    '--root'
    $webRoot
  ) -WorkingDirectory $repoRoot -RedirectStandardOutput $feedServerOut `
    -RedirectStandardError $feedServerErr -WindowStyle Hidden -PassThru
  $feedReady = $false
  for ($attempt = 0; $attempt -lt 120; $attempt++) {
    try {
      Invoke-WebRequest -UseBasicParsing "${feedBaseUrl}health" | Out-Null
      $feedReady = $true
      break
    } catch {
      Start-Sleep -Milliseconds 250
    }
  }
  if (-not $feedReady) {
    Get-Content -LiteralPath $feedServerOut, $feedServerErr `
      -ErrorAction SilentlyContinue | Out-Host
    throw 'Local Inno feed probe server did not become ready.'
  }

  if ($replayMode) {
    $version1 = Import-PreparedSmokeVersion `
      $artifactRoot $webRoot $keyProfilePath '3.1.2' 312 $packageId `
      $script:certificateSha256 $evidenceRoot
  } else {
    $version1Arguments = @{
      ExampleRoot = $exampleRoot
      TempRoot = $tempRoot
      ResolvedIscc = $resolvedIscc
      FeedBaseUrl = $feedBaseUrl
      WebRoot = $webRoot
      KeyProfilePath = $keyProfilePath
      Version = '3.1.2'
      BuildNumber = '312'
      PackageId = $packageId
      AppId = $appId
      ProtectedHelperInstallDir = $helperInstall312
      InstallRoot = $installRoot
      CertificateSha256 = $script:certificateSha256
      SigningHookPath = $signingHookPath
      EvidenceRoot = $evidenceRoot
      InitializeFeed = $true
    }
    $version1 = Publish-SmokeVersion @version1Arguments
  }
  $versionEvidence += $version1

  $installationStarted = $true
  $initialInstallLog = Join-Path $tempRoot 'inno-initial-install.log'
  Invoke-Checked $version1.ArtifactPath @(
    '/VERYSILENT'
    '/SUPPRESSMSGBOXES'
    '/NORESTART'
    "/DIR=$installRoot"
    "/LOG=$initialInstallLog"
  ) $repoRoot
  if (-not (Test-Path -LiteralPath $installedExe -PathType Leaf)) {
    throw "Version 3.1.2 executable was not installed: $installedExe"
  }
  Assert-FileText $installedSentinel '3.1.2'
  Assert-AuthenticodeIdentity `
    $installedExe $script:certificateSha1 $script:certificateSha256 `
    $script:certificatePublisher
  Assert-ProtectedHelperGeneration `
    $helperInstall312 $packageId $script:certificateSha1 `
    $script:certificateSha256 $script:certificatePublisher
  $initialEndpoints = @(Read-EndpointRecords $packageId)
  if ($initialEndpoints.Count -ne 1 -or
      (ConvertTo-WindowsInnoComparablePath `
        ([string] $initialEndpoints[0].helperPath)) -ne
        (ConvertTo-WindowsInnoComparablePath `
          (Join-Path $helperInstall312 'desktop_updater_install_helper.exe'))) {
    throw 'The 3.1.2 protected helper endpoint was not registered exactly.'
  }
  $initialUninstall = Get-UninstallRecord $packageId $installRoot
  if ([string] $initialUninstall.Record.DisplayVersion -ne '3.1.2' -or
      [string] $initialUninstall.Record.DesktopUpdaterBuildNumber -ne '312') {
    throw 'The initial Inno uninstall version/build proof is invalid.'
  }

  if ($replayMode) {
    $version2 = Import-PreparedSmokeVersion `
      $artifactRoot $webRoot $keyProfilePath '3.1.3' 313 $packageId `
      $script:certificateSha256 $evidenceRoot
  } else {
    $version2Arguments = @{
      ExampleRoot = $exampleRoot
      TempRoot = $tempRoot
      ResolvedIscc = $resolvedIscc
      FeedBaseUrl = $feedBaseUrl
      WebRoot = $webRoot
      KeyProfilePath = $keyProfilePath
      Version = '3.1.3'
      BuildNumber = '313'
      PackageId = $packageId
      AppId = $appId
      ProtectedHelperInstallDir = $helperInstall313
      InstallRoot = $installRoot
      CertificateSha256 = $script:certificateSha256
      SigningHookPath = $signingHookPath
      EvidenceRoot = $evidenceRoot
      InitializeFeed = $false
    }
    $version2 = Publish-SmokeVersion @version2Arguments
  }
  $versionEvidence += $version2

  $existingProcessIds = @(
    Get-ExactExecutableProcesses $installedExe | ForEach-Object {
      [int] $_.ProcessId
    }
  )
  $smokeStart = Get-Date
  $callerProcessId = Invoke-InstalledAppUpdate `
    $installedExe "${feedBaseUrl}app-archive.json" $version2.PackageId `
    $version2.TrustedPublicKeyId $version2.TrustedPublicKey `
    $recoveryStorePath $controllerTempRoot $markerPath $diagnosticsPath

  Wait-Until {
    (Test-Path -LiteralPath $installedSentinel -PathType Leaf) -and
    ((Get-Content -Raw -LiteralPath $installedSentinel).Trim() -eq '3.1.3')
  } 180 'Version 3.1.3 sentinel was not installed.'
  Wait-Until {
    @(Get-ChildItem -LiteralPath $controllerTempRoot -Directory `
        -Filter 'desktop_updater_stage_*' -ErrorAction SilentlyContinue).Count `
      -eq 0
  } 60 'Controller-owned Inno staging directory was not cleaned.'

  $relaunch = Wait-ForNewExactExecutableProcess `
    $installedExe (@($existingProcessIds) + @($callerProcessId)) 90
  $relaunchProcessId = [int] $relaunch.ProcessId
  Stop-Process -Id $relaunchProcessId -Force
  Wait-Process -Id $relaunchProcessId -Timeout 15 -ErrorAction SilentlyContinue

  Assert-FileText $installedSentinel '3.1.3'
  Assert-AuthenticodeIdentity `
    $installedExe $script:certificateSha1 $script:certificateSha256 `
    $script:certificatePublisher
  $installedHash = (
    Get-FileHash -LiteralPath $installedExe -Algorithm SHA256
  ).Hash.ToLowerInvariant()
  if ($installedHash -ne $version2.InstalledExecutableSha256) {
    throw 'Installed 3.1.3 executable does not match signed release authority.'
  }
  Assert-ProtectedHelperGeneration `
    $helperInstall312 $packageId $script:certificateSha1 `
    $script:certificateSha256 $script:certificatePublisher
  Assert-ProtectedHelperGeneration `
    $helperInstall313 $packageId $script:certificateSha1 `
    $script:certificateSha256 $script:certificatePublisher

  $finalEndpoints = @(Read-EndpointRecords $packageId)
  $endpointPaths = @($finalEndpoints | ForEach-Object {
    ConvertTo-WindowsInnoComparablePath ([string] $_.helperPath)
  })
  $expectedEndpointPaths = @(
    ConvertTo-WindowsInnoComparablePath (
      Join-Path $helperInstall312 'desktop_updater_install_helper.exe'
    )
    ConvertTo-WindowsInnoComparablePath (
      Join-Path $helperInstall313 'desktop_updater_install_helper.exe'
    )
  )
  if ($endpointPaths.Count -ne 2 -or
      @($expectedEndpointPaths | Where-Object {
        $endpointPaths -notcontains $_
      }).Count -ne 0) {
    throw 'Version-addressed protected helper endpoints are incomplete.'
  }

  $finalUninstall = Get-UninstallRecord $packageId $installRoot
  if ([string] $finalUninstall.Record.DisplayVersion -ne '3.1.3' -or
      [string] $finalUninstall.Record.DesktopUpdaterBuildNumber -ne '313') {
    throw 'The 3.1.3 Inno uninstall version/build proof is invalid.'
  }
  $controllerDiagnostics = Get-Content -Raw -LiteralPath $diagnosticsPath
  foreach ($event in @('checking', 'downloading', 'installing')) {
    if (-not $controllerDiagnostics.Contains("event=$event")) {
      throw "Controller diagnostics are missing the $event event."
    }
  }

  $helperEvents = @(
    Get-WinEvent -FilterHashtable @{
      LogName = 'Application'
      StartTime = $smokeStart.AddSeconds(-1)
    } -ErrorAction SilentlyContinue |
      Where-Object ProviderName -eq 'DesktopUpdater.InstallHelper.ProtocolV1'
  )
  $helperEventIds = @($helperEvents | ForEach-Object Id)
  if ($helperEventIds -notcontains 1003 -or
      $helperEventIds -notcontains 1016) {
    throw 'Protected helper Event Log evidence is incomplete.'
  }
  @($helperEvents | ForEach-Object {
    [ordered]@{
      id = $_.Id
      timeCreated = $_.TimeCreated.ToUniversalTime().ToString('o')
      level = $_.LevelDisplayName
      message = $_.Message
    }
  }) | ConvertTo-Json -Depth 4 | Set-Content `
    -LiteralPath (Join-Path $evidenceRoot 'helper-events.json') `
    -Encoding UTF8NoBOM

  Copy-Item -LiteralPath $diagnosticsPath `
    -Destination (Join-Path $evidenceRoot 'controller-diagnostics.jsonl') `
    -Force
  if (Test-Path -LiteralPath $initialInstallLog -PathType Leaf) {
    Copy-Item -LiteralPath $initialInstallLog `
      -Destination (Join-Path $evidenceRoot 'inno-initial-install.log') -Force
  }
  Get-ChildItem -LiteralPath $tempRoot -Recurse `
    -Filter 'desktop_updater_inno_install.log' -ErrorAction SilentlyContinue |
    ForEach-Object {
      Copy-Item -LiteralPath $_.FullName `
        -Destination (Join-Path $evidenceRoot 'inno-update-install.log') `
        -Force
    }

  $uninstaller = Get-ChildItem -LiteralPath $installRoot `
    -Filter 'unins*.exe' | Sort-Object Name | Select-Object -First 1
  if (-not $uninstaller) {
    throw 'Inno uninstaller is missing after the 3.1.3 update.'
  }
  Invoke-Checked $uninstaller.FullName @(
    '/VERYSILENT'
    '/SUPPRESSMSGBOXES'
    '/NORESTART'
  ) $repoRoot
  $uninstallCompleted = $true
  Wait-Until {
    -not (Test-Path -LiteralPath $installedExe) -and
    -not (Test-Path -LiteralPath $installedSentinel)
  } 90 'Inno uninstall did not remove the 3.1.3 payload.'
  Wait-Until {
    -not (Test-Path -LiteralPath $installRoot)
  } 60 'Inno uninstaller did not finish cleaning the install directory.'

  $result.status = 'passed'
  $result.versions = @($versionEvidence | ForEach-Object {
    [ordered]@{
      version = $_.Version
      buildNumber = $_.BuildNumber
      artifactSha256 = $_.ArtifactSha256
      artifactLength = $_.ArtifactLength
      installedExecutableSha256 = $_.InstalledExecutableSha256
    }
  })
  $result.relaunchProcessId = $relaunchProcessId
  $result.helperEventIds = @($helperEventIds | Sort-Object -Unique)
} catch {
  $primaryFailure = $_
  $result.status = 'failed'
  $result.error = $_.Exception.Message
} finally {
  if ($null -ne $feedServer -and -not $feedServer.HasExited) {
    Stop-Process -Id $feedServer.Id -Force -ErrorAction SilentlyContinue
    Wait-Process -Id $feedServer.Id -Timeout 15 -ErrorAction SilentlyContinue
  }
  if ($installationStarted -and -not $uninstallCompleted -and
      (Test-Path -LiteralPath $installRoot -PathType Container)) {
    try {
      Stop-ExactExecutableProcesses $installedExe
      $cleanupUninstaller = Get-ChildItem -LiteralPath $installRoot `
        -Filter 'unins*.exe' -ErrorAction SilentlyContinue |
        Sort-Object Name | Select-Object -First 1
      if ($cleanupUninstaller) {
        Invoke-Checked $cleanupUninstaller.FullName @(
          '/VERYSILENT'
          '/SUPPRESSMSGBOXES'
          '/NORESTART'
        ) $repoRoot
      }
    } catch {
      $cleanupFailures += "uninstaller cleanup: $($_.Exception.Message)"
    }
  }
  $cleanupFailures += @(Remove-SmokeSystemResidue `
    $packageId $policyId $helperServiceId $installRoot `
    $protectedHelperInstallDirs)

  foreach ($name in $environmentNames) {
    [Environment]::SetEnvironmentVariable(
      $name,
      $savedEnvironment[$name],
      [EnvironmentVariableTarget]::Process
    )
  }

  if ($null -ne $exampleDartPackageMetadataState) {
    try {
      Restore-ExampleDartPackageMetadata `
        $exampleRoot $tempRoot $exampleDartPackageMetadataState
    } catch {
      $cleanupFailures += "Dart package metadata restore: $($_.Exception.Message)"
    }
  }

  if ($cleanupFailures.Count -eq 0) {
    $result.cleanup = 'passed'
  } else {
    $result.cleanup = 'failed'
    if ($null -eq $primaryFailure) {
      $result.status = 'failed'
      $result.error = $cleanupFailures -join '; '
    }
  }
  $result.cleanupFailures = @($cleanupFailures)
  $result.completedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
  $result | ConvertTo-Json -Depth 8 | Set-Content `
    -LiteralPath (Join-Path $evidenceRoot 'result.json') `
    -Encoding UTF8NoBOM

  if ($KeepArtifacts) {
    Write-Host "Keeping bounded Windows Inno work files: $tempRoot"
  } else {
    $resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
    $resolvedWorkParent = [IO.Path]::GetFullPath($workParent).TrimEnd(
      [IO.Path]::DirectorySeparatorChar
    ) + [IO.Path]::DirectorySeparatorChar
    if (-not $resolvedTemp.StartsWith(
        $resolvedWorkParent,
        [StringComparison]::OrdinalIgnoreCase
      ) -or [IO.Path]::GetFileName($resolvedTemp) -ne $tempLeaf) {
      throw "Refusing to clean unexpected bounded work path: $resolvedTemp"
    }
    if (Test-Path -LiteralPath $resolvedTemp) {
      Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
    }
  }
}

if ($null -ne $primaryFailure) {
  [Console]::Error.WriteLine(($primaryFailure | Out-String))
  exit 1
}
if ($cleanupFailures.Count -ne 0) {
  [Console]::Error.WriteLine(
    "Windows Inno smoke cleanup failed: $($cleanupFailures -join '; ')"
  )
  exit 1
}

Write-Host 'Protected Windows Inno 3.1.2 -> 3.1.3 smoke passed.'
Write-Host "Evidence: $evidenceRoot"
exit 0
