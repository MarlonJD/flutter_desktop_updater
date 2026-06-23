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

  test(
    "macOS CI runs package, debug, integration, publish, and smoke checks",
    () {
      final workflow =
          File(".github/workflows/desktop-updater-ci.yml").readAsStringSync();

      expect(workflow, contains("macos:"));
      expect(workflow, contains("name: macOS"));
      expect(workflow, contains("runs-on: macos-latest"));
      expect(workflow, contains("flutter test --no-pub"));
      expect(workflow, contains("flutter build macos --debug"));
      expect(workflow, contains("flutter test integration_test -d macos"));
      expect(workflow, contains("Rebuild example for smoke"));
      expect(
        workflow,
        contains(
          "dart run tool/updater_smoke.dart "
          "--diagnostics-log build/desktop-updater-helper-debug.jsonl",
        ),
      );
      expect(workflow, contains("macos-update-smoke-debug-diagnostics"));
      expect(workflow, contains("flutter build macos --release"));
      expect(workflow, contains("Run release publish smoke"));
      expect(
        workflow,
        contains("dart run tool/release_publish_smoke.dart --platform macos"),
      );
      expect(
        workflow,
        contains(
          "dart run tool/updater_smoke.dart --config Release "
          "--diagnostics-log build/desktop-updater-helper-release.jsonl",
        ),
      );
      expect(workflow, contains("macos-update-smoke-release-diagnostics"));
    },
  );
}
