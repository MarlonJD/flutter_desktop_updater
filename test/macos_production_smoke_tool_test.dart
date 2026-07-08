import "dart:io";

import "package:flutter_test/flutter_test.dart";

void main() {
  test("macOS production smoke exposes required commands", () {
    final source = File("tool/macos_production_smoke.dart").readAsStringSync();

    expect(source, contains("doctor"));
    expect(source, contains("dmg-first-install"));
    expect(source, contains("move-to-applications"));
    expect(source, contains("dmg-update"));
    expect(source, contains("pkg-installer"));
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

  test("macOS production smoke writes blocked evidence for missing trust env",
      () {
    final source = File("tool/macos_production_smoke.dart").readAsStringSync();

    expect(source, contains(r"blocked: $name is required"));
    expect(source, contains("blocked: macOS production smoke requires"));
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
