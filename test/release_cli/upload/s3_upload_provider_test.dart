import "dart:io";

import "package:desktop_updater/src/release_cli/publish_manifest.dart";
import "package:desktop_updater/src/release_cli/release_publish_config.dart";
import "package:desktop_updater/src/release_cli/upload/s3_upload_provider.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  test("s3 uploader uploads app archive last", () async {
    final recorder = RecordingObjectStorageClient();
    final provider = S3UploadProvider(client: recorder);

    await provider.upload(
      localRoot: Directory("/tmp/dist"),
      manifest: testPublishManifest(),
      config: const S3UploadConfig(
        bucket: "updates",
        prefix: "desktop",
        region: "local",
      ),
      output: StringBuffer(),
    );

    expect(recorder.putKeys.last, "desktop/app-archive.json");
    expect(
      recorder.putKeys,
      contains("desktop/releases/2.0.1/macos/release.json"),
    );
  });
}

class RecordingObjectStorageClient implements ObjectStorageClient {
  final putKeys = <String>[];

  @override
  Future<void> putFile({
    required File file,
    required String bucket,
    required String key,
    required S3UploadConfig config,
  }) async {
    putKeys.add(key);
  }
}

PublishManifest testPublishManifest() {
  return PublishManifest(
    schemaVersion: 1,
    baseUrl: Uri.parse("https://updates.example.com/"),
    localRoot: "/tmp/dist",
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
