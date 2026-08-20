import "dart:io";

import "package:flutter_test/flutter_test.dart";

void main() {
  test("updater smoke supports Windows Release output", () {
    final source = File("example/tool/updater_smoke.dart").readAsStringSync();

    expect(source, contains("--config Debug|Release"));
    expect(source, contains('"windows"'));
    expect(source, contains('"runner"'));
    expect(source, contains("config,"));
    expect(source, contains('"desktop_updater_example.exe"'));
    expect(source, contains("DESKTOP_UPDATER_EXPECTED_PACKAGE_ID"));
    expect(source, contains("DESKTOP_UPDATER_TRUSTED_PUBLIC_KEY"));
    expect(source, contains("DESKTOP_UPDATER_SMOKE_DIAGNOSTICS_LOG"));
    expect(source, contains(r'"event":"$event"'));
    expect(source, contains("--diagnostics-log <path>"));
    expect(
      source,
      contains('? "2.7.1" : value.trim()'),
    );
    expect(source, contains('int.tryParse(raw ?? "271")'));
  });

  test("Windows updater smoke allows helper preparation before app exit", () {
    final source = File("example/tool/updater_smoke.dart").readAsStringSync();

    expect(
      source,
      contains(
        "const _defaultInitialAppExitTimeout = Duration(seconds: 30);",
      ),
    );
    expect(
      source,
      contains(
        "const _windowsInitialAppExitTimeout = Duration(seconds: 60);",
      ),
    );
    expect(
      source,
      matches(
        RegExp(
          r"final initialAppExitTimeout = Platform\.isWindows\s*"
          r"\? _windowsInitialAppExitTimeout\s*"
          r": _defaultInitialAppExitTimeout;",
        ),
      ),
    );
    expect(
      source,
      matches(
        RegExp(
          r"final exitCode = await process\.exitCode\.timeout\(\s*"
          r"initialAppExitTimeout,",
        ),
      ),
    );
  });

  test("Windows update smoke does not pin its replaceable install directory",
      () {
    final runner =
        File("tool/windows_direct_flutter_smoke.ps1").readAsStringSync();

    expect(runner, contains(r"$runnerWorkingDirectory = $smokeRoot"));
    expect(
      runner,
      contains(
        r"workingDirectory = ConvertTo-WindowsSmokeEvidenceText $runnerWorkingDirectory",
      ),
    );
    expect(runner, isNot(contains(r"runnerWorkingDirectory = $install")));
    expect(
      runner,
      matches(
        RegExp(
          r"\$smokeProcess = Start-Process -FilePath \$smokeRunner[\s\S]*?"
          r"-WorkingDirectory \$runnerWorkingDirectory[\s\S]*?"
          r"-PassThru",
        ),
      ),
    );
    expect(runner, contains(r"Wait-Process -Id $smokeProcess.Id"));
    expect(
      runner,
      contains(r"-Timeout $smokeRunnerTimeoutSeconds"),
    );
    expect(runner, contains("windows_process_tree_cleanup.ps1"));
    expect(runner, contains("Stop-ExactProcessTree -RootProcessId"));
    expect(runner, isNot(contains(r"-WorkingDirectory $install")));
  });

  test("Windows smoke delegates cross-user relaunch cleanup to the wrapper",
      () {
    final smoke = _readCanonicalText("example/tool/updater_smoke.dart");
    final runner =
        File("tool/windows_direct_flutter_smoke.ps1").readAsStringSync();

    expect(
      smoke,
      contains(
        'const _windowsExternalRelaunchCleanupEnvironment =\n'
        '    "DESKTOP_UPDATER_SMOKE_EXTERNAL_RELAUNCH_CLEANUP";',
      ),
    );
    final cleanupFunction = smoke.substring(
      smoke.indexOf("Future<void> _closeWindowsSmokeRelaunch"),
      smoke.indexOf(
        "Future<List<int>> _windowsSmokeProcessIds",
      ),
    );
    expect(cleanupFunction, isNot(contains('"/IM"')));
    expect(cleanupFunction, contains('<String>["/F", "/T", "/PID"'));
    expect(
      cleanupFunction.indexOf(
        'Platform.environment[_windowsExternalRelaunchCleanupEnvironment]',
      ),
      lessThan(cleanupFunction.indexOf('"taskkill.exe"')),
    );
    expect(
      smoke,
      contains(
        'Platform.environment[_windowsExternalRelaunchCleanupEnvironment] == "1"',
      ),
    );
    expect(
      runner,
      contains(
        'DESKTOP_UPDATER_SMOKE_EXTERNAL_RELAUNCH_CLEANUP = "1"',
      ),
    );
    expect(runner, contains("Stop-WindowsSmokeRelaunchProcess"));
    expect(runner, contains("taskkill.exe /F /T /PID"));
    expect(runner, contains("Repair-WindowsSmokeCleanupAccess"));
    expect(runner, contains("SkipNestedReparseCheck"));
    expect(runner, contains("Visit-WindowsSmokeCleanupDirectory"));
    expect(runner, contains(r"$children = $null"));
    expect(
      runner,
      contains(r"Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop"),
    );
    expect(
      runner.indexOf(
          r"Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop"),
      lessThan(runner.indexOf(r"takeown.exe /F $Path")),
    );
    expect(runner, isNot(contains(r"takeown.exe /F $Path /D Y")));
    expect(runner, contains(r"takeown.exe /F $Root /R /D Y"));
    expect(runner, contains(r"icacls.exe $Root /reset /T /C"));
    expect(runner, contains("standard-user-filesystem-evidence.json"));
    expect(runner, contains("standard-user-filesystem-probe.ps1"));
    expect(runner, contains("DESKTOP_UPDATER_SMOKE_FILESYSTEM_EVIDENCE"));
    expect(runner, contains("standardUserFilesystemEvidence"));
    expect(runner, contains("lifecycleEvents"));
    expect(runner, contains(r"^event=(checking|downloading|installing)$"));
    expect(runner, contains("collectionWarnings"));
    expect(
      runner,
      contains(
          "provider-filtered event log unavailable; fallback event query used"),
    );
  });

  test(
      "Windows update smoke preserves failure evidence outside its cleanup root",
      () {
    final runner =
        File("tool/windows_direct_flutter_smoke.ps1").readAsStringSync();
    final workflow =
        File(".github/workflows/desktop-updater-ci.yml").readAsStringSync();

    expect(runner, contains(r"[string]$EvidencePath"));
    expect(
      runner,
      contains(r"$evidenceBase = [IO.Path]::GetFullPath($EvidencePath)"),
    );
    expect(
      runner,
      contains(r"$evidenceRoot = Join-Path $evidenceBase $smokeRunId"),
    );
    expect(
      runner,
      isNot(
        matches(
          RegExp(
            r"Remove-Item[^\r\n]*\$(?:evidenceRoot|evidenceBase)\b",
            caseSensitive: false,
          ),
        ),
      ),
    );
    expect(runner, contains(r"$smokeRootWithSeparator"));
    expect(runner, contains(r"$evidenceCaptureFailure"));
    expect(
      runner,
      contains(
        r'Set-Content -LiteralPath (Join-Path $evidenceRoot "report.json")',
      ),
    );
    expect(
      runner,
      contains(r"(Join-Path $evidenceRoot $textArtifact.name)"),
    );
    expect(runner, contains("Get-WinEvent"));
    expect(runner, contains("DesktopUpdater.InstallHelper.ProtocolV1"));
    expect(runner, contains("Read-WindowsSmokeSharedText"));
    expect(runner, contains(r"[IO.FileShare]::Delete"));
    expect(runner, contains("Get-FileHash"));
    expect(runner, isNot(contains("ZipArchive")));
    expect(runner, contains("Remove-WindowsSmokeRootWithRetry"));
    expect(runner, contains("Start-Sleep -Milliseconds 250"));
    expect(runner, isNot(contains(r"$_.CommandLine")));
    expect(runner, isNot(contains(".ToXml()")));
    expect(runner, contains("Get-Acl"));
    expect(runner, contains("Get-ScheduledTask"));
    expect(runner, contains('TaskName "DesktopUpdater-Portable-*"'));
    expect(runner, contains("record.json"));
    expect(runner, contains("record.next"));
    expect(runner, contains("resolver_claim.json"));
    expect(runner, contains("resolver_claim.next"));
    expect(runner, contains("locator.json"));
    expect(runner, contains("locator.next"));
    expect(runner, contains("Get-CimInstance Win32_Process"));
    expect(runner, contains("helper-or-recovery-active"));
    expect(runner, contains("schemaVersion = 1"));
    expect(runner, contains("MaximumBytes = 262144"));
    expect(runner, contains("primaryFailure"));
    expect(runner, contains("PortableLaunch"));
    expect(runner, contains("request-nonce|nonce"));
    expect(runner, contains("desktop-updater-[redacted]"));
    expect(runner, contains(r"$smokeRunId"));
    expect(
      runner.lastIndexOf(r"Save-WindowsFlutterSmokeEvidence"),
      lessThan(
        runner.lastIndexOf(
          r"Remove-WindowsSmokeRootWithRetry -Root $smokeRoot",
        ),
      ),
    );
    expect(runner, isNot(contains("DiagnosticsPath")));
    expect(runner, contains(r"Save-WindowsFlutterSmokeEvidence"));
    expect(
      runner,
      isNot(
        matches(
          RegExp(
            r"\[IO\.File\]::WriteAllText\(\s*"
            r"\$destination,\s*"
            r"\(Read-WindowsSmokeSharedText \$capturedDiagnostics\)",
          ),
        ),
      ),
    );
    expect(
      workflow,
      contains(
        r'-Configuration Debug -EvidencePath (Join-Path $PWD "reports/windows-v3-debug-run-1")',
      ),
    );
    expect(
      workflow,
      contains(
        r'-Configuration Debug -EvidencePath (Join-Path $PWD "reports/windows-v3-debug-run-2")',
      ),
    );
    expect(
      workflow,
      contains(
        r'-Configuration Release -EvidencePath (Join-Path $PWD "reports/windows-v3-release-run-1")',
      ),
    );
    expect(
      workflow,
      contains(
        r'-Configuration Release -EvidencePath (Join-Path $PWD "reports/windows-v3-release-run-2")',
      ),
    );
    expect(
      workflow,
      matches(
        RegExp(
          r"- name: Upload update smoke diagnostics\s*"
          r"if: \$\{\{ failure\(\) \|\| vars\.DESKTOP_UPDATER_UPLOAD_SMOKE_DIAGNOSTICS == '1' \}\}\s*"
          r"uses: actions/upload-artifact@v4\s*"
          r"with:\s*"
          r"name: windows-update-smoke-debug-diagnostics\s*"
          r"path:\s*\|\s*"
          r"reports/windows-v3-debug-run-*",
        ),
      ),
    );
    expect(
      workflow,
      matches(
        RegExp(
          r"- name: Upload update smoke release diagnostics\s*"
          r"if: \$\{\{ failure\(\) \|\| vars\.DESKTOP_UPDATER_UPLOAD_SMOKE_DIAGNOSTICS == '1' \}\}\s*"
          r"uses: actions/upload-artifact@v4\s*"
          r"with:\s*"
          r"name: windows-update-smoke-release-diagnostics\s*"
          r"path:\s*\|\s*"
          r"reports/windows-v3-release-run-*",
        ),
      ),
    );
  });

  test("local Windows Inno smoke uses one bounded release key profile", () {
    final source = File("tool/windows_inno_smoke.ps1").readAsStringSync();

    expect(
      source,
      contains(
        r"$keyProfilePath = Join-Path $tempRoot 'desktop_updater.keys.json'",
      ),
    );
    expect(
      source,
      contains(
        r"if (-not (Test-Path -LiteralPath $KeyProfilePath -PathType Leaf))",
      ),
    );
    expect(source, contains("'keygen'"));
    expect(RegExp("'--key-profile'").allMatches(source).length, 2);
    expect(RegExp("'--initialize-feed'").allMatches(source).length, 1);
    expect(source, isNot(contains("https://updates.invalid/")));
    expect(source, contains("tool/native_transport_fixture_server.dart"));
    expect(source, contains("'--root'"));
    expect(source, contains(r"$webRoot"));
    expect(
      source,
      contains("test/e2e/fixtures/upload_commands/copy_updates.dart"),
    );
    expect(source, contains("'--port'"));
    expect(source, contains("(Get-Command 'dart' -ErrorAction Stop).Source"));
    expect(source, contains("'cache/dart-sdk/bin/dart.exe'"));
    expect(source, contains("[Net.Sockets.TcpListener]::new("));
    expect(source, contains(r"$feedReady = $false"));
    expect(
      source,
      contains(r"for ($attempt = 0; $attempt -lt 120; $attempt++)"),
    );
    expect(
      source,
      contains(
        r'Invoke-WebRequest -UseBasicParsing "${feedBaseUrl}health"',
      ),
    );
    expect(source, contains("Stop-ExactProcessTree \$feedServer.Id"));
    expect(source, contains("native_transport_fixture_server.dart"));
    expect(
      source,
      matches(
        RegExp(
          r"function Publish-SmokeVersion\([\s\S]*?"
          r"\[string\] \$KeyProfilePath,",
        ),
      ),
    );
    expect(source, contains("Version = '3.1.2'"));
    expect(source, contains("Version = '3.1.3'"));
    expect(source, isNot(contains("DESKTOP_UPDATER_SMOKE_STAGING")));
    expect(source, contains("DESKTOP_UPDATER_CONTROLLER_SMOKE"));
    expect(source, contains("DESKTOP_UPDATER_APP_ARCHIVE_URL"));
    expect(source, contains("DESKTOP_UPDATER_EXPECTED_PACKAGE_ID"));
    expect(source, contains("DESKTOP_UPDATER_TRUSTED_PUBLIC_KEY_ID"));
    expect(source, contains("DESKTOP_UPDATER_TRUSTED_PUBLIC_KEY"));
    expect(source, contains("DESKTOP_UPDATER_RECOVERY_STORE_PATH"));
    expect(source, contains(r"$keyProfile.activeKeyId"));
    expect(source, contains(r"$version2.PackageId"));
    expect(source, contains("'--executable-relative-path'"));
    expect(source, contains("'desktop_updater_example.exe'"));
  });

  test("local Windows Inno smoke replays only verified bounded artifacts", () {
    final source = File("tool/windows_inno_smoke.ps1").readAsStringSync();

    expect(source, contains(r"[string] $ReplayRunToken"));
    expect(source, contains("Import-PreparedSmokeVersion"));
    expect(
      source,
      contains(r'$artifactRoot = Join-Path $workParent "inno-$runToken"'),
    );
    expect(source, contains(r'$replayAttemptToken'));
    expect(
      source,
      contains(r'$tempLeaf = "ir-$($replayAttemptToken.Substring(0, 8))"'),
    );
    expect(source, contains("Refusing to replay an unexpected Inno work root"));
    expect(source, contains(r"if ($replayMode)"));
    expect(source, contains(r"replaySource = $artifactRoot"));
  });

  test("local Windows Inno replay preserves its signed loopback feed port", () {
    final source = File("tool/windows_inno_smoke.ps1").readAsStringSync();

    expect(source, contains("Get-PreparedReplayFeedPort"));
    expect(source, contains("Prepared replay app archive"));
    expect(source, contains(r"[Uri]::TryCreate("));
    expect(source, contains(r"$releaseUri.Scheme -cne 'http'"));
    expect(source, contains(r"$releaseUri.Host -cne '127.0.0.1'"));
    expect(source, contains(r"$releaseUri.UserInfo"));
    expect(source, contains(r"$releaseUri.Query"));
    expect(source, contains(r"$releaseUri.Fragment"));
    expect(source, contains(r"$releaseUri.Port -lt 1"));
    expect(source, contains(r"$releaseUri.Port -gt 65535"));
    expect(
      source,
      contains(r'$feedPort = Get-PreparedReplayFeedPort $webRoot'),
    );
  });

  test("protected Windows Inno restage retains exact installer handles", () {
    final source = File(
      "windows/native/src/helper/windows_inno_restage.cpp",
    ).readAsStringSync();

    expect(
      source,
      contains(
        "VerifyRetainedWindowsExecutable(source.get(), source_installer)",
      ),
    );
    expect(
      source,
      contains(
        "VerifyRetainedWindowsExecutable(result->installer.get(), "
        "result->path)",
      ),
    );
    expect(
      source,
      contains(
        "VerifyRetainedWindowsExecutable(installer.get(), installer_path)",
      ),
    );
    expect(
      RegExp("VerifyRetainedWindowsExecutableStillMatches").allMatches(source),
      hasLength(3),
    );
    expect(source, isNot(contains("VerifyWindowsExecutable(")));
    expect(source, isNot(contains("VerifyWindowsExecutableStillMatches(")));
  });

  test("local Windows Inno cleanup tolerates an exact process exit race", () {
    final source = File("tool/windows_inno_smoke.ps1").readAsStringSync();
    final cleanup = RegExp(
      r"function Stop-ExactExecutableProcesses[\s\S]*?\n}",
    ).firstMatch(source)!.group(0)!;

    expect(cleanup, contains(r"$processId = [int] $process.ProcessId"));
    expect(cleanup, contains("catch"));
    expect(cleanup, contains(r"$stillExact"));
    expect(cleanup, contains("Get-ExactExecutableProcesses"));
    expect(source, contains("Remove-BoundedSmokeRootWithRetry"));
    expect(
        source, contains(r"for ($attempt = 0; $attempt -lt 60; $attempt++)"));
    expect(source, contains("Start-Sleep -Milliseconds 250"));
  });

  test("local Windows Inno queries its classic Event Log source safely", () {
    final source = File("tool/windows_inno_smoke.ps1").readAsStringSync();

    expect(source, contains(r"Where-Object ProviderName -eq"));
    expect(
      source,
      isNot(
        contains(
          "ProviderName = 'DesktopUpdater.InstallHelper.ProtocolV1'",
        ),
      ),
    );
  });

  test("local Windows Inno smoke returns explicit process exit codes", () {
    final source = File("tool/windows_inno_smoke.ps1").readAsStringSync();

    expect(source, contains(r"[Console]::Error.WriteLine("));
    expect(RegExp(r"exit 1").allMatches(source), hasLength(2));
    expect(source.trimRight(), endsWith("exit 0"));
  });

  test("bounded Inno diagnostic launcher quotes spaced publisher arguments",
      () {
    final launcher = _readCanonicalText("tool/windows_inno_smoke_launcher.ps1");

    expect(
      launcher,
      contains(r"""('"' + $SigningPublisher + '"')"""),
    );
    expect(launcher, contains(r"[string] $ReplayRunToken"));
    expect(launcher, contains(r"$process.Refresh()"));
    expect(launcher, contains("'-ReplayRunToken'"));
    expect(launcher, contains("-Wait -PassThru"));
  });

  test("local Windows Inno smoke tolerates an empty marker write", () {
    final source = File("tool/windows_inno_smoke.ps1").readAsStringSync();

    expect(source, contains(r"$markerValue = if ("));
    expect(
      source,
      contains(r"Test-Path -LiteralPath $MarkerPath -PathType Leaf"),
    );
    expect(source, contains(r"$null -ne $markerValue"));
    expect(source, contains(r"$markerValue.Trim()"));
  });

  test("local Windows Inno smoke launches the installed app unelevated", () {
    final source = File("tool/windows_inno_smoke.ps1").readAsStringSync();

    expect(source, contains("Ensure-UnelevatedProcessLauncherType"));
    expect(source, contains("OpenProcessToken"));
    expect(source, contains("DuplicateTokenEx"));
    expect(source, contains("TokenAdjustDefault"));
    expect(source, contains("TokenAdjustSessionId"));
    expect(source, contains("GetTokenInformation"));
    expect(source, contains("CreateProcessWithTokenW"));
    expect(
      source,
      contains(
          r'private const string InteractiveDesktop = @"winsta0\default";'),
    );
    expect(
      source,
      contains(
        "startup.desktop = "
        "Marshal.StringToHGlobalUni(InteractiveDesktop);",
      ),
    );
    expect(source, contains("Marshal.FreeHGlobal(startup.desktop);"));
    expect(source, contains("DesktopUpdater.UnelevatedProcess"));
    expect(source, isNot(contains("ErrorInsufficientBuffer")));
    expect(
      source,
      isNot(contains("Marshal.GetLastWin32Error() != ErrorInsufficientBuffer")),
    );
    expect(
      source,
      contains("System32\\WindowsPowerShell\\v1.0\\powershell.exe"),
    );
    expect(
      source,
      contains("desktop_updater_unelevated_launcher.ps1"),
    );
    expect(
      source,
      contains("desktop_updater_unelevated_launcher.exit-code"),
    );
    expect(
      source,
      contains("desktop_updater_unelevated_launcher.process-id"),
    );
    expect(
      source,
      contains("desktop_updater_unelevated_launcher.token-proof"),
    );
    expect(
      source,
      contains(r"[Diagnostics.Process]::Start($startInfo)"),
    );
    expect(
      source,
      contains(r"$launcherLines -join [Environment]::NewLine"),
    );
  });

  test("local Windows Inno smoke normalizes protected endpoint paths", () {
    final source = File("tool/windows_inno_smoke.ps1").readAsStringSync();

    expect(source, contains("ConvertTo-WindowsInnoComparablePath"));
    expect(source, contains(r"$candidate.StartsWith('\\?\UNC\'"));
    expect(source, contains(r"$candidate.StartsWith('\\?\'"));
    expect(source, contains("(ConvertTo-WindowsInnoComparablePath"));
    expect(
      source,
      contains(r"([string] $initialEndpoints[0].helperPath)"),
    );
    expect(
      source,
      isNot(
        contains(
          r"[IO.Path]::GetFullPath([string] $initialEndpoints[0].helperPath)",
        ),
      ),
    );
  });

  test("local Windows Inno cleanup tolerates unrelated uninstall records", () {
    final source = File("tool/windows_inno_smoke.ps1").readAsStringSync();

    expect(source, contains("Get-OptionalRegistryPropertyValue"));
    expect(source, contains(r"if ($null -eq $Record)"));
    expect(source, contains(r"PSObject.Properties[$Name]"));
    expect(source, contains(r"$recordPackageId -eq $PackageId"));
    expect(source, contains(r"$recordInstallLocation"));
  });

  test("local Windows Inno smoke exercises the protected signed 3.1.3 path",
      () {
    final source = File("tool/windows_inno_smoke.ps1").readAsStringSync();
    final hook = File(
      "tool/windows_inno_smoke_signing_hook.ps1",
    ).readAsStringSync();

    expect(source, contains("'3.1.2'"));
    expect(source, contains("'3.1.3'"));
    expect(source, isNot(contains("'9.9.8'")));
    expect(source, isNot(contains("'9.9.9'")));
    expect(source, contains("privilegesRequired: admin"));
    expect(source, contains("requiresElevation: always"));
    expect(source, contains("authenticodeThumbprints:"));
    expect(source, contains("protectedHelperInstallDir:"));
    expect(source, contains("postPackage:"));
    expect(hook, contains("DESKTOP_UPDATER_ARTIFACT_FILE"));
    expect(hook, contains("desktop_updater_install_helper.exe"));
    expect(hook, contains("desktop_updater_helper_policy.json"));
    expect(hook, contains("Get-AuthenticodeSignature"));
    expect(hook, contains("verifiedInstallerHandoff"));
    expect(hook, contains("windowsInno"));
    expect(
      hook,
      contains(
        r"allowedInstallRoots = @($installRoot, $protectedHelperInstallDir)",
      ),
    );
    expect(hook, contains("/sha1"));
    expect(source, contains("[Environment+SpecialFolder]::ProgramFiles"));
    expect(source, contains("IsInRole("));
    expect(source, contains("WindowsBuiltInRole]::Administrator"));
  });

  test("native protected policy reader strips the canonical final LF", () {
    final bootstrap = File(
      "windows/native/src/helper/windows_helper_bootstrap.cpp",
    ).readAsStringSync();

    expect(bootstrap, contains("result.back() == '\\n'"));
    expect(bootstrap, contains("result.pop_back();"));
  });

  test("native app policy readers normalize the canonical final LF", () {
    final native =
        _readCanonicalText("windows/native/src/desktop_updater_native.cpp");

    expect(native, contains("std::string CanonicalPolicyFile("));
    expect(native, contains("contents.substr(0, contents.size() - 1)"));
    expect(
      RegExp(r"CanonicalPolicyFile\(").allMatches(native).length,
      5,
    );
    expect(
      native,
      contains(
        'CanonicalJsonFile(\n      path, kMaximumHelperPolicyBytes, description, true)',
      ),
    );
  });

  test("local Windows Inno smoke restores Dart package metadata", () {
    final source = File("tool/windows_inno_smoke.ps1").readAsStringSync();

    expect(source, contains("Save-ExampleDartPackageMetadata"));
    expect(source, contains("Restore-ExampleDartPackageMetadata"));
    expect(source, contains(r"package_config.json"));
    expect(source, contains(r"package_graph.json"));
    expect(source, contains(r"$exampleDartPackageMetadataState"));
    expect(source, contains("Dart package metadata restore:"));
  });

  test("local Windows Inno smoke hashes canonical policy bytes", () {
    final hook = File(
      "tool/windows_inno_smoke_signing_hook.ps1",
    ).readAsStringSync();

    expect(hook, contains(r"[IO.File]::ReadAllBytes($policyOutput)"));
    expect(
      hook,
      contains(r"$policyBytes[$policyBytes.Length - 1] -ne 0x0A"),
    );
    expect(hook, contains(r"[byte[]]::new($policyBytes.Length - 1)"));
    expect(hook, contains("[Buffer]::BlockCopy("));
    expect(
      hook,
      contains(
        r"[Security.Cryptography.SHA256]::HashData($canonicalPolicyBytes)",
      ),
    );
    expect(
      hook,
      isNot(contains("Get-FileHash -LiteralPath \$policyOutput")),
    );
  });

  test(
      "Windows CI runs Release build, native tests, integration, publish, and smoke",
      () {
    final workflow =
        File(".github/workflows/desktop-updater-ci.yml").readAsStringSync();

    expect(workflow, contains("flutter build windows --release"));
    expect(
      workflow,
      contains(
        "cmake --build build/windows/x64 --config Release "
        "--target desktop_updater_test",
      ),
    );
    const pluginCTestDirectory = "build/windows/x64/plugins/desktop_updater";
    expect(
      workflow,
      contains(
        "ctest --test-dir $pluginCTestDirectory "
        "-C Debug --output-on-failure",
      ),
    );
    expect(
      workflow,
      contains(
        "ctest --test-dir $pluginCTestDirectory "
        "-C Release --output-on-failure",
      ),
    );
    expect(
      workflow,
      contains(
        "cmake -S windows/native -B windows/native/build "
        "-DDESKTOP_UPDATER_NATIVE_BUILD_TESTS=ON",
      ),
    );
    expect(
      workflow,
      contains(
        "ctest --test-dir windows/native/build -C Release "
        "--output-on-failure",
      ),
    );
    expect(workflow, contains("--no-tests=error"));
    expect(
      workflow,
      contains(
        "dotnet test "
        "windows/native/dotnet/DesktopUpdater.Native.Tests/"
        "DesktopUpdater.Native.Tests.csproj",
      ),
    );
    final elevatedJob = workflow.indexOf("  windows-elevated-helper:");
    final macosJob = workflow.indexOf("  macos-native:", elevatedJob);
    expect(elevatedJob, greaterThanOrEqualTo(0));
    expect(macosJob, greaterThan(elevatedJob));
    expect(
      workflow.substring(0, elevatedJob),
      isNot(contains("windows_inno_smoke.ps1")),
    );
    expect(
      workflow.substring(elevatedJob, macosJob),
      contains("tool/windows_inno_smoke_launcher.ps1"),
    );
    expect(
      workflow,
      contains(
        "./tool/windows_direct_flutter_smoke.ps1 "
        "-Configuration Release",
      ),
    );
    expect(
      workflow,
      isNot(contains("-DiagnosticsPath")),
    );
    expect(workflow, contains("actions/upload-artifact@v4"));
    expect(
      workflow,
      contains("DESKTOP_UPDATER_UPLOAD_SMOKE_DIAGNOSTICS"),
    );
    expect(
      workflow,
      contains("windows-update-smoke-release-diagnostics"),
    );
    expect(workflow, contains("Run release publish smoke"));
    expect(
      workflow,
      contains("dart run tool/release_publish_smoke.dart --platform windows"),
    );
    final releaseSignIndex =
        workflow.indexOf("- name: Sign Windows release smoke binaries");
    expect(releaseSignIndex, greaterThan(0));
    expect(
      releaseSignIndex,
      greaterThan(workflow.indexOf("- name: Build native tests release")),
    );
    expect(
      releaseSignIndex,
      greaterThan(workflow.indexOf("- name: Run integration tests release")),
    );
    expect(
      releaseSignIndex,
      lessThan(workflow.indexOf("- name: Run release publish smoke")),
    );
    expect(
      releaseSignIndex,
      lessThan(workflow.indexOf("- name: Run update smoke release")),
    );
    expect(
      workflow,
      isNot(
        contains(
          "Rebuild example release for smoke\n"
          "        working-directory: example\n"
          "        run: flutter build windows --release",
        ),
      ),
    );
  });
}

String _readCanonicalText(String path) {
  return File(path).readAsStringSync().replaceAll("\r\n", "\n");
}
