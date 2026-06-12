import "dart:io";

import "package:desktop_updater/src/release_cli/publish_manifest.dart";
import "package:desktop_updater/src/release_cli/release_publish_config.dart";
import "package:desktop_updater/src/release_cli/upload/ftp_upload_provider.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  test("ftp config requires allowInsecure true", () async {
    await expectLater(
      ReleasePublishConfig.fromYaml("""
updates:
  baseUrl: https://updates.example.com
ftp:
  host: ftp.example.com
  remotePath: /public_html/updates
  username: deploy
"""),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          "message",
          contains("ftp.allowInsecure: true is required"),
        ),
      ),
    );
  });

  test("ftp uploader uploads app archive last", () async {
    final recorder = RecordingFtpRemoteFileClient();
    final provider = FtpUploadProvider(client: recorder);

    await provider.upload(
      localRoot: Directory("/tmp/dist"),
      manifest: testPublishManifest(),
      config: const FtpUploadConfig(
        host: "localhost",
        remotePath: "/updates",
        username: "deploy",
        allowInsecure: true,
      ),
      output: StringBuffer(),
    );

    expect(recorder.writes.last.remotePath, "/updates/app-archive.json");
  });
}

class RecordingFtpRemoteFileClient implements FtpRemoteFileClient {
  final writes = <FtpRemoteWrite>[];

  @override
  Future<void> writeFile({
    required File file,
    required String remotePath,
    required FtpUploadConfig config,
  }) async {
    writes.add(FtpRemoteWrite(file: file, remotePath: remotePath));
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
