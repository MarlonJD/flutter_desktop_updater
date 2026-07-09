import "dart:io";

import "package:flutter_test/flutter_test.dart";

void main() {
  test("macOS production smoke exposes required commands", () {
    final source = File("tool/macos_production_smoke.dart").readAsStringSync();

    expect(source, contains("doctor"));
    expect(source, contains("app-update"));
    expect(source, contains("dmg-first-install"));
    expect(source, contains("move-to-applications"));
    expect(source, contains("dmg-update"));
    expect(source, contains("pkg-installer"));
    expect(source, contains("pkg-install-verify"));
    expect(source, contains("all"));
    expect(source, contains("--cleanup"));
  });

  test("macOS production smoke documents required environment", () {
    final source = File("tool/macos_production_smoke.dart").readAsStringSync();

    expect(source, contains("DESKTOP_UPDATER_DEV_ID_APP"));
    expect(source, contains("DESKTOP_UPDATER_DEV_ID_INSTALLER"));
    expect(source, contains("DESKTOP_UPDATER_NOTARY_PROFILE"));
    expect(source, contains("DESKTOP_UPDATER_TEST_BUNDLE_ID"));
  });

  test("macOS production smoke keeps cleanup scoped", () {
    final source = File("tool/macos_production_smoke.dart").readAsStringSync();

    expect(source, contains("cleanup: removed smoke app from /Applications"));
    expect(source, contains("_isSmokeOwnedMacOSApp"));
    expect(source, contains("desktop_updater_smoke_owner.txt"));
    expect(source, contains("--cleanup-forget-receipt"));
    expect(source, contains("pkgutil --forget"));
    expect(source, contains("silent privileged install not run"));
  });

  test("normal app update smoke uses direct staged app replacement", () {
    final source = File("tool/macos_production_smoke.dart").readAsStringSync();

    expect(source, contains("Future<void> appUpdate()"));
    expect(source, contains("example/tool/updater_smoke.dart"));
    expect(source, contains("--staged-app"));
    expect(source, contains("app-update: whole-bundle replacement OK"));
    expect(source, contains("app-update: v2 relaunch OK"));
  });

  test("macOS production smoke clears stale sentinel from v1 app builds", () {
    final source = File("tool/macos_production_smoke.dart").readAsStringSync();

    expect(source, contains("final updateSentinel = File("));
    expect(source, contains("if (await updateSentinel.exists())"));
    expect(source, contains("await updateSentinel.delete();"));
  });

  test("DMG update smoke runs the hosted update flow before success evidence",
      () {
    final source = File("tool/macos_production_smoke.dart").readAsStringSync();

    final hostedFlow = source.indexOf("expectInstallerHandoff: false");
    final replacementEvidence =
        source.indexOf("dmg-update: whole-bundle replacement OK");
    final relaunchEvidence = source.indexOf("dmg-update: v2 relaunch OK");

    expect(hostedFlow, isNonNegative);
    expect(replacementEvidence, greaterThan(hostedFlow));
    expect(relaunchEvidence, greaterThan(hostedFlow));
    expect(source, contains("--production-gates"));
    expect(source, contains("--relaunch"));
  });

  test("PKG installer smoke stages through hosted flow before handoff", () {
    final source = File("tool/macos_production_smoke.dart").readAsStringSync();

    final hostedFlow = source.indexOf("expectInstallerHandoff: true");
    final installerEvidence =
        source.indexOf("pkg-installer: Installer.app handoff OK");

    expect(hostedFlow, isNonNegative);
    expect(installerEvidence, greaterThan(hostedFlow));
    expect(source, contains("--expect-installer-handoff"));
    expect(source, contains("pkg-installer: staged PKG update flow OK"));
  });

  test("PKG install verification is explicit and outside all smoke", () {
    final source = File("tool/macos_production_smoke.dart").readAsStringSync();

    expect(source, contains("Future<void> pkgInstallVerify()"));
    expect(source, contains("with administrator privileges"));
    expect(source, contains("/usr/sbin/installer"));
    expect(source, contains("pkg-install-verify: receipt OK"));
    expect(source, contains("pkg-install-verify: installed v2 app OK"));
    expect(source, contains("administratorApprovedReplacement: true"));
    expect(source, contains("_removeSmokeOwnedAppWithAdministratorApproval"));

    final allBodyStart = source.indexOf("Future<void> all() async");
    final allBodyEnd =
        source.indexOf("Future<void> cleanupSmokeOwnedArtifacts");
    expect(allBodyStart, isNonNegative);
    expect(allBodyEnd, greaterThan(allBodyStart));
    expect(
      source.substring(allBodyStart, allBodyEnd),
      isNot(contains("pkgInstallVerify")),
    );
  });

  test("macOS production smoke writes blocked evidence for missing trust env",
      () {
    final source = File("tool/macos_production_smoke.dart").readAsStringSync();

    expect(source, contains(r"blocked: $name is required"));
    expect(source, contains("blocked: macOS production smoke requires"));
  });

  test("macOS production smoke notarizes app bundles through zip archives", () {
    final source = File("tool/macos_production_smoke.dart").readAsStringSync();

    expect(source, contains("_notarizeAndStapleApp"));
    expect(source, contains("notary-upload.zip"));
    expect(source, contains("--keepParent"));
    expect(source, contains("_notarizeAndStapleZip"));
    expect(
      source,
      isNot(
        contains("notarytool submit /tmp/desktop_updater_macos_smoke/apps"),
      ),
    );
  });

  test("CI documents production smoke as local manual evidence", () {
    final workflow =
        File(".github/workflows/desktop-updater-ci.yml").readAsStringSync();

    expect(
      workflow,
      contains("dart run tool/macos_production_smoke.dart all --cleanup"),
    );
    expect(workflow, contains("Developer ID Installer"));
  });
}
