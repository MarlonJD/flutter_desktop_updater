import "dart:io";

import "package:desktop_updater/src/release_cli/publish_manifest.dart";
import "package:desktop_updater/src/release_cli/release_publish_config.dart";
import "package:desktop_updater/src/release_cli/upload/manual_upload_provider.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  test("manual provider prints folder, validate command, and docs", () async {
    final output = StringBuffer();

    await const ManualUploadProvider().upload(
      localRoot: Directory("/tmp/dist/desktop_updater"),
      manifest: testPublishManifest(),
      config: const ManualUploadConfig(),
      output: output,
    );

    expect(output.toString(), contains("Manual publish package is ready."));
    expect(output.toString(), contains("file:///tmp/dist/desktop_updater/"));
    expect(output.toString(), contains("Expected remote root:"));
    expect(output.toString(), contains("release validate --manifest"));
    expect(output.toString(), contains("docs/publishing.md"));
  });
}

PublishManifest testPublishManifest() {
  return PublishManifest(
    schemaVersion: 1,
    baseUrl: Uri.parse("https://updates.example.com/"),
    localRoot: "/tmp/dist/desktop_updater",
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
}
