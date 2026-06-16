import "dart:io";

import "package:flutter_test/flutter_test.dart";

void main() {
  test("updater smoke supports Linux Release output", () {
    final source = File("example/tool/updater_smoke.dart").readAsStringSync();

    expect(source, contains("--config Debug|Release"));
    expect(source, contains('"linux"'));
    expect(source, contains('"x64"'));
    expect(source, contains("config.toLowerCase()"));
    expect(source, contains('"bundle"'));
    expect(source, contains('"desktop_updater_example"'));
    expect(source, contains("DESKTOP_UPDATER_SMOKE_DIAGNOSTICS_LOG"));
    expect(source, contains(r'"event":"$event"'));
    expect(source, contains("--diagnostics-log <path>"));
  });

  test(
      "Linux CI runs Release build, native tests, integration, publish, and smoke",
      () {
    final workflow =
        File(".github/workflows/desktop-updater-ci.yml").readAsStringSync();

    expect(workflow, contains("flutter build linux --release"));
    expect(
      workflow,
      contains(
        "cmake --build build/linux/x64/release --target desktop_updater_test",
      ),
    );
    expect(workflow, contains("ctest --test-dir build/linux/x64/release"));
    expect(
      workflow,
      contains("xvfb-run -a dart run tool/updater_smoke.dart --config Release"),
    );
    expect(
      workflow,
      contains("--diagnostics-log build/desktop-updater-helper-release.jsonl"),
    );
    expect(workflow, contains("actions/upload-artifact@v4"));
    expect(
      workflow,
      contains("DESKTOP_UPDATER_UPLOAD_SMOKE_DIAGNOSTICS"),
    );
    expect(workflow, contains("linux-update-smoke-release-diagnostics"));
    expect(workflow, contains("Run release publish smoke"));
    expect(
      workflow,
      contains("dart run tool/release_publish_smoke.dart --platform linux"),
    );
    expect(
      workflow,
      isNot(
        contains(
          "Rebuild example release for smoke\n"
          "        working-directory: example\n"
          "        run: flutter build linux --release",
        ),
      ),
    );
  });
}
