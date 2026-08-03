import "dart:io";

import "package:desktop_updater/src/release_cli/publish_manifest.dart";
import "package:desktop_updater/src/release_cli/release_publish_config.dart";
import "package:desktop_updater/src/release_cli/upload/s3_upload_provider.dart";
import "package:desktop_updater/src/release_cli/upload/upload_provider.dart";
import "package:desktop_updater/src/release_manifest.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;

void main() {
  test("s3 uploader rejects app archive publish without conditional write",
      () async {
    final recorder = RecordingObjectStorageClient();
    final provider = S3UploadProvider(client: recorder);

    await expectLater(
      provider.upload(
        localRoot: Directory("/tmp/dist"),
        manifest: testPublishManifest(),
        config: const S3UploadConfig(
          bucket: "updates",
          prefix: "desktop",
          region: "local",
        ),
        output: StringBuffer(),
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          "message",
          contains("conditional index write"),
        ),
      ),
    );

    expect(recorder.putKeys, isNot(contains("desktop/app-archive.json")));
    expect(
      recorder.putKeys,
      contains("desktop/releases/2.0.1/macos/release.json"),
    );
  });

  test("s3 uploader publishes app archive with conditional receipt", () async {
    final tempDir = await Directory.systemTemp.createTemp("s3_upload_");
    try {
      final manifest = testPublishManifest(localRoot: tempDir.path);
      await _writePayload(tempDir, manifest);
      final recorder = ConditionalRecordingObjectStorageClient();
      final provider = S3UploadProvider(client: recorder);
      const expectedRevision = RemoteIndexRevision.present(
        sha256:
            "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        etag: '"old"',
      );

      final receipt = await provider.uploadAppArchive(
        localRoot: tempDir,
        manifest: manifest,
        config: const S3UploadConfig(
          bucket: "updates",
          prefix: "desktop",
          region: "local",
        ),
        output: StringBuffer(),
        expectedRevision: expectedRevision,
      );

      expect(recorder.indexKey, "desktop/app-archive.json");
      expect(recorder.expectedRevision, expectedRevision);
      expect(receipt.observedPriorRevision, expectedRevision);
      expect(
        receipt.publishedSha256,
        await sha256File(File(path.join(tempDir.path, "app-archive.json"))),
      );
    } finally {
      await tempDir.delete(recursive: true);
    }
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

class ConditionalRecordingObjectStorageClient
    implements ConditionalObjectStorageClient {
  String? indexKey;
  RemoteIndexRevision? expectedRevision;

  @override
  Future<void> putFile({
    required File file,
    required String bucket,
    required String key,
    required S3UploadConfig config,
  }) async {}

  @override
  Future<IndexPublishReceipt> putIndexFileConditionally({
    required File file,
    required String bucket,
    required String key,
    required S3UploadConfig config,
    required RemoteIndexRevision expectedRevision,
  }) async {
    indexKey = key;
    this.expectedRevision = expectedRevision;
    return IndexPublishReceipt(
      observedPriorRevision: expectedRevision,
      publishedSha256: await sha256File(file),
      mechanism: IndexPublishMechanism.conditionalWrite,
      leaseEvidenceSha256: null,
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
