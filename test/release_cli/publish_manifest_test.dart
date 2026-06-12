import "dart:io";

import "package:desktop_updater/src/release_cli/publish_manifest.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;

void main() {
  test("writes publish manifest used by validate", () async {
    final tempDir = await Directory.systemTemp.createTemp("publish_manifest_");
    try {
      final manifest = PublishManifest(
        schemaVersion: 1,
        baseUrl: Uri.parse("https://updates.example.com/"),
        localRoot: tempDir.path,
        appArchive: PublishManifestFile(
          path: "app-archive.json",
          url: Uri.parse("https://updates.example.com/app-archive.json"),
        ),
        release: PublishManifestRelease(
          version: "2.0.1",
          buildNumber: 201,
          platform: "macos",
          channel: "stable",
          path: "releases/2.0.1/macos/release.json",
          url: Uri.parse(
            "https://updates.example.com/releases/2.0.1/macos/release.json",
          ),
        ),
        artifact: PublishManifestArtifact(
          path: "releases/2.0.1/macos/Example-2.0.1-macos.zip",
          url: Uri.parse(
            "https://updates.example.com/releases/2.0.1/macos/Example-2.0.1-macos.zip",
          ),
          sha256:
              "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          length: 12,
        ),
      );

      final file =
          File(path.join(tempDir.path, ".desktop_updater_publish.json"));
      await manifest.writeTo(file);
      final parsed = await PublishManifest.readFrom(file);

      expect(parsed.release.version, "2.0.1");
      expect(parsed.artifact.length, 12);
      expect(await file.readAsString(), endsWith("\n"));
    } finally {
      await tempDir.delete(recursive: true);
    }
  });
}
