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
    expect(source, contains("--cleanup-forget-receipt"));
    expect(source, contains("pkgutil --forget"));
    expect(source, contains("silent privileged install not run"));
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
