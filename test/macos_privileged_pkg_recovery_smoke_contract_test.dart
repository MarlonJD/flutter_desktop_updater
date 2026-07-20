import "dart:io";

import "package:flutter_test/flutter_test.dart";

import "../tool/macos_privileged_pkg_recovery_smoke.dart" as recovery;

void main() {
  test("manager query retries one activation transient", () async {
    var attempts = 0;

    final result =
        await recovery.macOSRetryTransactionQueryActivationForTesting<String>(
      () async {
        attempts += 1;
        return attempts == 1 ? null : "ready";
      },
      maximumAttempts: 3,
      delay: Duration.zero,
    );

    expect(result, "ready");
    expect(attempts, 2);
  });

  test("manager query retry is bounded", () async {
    var attempts = 0;

    await expectLater(
      recovery.macOSRetryTransactionQueryActivationForTesting<String>(
        () async {
          attempts += 1;
          return null;
        },
        maximumAttempts: 3,
        delay: Duration.zero,
      ),
      throwsA(isA<StateError>()),
    );

    expect(attempts, 3);
  });

  test("manager query does not retry malformed typed output", () async {
    var attempts = 0;

    await expectLater(
      recovery.macOSRetryTransactionQueryActivationForTesting<String>(
        () async {
          attempts += 1;
          throw const FormatException("malformed typed output");
        },
        maximumAttempts: 3,
        delay: Duration.zero,
      ),
      throwsFormatException,
    );

    expect(attempts, 1);
  });

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
      contains("/private/var/tmp/net.monolib.updater.pkg-recovery.ready"),
    );
    expect(
      source,
      contains("/private/var/tmp/net.monolib.updater.pkg-recovery.release"),
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
    expect(source, contains("let helper = MacInstallHelper()"));
    expect(source, contains("helper.queryTransaction("));
    expect(source, contains("Select exactly one transaction operation."));
    expect(source, contains('"event": "query"'));
    expect(source, contains('"resultCode": recoveryResultName('));
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
      "/Applications/Desktop Updater SMAppService PKG E2E.app",
      "net.monolib.updater.pkg",
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

    expect(source, contains('"net.monolib.updater.helper"'));
    expect(source, isNot(contains('"net.monolib.updater.installer"')));
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
    expect(
      helper,
      contains("/private/var/tmp/net.monolib.updater.pkg-recovery.ready"),
    );
    expect(
      helper,
      contains("/private/var/tmp/net.monolib.updater.pkg-recovery.release"),
    );
    expect(helper, contains("lstat("));
    expect(helper, contains(".managerStarted"));
    expect(helper, contains("persistentOwnerIsLive("));
    expect(
      runtime,
      contains('optionalValue("--terminate-helper-for-recovery-smoke")'),
    );
    expect(runtime, contains('"event": "helperCrashScheduled"'));
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
