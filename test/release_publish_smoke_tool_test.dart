import "dart:io";

import "package:flutter_test/flutter_test.dart";

void main() {
  test("release publish smoke drives the user-facing publish command", () {
    final source =
        File("example/tool/release_publish_smoke.dart").readAsStringSync();

    expect(source, contains("desktop_updater:release"));
    expect(source, contains("publish"));
    expect(source, contains("--platform"));
    expect(source, contains("customCommand"));
    expect(source, contains("Hosted artifact SHA-256: OK"));
  });

  test("release publish smoke supports real notarized macOS publish", () {
    final source =
        File("example/tool/release_publish_smoke.dart").readAsStringSync();

    expect(source, contains("--notarize"));
    expect(source, contains("DESKTOP_UPDATER_RUN_NOTARIZED_PUBLISH_E2E"));
    expect(
      source,
      contains("DESKTOP_UPDATER_MACOS_DEVELOPER_ID_APPLICATION"),
    );
    expect(source, contains("DESKTOP_UPDATER_MACOS_NOTARY_PROFILE"));
    expect(source, contains("DESKTOP_UPDATER_MACOS_KEYCHAIN"));
  });
}
