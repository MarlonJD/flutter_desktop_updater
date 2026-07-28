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
    final macCommit = mac.indexOf("commitAfterExit");
    expect(macCommit, isNonNegative);
    expect(macCommit, lessThan(mac.indexOf("result(nil)", macCommit)));

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

  test("Linux restart bypasses the privileged install transaction", () {
    final plugin = File(pluginSources[2]).readAsStringSync();
    final restartBranch = plugin.substring(
      plugin.indexOf('strcmp(method, "restartApp")'),
      plugin.indexOf('strcmp(method, "installUpdate")'),
    );
    final nativeHeader = File(
      "linux/native/include/desktop_updater_native.h",
    ).readAsStringSync();

    expect(restartBranch, contains("RestartCurrentApplication"));
    expect(restartBranch, isNot(contains("HandoffNativeInstall")));
    expect(restartBranch, isNot(contains("PrepareInstall")));
    expect(
        nativeHeader, contains("InstallResult RestartCurrentApplication();"));
  });

  test("Windows restart bypasses the privileged install transaction", () {
    final plugin = File(pluginSources[1]).readAsStringSync();
    final restartBranch = plugin.substring(
      plugin.indexOf('method_name().compare("restartApp")'),
      plugin.indexOf('method_name().compare("installUpdate")'),
    );
    final nativeHeader = File(
      "windows/native/include/desktop_updater_native.h",
    ).readAsStringSync();
    final nativeSource = File(productionSources[1]).readAsStringSync();

    expect(restartBranch, contains("RestartCurrentApplication"));
    expect(restartBranch, isNot(contains("HandoffNativeInstall")));
    expect(restartBranch, isNot(contains("PrepareInstall")));
    expect(restartBranch, isNot(contains("InstallRequest")));
    expect(
      nativeHeader,
      contains("InstallResult RestartCurrentApplication();"),
    );
    expect(
      nativeHeader,
      contains("bool AwaitRestartParentExitIfRequested();"),
    );
    final restart = _functionBody(nativeSource, "RestartCurrentApplication");
    expect(restart, contains("CurrentExecutablePath"));
    expect(restart, contains("CreateProcessW"));
    expect(restart, contains("PROC_THREAD_ATTRIBUTE_HANDLE_LIST"));
    expect(restart, isNot(contains("PrepareInstall")));
    expect(restartBranch, contains("if (!restart.ok)"));
    expect(restartBranch, contains('result->Error("RestartError"'));
    expect(
      restartBranch.indexOf('result->Error("RestartError"'),
      lessThan(restartBranch.indexOf("ExitProcess(0)")),
    );
  });

  test("macOS restart bypasses the privileged install transaction", () {
    final plugin = File(pluginSources[0]).readAsStringSync();
    final restartBranch = plugin.substring(
      plugin.indexOf('case "restartApp"'),
      plugin.indexOf('case "installUpdate"'),
    );
    final restartSource = File(
      "macos/desktop_updater/Sources/DesktopUpdaterKit/"
      "MacApplicationRestarter.swift",
    ).readAsStringSync();

    expect(restartBranch, contains("restartCurrentApplication"));
    expect(restartBranch, isNot(contains("handoffInstallAndRelaunch")));
    expect(restartBranch, isNot(contains("prepareInstall")));
    expect(restartBranch, isNot(contains("MacInstallRequest")));
    final restart = plugin.substring(
      plugin.indexOf("private func restartCurrentApplication"),
      plugin.indexOf("private func handoffInstallAndRelaunch"),
    );
    expect(restart, contains("scheduleCurrentApplicationRestart"));
    expect(restart, contains("exit(EXIT_SUCCESS)"));
    expect(restartSource, contains("Bundle.main.executableURL"));
    expect(restartSource, contains("posix_spawn"));
    expect(restartSource, contains("POSIX_SPAWN_CLOEXEC_DEFAULT"));
    expect(
      restartSource,
      contains("posix_spawn_file_actions_addinherit_np"),
    );
    expect(
      restartSource,
      contains("awaitRestartParentExitIfRequested"),
    );
    final registration = plugin.substring(
      plugin.indexOf("public static func register"),
      plugin.indexOf("public func handle"),
    );
    expect(registration, contains("awaitRestartParentExitIfRequested"));
    expect(registration, contains("_exit"));
    final errorBranch = restart.substring(restart.indexOf("} catch {"));
    expect(errorBranch, contains('code: "RestartError"'));
    expect(errorBranch, isNot(contains("exit(")));
  });

  test("macOS install binds the caller transaction ID to the helper", () {
    final plugin = File(pluginSources[0]).readAsStringSync();
    final installBranch = plugin.substring(
      plugin.indexOf('case "installUpdate"'),
      plugin.indexOf('case "queryInstallTransaction"'),
    );
    final handoff = plugin.substring(
      plugin.indexOf("private func handoffInstallAndRelaunch"),
      plugin.indexOf("private func queryInstallTransaction"),
    );

    expect(installBranch, contains('arguments["transactionId"]'));
    expect(installBranch, contains("transactionID: transactionID"));
    expect(handoff, contains("transactionID: String?"));
    expect(
      handoff,
      matches(
        RegExp(
          r"helper\.prepareInstall\(\s*request,\s*"
          r"transactionID: transactionID\s*\)",
          multiLine: true,
        ),
      ),
    );
  });

  test("macOS and Linux ambiguous handoffs preserve recovery markers", () {
    final macPlugin = File(pluginSources[0]).readAsStringSync();
    final macInstallBranch = macPlugin.substring(
      macPlugin.indexOf("private func handoffInstallAndRelaunch"),
      macPlugin.indexOf("private func queryInstallTransaction"),
    );
    final linuxPlugin = File(pluginSources[2]).readAsStringSync();
    final linuxInstallBranch = linuxPlugin.substring(
      linuxPlugin.indexOf('strcmp(method, "installUpdate")'),
      linuxPlugin.indexOf('strcmp(method, "queryInstallTransaction")'),
    );

    expect(
      macInstallBranch,
      contains("MacInstallClientError.installRecoveryRequired"),
    );
    expect(macInstallBranch, contains('"recoveryRequired": true'));
    expect(linuxPlugin, contains("RecoveryRequiredErrorDetails"));
    expect(linuxPlugin, contains('"recoveryRequired"'));
    expect(linuxInstallBranch, contains("result.recovery_required"));
    expect(
      linuxInstallBranch,
      matches(
        RegExp(
          r"RecoveryRequiredErrorDetails\(\s*transaction_id,\s*"
          r"result\.error\s*\)",
          multiLine: true,
        ),
      ),
    );
  });

  test(
    "Windows install handoff keeps released errors with recovery details",
    () {
      final source = File(pluginSources[1]).readAsStringSync();
      final recoveryDetails = _functionBody(
        source,
        "RecoveryRequiredErrorDetails",
      );
      final restartBranch = source.substring(
        source.indexOf('method_name().compare("restartApp")'),
        source.indexOf('method_name().compare("installUpdate")'),
      );
      final installBranch = source.substring(
        source.indexOf('method_name().compare("installUpdate")'),
        source.indexOf('method_name().compare("queryInstallTransaction")'),
      );

      expect(
        recoveryDetails,
        contains('flutter::EncodableValue("recoveryRequired")'),
      );
      expect(recoveryDetails, contains("flutter::EncodableValue(true)"));
      expect(
        restartBranch,
        isNot(contains("RecoveryRequiredErrorDetails")),
      );
      expect(
        installBranch,
        contains(
          RegExp(
            r"if\s*\(recovery_required\)\s*\{\s*"
            r'result->Error\(\s*"InstallError",\s*error,\s*'
            r"RecoveryRequiredErrorDetails\(\)\)",
          ),
        ),
      );
      expect(source, isNot(contains('"InstallRecoveryRequired"')));
      expect(source, isNot(contains('"RestartRecoveryRequired"')));
    },
  );
}

String _readAll(Iterable<String> paths) =>
    paths.map((path) => File(path).readAsStringSync()).join("\n");

String _functionBody(String source, String functionName) {
  source = source.replaceAll("\r\n", "\n");
  final start = source.indexOf(functionName);
  expect(start, isNonNegative, reason: functionName);
  final nextFunction = source.indexOf("\n}\n\n", start);
  expect(nextFunction, isNonNegative, reason: functionName);
  return source.substring(start, nextFunction + 2);
}
