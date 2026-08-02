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
    expect(source, contains("DESKTOP_UPDATER_SMOKE_DIAGNOSTICS_LOG"));
    expect(source, contains("DESKTOP_UPDATER_SMOKE_INSTALL_ROOT"));
    expect(
      source,
      contains("DESKTOP_UPDATER_SMOKE_EXECUTABLE_RELATIVE_PATH"),
    );
    expect(source, contains(r'"event":"$event"'));
    expect(source, contains("--diagnostics-log <path>"));
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
    expect(runner, isNot(contains(r"-WorkingDirectory $install")));
  });

  test("Windows smoke delegates cross-user relaunch cleanup to the wrapper",
      () {
    final smoke = File("example/tool/updater_smoke.dart").readAsStringSync();
    final runner =
        File("tool/windows_direct_flutter_smoke.ps1").readAsStringSync();

    expect(
      smoke,
      contains(
        'const _windowsExternalRelaunchCleanupEnvironment =\n'
        '    "DESKTOP_UPDATER_SMOKE_EXTERNAL_RELAUNCH_CLEANUP";',
      ),
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
    expect(runner, contains(r"takeown.exe /F $Root /R /D Y"));
    expect(runner, contains(r"icacls.exe $Root /reset /T /C"));
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
    expect(
      runner,
      matches(
        RegExp(
          r"if \(-not \$smokeSucceeded\) \{\s*"
          r"try \{\s*"
          r"Save-WindowsFlutterSmokeEvidence",
        ),
      ),
    );
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
    expect(runner, isNot(contains("Get-FileHash")));
    expect(runner, isNot(contains("ZipArchive")));
    expect(runner, isNot(contains("Start-Sleep")));
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
      lessThan(runner.lastIndexOf(r"Remove-Item -LiteralPath $smokeRoot")),
    );
    expect(
      runner,
      contains(
        r"Copy-Item -LiteralPath $capturedDiagnostics -Destination $destination -Force",
      ),
    );
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
        r'-Configuration Debug -DiagnosticsPath (Join-Path $PWD "reports/windows-update-smoke-debug-diagnostics.jsonl") -EvidencePath (Join-Path $PWD "reports/windows-update-smoke-debug-evidence")',
      ),
    );
    expect(
      workflow,
      contains(
        r'-Configuration Release -DiagnosticsPath (Join-Path $PWD "reports/windows-update-smoke-release-diagnostics.jsonl") -EvidencePath (Join-Path $PWD "reports/windows-update-smoke-release-evidence")',
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
          r"reports/windows-update-smoke-debug-diagnostics\.jsonl\s*"
          r"reports/windows-update-smoke-debug-evidence",
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
          r"reports/windows-update-smoke-release-diagnostics\.jsonl\s*"
          r"reports/windows-update-smoke-release-evidence",
        ),
      ),
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
    expect(workflow, isNot(contains("windows_inno_smoke.ps1")));
    expect(
      workflow,
      contains(
        "./tool/windows_direct_flutter_smoke.ps1 "
        "-Configuration Release",
      ),
    );
    expect(
      workflow,
      contains(
        r"-DiagnosticsPath (Join-Path $PWD "
        '"reports/windows-update-smoke-release-diagnostics.jsonl")',
      ),
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
