import "dart:io";

import "package:flutter_test/flutter_test.dart";

void main() {
  test("Linux helper uses bash when the generated script uses bash features",
      () {
    final source = File(
      "linux/native/src/desktop_updater_native.cc",
    ).readAsStringSync();

    expect(
      source,
      contains('execl("/bin/bash", "bash", script_path.c_str(), nullptr);'),
    );
    expect(source, contains("#!/bin/bash"));
    expect(source, contains("set -euo pipefail"));
    expect(source, contains("removed=("));
  });

  test("Linux helper validates an app-owned install target before scripting",
      () {
    final header = File(
      "linux/native/include/desktop_updater_native.h",
    ).readAsStringSync();
    final source = File(
      "linux/native/src/desktop_updater_native.cc",
    ).readAsStringSync();

    expect(header, contains("enum class LinuxInstallOperation"));
    expect(header, contains("struct InstallRequest"));
    expect(header, contains("struct InstallTargetProof"));
    expect(header, contains("InstallTargetProofSource"));
    expect(header, contains("ValidateInstallRequest"));

    for (final protectedRoot in <String>[
      "/",
      "/bin",
      "/sbin",
      "/usr",
      "/usr/bin",
      "/usr/sbin",
      "/usr/local",
      "/usr/local/bin",
      "/opt",
      "/etc",
      "/var",
      "/home",
    ]) {
      expect(source, contains('"$protectedRoot"'));
    }

    final validationIndex = source.indexOf("ValidateNormalizedRequest(");
    final scriptPathIndex = source.indexOf("const std::string script_path");
    final writeIndex = source.indexOf("WriteFile(script_path, script)");
    expect(validationIndex, isNonNegative);
    expect(scriptPathIndex, isNonNegative);
    expect(writeIndex, isNonNegative);
    expect(validationIndex, lessThan(scriptPathIndex));
    expect(validationIndex, lessThan(writeIndex));
  });

  test("native target proof rejects shared roots before helper creation", () {
    final linux = File(
      "linux/native/src/desktop_updater_native.cc",
    ).readAsStringSync();
    final windows = File(
      "windows/native/src/desktop_updater_native.cpp",
    ).readAsStringSync();
    final windowsRuntimeHeader = File(
      "windows/native/include/desktop_updater_runtime_c.h",
    ).readAsStringSync();

    for (final protectedRoot in <String>[
      '"Desktop"',
      '"Downloads"',
      '".local/bin"',
    ]) {
      expect(linux, contains(protectedRoot));
    }
    expect(linux, contains("data/flutter_assets"));
    expect(linux, contains("lib/libflutter_linux_gtk.so"));
    expect(linux, contains("IsStrictDescendant(root, temp)"));
    expect(linux, contains(".desktop_updater_install_identity.json"));
    expect(
      linux,
      contains("IsTemporaryInstallRoot(request.install_root)"),
    );
    expect(linux, contains("InstallTargetProof"));
    expect(windows, contains("InstallTargetProof"));
    expect(windows, contains(".desktop_updater_install_identity.json"));
    expect(windows, contains("DesktopUpdaterPackageId"));
    expect(windowsRuntimeHeader, contains("install_root_utf8"));
    expect(windowsRuntimeHeader, contains("executable_relative_path_utf8"));
    expect(windowsRuntimeHeader, contains("expected_package_id_utf8"));

    final registryProof = windows.substring(
      windows.indexOf("bool HasMatchingUninstallRecord("),
      windows.indexOf("std::string JsonEscape("),
    );
    expect(registryProof, contains("HKEY_LOCAL_MACHINE"));
    expect(registryProof, contains("KEY_WOW64_64KEY"));
    expect(registryProof, contains("KEY_WOW64_32KEY"));
    expect(registryProof, isNot(contains("HKEY_CURRENT_USER")));

    final stageReparseCheck = windows.indexOf(
      "GetFileAttributesW(request.staging_path.c_str())",
    );
    final windowsProof = windows.indexOf("ProveInstallTarget(");
    final windowsScript = windows.indexOf("const fs::path script_path");
    expect(stageReparseCheck, isNonNegative);
    expect(windowsProof, isNonNegative);
    expect(windowsScript, isNonNegative);
    expect(stageReparseCheck, lessThan(windowsProof));
    expect(stageReparseCheck, lessThan(windowsScript));

    expect(windowsProof, lessThan(windowsScript));
  });

  test("macOS public install request cannot select another PID or bundle", () {
    final request = File(
      "macos/desktop_updater/Sources/DesktopUpdaterKit/MacInstallRequest.swift",
    ).readAsStringSync();
    final helper = File(
      "macos/desktop_updater/Sources/DesktopUpdaterKit/MacInstallHelper.swift",
    ).readAsStringSync();

    final publicRequest = request.substring(
      request.indexOf("public struct MacInstallRequest"),
    );
    expect(publicRequest, isNot(contains("currentProcessIdentifier")));
    expect(publicRequest, isNot(contains("bundlePath")));
    expect(helper, contains("ProcessInfo.processInfo.processIdentifier"));
    expect(helper, contains("Bundle.main.bundleURL"));
    expect(helper, contains("MacInstallTargetResolver"));
  });

  test("Linux install validation bounds staging and removed paths", () {
    final source = File(
      "linux/native/src/desktop_updater_native.cc",
    ).readAsStringSync();

    expect(source, contains("Staging path must not overlap install root"));
    expect(source, contains("Removed file path escapes install root"));
    expect(source, contains("Linux install package identity is required"));
    expect(source, contains("package_id.find_first_not_of"));
    expect(source, contains("LinuxInstallOperation::kRestart"));
  });

  test("Linux helper revalidates roots after the parent process exits", () {
    final source = File(
      "linux/native/src/desktop_updater_native.cc",
    ).readAsStringSync();

    expect(
        source, contains(r'resolved_target=\"$(cd \"$target\" && pwd -P)\"'));
    expect(source, contains(r'[ \"$resolved_target\" != \"$target\" ]'));
    expect(source, contains(r'staging_root=\"$(cd \"$staging\" && pwd -P)\"'));
    expect(source, contains(r'\"$target_root\"/*'));
    expect(source, contains(r'\"$staging_root\"/*'));
  });

  test("native helpers append diagnostics only when an explicit path is passed",
      () {
    final macosSource = File(
      "macos/desktop_updater/Sources/DesktopUpdaterKit/MacInstallHelper.swift",
    ).readAsStringSync();
    final linuxSource = File(
      "linux/native/src/desktop_updater_native.cc",
    ).readAsStringSync();
    final windowsSource = File("windows/native/src/desktop_updater_native.cpp")
        .readAsStringSync();

    expect(macosSource, contains("diagnosticsLogPath"));
    expect(macosSource, contains("DIAGNOSTICS_LOG="));
    expect(macosSource, contains("log_event \"helper scheduled\""));
    expect(macosSource, contains(r'[ -n "$DIAGNOSTICS_LOG" ] || return 0'));

    expect(linuxSource, contains("diagnostics_log_path"));
    expect(linuxSource, contains("diagnostics_log="));
    expect(linuxSource, contains(r'log_event \"helper scheduled\"'));
    expect(linuxSource, contains(r'[ -n \"$diagnostics_log\" ] || return 0'));

    expect(windowsSource, contains("diagnostics_log_path"));
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
      "macos/desktop_updater/Sources/DesktopUpdaterKit/MacInstallHelper.swift",
    ).readAsStringSync();
    final linuxSource = File(
      "linux/native/src/desktop_updater_native.cc",
    ).readAsStringSync();
    final windowsSource = File("windows/native/src/desktop_updater_native.cpp")
        .readAsStringSync();

    for (final source in <String>[macosSource, linuxSource, windowsSource]) {
      expect(source, contains("backup failure"));
      expect(source, contains("move failure"));
      expect(source, contains("cleanup failure"));
      expect(source, contains("rollback failure"));
    }
  });

  test("Linux native header exposes diagnostics log path scheduling", () {
    final source = File(
      "linux/native/include/desktop_updater_native.h",
    ).readAsStringSync();

    expect(source, contains("diagnostics_log_path"));
  });

  test("Linux helper prunes target before whole directory overlay", () {
    final source = File(
      "linux/native/src/desktop_updater_native.cc",
    ).readAsStringSync();
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
    final source = File(
      "linux/native/src/desktop_updater_native.cc",
    ).readAsStringSync();
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
    final relaunchIndex = source.indexOf(relaunchSnippet, restoreSearchStart);

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
    final source = File("windows/native/src/desktop_updater_native.cpp")
        .readAsStringSync();
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
    final source = File("windows/native/src/desktop_updater_native.cpp")
        .readAsStringSync();
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
    final source = File("windows/native/src/desktop_updater_native.cpp")
        .readAsStringSync();
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
    final source = File("windows/native/src/desktop_updater_native.cpp")
        .readAsStringSync();
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
    final source = File("windows/native/src/desktop_updater_native.cpp")
        .readAsStringSync();

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
      "macos/desktop_updater/Sources/DesktopUpdaterKit/MacInstallHelper.swift",
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
    final source = File("windows/native/src/desktop_updater_native.cpp")
        .readAsStringSync();

    expect(source, contains("function Test-AuthenticodePolicy"));
    expect(source, contains(r"Get-AuthenticodeSignature -FilePath $installer"));
    expect(source, contains("SignerCertificate"));
    expect(source, contains("Thumbprint"));
    expect(source, contains("inno authenticode verified"));
    expect(source, contains("inno authenticode failure"));
  });

  test("helpers verify immutable stage provenance before target mutation", () {
    final macosSource = File(
      "macos/desktop_updater/Sources/DesktopUpdaterKit/MacInstallHelper.swift",
    ).readAsStringSync();
    final linuxSource = File(
      "linux/native/src/desktop_updater_native.cc",
    ).readAsStringSync();
    final windowsSource = File("windows/native/src/desktop_updater_native.cpp")
        .readAsStringSync();

    for (final source in <String>[macosSource, linuxSource, windowsSource]) {
      expect(source, contains("expected_provenance_sha256"));
      expect(source, contains("stage provenance validation failure"));
      final verification = source.indexOf("stage provenance validation");
      final backup = source.indexOf("backup start");
      expect(verification, isNonNegative);
      expect(backup, isNonNegative);
      expect(verification, lessThan(backup));
    }
  });

  test("installer helpers reverify platform trust at installer open", () {
    final macosSource = File(
      "macos/desktop_updater/Sources/DesktopUpdaterKit/MacInstallHelper.swift",
    ).readAsStringSync();
    final windowsSource = File("windows/native/src/desktop_updater_native.cpp")
        .readAsStringSync();

    final macProvenance = macosSource.indexOf("stage provenance validation");
    final pkgutil = macosSource.indexOf("pkgutil --check-signature");
    final spctl = macosSource.indexOf("spctl --assess --type install");
    final stapler = macosSource.indexOf("stapler validate \"\$PKG\"");
    final packageIds = macosSource.indexOf("EXPECTED_PACKAGE_IDS");
    final open = macosSource.indexOf('/usr/bin/open "\$PKG"');
    expect(macProvenance, lessThan(pkgutil));
    expect(pkgutil, lessThan(open));
    expect(spctl, lessThan(open));
    expect(stapler, lessThan(open));
    expect(packageIds, lessThan(open));

    expect(windowsSource, contains(r"$expectedArtifactSha256 = "));
    expect(windowsSource, contains(r"$allowedSignerThumbprints = @("));
    expect(windowsSource, contains("Get-FileHash -Algorithm SHA256"));
    final windowsProvenance = windowsSource.indexOf(
      r'<< "  Test-StageProvenance\n"',
    );
    final authenticode = windowsSource.indexOf(
      r'<< "  Test-AuthenticodePolicy -installer $installer\n"',
    );
    final installerStart = windowsSource.indexOf("inno installer start");
    final innoInvocation = windowsSource.indexOf(
      r'<< "        Invoke-InnoInstallerUpdate $descriptor\n"',
    );
    expect(windowsProvenance, lessThan(innoInvocation));
    expect(authenticode, lessThan(installerStart));
  });

  test("macOS helper cleanup never recursively deletes a manifest parent", () {
    final source = File(
      "macos/desktop_updater/Sources/DesktopUpdaterKit/MacInstallHelper.swift",
    ).readAsStringSync();

    expect(
      source,
      isNot(contains(r'/bin/rm -rf "$(dirname "$MANIFEST")"')),
    );
    expect(source, isNot(contains('/bin/rm -rf "/Applications"')));
    expect(source, contains(r'cleanup_owned_stage "$STAGE_ROOT"'));
  });

  test("Windows helper requests UAC with verified script for protected targets",
      () {
    final source = File("windows/native/src/desktop_updater_native.cpp")
        .readAsStringSync();

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
    final source = File("windows/native/src/desktop_updater_native.cpp")
        .readAsStringSync();

    expect(source, contains("IsKnownProtectedInstallDirectory"));
    expect(source, contains("ProtectedInstallRootPaths"));
    expect(
      source,
      contains("IsKnownProtectedInstallDirectory("),
    );
    expect(source, contains("target_directory.wstring()"));
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
