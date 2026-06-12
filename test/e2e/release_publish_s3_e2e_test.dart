import "dart:io";

import "package:flutter_test/flutter_test.dart";

import "release_publish_e2e_helpers.dart";

void main() {
  test("s3 release publish e2e", () async {
    if (!releasePublishE2eEnabled) {
      markTestSkipped(
        "Set DESKTOP_UPDATER_RUN_RELEASE_PUBLISH_E2E=1 to run release publish provider e2e tests.",
      );
      return;
    }
    if (!await executableExists("aws")) {
      markTestSkipped("AWS CLI is required for the S3-compatible e2e.");
      return;
    }
    if (!await dockerDaemonAvailable()) {
      markTestSkipped("Docker daemon is not available for the S3 e2e.");
      return;
    }
    final accessKey = Platform.environment["AWS_ACCESS_KEY_ID"] ??
        Platform.environment["DESKTOP_UPDATER_E2E_S3_ACCESS_KEY"];
    final secretKey = Platform.environment["AWS_SECRET_ACCESS_KEY"] ??
        Platform.environment["DESKTOP_UPDATER_E2E_S3_SECRET_KEY"];
    if (accessKey == null ||
        accessKey.isEmpty ||
        secretKey == null ||
        secretKey.isEmpty) {
      markTestSkipped(
        "Set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY for local MinIO.",
      );
      return;
    }

    await startDockerComposeServices(["minio"]);
    await waitForPort(9000);
    await configureMinioBucket(
      bucket: "updates",
      endpoint: "http://127.0.0.1:9000",
      accessKey: accessKey,
      secretKey: secretKey,
    );

    final fixture = await createReleasePublishE2eFixture(
      baseUrl: Uri.parse("http://127.0.0.1:9000/updates/desktop/"),
      providerConfig: """
s3:
  bucket: updates
  prefix: desktop
  region: us-east-1
  endpoint: http://127.0.0.1:9000
  pathStyle: true
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
