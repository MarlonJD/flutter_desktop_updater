import "dart:io";

import "package:flutter_test/flutter_test.dart";

void main() {
  test("workflow has an opt-in notarized macOS publish smoke", () {
    final workflow =
        File(".github/workflows/desktop-updater-ci.yml").readAsStringSync();

    expect(workflow, contains("macos-notarized"));
    expect(workflow, contains("DESKTOP_UPDATER_RUN_NOTARIZED_PUBLISH_E2E"));
    expect(
      workflow,
      contains(
        "dart run tool/release_publish_smoke.dart --platform macos --notarize",
      ),
    );
  });
}
