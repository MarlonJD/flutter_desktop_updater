import "dart:io";

import "package:flutter_test/flutter_test.dart";

void main() {
  test("updater smoke supports Windows Release output", () {
    final source = File("example/tool/updater_smoke.dart").readAsStringSync();

    expect(source, contains("--config Debug|Release"));
    expect(source, contains('"windows"'));
    expect(source, contains('"runner"'));
    expect(source, contains("config,"));
    expect(source, contains('"desktop_updater_example.exe"'));
  });

  test(
      "Windows CI runs Release build, native tests, integration, publish, and smoke",
      () {
    final workflow =
        File(".github/workflows/desktop-updater-ci.yml").readAsStringSync();

    expect(workflow, contains("flutter build windows --release"));
    expect(
      workflow,
      contains(
        "cmake --build build/windows/x64 --config Release "
        "--target desktop_updater_test",
      ),
    );
    expect(
      workflow,
      contains("ctest --test-dir build/windows/x64 -C Release"),
    );
    expect(
      workflow,
      contains("dart run tool/updater_smoke.dart --config Release"),
    );
    expect(workflow, contains("Run release publish smoke"));
    expect(
      workflow,
      contains("dart run tool/release_publish_smoke.dart --platform windows"),
    );
    expect(
      workflow,
      isNot(
        contains(
          "Rebuild example release for smoke\n"
          "        working-directory: example\n"
          "        run: flutter build windows --release",
        ),
      ),
    );
  });
}
