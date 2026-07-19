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
      "/Applications/Desktop Updater SMAppService PKG E2E.app",
      "net.monolib.updater",
      "net.monolib.updater.pkg",
      "desktop_updater macOS production smoke",
      "desktop_updater_smoke_owner.txt",
      "UPK4SC93AN",
      "2.7.0",
      "270",
      "2.7.1",
      "271",
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
    expect(source, contains("2.7.0"));
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

  test("bootstrap cleanup is provenance-bound and excluded from final install",
      () {
    final smokeFile = File("tool/macos_privileged_pkg_smoke.dart");
    if (!smokeFile.existsSync()) return;
    final source = smokeFile.readAsStringSync();

    expect(
      RegExp(r"await _removeVerifiedBootstrapRefreshStage\(\);")
          .allMatches(source),
      hasLength(1),
    );
    expect(source, contains("readStagedUpdateProvenance("));
    expect(source, contains("verifyStagedUpdateProvenance("));
    expect(source, contains("deleteOwnedStagingDirectory("));
    expect(source, contains("state.provenance.artifactSha256"));

    final refreshIdentity = source.indexOf("fresh-v2-bootstrap-failed");
    final bootstrapCleanup = source.indexOf(
      "await _removeVerifiedBootstrapRefreshStage();",
    );
    final downgrade = source.indexOf("final downgrade = await _runRuntime(");
    final finalInstall = source.indexOf("Future<void> install() async");
    final validateInputs = source.indexOf(
      "Future<void> _validateInputs",
      finalInstall,
    );
    expect(refreshIdentity, isNonNegative);
    expect(bootstrapCleanup, greaterThan(refreshIdentity));
    expect(downgrade, greaterThan(bootstrapCleanup));
    expect(finalInstall, greaterThan(downgrade));
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
      "/private/var/tmp/net.monolib.updater.pkg-recovery.ready",
      "/private/var/tmp/net.monolib.updater.pkg-recovery.release",
      "root:wheel:600",
      "_probeInstalledLaunchDaemon",
      "--hold-helper-active",
    ]) {
      expect(source, contains(value), reason: value);
    }

    expect(source, contains("readStagedUpdateProvenance("));
    expect(source, contains("verifyStagedUpdateProvenance("));
    expect(source, contains("deleteOwnedStagingDirectory("));
    expect(source, contains("Process.start(host,"));
    expect(
      source,
      isNot(contains('Process.run("/usr/sbin/installer"')),
    );
    expect(
      source,
      isNot(contains('Process.start("/usr/sbin/installer"')),
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

  test("bootstrap refresh releases the fixed recovery gate", () {
    final source = File(
      "tool/macos_privileged_pkg_smoke.dart",
    ).readAsStringSync();
    final bootstrap = source.indexOf("Future<void> bootstrapV1() async");
    final verify = source.indexOf("Future<void> verifyV1() async");
    final refresh = source.indexOf(
      "final refresh = await _runRuntime(",
      bootstrap,
    );
    final waitForManager = source.indexOf(
      "final refreshManager = await _waitForFixedInstallerManager(",
      refresh,
    );
    final release = source.indexOf(
      "await _releaseRecoveryGate(refreshManager.processIdentifier);",
      refresh,
    );
    final waitForBundle = source.indexOf(
      "if (!await _waitForBundleIdentity(",
      refresh,
    );

    expect(bootstrap, isNonNegative);
    expect(refresh, greaterThan(bootstrap));
    expect(waitForManager, greaterThan(refresh));
    expect(release, greaterThan(waitForManager));
    expect(waitForBundle, greaterThan(release));
    expect(waitForBundle, lessThan(verify));
  });

  test("only bootstrap accepts the known v2 app and v1 receipt recovery pair",
      () {
    final smokeFile = File("tool/macos_privileged_pkg_smoke.dart");
    if (!smokeFile.existsSync()) return;
    final source = smokeFile.readAsStringSync();

    expect(
      RegExp(r"allowedReceiptStates:").allMatches(source),
      hasLength(1),
    );
    expect(
      source,
      contains("(_v2Version, _v1Version)"),
    );
    final bootstrap = source.indexOf("Future<void> bootstrapV1() async");
    final verify = source.indexOf("Future<void> verifyV1() async");
    final receiptOverride = source.indexOf("allowedReceiptStates:");
    expect(bootstrap, isNonNegative);
    expect(receiptOverride, greaterThan(bootstrap));
    expect(receiptOverride, lessThan(verify));
  });

  test("baseline package disables version checks only for the fixed v1 smoke",
      () {
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
    expect(source, contains("--component-plist"));
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

  test("bootstrap recovery uses typed signed-app XPC without exposing identity",
      () {
    final smokeFile = File("tool/macos_privileged_pkg_smoke.dart");
    if (!smokeFile.existsSync()) return;
    final source = smokeFile.readAsStringSync();

    expect(source, contains('addOption("recovery-app", mandatory: true)'));
    expect(source, contains("_recoverBlockingBootstrapTransaction("));
    expect(source, contains('"--recover-transaction"'));
    expect(source, contains(r"\.provider\.json$"));
    expect(source, contains('value["event"] == "recovery"'));
    expect(source, contains('"manualActionRequired"'));
    expect(source, contains('"completed"'));
    expect(source, isNot(contains('"transactionID": transactionID')));

    final bootstrap = source.indexOf("Future<void> bootstrapV1() async");
    final verify = source.indexOf("Future<void> verifyV1() async");
    final recovery = source.indexOf(
      "await _recoverBlockingBootstrapTransaction(",
    );
    expect(recovery, greaterThan(bootstrap));
    expect(recovery, lessThan(verify));
  });
}
