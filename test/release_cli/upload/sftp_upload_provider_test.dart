import "dart:io";

import "package:desktop_updater/src/release_cli/publish_manifest.dart";
import "package:desktop_updater/src/release_cli/release_publish_config.dart";
import "package:desktop_updater/src/release_cli/upload/sftp_upload_provider.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  test("sftp uploader uploads versioned files before app archive", () async {
    final recorder = RecordingRemoteFileClient();
    final provider = SftpUploadProvider(client: recorder);

    await provider.upload(
      localRoot: Directory("/tmp/dist"),
      manifest: testPublishManifest(),
      config: const SftpUploadConfig(
        host: "localhost",
        port: 2222,
        remotePath: "/updates",
        username: "deploy",
      ),
      output: StringBuffer(),
    );

    expect(recorder.writes.last.remotePath, "/updates/app-archive.json");
  });

  test("sftp curl transport prefers Homebrew curl when available", () {
    expect(
      defaultSftpCurlExecutable(
        exists: (path) => path == "/opt/homebrew/opt/curl/bin/curl",
      ),
      "/opt/homebrew/opt/curl/bin/curl",
    );
  });

  test("sftp curl config allows unknown host keys only for loopback", () {
    expect(
      sftpCurlConfigAllowsUnknownHost(SftpUploadConfig(
        host: "127.0.0.1",
        remotePath: "/updates",
        username: "deploy",
      )),
      isTrue,
    );
    expect(
      sftpCurlConfigAllowsUnknownHost(SftpUploadConfig(
        host: "deploy.example.com",
        remotePath: "/updates",
        username: "deploy",
      )),
      isFalse,
    );
  });
}

class RecordingRemoteFileClient implements SftpRemoteFileClient {
  final writes = <SftpRemoteWrite>[];

  @override
  Future<void> writeFile({
    required File file,
    required String remotePath,
    required SftpUploadConfig config,
  }) async {
    writes.add(SftpRemoteWrite(file: file, remotePath: remotePath));
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
