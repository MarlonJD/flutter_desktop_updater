import "dart:convert";
import "dart:io";

import "package:desktop_updater/src/core/update_client.dart";
import "package:desktop_updater/src/version_info.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;

import "fixtures/update_server.dart";

void main() {
  test("rejects index item that points to an older descriptor", () async {
    final fixture = await _UpdateFixture.create(
      indexVersion: "99.0.0",
      indexBuildNumber: 9900,
      descriptorVersion: "1.0.0",
      descriptorBuildNumber: 100,
    );
    try {
      final client = UpdateClient(
        appArchiveUrl: fixture.archiveUrl,
        currentVersion: DesktopVersionInfo.fromParts(
          versionName: "2.0.0",
          buildNumber: "200",
        ),
        platform: "macos",
      );

      await expectLater(
        client.checkForUpdate(),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            "message",
            contains("release.json version does not match app-archive.json"),
          ),
        ),
      );
    } finally {
      await fixture.delete();
    }
  });

  test("accepts index item when descriptor identity matches", () async {
    final fixture = await _UpdateFixture.create(
      indexVersion: "2.1.0",
      indexBuildNumber: 210,
      descriptorVersion: "2.1.0",
      descriptorBuildNumber: 210,
    );
    try {
      final client = UpdateClient(
        appArchiveUrl: fixture.archiveUrl,
        currentVersion: DesktopVersionInfo.fromParts(
          versionName: "2.0.0",
          buildNumber: "200",
        ),
        platform: "macos",
      );

      final result = await client.checkForUpdate();

      expect(result, isNotNull);
      expect(result!.item.version, "2.1.0");
      expect(result.item.version, result.descriptor.version);
      expect(result.item.buildNumber, 210);
      expect(result.descriptor.version, "2.1.0");
      expect(result.descriptor.buildNumber, 210);
      expect(result.item.buildNumber, result.descriptor.buildNumber);
    } finally {
      await fixture.delete();
    }
  });
}

class _UpdateFixture {
  const _UpdateFixture({
    required this.root,
    required this.server,
    required this.archiveUrl,
  });

  final Directory root;
  final UpdateServer server;
  final Uri archiveUrl;

  static Future<_UpdateFixture> create({
    required String indexVersion,
    required int indexBuildNumber,
    required String descriptorVersion,
    required int descriptorBuildNumber,
  }) async {
    final root = await Directory.systemTemp.createTemp(
      "update_client_security_",
    );
    final server = await UpdateServer.bind(root);
    final releaseUrl = server.uri.resolve("release.json");
    final artifactUrl = server.uri.resolve("artifact.zip");
    final artifactFile = File(path.join(root.path, "artifact.zip"));
    await artifactFile.writeAsString("artifact bytes");
    final artifactLength = await artifactFile.length();
    const artifactSha256 =
        "4659fc0570122b0e0aa14f4ff7c261b1fe51795a01ba79963f462ebf40d7520d";

    await File(path.join(root.path, "app-archive.json")).writeAsString(
      "${const JsonEncoder.withIndent("  ").convert({
            "schemaVersion": 3,
            "appName": "Example",
            "items": [
              {
                "version": indexVersion,
                "buildNumber": indexBuildNumber,
                "platform": "macos",
                "channel": "stable",
                "mandatory": true,
                "release": releaseUrl.toString(),
              },
            ],
          })}\n",
    );
    await File(path.join(root.path, "release.json")).writeAsString(
      "${const JsonEncoder.withIndent("  ").convert({
            "schemaVersion": 3,
            "packageId": "com.example.app",
            "appName": "Example",
            "version": descriptorVersion,
            "buildNumber": descriptorBuildNumber,
            "platform": "macos",
            "channel": "stable",
            "artifact": {
              "kind": "zip",
              "url": artifactUrl.toString(),
              "sha256": artifactSha256,
              "length": artifactLength,
            },
            "install": {"strategy": "wholeBundleReplace"},
            "minimumUpdaterVersion": "2.0.0",
            "generatedAt": DateTime.utc(2026, 6, 12).toIso8601String(),
          })}\n",
    );

    return _UpdateFixture(
      root: root,
      server: server,
      archiveUrl: server.uri.resolve("app-archive.json"),
    );
  }

  Future<void> delete() async {
    await server.close();
    await root.delete(recursive: true);
  }
}
