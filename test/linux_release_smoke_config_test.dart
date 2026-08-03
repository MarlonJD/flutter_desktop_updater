import "dart:io";

import "package:flutter_test/flutter_test.dart";

void main() {
  test("updater smoke supports Linux Release output", () {
    final source = File("example/tool/updater_smoke.dart").readAsStringSync();
    final appSource = File("example/lib/app.dart").readAsStringSync();

    expect(source, contains("--config Debug|Release"));
    expect(source, contains('"linux"'));
    expect(source, contains('"x64"'));
    expect(source, contains("config.toLowerCase()"));
    expect(source, contains('"bundle"'));
    expect(source, contains('"desktop_updater_example"'));
    expect(source, contains("DESKTOP_UPDATER_SMOKE_DIAGNOSTICS_LOG"));
    expect(source, contains("DESKTOP_UPDATER_SMOKE_PACKAGE_ID"));
    expect(source, contains("DESKTOP_UPDATER_SMOKE_INSTALL_ROOT"));
    expect(
      source,
      contains("DESKTOP_UPDATER_SMOKE_EXECUTABLE_RELATIVE_PATH"),
    );
    expect(appSource, contains("DESKTOP_UPDATER_SMOKE_PACKAGE_ID"));
    expect(appSource, contains("DESKTOP_UPDATER_SMOKE_INSTALL_ROOT"));
    expect(
      appSource,
      contains("DESKTOP_UPDATER_SMOKE_EXECUTABLE_RELATIVE_PATH"),
    );
    expect(appSource, contains(r"packageId=$packageId"));
    expect(appSource, contains(r"installRoot=$installRoot"));
    expect(
      appSource,
      contains(r"executableRelativePath=$executableRelativePath"),
    );
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
      contains(
        "--diagnostics-log "
        "../reports/linux-update-smoke-release-diagnostics.jsonl",
      ),
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
