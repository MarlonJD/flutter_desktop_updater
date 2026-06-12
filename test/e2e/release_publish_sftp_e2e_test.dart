import "dart:io";

import "package:flutter_test/flutter_test.dart";

import "release_publish_e2e_helpers.dart";

void main() {
  test("sftp release publish e2e", () async {
    if (!releasePublishE2eEnabled) {
      markTestSkipped(
        "Set DESKTOP_UPDATER_RUN_RELEASE_PUBLISH_E2E=1 to run release publish provider e2e tests.",
      );
      return;
    }
    if (Platform.environment["DESKTOP_UPDATER_SFTP_PASSWORD"] == null) {
      markTestSkipped(
        "Set DESKTOP_UPDATER_SFTP_PASSWORD=desktop-updater-test for the local SFTP e2e.",
      );
      return;
    }
    if (!await dockerDaemonAvailable()) {
      markTestSkipped("Docker daemon is not available for the SFTP e2e.");
      return;
    }

    await startDockerComposeServices(["sftp", "static"]);
    await chownSftpUploadVolume();
    await waitForPort(2222);
    await waitForTcpPrefix(2222, "SSH-");
    await waitForPort(8088);
    final fixture = await createReleasePublishE2eFixture(
      baseUrl: Uri.parse("http://127.0.0.1:8088/sftp/updates/"),
      providerConfig: """
sftp:
  host: 127.0.0.1
  port: 2222
  remotePath: /upload/updates
  username: deploy
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
