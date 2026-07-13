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
      windows.indexOf("bool HasMatchingInstallIdentityMarker("),
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

    final reparseWalkStart = windows.indexOf(
      "WindowsPathComponentState ValidatePathComponentsImpl(",
    );
    final reparseWalkEnd =
        windows.indexOf("InstallResult ValidateStagingRoot(");
    expect(reparseWalkStart, isNonNegative);
    expect(reparseWalkEnd, greaterThan(reparseWalkStart));
    if (reparseWalkStart < 0 || reparseWalkEnd <= reparseWalkStart) {
      return;
    }
    final reparseWalk = windows.substring(reparseWalkStart, reparseWalkEnd);
    expect(reparseWalk, contains("ClassifyWindowsPathComponentAttributes"));
    expect(reparseWalk, contains("kUnavailable"));
    expect(reparseWalk, contains("kReparsePoint"));
    expect(reparseWalk, contains("staging_path.relative_path()"));
    expect(reparseWalk, contains("for (const fs::path& component"));
    expect(reparseWalk, contains("GetFileAttributesW(current.c_str())"));
    expect(windows, contains("attributes == INVALID_FILE_ATTRIBUTES"));
    expect(windows, contains("attributes & FILE_ATTRIBUTE_REPARSE_POINT"));
    expect(
      windows.indexOf("ValidatePathComponentsImpl(staging_path)"),
      lessThan(windowsProof),
    );

    for (final category in <String>[
      "GetWindowsDirectoryW",
      "GetSystemDirectoryW",
      'L"ProgramData"',
      'L"ALLUSERSPROFILE"',
      'L"PUBLIC"',
      'L"USERPROFILE"',
      'L"Desktop"',
      'L"Downloads"',
      'L".local"',
      'L"bin"',
      "GetTempPathW",
    ]) {
      expect(windows, contains(category), reason: category);
    }
    for (final sharedTree in <String>[
      'AddEnvironmentRoot(L"ProgramData", &policy.tree_roots)',
      'AddEnvironmentRoot(L"ALLUSERSPROFILE", &policy.tree_roots)',
      'AddEnvironmentRoot(L"PUBLIC", &policy.tree_roots)',
    ]) {
      expect(windows, contains(sharedTree), reason: sharedTree);
    }
    for (final knownFolder in <String>[
      "SHGetKnownFolderPath",
      "FOLDERID_ProgramData",
      "FOLDERID_Public",
      "FOLDERID_Profile",
      "CoTaskMemFree",
    ]) {
      expect(windows, contains(knownFolder), reason: knownFolder);
    }
    expect(windows, contains("bool authoritative_roots_available = false"));
    expect(
      windows,
      contains("!unsafe_roots.authoritative_roots_available"),
    );
    expect(
      windows,
      contains("AddProfilePolicyRoots(known_profile, true"),
    );
    expect(
      windows,
      contains("fs::path(profile).parent_path()"),
    );
    final unsafeRootCheck = windows.indexOf(
      "IsUnsafeWindowsInstallRoot(canonical_root.wstring(),",
    );
    final markerProof = windows.indexOf(
      "HasMatchingInstallIdentityMarker(canonical_root,",
    );
    expect(unsafeRootCheck, isNonNegative);
    expect(unsafeRootCheck, lessThan(markerProof));
    expect(
      windows,
      contains(
        "PathEquals(canonical_root, canonical_executable.parent_path())",
      ),
    );

    expect(windows, contains("ParseJson(contents)"));
    expect(windows, contains("kMaximumInstalledIdentityMarkerBytes"));
    expect(windows, contains("identity.object().size() != 2"));
    expect(windows, isNot(contains("std::string JsonEscape(")));

    final markerReadStart = windows.indexOf(
      "bool HasMatchingInstallIdentityMarker(",
    );
    final markerReadEnd = windows.indexOf(
      "bool IsCanonicalRelativeExecutable(",
      markerReadStart,
    );
    expect(markerReadStart, isNonNegative);
    expect(markerReadEnd, greaterThan(markerReadStart));
    if (markerReadStart < 0 || markerReadEnd <= markerReadStart) {
      return;
    }
    final markerRead = windows.substring(markerReadStart, markerReadEnd);
    expect(markerRead, contains("CreateFileW"));
    expect(markerRead, contains("GENERIC_READ"));
    expect(markerRead, contains("FILE_SHARE_READ"));
    expect(markerRead, isNot(contains("FILE_SHARE_WRITE")));
    expect(markerRead, isNot(contains("FILE_SHARE_DELETE")));
    expect(markerRead, contains("FILE_FLAG_OPEN_REPARSE_POINT"));
    expect(markerRead, contains("GetFileInformationByHandle"));
    expect(markerRead, contains("FILE_ATTRIBUTE_DIRECTORY"));
    expect(markerRead, contains("FILE_ATTRIBUTE_REPARSE_POINT"));
    expect(
      markerRead,
      contains("kMaximumInstalledIdentityMarkerBytes + 1"),
    );
    expect(markerRead, contains("ReadFile"));
    expect(markerRead, contains("CloseHandle"));
    expect(markerRead, isNot(contains("fs::file_size")));
    expect(markerRead, isNot(contains("istreambuf_iterator")));
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
    expect(source, contains("InstallElevationPolicy::kAlways"));
    expect(source, contains("InstallElevationPolicy::kNever"));
    expect(source, contains("ResolveInstallLaunchDecision"));
    expect(source, contains(r"$expectedElevationPolicy = "));
    expect(
      source,
      contains("Release descriptor elevation policy changed."),
    );
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

  test("Windows diagnostics invariant accepts the contained scheduler", () {
    final source = File("windows/native/src/desktop_updater_native.cpp")
        .readAsStringSync();

    expect(
      _windowsDiagnosticsContainmentViolations(source),
      isEmpty,
    );
  });

  test("Windows diagnostics invariant rejects a pre-script caller-path alias",
      () {
    final source = File("windows/native/src/desktop_updater_native.cpp")
        .readAsStringSync();
    const marker = "  const std::wstring nonce = CreateUuidNonce();";
    expect(source, contains(marker));
    final mutatedSource = source.replaceFirst(
      marker,
      "  const std::wstring unsafe_diagnostics_alias =\n"
      "      request.diagnostics_log_path;\n\n"
      "$marker",
    );

    expect(
      _windowsDiagnosticsContainmentViolations(mutatedSource),
      contains(
        "request.diagnostics_log_path must appear exactly once in "
        "ScheduleInstallAndRelaunch",
      ),
    );
  });

  test("Windows diagnostics invariant rejects an alternate diagnostics sink",
      () {
    final source = File("windows/native/src/desktop_updater_native.cpp")
        .readAsStringSync();
    const marker =
        r'''      << "    Add-Content -LiteralPath $diagnosticsLog -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue\n"''';
    expect(source, contains(marker));
    final mutatedSource = source.replaceFirst(
      marker,
      r'''      << "    $alternateSink = $diagnosticsLog\n"
      << "    Set-Content -LiteralPath $alternateSink -Value $line\n"
''' +
          marker,
    );

    expect(
      _windowsDiagnosticsContainmentViolations(mutatedSource),
      contains(
        r"$diagnosticsLog may appear only in its assignment, guard, and "
        "Add-Content sink",
      ),
    );
    expect(
      _windowsDiagnosticsContainmentViolations(mutatedSource),
      contains(
        "alternate diagnostics write primitive is forbidden: Set-Content",
      ),
    );
  });

  test("Windows diagnostics invariant rejects a second Add-Content sink", () {
    final source = File("windows/native/src/desktop_updater_native.cpp")
        .readAsStringSync();
    const marker =
        r'''      << "    Add-Content -LiteralPath $diagnosticsLog -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue\n"''';
    expect(source, contains(marker));
    final mutatedSource = source.replaceFirst(
      marker,
      "$marker\n"
      r'''      << "    Add-Content -LiteralPath $secondDiagnosticsSink -Value $line\n"''',
    );

    expect(
      _windowsDiagnosticsContainmentViolations(mutatedSource),
      contains(
        r"Add-Content must appear exactly once and target $diagnosticsLog",
      ),
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
      contains("return target_is_protected || !target_is_writable"),
    );
    expect(source, contains("InstallLaunchDecision::kElevated"));
  });
}

