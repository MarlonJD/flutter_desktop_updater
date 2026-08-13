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
    expect(workflow, contains("DESKTOP_UPDATER_RELEASE_PUBLISH_EVIDENCE_ROOT"));
    expect(workflow, contains("macos_release_publish_evidence.dart"));
    expect(
      workflow,
      contains("Install repository dependencies for release trust fixture"),
    );
    expect(workflow, contains("git rev-parse HEAD"));
    expect(workflow, contains("actions/upload-artifact@v4"));
  });

  test("credentialed smoke keeps signing references in the environment", () {
    final source =
        File("example/tool/release_publish_smoke.dart").readAsStringSync();
    final start = source.indexOf("String _macOSNotarizationConfig()");
    final end = source.indexOf("String _copyCommand", start);
    final configBuilder = source.substring(start, end);

    expect(configBuilder, contains("notarize: true"));
    expect(configBuilder, isNot(contains("developerIdApplication:")));
    expect(configBuilder, isNot(contains("notaryProfile:")));
    expect(configBuilder, isNot(contains("keychain:")));
    expect(source, contains("DESKTOP_UPDATER_MACOS_DEVELOPER_ID_APPLICATION"));
    expect(source, contains("DESKTOP_UPDATER_MACOS_NOTARY_PROFILE"));
    expect(source, contains("DESKTOP_UPDATER_MACOS_KEYCHAIN"));
    expect(source, contains("_downloadBytes"));
    expect(source, contains("publish-smoke.json"));
  });
}
