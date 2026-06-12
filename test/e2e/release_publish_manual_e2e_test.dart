import "package:flutter_test/flutter_test.dart";

import "release_publish_e2e_helpers.dart";

void main() {
  test("manual publish package validates after local upload", () async {
    final fixture = await createReleasePublishE2eFixture();
    try {
      final publishOutput = await publishFixture(fixture);
      expect(
        publishOutput.toString(),
        contains("Manual publish package is ready."),
      );

      await copyDirectory(fixture.distRoot, fixture.webRoot);
      final validateOutput = await validateFixture(fixture);

      expect(validateOutput.toString(), contains("Hosted app archive: OK"));
      expect(validateOutput.toString(), contains("Update selection: OK"));
      expect(
          validateOutput.toString(), contains("Hosted artifact SHA-256: OK"));
    } finally {
      await fixture.delete();
    }
  });
}
