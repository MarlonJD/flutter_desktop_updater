import "dart:io";

import "package:flutter_test/flutter_test.dart";

void main() {
  test("Linux helper uses bash when the generated script uses bash features",
      () {
    final source = File("linux/desktop_updater_plugin.cc").readAsStringSync();

    expect(
      source,
      contains('execl("/bin/bash", "bash", script_path.c_str(), nullptr);'),
    );
    expect(source, contains("#!/bin/bash"));
    expect(source, contains("set -euo pipefail"));
    expect(source, contains("removed=("));
  });

  test("native helpers append diagnostics only when an explicit path is passed",
      () {
    final macosSource = File(
      "macos/desktop_updater/Sources/desktop_updater/DesktopUpdaterPlugin.swift",
    ).readAsStringSync();
    final linuxSource =
        File("linux/desktop_updater_plugin.cc").readAsStringSync();
    final windowsSource =
        File("windows/desktop_updater_plugin.cpp").readAsStringSync();

    expect(macosSource, contains("diagnosticsLogPath"));
    expect(macosSource, contains("DIAGNOSTICS_LOG="));
    expect(macosSource, contains("log_event \"helper scheduled\""));
    expect(macosSource, contains(r'[ -n "$DIAGNOSTICS_LOG" ] || return 0'));

    expect(linuxSource, contains("diagnosticsLogPath"));
    expect(linuxSource, contains("diagnostics_log="));
    expect(linuxSource, contains(r'log_event \"helper scheduled\"'));
    expect(linuxSource, contains(r'[ -n \"$diagnostics_log\" ] || return 0'));

    expect(windowsSource, contains("diagnosticsLogPath"));
    expect(windowsSource, contains(r"$diagnosticsLog = "));
    expect(
      windowsSource,
      contains("Write-DiagnosticsEvent 'helper scheduled'"),
    );
    expect(
      windowsSource,
      contains(
        r"if ([string]::IsNullOrWhiteSpace($diagnosticsLog)) { return }",
      ),
    );
  });

  test("native helpers include failure events for support diagnostics", () {
    final macosSource = File(
      "macos/desktop_updater/Sources/desktop_updater/DesktopUpdaterPlugin.swift",
    ).readAsStringSync();
    final linuxSource =
        File("linux/desktop_updater_plugin.cc").readAsStringSync();
    final windowsSource =
        File("windows/desktop_updater_plugin.cpp").readAsStringSync();

    for (final source in <String>[macosSource, linuxSource, windowsSource]) {
      expect(source, contains("backup failure"));
      expect(source, contains("move failure"));
      expect(source, contains("cleanup failure"));
      expect(source, contains("rollback failure"));
    }
  });

  test("Linux native test header exposes diagnostics log path scheduling", () {
    final source =
        File("linux/desktop_updater_plugin_private.h").readAsStringSync();

    expect(source, contains("diagnostics_log_path"));
  });

  test("Linux helper prunes target before whole directory overlay", () {
    final source = File("linux/desktop_updater_plugin.cc").readAsStringSync();
    const pruneSnippet =
        r'find \"$target\" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +';
    const copySnippet = r'cp -a \"$staging/.\" \"$target/\"';

    final pruneIndex = source.indexOf(pruneSnippet);
    final copyIndex = source.indexOf(copySnippet);

    expect(pruneIndex, isNonNegative);
    expect(copyIndex, isNonNegative);
    expect(pruneIndex, lessThan(copyIndex));
  });

  test("Linux helper restores executable permission before commit cleanup", () {
    final source = File("linux/desktop_updater_plugin.cc").readAsStringSync();
    const copySnippet = r'cp -a \"$staging/.\" \"$target/\"';
    const restoreSnippet = r'chmod +x \"$exe\"';
    const existsSnippet = r'[ -e \"$exe\" ] && [ ! -x \"$exe\" ]';
    const missingExecutableSnippet =
        r'[ ! -e \"$exe\" ] && [ \"$skip_relaunch\" != \"1\" ]';
    const cleanupSnippet = r'rm -rf \"$backup\"';
    const trapDisabledSnippet = r'trap - ERR';
    const relaunchSnippet = r'\"$exe\" &';

    final copyIndex = source.indexOf(copySnippet);
    final restoreIndex = source.indexOf(restoreSnippet);
    final existsIndex = source.indexOf(existsSnippet);
    final missingExecutableIndex = source.indexOf(missingExecutableSnippet);
    final restoreSearchStart = restoreIndex < 0 ? 0 : restoreIndex;
    final cleanupIndex = source.indexOf(cleanupSnippet, restoreSearchStart);
    final trapDisabledIndex =
        source.indexOf(trapDisabledSnippet, restoreSearchStart);
    final relaunchIndex = source.indexOf(relaunchSnippet);

    expect(copyIndex, isNonNegative);
    expect(existsIndex, isNonNegative);
    expect(restoreIndex, isNonNegative);
    expect(missingExecutableIndex, isNonNegative);
    expect(cleanupIndex, isNonNegative);
    expect(trapDisabledIndex, isNonNegative);
    expect(relaunchIndex, isNonNegative);
    expect(copyIndex, lessThan(restoreIndex));
    expect(existsIndex, lessThan(restoreIndex));
    expect(restoreIndex, lessThan(missingExecutableIndex));
    expect(restoreIndex, lessThan(cleanupIndex));
    expect(restoreIndex, lessThan(trapDisabledIndex));
    expect(restoreIndex, lessThan(relaunchIndex));
  });

  test("Windows helper prunes target before whole directory overlay", () {
    final source =
        File("windows/desktop_updater_plugin.cpp").readAsStringSync();
    const pruneSnippet = r"Get-ChildItem -LiteralPath $target -Force";
    const copySnippet =
        r"Copy-Item -LiteralPath $_.FullName -Destination $target -Recurse -Force";

    final pruneIndex = source.indexOf(pruneSnippet);
    final removeIndex =
        source.indexOf(r"Remove-Item -LiteralPath $_.FullName -Recurse -Force");
    final copyIndex = source.indexOf(copySnippet);

    expect(pruneIndex, isNonNegative);
    expect(
      source,
      contains(r"Remove-Item -LiteralPath $_.FullName -Recurse -Force"),
    );
    expect(removeIndex, isNonNegative);
    expect(copyIndex, isNonNegative);
    expect(pruneIndex, lessThan(copyIndex));
  });

  test("Windows helper preserves Inno uninstall artifacts during prune", () {
    final source =
        File("windows/desktop_updater_plugin.cpp").readAsStringSync();
    const predicateSnippet = "function Test-InstallerOwnedWindowsFile";
    const preserveCondition =
        r"$_.PSIsContainer -or -not (Test-InstallerOwnedWindowsFile $_.Name)";
    const preserveEvent = "preserve installer file";
    const pruneSnippet = r"Get-ChildItem -LiteralPath $target -Force";
    const copySnippet =
        r"Copy-Item -LiteralPath $_.FullName -Destination $target -Recurse -Force";

    final predicateIndex = source.indexOf(predicateSnippet);
    final pruneIndex = source.indexOf(pruneSnippet);
    final conditionIndex = source.indexOf(preserveCondition);
    final eventIndex = source.indexOf(preserveEvent);
    final copyIndex = source.indexOf(copySnippet);

    expect(predicateIndex, isNonNegative);
    expect(pruneIndex, isNonNegative);
    expect(conditionIndex, isNonNegative);
    expect(eventIndex, isNonNegative);
    expect(copyIndex, isNonNegative);
    expect(predicateIndex, lessThan(pruneIndex));
    expect(pruneIndex, lessThan(copyIndex));
    expect(conditionIndex, lessThan(copyIndex));
  });

  test("Windows helper retries staging cleanup after successful copy", () {
    final source =
        File("windows/desktop_updater_plugin.cpp").readAsStringSync();
    const cleanupFunction = "function Remove-StagingDirectoryWithRetry";
    const retryEvent = "Write-DiagnosticsEvent 'cleanup retry'";
    const cleanupCall = r"Remove-StagingDirectoryWithRetry -Path $staging";
    const moveSuccess = "Write-DiagnosticsEvent 'move success'";
    const relaunchSnippet = r"Start-Process -FilePath $exe";

    final functionIndex = source.indexOf(cleanupFunction);
    final retryIndex = source.indexOf(retryEvent);
    final moveSuccessIndex = source.indexOf(moveSuccess);
    final cleanupCallIndex = source.indexOf(cleanupCall);
    final relaunchIndex = source.indexOf(relaunchSnippet);

    expect(functionIndex, isNonNegative);
    expect(retryIndex, isNonNegative);
    expect(moveSuccessIndex, isNonNegative);
    expect(cleanupCallIndex, isNonNegative);
    expect(relaunchIndex, isNonNegative);
    expect(functionIndex, lessThan(moveSuccessIndex));
    expect(moveSuccessIndex, lessThan(cleanupCallIndex));
    expect(cleanupCallIndex, lessThan(relaunchIndex));
  });

  test("Windows helper updates uninstall DisplayVersion after overlay", () {
    final source =
        File("windows/desktop_updater_plugin.cpp").readAsStringSync();
    const copySnippet =
        r"Copy-Item -LiteralPath $_.FullName -Destination $target -Recurse -Force";
    const registrySnippet = r"Update-UninstallDisplayVersion -Version";

    final copyIndex = source.indexOf(copySnippet);
    final registryIndex = source.indexOf(registrySnippet);
    final relaunchIndex = source.indexOf(r"Start-Process -FilePath $exe");

    expect(source, contains(r".desktop_updater_release_manifest.json"));
    expect(source, contains("DisplayVersion"));
    expect(copyIndex, isNonNegative);
    expect(registryIndex, isNonNegative);
    expect(relaunchIndex, isNonNegative);
    expect(copyIndex, lessThan(registryIndex));
    expect(registryIndex, lessThan(relaunchIndex));
  });

  test("Windows helper executes staged Inno installer from manifest", () {
    final source =
        File("windows/desktop_updater_plugin.cpp").readAsStringSync();

    const manifestSnippet =
        r"$manifest = Join-Path $staging '.desktop_updater_release_manifest.json'";
    const strategySnippet =
        r"if ($descriptor.install.strategy -eq 'innoInstaller')";
    const invokeSnippet = "function Invoke-InnoInstallerUpdate";
    const installerPathSnippet =
        r"$installer = Join-Path $staging 'installer.exe'";
    const startSnippet = "Write-DiagnosticsEvent 'inno installer start'";
    const waitSnippet = r"Start-Process -FilePath $installer";

    final manifestIndex = source.indexOf(manifestSnippet);
    final strategyIndex = source.indexOf(strategySnippet);
    final invokeIndex = source.indexOf(invokeSnippet);
    final installerPathIndex = source.indexOf(installerPathSnippet);
    final startIndex = source.indexOf(startSnippet);
    final waitIndex = source.indexOf(waitSnippet);

    expect(invokeIndex, isNonNegative);
    expect(manifestIndex, isNonNegative);
    expect(strategyIndex, isNonNegative);
    expect(installerPathIndex, isNonNegative);
    expect(startIndex, isNonNegative);
    expect(waitIndex, isNonNegative);
    expect(invokeIndex, lessThan(strategyIndex));
    expect(invokeIndex, lessThan(waitIndex));
  });

  test(
      "macOS helper opens staged PKG installers without silent privilege escalation",
      () {
    final source = File(
      "macos/desktop_updater/Sources/desktop_updater/DesktopUpdaterPlugin.swift",
    ).readAsStringSync();

    expect(source, contains("pkgInstaller"));
    expect(source, contains("launchMode"));
    expect(source, contains("installerApp"));
    expect(source, contains("installer.pkg"));
    expect(source, contains("pkg installer open"));
    expect(source, contains("/usr/bin/open"));
    expect(source, isNot(contains("/usr/sbin/installer -pkg")));
    expect(source, isNot(contains("sudo")));
    expect(source, isNot(contains("osascript")));

    final pkgBranchIndex = source.indexOf("pkg manifest loaded");
    final appValidationIndex = source.indexOf(r'case "$STAGING" in');
    expect(pkgBranchIndex, isNonNegative);
    expect(appValidationIndex, isNonNegative);
    expect(pkgBranchIndex, lessThan(appValidationIndex));
  });

  test("macOS move to Applications avoids destructive replacement", () {
    final source = File(
      "macos/desktop_updater/Sources/desktop_updater/DesktopUpdaterPlugin.swift",
    ).readAsStringSync();

    expect(source, contains("sourceURL.path == destinationURL.path"));
    expect(source, contains("desktop_updater_move_staging"));
    expect(source, contains("desktop_updater_move_backup"));
    expect(source, contains("restoreMoveBackup"));
    expect(source,
        isNot(contains("try fileManager.removeItem(at: destinationURL)")));
  });

  test("Windows helper verifies Authenticode thumbprints for Inno installers",
      () {
    final source =
        File("windows/desktop_updater_plugin.cpp").readAsStringSync();

    expect(source, contains("function Test-AuthenticodePolicy"));
    expect(source, contains(r"Get-AuthenticodeSignature -FilePath $installer"));
    expect(source, contains("SignerCertificate"));
    expect(source, contains("Thumbprint"));
    expect(source, contains("inno authenticode verified"));
    expect(source, contains("inno authenticode failure"));
  });

  test("Windows helper requests UAC with verified script for protected targets",
      () {
    final source =
        File("windows/desktop_updater_plugin.cpp").readAsStringSync();

    expect(source, contains("#include <shellapi.h>"));
    expect(source, contains("IsProcessElevated"));
    expect(source, contains("CanWriteDirectory"));
    expect(source, contains("StartElevatedPowerShell"));
    expect(source, contains('launch_mode == PowerShellLaunchMode::kElevated'));
    expect(source, contains("ShellExecuteExW"));
    expect(source, contains('L"runas"'));
    expect(source, contains("-EncodedCommand"));
    expect(source, contains("SHA256"));
    expect(source, contains(r"Invoke-Expression $scriptText"));
    expect(source, contains("Write-DiagnosticsEvent 'elevation requested'"));
    expect(
      source,
      contains(
        "Target directory is protected or not writable. "
        "Requesting UAC elevation.",
      ),
    );
    expect(
      source,
      contains("User cancelled the Windows UAC update prompt."),
    );
  });

  test("Windows helper treats Program Files roots as protected installs", () {
    final source =
        File("windows/desktop_updater_plugin.cpp").readAsStringSync();

    expect(source, contains("IsKnownProtectedInstallDirectory"));
    expect(source, contains("ProtectedInstallRootPaths"));
    expect(
      source,
      contains("IsKnownProtectedInstallDirectory(target_directory"),
    );
    expect(source, contains("const bool target_is_protected"));
    expect(
      source,
      contains(
        "if (!process_is_elevated && "
        "(target_is_protected || !target_is_writable))",
      ),
    );
  });
}
