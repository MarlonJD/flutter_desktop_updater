import "dart:io";

import "package:flutter_test/flutter_test.dart";

import "../tool/macos_privileged_pkg_recovery_smoke.dart" as recovery;

void main() {
  test(
    "runtime process contains smoke argument failures",
    () async {
      final tempRoot = await Directory(
        "/private/tmp",
      ).createTemp("desktop-updater-runtime-containment-");
      final scratch = Directory("${tempRoot.path}/swiftpm-scratch");
      final moduleCache = Directory("${tempRoot.path}/module-cache");
      final runtimePackage = Directory(
        "example/native/macos-runtime",
      ).absolute;
      final environment = <String, String>{
        ...Platform.environment,
        "CLANG_MODULE_CACHE_PATH": moduleCache.path,
        "SWIFTPM_MODULECACHE_OVERRIDE": moduleCache.path,
      };

      try {
        await moduleCache.create(recursive: true);
        final build = await Process.run(
          "swift",
          [
            "build",
            "--package-path",
            runtimePackage.path,
            "--scratch-path",
            scratch.path,
            "--disable-sandbox",
            "--product",
            "MacOSRuntimeCompile",
          ],
          environment: environment,
        );
        expect(
          build.exitCode,
          0,
          reason: "Fresh runtime build failed:\n${build.stdout}${build.stderr}",
        );

        final binPath = await Process.run(
          "swift",
          [
            "build",
            "--package-path",
            runtimePackage.path,
            "--scratch-path",
            scratch.path,
            "--disable-sandbox",
            "--show-bin-path",
          ],
          environment: environment,
        );
        expect(
          binPath.exitCode,
          0,
          reason: "Could not resolve the fresh build output path: "
              "${binPath.stdout}${binPath.stderr}",
        );

        const sensitiveInput = "sensitive-raw-input-never-emit";
        final executable = File(
          "${(binPath.stdout as String).trim()}/MacOSRuntimeCompile",
        );
        expect(executable.existsSync(), isTrue);
        final result = await Process.run(executable.path, [
          "--smoke",
          "--public-key-base64",
          sensitiveInput,
        ]);
        final stdout = result.stdout as String;
        final stderr = result.stderr as String;

        expect(result.exitCode, 1);
        expect(
          stdout.trim().split("\n"),
          [r'{"event":"smokeFailed","status":"failed"}'],
        );
        expect(stderr, isEmpty);
        expect("$stdout$stderr", isNot(contains(sensitiveInput)));
        expect("$stdout$stderr", isNot(contains("Missing required argument")));
        expect("$stdout$stderr", isNot(contains("SmokeFailure")));
      } finally {
        if (tempRoot.existsSync()) {
          await tempRoot.delete(recursive: true);
        }
      }
    },
    skip: !Platform.isMacOS,
    timeout: const Timeout(Duration(minutes: 10)),
  );

  test("process start identity matches the helper macOS identity shape", () {
    if (!Platform.isMacOS) return;
    final first = recovery.macOSProcessStartIdentityForTesting(pid);
    final second = recovery.macOSProcessStartIdentityForTesting(pid);

    expect(first, matches(RegExp(r"^macos:[0-9]+:[0-9]+$")));
    expect(second, first);
    expect(recovery.macOSProcessStartIdentityForTesting(-1), isNull);
    expect(recovery.macOSKernProcessStartIdentityForTesting(pid), first);
    expect(
      recovery.macOSKernProcessStartIdentityForTesting(1),
      matches(RegExp(r"^macos:[0-9]+:[0-9]+$")),
    );

    final executable = recovery.macOSProcessExecutablePathForTesting(pid);
    expect(executable, isNotNull);
    expect(
      File(executable!).resolveSymbolicLinksSync(),
      File(Platform.resolvedExecutable).resolveSymbolicLinksSync(),
    );
    expect(recovery.macOSProcessExecutablePathForTesting(-1), isNull);
  });

  test("recovery package uses only the fixed repository preinstall gate", () {
    final script = File(
      "example/native/macos-runtime/pkg-scripts/recovery/preinstall",
    );
    expect(script.existsSync(), isTrue, reason: "fixed preinstall is required");
    if (!script.existsSync()) return;
    final source = script.readAsStringSync();

    expect(source, contains("#!/bin/sh"));
    expect(source, contains("set -eu"));
    expect(
      source,
      contains(
        "/private/var/tmp/com.example.desktopUpdaterSmoke.pkg-recovery.ready",
      ),
    );
    expect(
      source,
      contains(
        "/private/var/tmp/com.example.desktopUpdaterSmoke.pkg-recovery.release",
      ),
    );
    expect(source, contains("'%s\\n' \"\$PPID\""));
    expect(source, contains("/bin/sleep 0.1"));
    expect(source, contains("umask 077"));
    expect(source, contains("set -C"));
    expect(source, isNot(contains(r"$1")));
    expect(source, isNot(contains("eval")));
  });

  test("recovery harness does not read the root-only ready marker", () {
    final source = File(
      "tool/macos_privileged_pkg_recovery_smoke.dart",
    ).readAsStringSync();

    expect(source, contains('authority.trim() != "root:wheel:600"'));
    expect(
      source,
      isNot(contains("File(_readyMarker).readAsString()")),
    );
    expect(source, contains("_waitForUniqueInstaller("));
    expect(source, contains("_sameLiveManager("));
  });

  test("recovery harness recognizes only the fixed installer argv", () {
    const stageOwner =
        "a979abee7efd579fda2f2fce032782046d5511f530ec444342ef696ca1c505d9";
    const transactionID = "c6de8ff0-a318-4062-8835-103a9dc57f3c";
    const command = "/usr/sbin/installer -pkg "
        "/Library/PrivilegedHelperTools/.desktop-updater-stages-$stageOwner/"
        "desktop-updater-stage-$transactionID/installer.pkg -target /";

    expect(
      recovery.macOSFixedInstallerArgumentsForTesting(command, transactionID),
      isTrue,
    );
    for (final rejected in <String>[
      command.replaceFirst("/usr/sbin/installer", "/bin/sh"),
      command.replaceFirst(" -target /", " -target CurrentUserHomeDirectory"),
      "$command -verbose",
      command.replaceFirst(stageOwner, "0" * 63),
      command.replaceFirst(transactionID, "other-transaction"),
    ]) {
      expect(
        recovery.macOSFixedInstallerArgumentsForTesting(
          rejected,
          transactionID,
        ),
        isFalse,
        reason: rejected,
      );
    }
  });

  test("packager enables scripts only for the fixed recovery smoke flag", () {
    final source = File(
      "example/native/macos-runtime/package_smoke_app.sh",
    ).readAsStringSync();

    expect(
      source,
      contains("DESKTOP_UPDATER_RUNTIME_PKG_RECOVERY_SMOKE"),
    );
    expect(source, contains("pkg-scripts/recovery"));
    expect(source, contains("--scripts"));
    expect(source, contains("[ -f \"\$recovery_scripts/preinstall\" ]"));
    expect(source, contains("recovery_entry_count"));
    expect(source, isNot(contains("DESKTOP_UPDATER_RUNTIME_PKG_SCRIPTS")));
  });

  test("signed smoke adapter exposes typed query without identity output", () {
    final source = File(
      "example/native/macos-runtime/Sources/MacOSRuntimeCompile/main.swift",
    ).readAsStringSync();

    expect(source, contains('optionalValue("--query-transaction")'));
    expect(source, contains("queryTransactionForSmoke"));
    expect(source, contains("refreshMismatchedPrivilegedEndpointForSmoke"));
    expect(source, contains('has("--refresh-mismatched-helper")'));
    expect(source, contains("emitTransactionOutcome"));
    expect(source, contains('emitTransactionOutcome("query", outcome)'));
    expect(source, contains("Select exactly one transaction operation."));
    expect(
      source,
      contains('"resultCode": recoveryResultName(status.resultCode)'),
    );
    expect(source, isNot(contains('"transactionID": transactionID')));
    expect(source, isNot(contains('"managerPID"')));
    expect(source, isNot(contains('"managerStartIdentity"')));
  });

  test("recovery harness binds exact manager identity and stage lifetime", () {
    final harness = File("tool/macos_privileged_pkg_recovery_smoke.dart");
    expect(
      harness.existsSync(),
      isTrue,
      reason: "recovery harness is required",
    );
    if (!harness.existsSync()) return;
    final source = harness.readAsStringSync();

    for (final value in [
      "/Applications/Desktop Updater Smoke.app",
      "com.example.desktopUpdaterSmoke.pkg",
      "/usr/sbin/installer",
      "managerStarted",
      "recoveryRequired",
      "managerObservedLive",
      "stageRetainedWhileManagerLive",
      "concurrentMutationObserved",
      "stageRemovedAfterCompletion",
      "verifiedOutcome",
      "newTarget",
      "completed",
      "root:wheel",
      "root:wheel:600",
    ]) {
      expect(source, contains(value), reason: value);
    }

    expect(source, contains("_ProcessStartIdentity"));
    expect(source, contains("proc_pidinfo"));
    expect(source, contains(r'"macos:$seconds:$microseconds"'));
    expect(source, contains("_sameLiveManager("));
    expect(source, contains("_sameLaunchDaemonIdentity("));
    expect(source, contains("_fixedInstallerArguments("));
    expect(source, contains("_launchDaemonPID("));
    expect(source, contains('"--terminate-helper-for-recovery-smoke"'));
    expect(source, contains('crash.event != "helperCrashScheduled"'));
    expect(source, isNot(contains("Process.killPid")));
    expect(source, contains("followLinks: false"));
    expect(source, contains("_validateEvidence("));
    expect(source, isNot(contains("sudo")));
    expect(source, isNot(contains("osascript")));
    expect(source, isNot(contains("Installer.app")));
    expect(source, isNot(contains("AuthorizationExecuteWithPrivileges")));
  });

  test("recovery harness binds the packaged smoke helper service", () {
    final source = File(
      "tool/macos_privileged_pkg_recovery_smoke.dart",
    ).readAsStringSync();

    expect(source, contains("DesktopUpdaterInstallHelperServiceID"));
    expect(source, contains("_servicePattern"));
    expect(source, contains("metadata.serviceIdentifier"));
    expect(
        source, isNot(contains('"com.example.desktopUpdaterSmoke.installer"')));
  });

  test("recovery refreshes the installed helper after manager exit", () {
    final source = File(
      "tool/macos_privileged_pkg_recovery_smoke.dart",
    ).readAsStringSync();

    final release = source.indexOf("await _createReleaseMarker(manager.pid)");
    final managerExit = release < 0
        ? -1
        : source.indexOf("await _waitForIdentityExit(manager", release);
    final refresh = managerExit < 0
        ? -1
        : source.indexOf(
            "await _refreshInstalledLaunchDaemon(",
            managerExit,
          );
    final terminalRecovery = refresh < 0
        ? -1
        : source.indexOf("await _waitForCompletedRecovery(", refresh);

    expect(release, isNonNegative);
    expect(managerExit, greaterThan(release));
    expect(refresh, greaterThan(managerExit));
    expect(terminalRecovery, greaterThan(refresh));
    expect(source, contains('"--refresh-mismatched-helper"'));
    expect(source, contains("Process.start("));
    expect(source, contains("environment: _controllerSmokeEnvironment"));
    expect(source, contains("_waitForCurrentLaunchDaemon("));
    expect(source, contains("_terminateOwnedChild("));
    expect(source, contains("ProcessSignal.sigkill"));
    expect(source, isNot(contains("refreshedHelper.pid == manager.pid")));
    expect(source, contains("installed-helper-refresh-target-invalid"));
    expect(source, contains("installed-helper-refresh-failed"));

    final refreshBodyStart = source.indexOf(
      "Future<_ProcessStartIdentity> _refreshInstalledLaunchDaemon(",
    );
    final refreshBodyEnd = refreshBodyStart < 0
        ? -1
        : source.indexOf(
            "Future<_TransactionEvent> _waitForCompletedRecovery(",
            refreshBodyStart,
          );
    expect(refreshBodyStart, isNonNegative);
    expect(refreshBodyEnd, greaterThan(refreshBodyStart));
    final refreshBody = source.substring(refreshBodyStart, refreshBodyEnd);
    expect(refreshBody, isNot(contains("_waitForIdentityExit(")));
    expect(refreshBody, isNot(contains('"--hold-helper-active"')));
    expect(refreshBody, contains("const Duration(seconds: 90)"));
    expect(refreshBody, contains("_installedHelperRefreshRetryAttempts"));
    expect(refreshBody, contains("_runInstalledHelperRefreshProbe(host)"));
    expect(
      refreshBody,
      contains("Future<void>.delayed(_installedHelperRefreshRetryDelay)"),
    );
  });

  test("recovery smoke self-crash is gate and manager identity bound", () {
    final helper = File(
      "macos/install_helper/Sources/DesktopUpdaterInstallHelper/"
      "MacPersistentRecovery.swift",
    ).readAsStringSync();
    final runtime = File(
      "example/native/macos-runtime/Sources/MacOSRuntimeCompile/main.swift",
    ).readAsStringSync();

    expect(helper, contains("terminateForRecoverySmoke"));
    expect(helper, contains("persistentRecoverySmokeGateIsActive"));
    expect(helper, contains("applicationPackageID"));
    expect(helper, contains("pkg-recovery."));
    expect(helper, contains("lstat("));
    expect(helper, contains(".managerStarted"));
    expect(helper, contains("persistentOwnerIsLive("));
    expect(
      runtime,
      contains('optionalValue("--terminate-helper-for-recovery-smoke")'),
    );
    expect(runtime, contains('"event": "helperCrashScheduled"'));
  });

  test("retries only typed replay-safe transaction transport failures", () {
    final harness = File(
      "tool/macos_privileged_pkg_recovery_smoke.dart",
    ).readAsStringSync();
    final runtime = File(
      "example/native/macos-runtime/Sources/MacOSRuntimeCompile/main.swift",
    ).readAsStringSync();
    final helper = File(
      "macos/desktop_updater/Sources/DesktopUpdaterKit/MacInstallHelper.swift",
    ).readAsStringSync();

    expect(runtime, contains("queryTransactionForSmoke"));
    expect(runtime, contains("recoverPendingInstallForSmoke"));
    expect(runtime, contains("MacInstallSmokeTransactionOutcome"));
    expect(runtime, contains("static func main() async {"));
    expect(runtime, isNot(contains("static func main() async throws")));
    expect(runtime, isNot(contains("catch MacInstallClientError")));
    expect(
      runtime,
      isNot(contains("let outcome = try MacInstallHelper()")),
    );
    expect(runtime, contains('"state": "unknown"'));
    expect(runtime, contains('"resultCode": "endpointUnavailable"'));
    expect(runtime, contains("smokeFailed"));
    expect(runtime, isNot(contains("error.localizedDescription")));
    expect(helper, contains("MacInstallOperationOutcome"));
    expect(helper, contains("endpointPolicy: .existingOnly"));
    expect(
      helper,
      isNot(
        contains("_ operation: () throws -> InstallTransactionStatus"),
      ),
    );
    expect(helper, isNot(contains(".get()")));
    expect(harness, contains("_transactionRetryAttempts"));
    expect(harness, contains("_transactionRetryDelay"));
    expect(harness, contains('"--query-transaction"'));
    expect(harness, contains('"--recover-transaction"'));
    final replaySafeStart = harness.indexOf(
      "const _replaySafeTransactionOperations",
    );
    final replaySafeEnd = harness.indexOf("};", replaySafeStart);
    expect(replaySafeStart, isNonNegative);
    expect(replaySafeEnd, greaterThan(replaySafeStart));
    expect(
      harness.substring(replaySafeStart, replaySafeEnd),
      isNot(contains("--terminate-helper-for-recovery-smoke")),
    );
    expect(harness, contains('event.state == "unknown"'));
    expect(harness, contains('event.resultCode == "endpointUnavailable"'));
  });

  test("recovery evidence is sanitized and excludes raw process identity", () {
    final harness = File("tool/macos_privileged_pkg_recovery_smoke.dart");
    if (!harness.existsSync()) return;
    final source = harness.readAsStringSync();
    final evidenceStart = source.indexOf("final evidence = <String, Object?>{");
    final evidenceEnd = source.indexOf("_validateEvidence(evidence)");
    expect(evidenceStart, isNonNegative);
    expect(evidenceEnd, greaterThan(evidenceStart));
    final evidenceSource = source.substring(evidenceStart, evidenceEnd);

    expect(evidenceSource, contains('"status": "verified locally"'));
    expect(evidenceSource, contains('"gitCommit"'));
    expect(evidenceSource, contains('"artifactSHA256"'));
    expect(evidenceSource, contains('"notarizationSubmissionId"'));
    expect(evidenceSource, isNot(contains('"managerPID"')));
    expect(evidenceSource, isNot(contains('"managerStartIdentity"')));
    expect(evidenceSource, isNot(contains('"commandLine"')));
    expect(evidenceSource, isNot(contains('"stagePath"')));
    expect(evidenceSource, isNot(contains('"helperLog"')));
    expect(source, isNot(contains("Platform.environment")));
  });
}
