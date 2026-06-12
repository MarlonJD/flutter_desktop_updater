import "dart:convert";
import "dart:io";

import "package:desktop_updater/src/release_cli/publish_manifest.dart";
import "package:desktop_updater/src/release_cli/release_command.dart";
import "package:desktop_updater/src/release_manifest.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;

import "../fixtures/update_server.dart";

void main() {
  test("validate simulates an older version and verifies hosted artifact",
      () async {
    final fixture = await createHostedPublishFixture(
      targetVersion: "2.0.1",
      targetBuildNumber: 201,
    );
    try {
      final output = StringBuffer();

      final exitCode = await runReleaseCommand(
        [
          "validate",
          "--manifest",
          fixture.manifestFile.path,
          "--from-version",
          "2.0.0+200",
        ],
        projectRoot: fixture.projectRoot,
        output: output,
      );

      expect(exitCode, 0);
      expect(output.toString(), contains("Hosted app archive: OK"));
      expect(output.toString(), contains("Update selection: OK"));
      expect(output.toString(), contains("Hosted release descriptor: OK"));
      expect(output.toString(), contains("Hosted artifact SHA-256: OK"));
    } finally {
      await fixture.delete();
    }
  });
}

class HostedPublishFixture {
  const HostedPublishFixture({
    required this.projectRoot,
    required this.manifestFile,
    required this.server,
  });

  final Directory projectRoot;
  final File manifestFile;
  final UpdateServer server;

  Future<void> delete() async {
    await server.close();
    await projectRoot.delete(recursive: true);
  }
}

Future<HostedPublishFixture> createHostedPublishFixture({
  required String targetVersion,
  required int targetBuildNumber,
}) async {
  final projectRoot = await Directory.systemTemp.createTemp("hosted_publish_");
  final webRoot = Directory(path.join(projectRoot.path, "web"));
  await webRoot.create();
  final server = await UpdateServer.bind(webRoot);

  final releaseRelativePath = path.posix.join(
    "releases",
    targetVersion,
    "macos",
    "release.json",
  );
  final artifactRelativePath = path.posix.join(
    "releases",
    targetVersion,
    "macos",
    "Example-$targetVersion-macos.zip",
  );
  final releaseUrl = server.uri.resolve(releaseRelativePath);
  final artifactUrl = server.uri.resolve(artifactRelativePath);
  final artifactFile = File(path.join(webRoot.path, artifactRelativePath));
  await artifactFile.parent.create(recursive: true);
  await artifactFile.writeAsString("artifact bytes");
  final artifactSha256 = await sha256File(artifactFile);
  final artifactLength = await artifactFile.length();

  await File(path.join(webRoot.path, "app-archive.json")).writeAsString(
    "${const JsonEncoder.withIndent("  ").convert({
          "schemaVersion": 3,
          "appName": "Example",
          "items": [
            {
              "version": targetVersion,
              "buildNumber": targetBuildNumber,
              "platform": "macos",
              "channel": "stable",
              "mandatory": false,
              "release": releaseUrl.toString(),
            },
          ],
        })}\n",
  );
  await File(path.join(webRoot.path, releaseRelativePath)).writeAsString(
    "${const JsonEncoder.withIndent("  ").convert({
          "schemaVersion": 3,
          "packageId": "com.example.app",
          "appName": "Example",
          "version": targetVersion,
          "buildNumber": targetBuildNumber,
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

  final manifest = PublishManifest(
    schemaVersion: 1,
    baseUrl: server.uri,
    localRoot: webRoot.path,
    appArchive: PublishManifestFile(
      path: "app-archive.json",
      url: server.uri.resolve("app-archive.json"),
    ),
    release: PublishManifestRelease(
      version: targetVersion,
      buildNumber: targetBuildNumber,
      platform: "macos",
      channel: "stable",
      path: releaseRelativePath,
      url: releaseUrl,
    ),
    artifact: PublishManifestArtifact(
      path: artifactRelativePath,
      url: artifactUrl,
      sha256: artifactSha256,
      length: artifactLength,
    ),
  );
  final manifestFile = File(
    path.join(projectRoot.path, ".desktop_updater_publish.json"),
  );
  await manifest.writeTo(manifestFile);

  return HostedPublishFixture(
    projectRoot: projectRoot,
    manifestFile: manifestFile,
    server: server,
  );
}
