import "dart:io";

import "package:flutter_test/flutter_test.dart";

void main() {
  test("updater smoke supports macOS Release output", () {
    final source = File("example/tool/updater_smoke.dart").readAsStringSync();

    expect(source, contains("--config Debug|Release"));
    expect(source, contains("Platform.isMacOS"));
    expect(source, contains('"Build"'));
    expect(source, contains('"Products"'));
    expect(source, contains('"desktop_updater_example.app"'));
    expect(source, contains('"Contents"'));
    expect(source, contains("DESKTOP_UPDATER_SMOKE_ALLOW_UNSIGNED_MACOS"));
    expect(source, contains("DESKTOP_UPDATER_SMOKE_DIAGNOSTICS_LOG"));
    expect(source, contains("--diagnostics-log <path>"));
  });

  test("default CI skips the macOS runner", () {
    final workflow =
        File(".github/workflows/desktop-updater-ci.yml").readAsStringSync();

    expect(workflow, isNot(contains("\n  macos:\n")));
    expect(workflow, isNot(contains("name: macOS\n")));
    expect(workflow, isNot(contains("flutter build macos --debug")));
    expect(workflow, isNot(contains("flutter test integration_test -d macos")));
    expect(workflow, isNot(contains("macos-update-smoke-debug-diagnostics")));

    expect(workflow, contains("macos-notarized:"));
    expect(workflow, contains("DESKTOP_UPDATER_RUN_NOTARIZED_PUBLISH_E2E"));
  });
}
