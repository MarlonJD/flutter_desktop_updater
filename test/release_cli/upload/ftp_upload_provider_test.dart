import "dart:io";

import "package:crypto/crypto.dart";
import "package:desktop_updater/src/release_cli/publish_manifest.dart";
import "package:desktop_updater/src/release_cli/release_publish_config.dart";
import "package:desktop_updater/src/release_cli/upload/ftp_upload_provider.dart";
import "package:desktop_updater/src/release_cli/upload/upload_provider.dart";
import "package:desktop_updater/src/release_manifest.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;

void main() {
  test("default FTP client refuses to overwrite a changed index", () async {
    final tempDir = await Directory.systemTemp.createTemp("ftp_revision_");
    try {
      final index = File(path.join(tempDir.path, "app-archive.json"));
      await index.writeAsString("new index");
      final operations = RecordingFtpRemoteOperations()
        ..files["/updates/app-archive.json"] = "old index".codeUnits;
      final client = CurlFtpRemoteFileClient(operations: operations);

      await expectLater(
        client.writeIndexFileWithLease(
          file: index,
          remotePath: "/updates/app-archive.json",
          config: const FtpUploadConfig(
            host: "localhost",
            remotePath: "/updates",
            username: "deploy",
            allowInsecure: true,
          ),
          expectedRevision: const RemoteIndexRevision.present(
            sha256:
                "0000000000000000000000000000000000000000000000000000000000000000",
            etag: null,
          ),
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            "message",
            contains("changed before publish"),
          ),
        ),
      );

      expect(
        String.fromCharCodes(operations.files["/updates/app-archive.json"]!),
        "old index",
      );
      expect(operations.directories, isEmpty);
    } finally {
      await tempDir.delete(recursive: true);
    }
  });

  test("default FTP client fails closed when the lease is occupied", () async {
    final tempDir = await Directory.systemTemp.createTemp("ftp_lock_");
    try {
      final index = File(path.join(tempDir.path, "app-archive.json"));
      await index.writeAsString("new index");
      final operations = RecordingFtpRemoteOperations()
        ..directories.add("/updates/.app-archive.json.desktop_updater.lock");
      final client = CurlFtpRemoteFileClient(operations: operations);

      await expectLater(
        client.writeIndexFileWithLease(
          file: index,
          remotePath: "/updates/app-archive.json",
          config: const FtpUploadConfig(
            host: "localhost",
            remotePath: "/updates",
            username: "deploy",
            allowInsecure: true,
          ),
          expectedRevision: const RemoteIndexRevision.absent(),
        ),
        throwsA(isA<StateError>()),
      );

      expect(operations.files, isEmpty);
      expect(
        operations.directories,
        contains("/updates/.app-archive.json.desktop_updater.lock"),
      );
    } finally {
      await tempDir.delete(recursive: true);
    }
  });

  test("default FTP client publishes a missing index with an exclusive lease",
      () async {
    final tempDir = await Directory.systemTemp.createTemp("ftp_lease_");
    try {
      final index = File(path.join(tempDir.path, "app-archive.json"));
      await index.writeAsString("new index");
      final operations = RecordingFtpRemoteOperations();
      final client = CurlFtpRemoteFileClient(operations: operations);

      final receipt = await client.writeIndexFileWithLease(
        file: index,
        remotePath: "/updates/app-archive.json",
        config: const FtpUploadConfig(
          host: "localhost",
          remotePath: "/updates",
          username: "deploy",
          allowInsecure: true,
        ),
        expectedRevision: const RemoteIndexRevision.absent(),
      );

      expect(
        String.fromCharCodes(operations.files["/updates/app-archive.json"]!),
        "new index",
      );
      expect(operations.directories, isEmpty);
      expect(operations.events, contains("rename"));
      expect(receipt.observedPriorRevision, const RemoteIndexRevision.absent());
      expect(receipt.mechanism, IndexPublishMechanism.exclusiveLease);
      expect(receipt.leaseEvidenceSha256, matches(RegExp(r"^[0-9a-f]{64}$")));
    } finally {
      await tempDir.delete(recursive: true);
    }
  });

  test("default FTP client cleans a partial file after upload failure",
      () async {
    final tempDir =
        await Directory.systemTemp.createTemp("ftp_upload_failure_");
    try {
      final index = File(path.join(tempDir.path, "app-archive.json"));
      await index.writeAsString("new index");
      final operations = RecordingFtpRemoteOperations()..failUpload = true;
      final client = CurlFtpRemoteFileClient(operations: operations);

      await expectLater(
        client.writeIndexFileWithLease(
          file: index,
          remotePath: "/updates/app-archive.json",
          config: const FtpUploadConfig(
            host: "localhost",
            remotePath: "/updates",
            username: "deploy",
            allowInsecure: true,
          ),
          expectedRevision: const RemoteIndexRevision.absent(),
        ),
        throwsA(isA<StateError>().having(
          (error) => error.message,
          "message",
          contains("upload failed"),
        )),
      );

      expect(operations.files, isEmpty);
      expect(operations.directories, isEmpty);
      expect(operations.events, contains("removeFile"));
    } finally {
      await tempDir.delete(recursive: true);
    }
  });

  test("default FTP client rejects a revision change after upload", () async {
    final tempDir = await Directory.systemTemp.createTemp("ftp_revision_race_");
    try {
      final index = File(path.join(tempDir.path, "app-archive.json"));
      await index.writeAsString("new index");
      final oldBytes = "old index".codeUnits;
      final operations = RecordingFtpRemoteOperations();
      operations.files["/updates/app-archive.json"] = oldBytes;
      operations.afterUpload = () {
        operations.files["/updates/app-archive.json"] = "raced index".codeUnits;
      };
      final client = CurlFtpRemoteFileClient(operations: operations);

      await expectLater(
        client.writeIndexFileWithLease(
          file: index,
          remotePath: "/updates/app-archive.json",
          config: const FtpUploadConfig(
            host: "localhost",
            remotePath: "/updates",
            username: "deploy",
            allowInsecure: true,
          ),
          expectedRevision: RemoteIndexRevision.present(
            sha256: sha256.convert(oldBytes).toString(),
            etag: null,
          ),
        ),
        throwsA(isA<StateError>().having(
          (error) => error.message,
          "message",
          contains("changed before publish"),
        )),
      );

      expect(
        String.fromCharCodes(operations.files["/updates/app-archive.json"]!),
        "raced index",
      );
      expect(
          operations.files.keys,
          isNot(contains(
            "/updates/.app-archive.json.desktop_updater.lock/app-archive.json.",
          )));
      expect(operations.directories, isEmpty);
    } finally {
      await tempDir.delete(recursive: true);
    }
  });

  test("default FTP client falls back to direct upload when rename fails",
      () async {
    final tempDir =
        await Directory.systemTemp.createTemp("ftp_rename_failure_");
    try {
      final index = File(path.join(tempDir.path, "app-archive.json"));
      await index.writeAsString("new index");
      final operations = RecordingFtpRemoteOperations()..failRename = true;
      final client = CurlFtpRemoteFileClient(operations: operations);

      final receipt = await client.writeIndexFileWithLease(
        file: index,
        remotePath: "/updates/app-archive.json",
        config: const FtpUploadConfig(
          host: "localhost",
          remotePath: "/updates",
          username: "deploy",
          allowInsecure: true,
        ),
        expectedRevision: const RemoteIndexRevision.absent(),
      );

      // The rename failed (simulating an FTP server that refuses RNTO onto an
      // existing destination with 553), so the publisher must overwrite the
      // final index with a direct upload and still verify the readback.
      expect(
        String.fromCharCodes(operations.files["/updates/app-archive.json"]!),
        "new index",
      );
      expect(operations.directories, isEmpty);
      expect(
          operations.events.where((event) => event == "upload"), hasLength(2));
      expect(operations.events, contains("rename"));
      expect(operations.events, contains("removeFile"));
      expect(receipt.mechanism, IndexPublishMechanism.exclusiveLease);
      expect(receipt.publishedSha256,
          sha256.convert(index.readAsBytesSync()).toString());
    } finally {
      await tempDir.delete(recursive: true);
    }
  });

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

  test("ftp uploader rejects app archive publish without lease", () async {
    final recorder = RecordingFtpRemoteFileClient();
    final provider = FtpUploadProvider(client: recorder);

    await expectLater(
      provider.upload(
        localRoot: Directory("/tmp/dist"),
        manifest: testPublishManifest(),
        config: const FtpUploadConfig(
          host: "localhost",
          remotePath: "/updates",
          username: "deploy",
          allowInsecure: true,
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

  test("ftp uploader publishes app archive with exclusive lease receipt",
      () async {
    final tempDir = await Directory.systemTemp.createTemp("ftp_upload_");
    try {
      final manifest = testPublishManifest(localRoot: tempDir.path);
      await _writePayload(tempDir, manifest);
      final recorder = LeaseRecordingFtpRemoteFileClient();
      final provider = FtpUploadProvider(client: recorder);
      const expectedRevision = RemoteIndexRevision.present(
        sha256:
            "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        etag: '"old"',
      );

      final receipt = await provider.uploadAppArchive(
        localRoot: tempDir,
        manifest: manifest,
        config: const FtpUploadConfig(
          host: "localhost",
          remotePath: "/updates",
          username: "deploy",
          allowInsecure: true,
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

class RecordingFtpRemoteOperations implements FtpRemoteOperations {
  final files = <String, List<int>>{};
  final directories = <String>{};
  final events = <String>[];
  bool failUpload = false;
  bool failRename = false;
  void Function()? afterUpload;

  @override
  Future<void> upload(
    File file,
    String remotePath,
    FtpUploadConfig config,
  ) async {
    events.add("upload");
    files[remotePath] = await file.readAsBytes();
    afterUpload?.call();
    if (failUpload) throw StateError("upload failed");
  }

  @override
  Future<List<int>?> read(
    String remotePath,
    FtpUploadConfig config,
  ) async {
    events.add("read");
    final value = files[remotePath];
    return value == null ? null : List<int>.from(value);
  }

  @override
  Future<void> makeDirectory(
    String remotePath,
    FtpUploadConfig config,
  ) async {
    events.add("makeDirectory");
    if (!directories.add(remotePath)) {
      throw StateError("directory already exists");
    }
  }

  @override
  Future<void> removeDirectory(
    String remotePath,
    FtpUploadConfig config,
  ) async {
    events.add("removeDirectory");
    directories.remove(remotePath);
  }

  @override
  Future<void> removeFile(
    String remotePath,
    FtpUploadConfig config,
  ) async {
    events.add("removeFile");
    files.remove(remotePath);
  }

  @override
  Future<void> rename(
    String from,
    String to,
    FtpUploadConfig config,
  ) async {
    events.add("rename");
    if (failRename) throw StateError("rename failed");
    final value = files.remove(from);
    if (value == null) throw StateError("source missing");
    files[to] = value;
  }
}

class LeaseRecordingFtpRemoteFileClient
    implements ExclusiveLeaseFtpRemoteFileClient {
  String? indexRemotePath;
  RemoteIndexRevision? expectedRevision;

  @override
  Future<void> writeFile({
    required File file,
    required String remotePath,
    required FtpUploadConfig config,
  }) async {}

  @override
  Future<IndexPublishReceipt> writeIndexFileWithLease({
    required File file,
    required String remotePath,
    required FtpUploadConfig config,
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
