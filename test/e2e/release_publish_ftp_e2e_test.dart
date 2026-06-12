import "dart:io";

import "package:flutter_test/flutter_test.dart";

import "release_publish_e2e_helpers.dart";

void main() {
  test("ftp release publish e2e", () async {
    if (!releasePublishE2eEnabled) {
      markTestSkipped(
        "Set DESKTOP_UPDATER_RUN_RELEASE_PUBLISH_E2E=1 to run release publish provider e2e tests.",
      );
      return;
    }
    if (Platform.environment["DESKTOP_UPDATER_FTP_PASSWORD"] == null) {
      markTestSkipped(
        "Set DESKTOP_UPDATER_FTP_PASSWORD=desktop-updater-test for the local FTP e2e.",
      );
      return;
    }
    if (!await dockerDaemonAvailable()) {
      markTestSkipped("Docker daemon is not available for the FTP e2e.");
      return;
    }

    await startDockerComposeServices(["ftp", "static"]);
    await waitForPort(2121);
    await waitForPort(8088);
    final fixture = await createReleasePublishE2eFixture(
      baseUrl: Uri.parse("http://127.0.0.1:8088/ftp/updates/"),
      providerConfig: """
ftp:
  host: 127.0.0.1
  port: 2121
  remotePath: /updates
  username: deploy
  allowInsecure: true
""",
    );
    try {
      final output = await publishFixture(fixture);
      expect(output.toString(), contains("OK: Published and validated."));
    } finally {
      await fixture.delete();
    }
  });
}
