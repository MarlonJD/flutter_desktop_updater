import "dart:io";

import "package:flutter_test/flutter_test.dart";

void main() {
  const productionSources = <String>[
    "macos/desktop_updater/Sources/DesktopUpdaterKit/MacInstallHelper.swift",
    "windows/native/src/desktop_updater_native.cpp",
    "linux/native/src/desktop_updater_native.cc",
  ];
  const pluginSources = <String>[
    "macos/desktop_updater/Sources/desktop_updater/DesktopUpdaterPlugin.swift",
    "windows/desktop_updater_plugin.cpp",
    "linux/desktop_updater_plugin.cc",
  ];

  test("production install clients contain no generated script fallback", () {
    final source = _readAll(productionSources);
    for (final forbidden in <String>[
      ".command",
      "PowerShell",
      "powershell.exe",
      "/bin/sh",
      "/bin/bash",
      "sudo",
      "LegacyScriptScheduleForRemoval",
      "BuildInstallScriptForTesting",
      "makeHelperScript",
      "writeHelperScript",
      "StartDetachedScript",
      "StartDetachedPowerShell",
    ]) {
      expect(source, isNot(contains(forbidden)), reason: forbidden);
    }
    expect(source, isNot(matches(RegExp(r"desktop_updater_.+\.sh"))));
    expect(source, isNot(contains(".ps1")));
  });

  test("Flutter adapters reserve then commit through native clients", () {
    for (final path in pluginSources.skip(1)) {
      final source = File(path).readAsStringSync();
      expect(source, contains("PrepareInstall"), reason: path);
      expect(source, contains("CommitAfterExit"), reason: path);
      expect(
        source,
        isNot(contains("ScheduleInstallAndRelaunch")),
        reason: path,
      );
    }

    final mac = File(pluginSources.first).readAsStringSync();
    expect(mac, contains("prepareInstall"));
    expect(mac, contains("commitAfterExit"));
    expect(mac, isNot(contains("scheduleInstallAndRelaunch")));
    expect(
      mac.indexOf("commitAfterExit"),
      lessThan(mac.indexOf("result(nil)")),
    );

    final windows = File(pluginSources[1]).readAsStringSync();
    expect(
      windows.indexOf("CommitAfterExit"),
      lessThan(windows.indexOf("ExitProcess(0)")),
    );

    final linux = File(pluginSources[2]).readAsStringSync();
    expect(
      linux.indexOf("CommitAfterExit"),
      lessThan(linux.indexOf("std::exit(0)")),
    );
  });

  test("native convenience entry points are reservation-only wrappers", () {
    for (final path in productionSources.skip(1)) {
      final source = File(path).readAsStringSync();
      final schedule = _functionBody(source, "ScheduleInstallAndRelaunch");
      expect(schedule, contains("PrepareInstall"), reason: path);
      expect(schedule, contains("CommitAfterExit"), reason: path);
      expect(schedule, isNot(contains("script")), reason: path);
    }
  });

  test("target proof and provenance gates remain in native clients", () {
    final mac = File(productionSources[0]).readAsStringSync();
    expect(mac, contains("validateCompleteHandoff"));
    expect(mac, contains("StageProvenance.verify"));
    expect(mac, contains("invalidReservationResponse"));

    final windows = File(productionSources[1]).readAsStringSync();
    expect(windows, contains("ProveInstallTarget"));
    expect(windows, contains("ValidateStagingRoot"));
    expect(windows, contains("RegistryRecordMatchesInstallTarget"));
    expect(windows, contains("InstalledIdentityMarkerMatchesJson"));
    expect(
      _functionBody(windows, "PrepareInstall"),
      contains("ProveInstallTarget"),
    );

    final linux = File(productionSources[2]).readAsStringSync();
    expect(linux, contains("ValidateNormalizedRequest"));
    expect(linux, contains("BindProvenanceToMarker"));
    expect(linux, contains("kInstalledIdentityMarkerName"));
  });

  test("installer strategies live in authenticated helper components", () {
    final mac = _readAll(const [
      "macos/install_helper/Sources/DesktopUpdaterInstallHelper/InstallStrategy.swift",
      "macos/install_helper/Sources/DesktopUpdaterInstallHelper/VerifiedInstallerHandoff.swift",
    ]);
    expect(mac, contains("verifiedInstallerHandoff"));
    expect(mac, contains("macosInstaller"));

    final windows = _readAll(const [
      "windows/native/src/helper/install_strategy.cpp",
      "windows/native/src/helper/verified_installer_handoff.cpp",
    ]);
    expect(windows, contains("verifiedInstallerHandoff"));
    expect(windows, contains("Authenticode"));

    final linux = _readAll(const [
      "linux/native/src/helper/install_strategy.cc",
      "linux/native/src/helper/system_package_transaction.cc",
    ]);
    expect(linux, contains("systemPackageTransaction"));
    expect(linux, contains("externalManagedRefresh"));
  });

  test("compatible Flutter method and error names remain stable", () {
    final source = _readAll(pluginSources);
    for (final name in <String>[
      "desktop_updater",
      "restartApp",
      "installUpdate",
      "InvalidArguments",
      "RestartError",
      "InstallError",
    ]) {
      expect(source, contains(name), reason: name);
    }
  });
}

String _readAll(Iterable<String> paths) =>
    paths.map((path) => File(path).readAsStringSync()).join("\n");

String _functionBody(String source, String functionName) {
  final start = source.indexOf(functionName);
  expect(start, isNonNegative, reason: functionName);
  final nextFunction = source.indexOf("\n}\n\n", start);
  expect(nextFunction, isNonNegative, reason: functionName);
  return source.substring(start, nextFunction + 2);
}
