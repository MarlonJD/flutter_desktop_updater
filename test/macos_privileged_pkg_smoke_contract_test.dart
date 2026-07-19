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
      "/usr/sbin/installer",
      "Process.start",
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
}
