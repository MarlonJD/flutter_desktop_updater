import "package:flutter_test/flutter_test.dart";

import "release_publish_e2e_helpers.dart";

void main() {
  test("custom command publish copies files and validates hosted update",
      () async {
    final fixture = await createReleasePublishE2eFixture(
      providerConfig: """
customCommand:
  command: dart test/e2e/fixtures/upload_commands/copy_updates.dart ${r"$DESKTOP_UPDATER_LOCAL_ROOT"} "{{WEB_ROOT}}"
""",
    );
    try {
      final output = await publishFixture(fixture);

      expect(output.toString(), contains("Uploading versioned files..."));
      expect(
          output.toString(), contains("Publishing app-archive.json last..."));
      expect(output.toString(), contains("OK: Published and validated."));
    } finally {
      await fixture.delete();
    }
  });
}
