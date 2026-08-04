import "dart:io";

import "package:desktop_updater/src/release_cli/publish_manifest.dart";
import "package:desktop_updater/src/release_cli/release_publish_config.dart";
import "package:desktop_updater/src/release_cli/upload/sftp_upload_provider.dart";
import "package:desktop_updater/src/release_cli/upload/upload_provider.dart";
import "package:desktop_updater/src/release_manifest.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;

void main() {
  test("sftp uploader rejects app archive publish without lease", () async {
    final recorder = RecordingRemoteFileClient();
    final provider = SftpUploadProvider(client: recorder);

    await expectLater(
      provider.upload(
        localRoot: Directory("/tmp/dist"),
        manifest: testPublishManifest(),
        config: const SftpUploadConfig(
          host: "localhost",
          port: 2222,
          remotePath: "/updates",
          username: "deploy",
        ),
        output: StringBuffer(),
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          "message",
          contains("tested exclusive publication lease"),
        ),
      ),
    );

    expect(
      recorder.writes.map((write) => write.remotePath),
      isNot(contains("/updates/app-archive.json")),
    );
  });

  test("sftp uploader publishes app archive with exclusive lease receipt",
      () async {
    final tempDir = await Directory.systemTemp.createTemp("sftp_upload_");
    try {
      final manifest = testPublishManifest(localRoot: tempDir.path);
      await _writePayload(tempDir, manifest);
      final recorder = LeaseRecordingRemoteFileClient();
      final provider = SftpUploadProvider(client: recorder);
      const expectedRevision = RemoteIndexRevision.present(
        sha256:
            "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        etag: '"old"',
      );

      final receipt = await provider.uploadAppArchive(
        localRoot: tempDir,
        manifest: manifest,
        config: const SftpUploadConfig(
          host: "localhost",
          port: 2222,
          remotePath: "/updates",
          username: "deploy",
        ),
        output: StringBuffer(),
        expectedRevision: expectedRevision,
      );

      expect(recorder.indexRemotePath, "/updates/app-archive.json");
      expect(recorder.expectedRevision, expectedRevision);
      expect(receipt.observedPriorRevision, expectedRevision);
      expect(receipt.mechanism, IndexPublishMechanism.exclusiveLease);
    } finally {
      await tempDir.delete(recursive: true);
    }
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
      sftpCurlConfigAllowsUnknownHost(
        const SftpUploadConfig(
          host: "127.0.0.1",
          remotePath: "/updates",
          username: "deploy",
        ),
      ),
      isTrue,
    );
    expect(
      sftpCurlConfigAllowsUnknownHost(
        const SftpUploadConfig(
          host: "deploy.example.com",
          remotePath: "/updates",
          username: "deploy",
        ),
      ),
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

class LeaseRecordingRemoteFileClient
    implements ExclusiveLeaseSftpRemoteFileClient {
  String? indexRemotePath;
  RemoteIndexRevision? expectedRevision;

  @override
  Future<void> writeFile({
    required File file,
    required String remotePath,
    required SftpUploadConfig config,
  }) async {}

  @override
  Future<IndexPublishReceipt> writeIndexFileWithLease({
    required File file,
    required String remotePath,
    required SftpUploadConfig config,
    required RemoteIndexRevision expectedRevision,
  }) async {
    indexRemotePath = remotePath;
    this.expectedRevision = expectedRevision;
    return IndexPublishReceipt(
      observedPriorRevision: expectedRevision,
      publishedSha256: await sha256File(file),
      mechanism: IndexPublishMechanism.exclusiveLease,
      leaseEvidenceSha256:
          "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
    );
  }
}

Future<void> _writePayload(
  Directory localRoot,
  PublishManifest manifest,
) async {
  for (final relativePath in [
    ".desktop_updater_publish.json",
    manifest.appArchive.path,
    manifest.release.path,
    manifest.artifact.path,
  ]) {
    final file = File(path.join(localRoot.path, relativePath));
    await file.parent.create(recursive: true);
    await file.writeAsString(relativePath);
  }
}

PublishManifest testPublishManifest({String localRoot = "/tmp/dist"}) {
  return PublishManifest(
    schemaVersion: 1,
    baseUrl: Uri.parse("https://updates.example.com/"),
    localRoot: localRoot,
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
