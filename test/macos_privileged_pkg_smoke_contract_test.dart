import "dart:io";

import "package:flutter_test/flutter_test.dart";

void main() {
  test("privileged PKG smoke owns only the exact production target", () {
    final smokeFile = File("tool/macos_privileged_pkg_smoke.dart");
    expect(
      smokeFile.existsSync(),
      isTrue,
      reason: "the privileged PKG target-host smoke tool must exist",
    );
    if (!smokeFile.existsSync()) return;
    final source = smokeFile.readAsStringSync();

    for (final value in [
      "/Applications/Desktop Updater Smoke.app",
      "com.example.desktopUpdaterSmoke",
      "com.example.desktopUpdaterSmoke.pkg",
      "desktop_updater macOS production smoke",
      "desktop_updater_smoke_owner.txt",
      "UPK4SC93AN",
      "1.0.0",
      "100",
      "1.1.0",
      "110",
    ]) {
      expect(source, contains(value), reason: value);
    }
    expect(source, contains("followLinks: false"));
    expect(source, contains("root:wheel"));
    expect(source, contains("pkgutil"));
    expect(source, contains("codesign"));
    expect(source, contains("spctl"));
    expect(source, contains("stapler"));
    expect(source, contains("launchctl"));
    expect(source, contains("stageRemovedAfterCompletion"));
    expect(source, contains("_validateEvidenceDocument"));
  });

  test("privileged PKG smoke uses typed approval and fixed updater authority",
      () {
    final smokeFile = File("tool/macos_privileged_pkg_smoke.dart");
    if (!smokeFile.existsSync()) return;
    final source = smokeFile.readAsStringSync();

    expect(source, contains('"event"'));
    expect(source, contains('"installFailed"'));
    expect(source, contains('"PrivilegedHelperApprovalRequired"'));
    expect(source, contains('"openMacOSBackgroundItemsSettings"'));
    expect(source, contains("--open-settings"));
    expect(source, contains("requiresApproval"));
    expect(source, contains("privilegedInstallerTool"));
    expect(source, contains("pkgInstaller"));
    expect(source, contains("minimumUpdaterVersion"));
    expect(source, contains("3.1.0"));
    expect(source, contains("owned stage"));

    for (final forbidden in [
      "SMJobBless",
      "AuthorizationExecuteWithPrivileges",
      "sudo",
      "osascript",
      "Installer.app",
    ]) {
      expect(source, isNot(contains(forbidden)), reason: forbidden);
    }
  });

  test("bootstrap avoids same-version refresh and final-install cleanup", () {
    final smokeFile = File("tool/macos_privileged_pkg_smoke.dart");
    if (!smokeFile.existsSync()) return;
    final source = smokeFile.readAsStringSync();

    expect(
      RegExp(r"await _removeVerifiedBootstrapRefreshStage\(\);")
          .allMatches(source),
      isEmpty,
    );
    expect(source, contains("readStagedUpdateProvenance("));
    expect(source, contains("verifyStagedUpdateProvenance("));
    expect(source, contains("deleteOwnedStagingDirectory("));
    expect(source, contains("state.provenance.artifactSha256"));
    expect(source, contains("_bundlesShareBundleIdentity("));
    expect(
      source,
      contains("Stapling a product package may rewrite the nested app/helper"),
    );

    final bootstrap = source.indexOf("Future<void> bootstrapV1()");
    final finalInstall = source.indexOf("Future<void> install() async");
    final validateInputs = source.indexOf(
      "Future<void> _validateInputs",
      finalInstall,
    );
    expect(source, isNot(contains("fresh-v2-bootstrap-failed")));
    expect(source, isNot(contains("final downgrade = await _runRuntime(")));
    expect(finalInstall, greaterThan(bootstrap));
    expect(validateInputs, greaterThan(finalInstall));
    expect(
      source.substring(finalInstall, validateInputs),
      isNot(contains("_removeVerifiedBootstrapRefreshStage")),
    );
  });

  test("approval install resumes through the fixed recovery gate", () {
    final source = File(
      "tool/macos_privileged_pkg_smoke.dart",
    ).readAsStringSync();

    for (final value in [
      "_removeVerifiedApprovalStage",
      "approval.json",
      "_waitForFixedInstallerManager",
      "/usr/sbin/installer",
      "/private/var/tmp/com.example.desktopUpdaterSmoke.pkg-recovery.ready",
      "/private/var/tmp/com.example.desktopUpdaterSmoke.pkg-recovery.release",
      "root:wheel:600",
      "_probeInstalledLaunchDaemon",
      "--probe-helper",
      "--hold-helper-active",
    ]) {
      expect(source, contains(value), reason: value);
    }

    expect(source, contains("readStagedUpdateProvenance("));
    expect(source, contains("verifyStagedUpdateProvenance("));
    expect(source, contains("deleteOwnedStagingDirectory("));
    expect(source, contains("final process = await Process.start("));
    expect(
      source,
      contains('"DESKTOP_UPDATER_CONTROLLER_SMOKE": "1"'),
    );
    expect(
      source,
      contains('"DESKTOP_UPDATER_CONTROLLER_SMOKE_TARGET": _targetPath'),
    );
    expect(
      source,
      contains('"DESKTOP_UPDATER_NATIVE_CONTROLLER_SMOKE": "1"'),
    );
    expect(source, contains('output.contains(\'"event":"helperProbe"\')'));
    expect(
      source,
      isNot(contains('Process.run("/usr/sbin/installer"')),
    );
    expect(
      source,
      isNot(contains('Process.start("/usr/sbin/installer"')),
    );
  });

  test("terminal install recovers before claiming owned stage cleanup", () {
    final source = File(
      "tool/macos_privileged_pkg_smoke.dart",
    ).readAsStringSync();
    final install = source.indexOf("Future<void> install() async");
    final validateInputs = source.indexOf(
      "Future<void> _validateInputs",
      install,
    );
    final body = source.substring(install, validateInputs);
    final probe = body.indexOf("await _probeInstalledLaunchDaemon(");
    final recovery = body.indexOf(
      "await _recoverBlockingBootstrapTransaction(",
      probe,
    );
    final cleanup = body.indexOf("await _waitForOwnedStageEmpty();");

    expect(install, isNonNegative);
    expect(probe, isNonNegative);
    expect(recovery, greaterThan(probe));
    expect(cleanup, greaterThan(recovery));
    expect(
      body.substring(recovery, cleanup),
      allOf(
        contains('expectedState: "completed"'),
        contains('expectedResultCode: "succeeded"'),
        contains("required: false"),
      ),
    );
  });

  test("launch daemon probes bind the kernel executable path", () {
    for (final harness in [
      "tool/macos_privileged_pkg_smoke.dart",
      "tool/macos_privileged_pkg_recovery_smoke.dart",
    ]) {
      final source = File(harness).readAsStringSync();
      expect(source, contains("proc_pidpath"), reason: harness);
      expect(
        source,
        isNot(
          contains(r'["-ww", "-p", "$pid", "-o", "command="]'),
        ),
        reason: harness,
      );
    }
  });

  test("bootstrap requires a package-installed v1 without version forgery", () {
    final source = File(
      "tool/macos_privileged_pkg_smoke.dart",
    ).readAsStringSync();
    final bootstrap = source.indexOf("Future<void> bootstrapV1() async");
    final verify = source.indexOf("Future<void> verifyV1() async");
    expect(bootstrap, isNonNegative);
    expect(verify, greaterThan(bootstrap));
    expect(
      source.substring(bootstrap, verify),
      contains('throw const _SmokeFailure("v1-package-baseline-required")'),
    );
    expect(source, isNot(contains("CONTROLLER_SMOKE_CURRENT_VERSION")));
    expect(source, isNot(contains("CONTROLLER_SMOKE_CURRENT_BUILD")));
    expect(
        source.substring(bootstrap, verify), isNot(contains("_runRuntime(")));
  });

  test("privileged runtime launches the authenticated smoke target", () {
    final source = File(
      "tool/macos_privileged_pkg_smoke.dart",
    ).readAsStringSync();
    final runtime = source.indexOf("Future<_RuntimeResult> _runRuntime");
    final target = source.indexOf(
      "final runtimeApp = Directory(_targetPath);",
      runtime,
    );

    expect(runtime, isNonNegative);
    expect(target, greaterThan(runtime));
    expect(
      source.substring(runtime, target),
      isNot(contains("final runtimeApp = request.recoveryApp;")),
    );
  });

  test("bootstrap accepts only the exact package-installed v1 baseline", () {
    final smokeFile = File("tool/macos_privileged_pkg_smoke.dart");
    if (!smokeFile.existsSync()) return;
    final source = smokeFile.readAsStringSync();

    final bootstrap = source.indexOf("Future<void> bootstrapV1() async");
    final verify = source.indexOf("Future<void> verifyV1() async");
    expect(bootstrap, isNonNegative);
    final body = source.substring(bootstrap, verify);
    expect(body, contains("allowedVersions: const {(_v1Version, _v1Build)}"));
    expect(body, isNot(contains("allowedReceiptStates:")));
    expect(body, isNot(contains("allowMissingReceipt:")));
  });

  test("fixed baseline and recovery packages cannot relocate", () {
    final source = File(
      "example/native/macos-runtime/package_smoke_app.sh",
    ).readAsStringSync();

    expect(
      source,
      contains("DESKTOP_UPDATER_RUNTIME_PKG_BASELINE_SMOKE"),
    );
    for (final boundary in [
      "net.monolib.updater",
      "net.monolib.updater.pkg",
      "Desktop Updater SMAppService PKG E2E",
      "2.7.0:270",
      "/Applications",
    ]) {
      expect(source, contains(boundary), reason: boundary);
    }
    expect(source, contains("baseline and recovery smoke flags are exclusive"));
    expect(source, contains("pkgbuild --analyze"));
    expect(source, contains("BundleIsVersionChecked"));
    expect(source, contains("BundleIsRelocatable"));
    expect(source, contains("BundleHasStrictIdentifier"));
    expect(source, contains("BundleOverwriteAction"));
    expect(
      RegExp(
        r'--component-plist "\$component_plist"',
      ).allMatches(source),
      hasLength(2),
    );
    expect(source, contains("baseline-distribution.xml"));
    expect(source, contains("productbuild --synthesize"));
    expect(source, contains("baseline distribution bundle-version mismatch"));
    expect(
      source,
      contains("baseline final distribution retained bundle-version"),
    );
    expect(source, contains("--distribution"));
    expect(source, contains("pkgutil --flatten"));
    expect(source, contains("productsign"));
    expect(source, contains("baseline-product-expanded"));
    expect(
      RegExp("fixed smoke application bundle").allMatches(source),
      hasLength(2),
    );
  });

  test(
      "transaction recovery uses typed signed-app XPC without exposing identity",
      () {
    final smokeFile = File("tool/macos_privileged_pkg_smoke.dart");
    if (!smokeFile.existsSync()) return;
    final source = smokeFile.readAsStringSync();

    expect(source, contains('addOption("recovery-app", mandatory: true)'));
    expect(source, contains("_recoverBlockingBootstrapTransaction("));
    expect(source, contains('"--recover-transaction"'));
    expect(source, contains(r"\.provider\.json$"));
    expect(source, contains('value["event"] == "recovery"'));
    expect(source, isNot(contains('"manualActionRequired"')));
    expect(source, contains('"completed"'));
    expect(source, isNot(contains('"transactionID": transactionID')));

    expect(source, contains("await _recoverBlockingBootstrapTransaction("));
    final recovery = source.indexOf(
      "Future<void> _recoverBlockingBootstrapTransaction(",
    );
    final metadata = source.indexOf(
      "Future<_BundleMetadata> _readBundleMetadata(",
      recovery,
    );
    final body = source.substring(recovery, metadata);
    expect(body, contains("final runtimeApp = Directory(_targetPath);"));
    expect(body,
        contains("final metadata = await _readBundleMetadata(runtimeApp);"));
    expect(body, isNot(contains("_readBundleMetadata(request.recoveryApp)")));
  });
}
