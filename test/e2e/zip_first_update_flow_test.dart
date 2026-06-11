import "dart:io";

import "package:desktop_updater/src/core/update_client.dart";
import "package:desktop_updater/src/version_info.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;

import "../fixtures/release_fixture_builder.dart";
import "../fixtures/update_server.dart";

void main() {
  test("checks, downloads, verifies, and stages a zip-first update", () async {
    final tempDir = await Directory.systemTemp.createTemp("zip_first_e2e_");
    UpdateServer? server;
    try {
      server = await UpdateServer.bind(tempDir);
      await buildReleaseFixture(root: tempDir, baseUri: server.uri);

      final client = UpdateClient(
        appArchiveUrl: server.uri.resolve("app-archive.json"),
        currentVersion: DesktopVersionInfo.fromParts(
          versionName: "1.0.0",
          buildNumber: "100",
        ),
        platform: "linux",
      );

      final check = await client.checkForUpdate();
      expect(check, isNotNull);

      final progress = <int>[];
      final staged = await client.downloadVerifyAndStage(
        descriptor: check!.descriptor,
        onProgress: (receivedBytes, _) => progress.add(receivedBytes),
      );

      expect(progress, isNotEmpty);
      expect(File(path.join(staged.stagingPath, "app.txt")).readAsStringSync(),
          "version=2.0.0");
    } finally {
      await server?.close();
      await tempDir.delete(recursive: true);
    }
  });

  test("checksum mismatch fails before extraction", () async {
    final tempDir = await Directory.systemTemp.createTemp("zip_first_e2e_");
    UpdateServer? server;
    try {
      server = await UpdateServer.bind(tempDir);
      await buildReleaseFixture(
        root: tempDir,
        baseUri: server.uri,
        badChecksum: true,
      );

      final client = UpdateClient(
        appArchiveUrl: server.uri.resolve("app-archive.json"),
        currentVersion: DesktopVersionInfo.fromParts(
          versionName: "1.0.0",
          buildNumber: "100",
        ),
        platform: "linux",
      );
      final check = await client.checkForUpdate();

      await expectLater(
        client.downloadVerifyAndStage(descriptor: check!.descriptor),
        throwsA(isA<FileSystemException>()),
      );
    } finally {
      await server?.close();
      await tempDir.delete(recursive: true);
    }
  });

  test("path traversal inside zip is rejected", () async {
    final tempDir = await Directory.systemTemp.createTemp("zip_first_e2e_");
    UpdateServer? server;
    try {
      server = await UpdateServer.bind(tempDir);
      await buildReleaseFixture(
        root: tempDir,
        baseUri: server.uri,
        traversalZip: true,
      );

      final client = UpdateClient(
        appArchiveUrl: server.uri.resolve("app-archive.json"),
        currentVersion: DesktopVersionInfo.fromParts(
          versionName: "1.0.0",
          buildNumber: "100",
        ),
        platform: "linux",
      );
      final check = await client.checkForUpdate();

      await expectLater(
        client.downloadVerifyAndStage(descriptor: check!.descriptor),
        throwsFormatException,
      );
    } finally {
      await server?.close();
      await tempDir.delete(recursive: true);
    }
  });
}