List<String> _windowsDiagnosticsContainmentViolations(String source) {
  const scheduleStartMarker = "InstallResult ScheduleInstallAndRelaunch(";
  const scheduleEndMarker = "\nbool IsStrictChildPath(";
  final scheduleStart = source.indexOf(scheduleStartMarker);
  if (scheduleStart < 0) {
    return <String>["ScheduleInstallAndRelaunch is missing"];
  }
  final scheduleEnd = source.indexOf(scheduleEndMarker, scheduleStart);
  if (scheduleEnd < 0) {
    return <String>["ScheduleInstallAndRelaunch scope end is missing"];
  }

  final schedule = source.substring(scheduleStart, scheduleEnd);
  final violations = <String>[];
  const selectedPathDecision =
      "const std::wstring helper_diagnostics_log_path =\n"
      "      launch_mode == PowerShellLaunchMode::kElevated\n"
      "          ? L\"\"\n"
      "          : request.diagnostics_log_path;";
  const launchModeResolution = "launch_mode = PowerShellLaunchMode::kElevated;";
  const scriptConstruction = "std::ostringstream script;";
  const selectedInterpolation = r'''<< "$diagnosticsLog = "
      << PowerShellQuote(helper_diagnostics_log_path) << "\n"''';

  final callerPathCount = RegExp(
    r"\brequest\.diagnostics_log_path\b",
  ).allMatches(schedule).length;
  if (callerPathCount != 1) {
    violations.add(
      "request.diagnostics_log_path must appear exactly once in "
      "ScheduleInstallAndRelaunch",
    );
  }
  if (_countOccurrences(schedule, selectedPathDecision) != 1) {
    violations.add(
      "the caller path must occur only in the normal branch of the "
      "launch-mode-selected helper diagnostics path",
    );
  }

  final launchModeIndex = schedule.indexOf(launchModeResolution);
  final decisionIndex = schedule.indexOf(selectedPathDecision);
  final scriptIndex = schedule.indexOf(scriptConstruction);
  if (launchModeIndex < 0 ||
      decisionIndex <= launchModeIndex ||
      scriptIndex <= decisionIndex) {
    violations.add(
      "helper diagnostics selection must follow launch-mode resolution and "
      "precede script construction",
    );
  }

  if (_countOccurrences(
        schedule,
        "PowerShellQuote(helper_diagnostics_log_path)",
      ) !=
      1) {
    violations.add(
      "the selected helper diagnostics path must be interpolated exactly once",
    );
  }
  if (_countOccurrences(schedule, selectedInterpolation) != 1) {
    violations.add(
      r"the selected helper diagnostics path must assign only $diagnosticsLog",
    );
  }

  final diagnosticsAssignments = RegExp(
    r"\$[A-Za-z0-9_]*diagnostic[A-Za-z0-9_]*\s*=",
    caseSensitive: false,
  ).allMatches(schedule).toList(growable: false);
  final soleAssignment = diagnosticsAssignments.length == 1
      ? diagnosticsAssignments.single.group(0)!.replaceAll(RegExp(r"\s+"), " ")
      : "";
  if (diagnosticsAssignments.length != 1 ||
      soleAssignment != r"$diagnosticsLog =") {
    violations.add("exactly one diagnostics sink assignment is allowed");
  }
  final diagnosticsLogReferences = RegExp(
    r"\$diagnosticsLog\b",
  ).allMatches(schedule).length;
  if (diagnosticsLogReferences != 3) {
    violations.add(
      r"$diagnosticsLog may appear only in its assignment, guard, and "
      "Add-Content sink",
    );
  }

  final addContentCount = RegExp(
    r"\bAdd-Content\b",
  ).allMatches(schedule).length;
  const expectedAddContent =
      r"Add-Content -LiteralPath $diagnosticsLog -Value $line";
  if (addContentCount != 1 ||
      _countOccurrences(schedule, expectedAddContent) != 1) {
    violations.add(
      r"Add-Content must appear exactly once and target $diagnosticsLog",
    );
  }

  const forbiddenWritePrimitives = <String>[
    "Set-Content",
    "Out-File",
    "AppendAllText",
    "WriteAllText",
    "OpenWrite",
    "CreateText",
    "StreamWriter",
    "New-Item",
    "File]::Open(",
    "File]::Create(",
  ];
  for (final primitive in forbiddenWritePrimitives) {
    if (schedule.contains(primitive)) {
      violations.add(
        "alternate diagnostics write primitive is forbidden: $primitive",
      );
    }
  }

  return violations;
}

int _countOccurrences(String source, String pattern) {
  return RegExp(RegExp.escape(pattern)).allMatches(source).length;
}
