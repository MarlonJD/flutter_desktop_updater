import "dart:convert";
import "dart:io";
import "dart:typed_data";

import "package:archive/archive.dart";
import "package:crypto/crypto.dart";
import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:desktop_updater/src/core/safe_zip_extractor.dart";
import "package:desktop_updater/src/core/update_client.dart";
import "package:desktop_updater/src/io/composite_update_transport.dart";
import "package:desktop_updater/src/io/file_update_transport.dart";
import "package:desktop_updater/src/io/http_update_transport.dart";
import "package:desktop_updater/src/io/update_transport.dart";
import "package:desktop_updater/src/version_info.dart";
import "package:flutter_test/flutter_test.dart";
import "package:http/http.dart" as http;
import "package:http/testing.dart";
import "package:path/path.dart" as path;

void main() {
  group("bounded stable metadata", () {
    test("rejects oversized declared HTTP length without retry or files",
        () async {
      final root = await Directory.systemTemp.createTemp("metadata_limit_");
      addTearDown(() => root.delete(recursive: true));
      var attempts = 0;
      final destination = File(path.join(root.path, "app-archive.json"))
        ..writeAsStringSync("stale");
      final transport = HttpUpdateTransport(
        client: MockClient.streaming((request, bodyStream) async {
          attempts += 1;
          return http.StreamedResponse(
            Stream<List<int>>.value(<int>[1, 2, 3, 4, 5]),
            HttpStatus.ok,
            contentLength: 5,
          );
        }),
        delay: (_) async {},
      );

      await expectLater(
        transport.downloadBounded(
          Uri.parse("https://updates.example.test/app-archive.json"),
          destination,
          maximumBytes: 4,
        ),
        throwsA(isA<UpdateDownloadSizeLimitException>()),
      );

      expect(attempts, 1);
      expect(destination.existsSync(), isFalse);
      expect(File("${destination.path}.part").existsSync(), isFalse);
    });

    test("rejects streamed HTTP overrun before appending the offending chunk",
        () async {
      final root = await Directory.systemTemp.createTemp("metadata_limit_");
      addTearDown(() => root.delete(recursive: true));
      var attempts = 0;
      final destination = File(path.join(root.path, "release.json"))
        ..writeAsStringSync("stale");
      final transport = HttpUpdateTransport(
        client: MockClient.streaming((request, bodyStream) async {
          attempts += 1;
          return http.StreamedResponse(
            Stream<List<int>>.fromIterable(<List<int>>[
              <int>[1, 2, 3],
              <int>[4, 5],
            ]),
            HttpStatus.ok,
          );
        }),
        delay: (_) async {},
      );

      await expectLater(
        transport.downloadBounded(
          Uri.parse("https://updates.example.test/release.json"),
          destination,
          maximumBytes: 4,
        ),
        throwsA(
          isA<UpdateDownloadSizeLimitException>().having(
            (error) => error.actualBytes,
            "actualBytes",
            5,
          ),
        ),
      );

      expect(attempts, 1);
      expect(destination.existsSync(), isFalse);
      expect(File("${destination.path}.part").existsSync(), isFalse);
    });

    test("file transport rejects oversized metadata with cleanup", () async {
      final root = await Directory.systemTemp.createTemp("metadata_limit_");
      addTearDown(() => root.delete(recursive: true));
      final source = File(path.join(root.path, "source.json"))
        ..writeAsStringSync("12345");
      final destination = File(path.join(root.path, "destination.json"))
        ..writeAsStringSync("stale");
      File("${destination.path}.part").writeAsStringSync("partial");

      await expectLater(
        const FileUpdateTransport().downloadBounded(
          source.uri,
          destination,
          maximumBytes: 4,
        ),
        throwsA(isA<UpdateDownloadSizeLimitException>()),
      );

      expect(destination.existsSync(), isFalse);
      expect(File("${destination.path}.part").existsSync(), isFalse);
    });

    test("composite transport forwards bounded file downloads", () async {
      final root = await Directory.systemTemp.createTemp("metadata_limit_");
      addTearDown(() => root.delete(recursive: true));
      final source = File(path.join(root.path, "source.json"))
        ..writeAsStringSync("1234");
      final destination = File(path.join(root.path, "destination.json"));
      final transport = CompositeUpdateTransport();
      addTearDown(transport.close);

      await transport.downloadBounded(
        source.uri,
        destination,
        maximumBytes: 4,
      );

      expect(destination.readAsStringSync(), "1234");
    });

    test("UpdateClient bounds both index and descriptor downloads", () async {
      final archiveUrl =
          Uri.parse("https://updates.example.test/app-archive.json");
      final releaseUrl = Uri.parse("https://updates.example.test/release.json");
      final artifactUrl =
          Uri.parse("https://updates.example.test/artifact.zip");
      final transport = _BoundedMapTransport(<Uri, String>{
        archiveUrl: _indexJson(releaseUrl),
        releaseUrl: _descriptorJson(artifactUrl),
      });
      final client = UpdateClient(
        appArchiveUrl: archiveUrl,
        currentVersion: DesktopVersionInfo.parse("1.0.0"),
        platform: "linux",
        transport: transport,
      );

      expect(await client.checkForUpdate(), isNotNull);
      expect(transport.unboundedSources, isEmpty);
      expect(transport.boundedCalls, <(Uri, int)>[
        (archiveUrl, maximumStableMetadataBytes),
        (releaseUrl, maximumStableMetadataBytes),
      ]);
      expect(maximumStableMetadataBytes, 4 * 1024 * 1024);
    });

    test("UpdateClient checks legacy custom transport output after download",
        () async {
      final archiveUrl =
          Uri.parse("https://updates.example.test/app-archive.json");
      final releaseUrl = Uri.parse("https://updates.example.test/release.json");
      final artifactUrl =
          Uri.parse("https://updates.example.test/artifact.zip");
      final transport = _LegacyMapTransport(<Uri, String>{
        archiveUrl: _indexJson(releaseUrl),
        releaseUrl:
            "${_descriptorJson(artifactUrl)}${" " * maximumStableMetadataBytes}",
      });
      final client = UpdateClient(
        appArchiveUrl: archiveUrl,
        currentVersion: DesktopVersionInfo.parse("1.0.0"),
        platform: "linux",
        transport: transport,
      );

      await expectLater(
        client.checkForUpdate(),
        throwsA(isA<UpdateDownloadSizeLimitException>()),
      );

      expect(transport.downloadedSources, <Uri>[archiveUrl, releaseUrl]);
    });

    test("UpdateClient bounds artifact transfer to descriptor length",
        () async {
      final artifactUrl =
          Uri.parse("https://updates.example.test/artifact.zip");
      final transport = _ArtifactRecordingTransport(artifactUrl);
      final client = UpdateClient(
        appArchiveUrl:
            Uri.parse("https://updates.example.test/app-archive.json"),
        currentVersion: DesktopVersionInfo.parse("1.0.0"),
        platform: "linux",
        transport: transport,
      );
      final descriptor = ReleaseDescriptor(
        schemaVersion: 3,
        packageId: "com.example.app",
        appName: "Example",
        version: "2.0.0",
        buildNumber: 200,
        platform: "linux",
        channel: "stable",
        artifact: ReleaseArtifact(
          kind: "zip",
          url: artifactUrl,
          sha256: "a" * 64,
          length: 123,
        ),
        install: const ReleaseInstall(strategy: "wholeBundleReplace"),
        minimumUpdaterVersion: "2.0.0",
        generatedAt: DateTime.utc(2026, 7, 13),
      );

      await expectLater(
        client.downloadVerifyAndStage(descriptor: descriptor),
        throwsA(isA<_ArtifactTransferStopped>()),
      );

      expect(transport.unboundedSources, isEmpty);
      expect(transport.boundedCalls, <(Uri, int)>[(artifactUrl, 123)]);
    });

    test("built-in artifact overrun removes partials and owned stage",
        () async {
      final root = await Directory.systemTemp.createTemp("artifact_limit_");
      addTearDown(() => root.delete(recursive: true));
      final artifact = File(path.join(root.path, "oversized.zip"));
      final bytes = utf8.encode("oversized");
      await artifact.writeAsBytes(bytes);
      final client = UpdateClient(
        appArchiveUrl: Uri.file(path.join(root.path, "app-archive.json")),
        currentVersion: DesktopVersionInfo.parse("1.0.0"),
        platform: "linux",
        stagingParent: root,
      );

      await expectLater(
        client.downloadVerifyAndStage(
          descriptor: _artifactDescriptor(
            artifact.uri,
            length: bytes.length - 1,
          ),
        ),
        throwsA(isA<UpdateDownloadSizeLimitException>()),
      );

      expect(await artifact.exists(), isTrue);
      expect(await _ownedStages(root), isEmpty);
      expect(
        await root
            .list()
            .where((entity) => entity.path.endsWith(".part"))
            .toList(),
        isEmpty,
      );
    });

    test("legacy artifact overrun is rejected and cleans owned stage",
        () async {
      final root = await Directory.systemTemp.createTemp("artifact_limit_");
      addTearDown(() => root.delete(recursive: true));
      final artifactUrl =
          Uri.parse("https://updates.example.test/oversized.zip");
      final client = UpdateClient(
        appArchiveUrl:
            Uri.parse("https://updates.example.test/app-archive.json"),
        currentVersion: DesktopVersionInfo.parse("1.0.0"),
        platform: "linux",
        stagingParent: root,
        transport: _LegacyArtifactTransport(List<int>.filled(124, 1)),
      );

      await expectLater(
        client.downloadVerifyAndStage(
          descriptor: _artifactDescriptor(artifactUrl, length: 123),
        ),
        throwsA(isA<UpdateDownloadSizeLimitException>()),
      );

      expect(await _ownedStages(root), isEmpty);
    });
  });

  group("bounded zip staging", () {
    test("Dart ZIP decoding remains file-backed", () {
      final source =
          File("lib/src/core/safe_zip_extractor.dart").readAsStringSync();

      expect(source, contains("InputFileStream(archiveFile.path)"));
      expect(source, contains("ZipDecoder().decodeStream("));
      expect(source, isNot(contains("archiveFile.readAsBytes()")));
      expect(source, contains("input.closeSync()"));
    });

    test("file-backed ZIP input closes after successful extraction", () async {
      final fixture = await _ZipFixture.create(
        Archive()..addFile(ArchiveFile.string("file.txt", "content")),
      );
      addTearDown(fixture.delete);

      await const SafeZipExtractor().extract(
        archiveFile: fixture.archive,
        destination: fixture.destination,
        platform: "linux",
      );
      final renamed = await fixture.archive.rename(
        path.join(fixture.root.path, "renamed.zip"),
      );

      expect(await renamed.exists(), isTrue);
      expect(
        await fixture.root
            .list()
            .where(
              (entity) => path.basename(entity.path).startsWith(
                    ".desktop_updater_extract_",
                  ),
            )
            .toList(),
        isEmpty,
      );
    });

    test("native-compatible archive defaults are exact", () {
      const extractor = SafeZipExtractor();

      expect(extractor.maximumArchiveEntries, 100000);
      expect(extractor.maximumUncompressedBytes, 8 * 1024 * 1024 * 1024);
      expect(extractor.maximumSingleEntryBytes, 4 * 1024 * 1024 * 1024);
    });

    test("rejects excessive entry count before destination mutation", () async {
      final fixture = await _ZipFixture.create(
        Archive()
          ..addFile(ArchiveFile.string("one.txt", "1"))
          ..addFile(ArchiveFile.string("two.txt", "2")),
      );
      addTearDown(fixture.delete);
      final sentinel = File(path.join(fixture.destination.path, "sentinel"));
      await sentinel.create(recursive: true);
      await sentinel.writeAsString("keep");

      await expectLater(
        const SafeZipExtractor(maximumArchiveEntries: 1).extract(
          archiveFile: fixture.archive,
          destination: fixture.destination,
          platform: "linux",
        ),
        throwsFormatException,
      );

      expect(sentinel.readAsStringSync(), "keep");
      expect(
        File(path.join(fixture.destination.path, "one.txt")).existsSync(),
        isFalse,
      );
      expect(
        File(path.join(fixture.destination.path, "two.txt")).existsSync(),
        isFalse,
      );
    });

    test("rejects excessive single entry before creating destination",
        () async {
      final fixture = await _ZipFixture.create(
        Archive()..addFile(ArchiveFile.string("large.txt", "1234")),
      );
      addTearDown(fixture.delete);

      await expectLater(
        const SafeZipExtractor(maximumSingleEntryBytes: 3).extract(
          archiveFile: fixture.archive,
          destination: fixture.destination,
          platform: "linux",
        ),
        throwsFormatException,
      );

      expect(fixture.destination.existsSync(), isFalse);
    });

    test("rejects excessive cumulative size before destination mutation",
        () async {
      final fixture = await _ZipFixture.create(
        Archive()
          ..addFile(ArchiveFile.string("one.txt", "123"))
          ..addFile(ArchiveFile.string("two.txt", "456")),
      );
      addTearDown(fixture.delete);
      final sentinel = File(path.join(fixture.destination.path, "sentinel"));
      await sentinel.create(recursive: true);
      await sentinel.writeAsString("keep");

      await expectLater(
        const SafeZipExtractor(maximumUncompressedBytes: 5).extract(
          archiveFile: fixture.archive,
          destination: fixture.destination,
          platform: "linux",
        ),
        throwsFormatException,
      );

      expect(sentinel.readAsStringSync(), "keep");
      expect(
        File(path.join(fixture.destination.path, "one.txt")).existsSync(),
        isFalse,
      );
    });

    test("preflights macOS zip limits before invoking ditto", () async {
      final root = await Directory.systemTemp.createTemp("mac_zip_limit_");
      addTearDown(() => root.delete(recursive: true));
      final archive = File(path.join(root.path, "artifact.zip"));
      await archive.writeAsBytes(
        ZipEncoder().encode(
          Archive()
            ..addFile(
              ArchiveFile.string("Example.app/Contents/file", "1234"),
            ),
        ),
      );
      final processCalls = <String>[];
      final client = UpdateClient(
        appArchiveUrl: Uri.file(path.join(root.path, "app-archive.json")),
        currentVersion: DesktopVersionInfo.parse("1.0.0"),
        platform: "macos",
        stagingParent: root,
        extractor: const SafeZipExtractor(maximumSingleEntryBytes: 3),
        runProcess: (executable, arguments) async {
          processCalls.add(executable);
          return ProcessResult(0, 0, "", "");
        },
      );

      await expectLater(
        client.downloadVerifyAndStage(
          descriptor: await _zipDescriptor(archive, platform: "macos"),
        ),
        throwsFormatException,
      );

      expect(processCalls, isEmpty);
      expect(
        root.listSync().whereType<Directory>().where(
              (directory) => path
                  .basename(directory.path)
                  .startsWith("desktop_updater_stage_"),
            ),
        isEmpty,
      );
    });

    test("rejects a ZIP64 entry with overflowing uncompressed size", () async {
      final fixture = await _ZipFixture.fromBytes(
        _zipWithZip64EntrySize(0xffffffffffffffff),
      );
      addTearDown(fixture.delete);

      await expectLater(
        const SafeZipExtractor().extract(
          archiveFile: fixture.archive,
          destination: fixture.destination,
          platform: "linux",
        ),
        throwsFormatException,
      );

      expect(fixture.destination.existsSync(), isFalse);
    });

    test("rejects truncated ZIP64 entry metadata", () async {
      final fixture = await _ZipFixture.fromBytes(
        _zipWithZip64EntrySize(null),
      );
      addTearDown(fixture.delete);

      await expectLater(
        const SafeZipExtractor().extract(
          archiveFile: fixture.archive,
          destination: fixture.destination,
          platform: "linux",
        ),
        throwsFormatException,
      );

      expect(fixture.destination.existsSync(), isFalse);
    });

    test("rejects ZIP64 entry count before parsing archive bodies", () async {
      final fixture = await _ZipFixture.fromBytes(
        _zip64WithDeclaredEntryCount(100001),
      );
      addTearDown(fixture.delete);

      await expectLater(
        const SafeZipExtractor().extract(
          archiveFile: fixture.archive,
          destination: fixture.destination,
          platform: "linux",
        ),
        throwsFormatException,
      );

      expect(fixture.destination.existsSync(), isFalse);
    });

    test(
        "rejects conflicting local flags, compression, CRC, and sizes before ditto",
        () async {
      final archive = ZipEncoder().encode(
        Archive()..addFile(ArchiveFile.string("Example.app/file", "content")),
      );
      final local = _findSignature(archive, 0x04034b50);
      final corruptions = <String, List<int>>{
        "flags": _withUint16(
          archive,
          local + 6,
          _readU16(archive, local + 6) ^ 1,
        ),
        "compression": _withUint16(
          archive,
          local + 8,
          _readU16(archive, local + 8) == 0 ? 8 : 0,
        ),
        "CRC": _withUint32(
          archive,
          local + 14,
          _readU32(archive, local + 14) ^ 1,
        ),
        "compressed size": _withUint32(
          archive,
          local + 18,
          _readU32(archive, local + 18) + 1,
        ),
        "uncompressed size": _withUint32(
          archive,
          local + 22,
          _readU32(archive, local + 22) + 1,
        ),
      };

      for (final corruption in corruptions.entries) {
        await _expectMacZipRejectedBeforeDitto(
          corruption.value,
          reason: corruption.key,
        );
      }
    });

    test("rejects missing local ZIP64 extra before ditto", () async {
      final archive = _zipWithZip64EntrySize(0);
      final local = _findSignature(archive, 0x04034b50);
      final missingLocalZip64 = _withUint32(
        archive,
        local + 22,
        0xffffffff,
      );

      await _expectMacZipRejectedBeforeDitto(missingLocalZip64);
    });

    test("rejects truncated local ZIP64 extra before ditto", () async {
      await _expectMacZipRejectedBeforeDitto(
        _zipWithTruncatedLocalZip64Extra(),
      );
    });

    test("rejects overflowing local ZIP64 extra before ditto", () async {
      await _expectMacZipRejectedBeforeDitto(
        _zipWithOverflowingLocalZip64Extra(),
        expectedError: throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            "message",
            contains("ZIP64 local entry metadata overflows"),
          ),
        ),
      );
    });

    test("allows valid data-descriptor local placeholders", () async {
      final signed = await _ZipFixture.fromBytes(_dataDescriptorZip());
      final unsigned = await _ZipFixture.fromBytes(
        _dataDescriptorZip(includeSignature: false),
      );
      addTearDown(signed.delete);
      addTearDown(unsigned.delete);

      await const SafeZipExtractor().preflight(signed.archive);
      await const SafeZipExtractor().preflight(unsigned.archive);
    });

    test("allows an unsigned descriptor CRC equal to the optional signature",
        () async {
      final fixture = await _ZipFixture.fromBytes(
        _dataDescriptorZip(
          includeSignature: false,
          centralCrc32: 0x08074b50,
          descriptorCrc32: 0x08074b50,
        ),
      );
      addTearDown(fixture.delete);

      await const SafeZipExtractor().preflight(fixture.archive);
    });

    test("rejects conflicting data-descriptor values before ditto", () async {
      const data = <int>[0x78];
      final crc = getCrc32(data);
      final corruptions = <String, List<int>>{
        "CRC": _dataDescriptorZip(descriptorCrc32: crc ^ 1),
        "compressed size": _dataDescriptorZip(descriptorCompressedBytes: 2),
        "uncompressed size": _dataDescriptorZip(
          descriptorUncompressedBytes: 2,
        ),
      };

      for (final corruption in corruptions.entries) {
        await _expectMacZipRejectedBeforeDitto(
          corruption.value,
          reason: corruption.key,
        );
      }
    });

    test("rejects a truncated data descriptor before ditto", () async {
      await _expectMacZipRejectedBeforeDitto(
        _dataDescriptorZip(truncateDescriptorBytes: 4),
      );
    });

    test("rejects an overflowing ZIP64 data descriptor before ditto", () async {
      await _expectMacZipRejectedBeforeDitto(
        _dataDescriptorZip(
          zip64: true,
          descriptorCompressedBytes: 0xffffffffffffffff,
        ),
      );
    });

    test("allows legacy non-UTF8 filenames when UTF8 flag is clear", () async {
      final fixture = await _ZipFixture.fromBytes(
        _storedZipWithName(<int>[0x82, 0x2e, 0x74, 0x78, 0x74]),
      );
      addTearDown(fixture.delete);

      await const SafeZipExtractor().preflight(fixture.archive);
    });
  });
}

String _indexJson(Uri releaseUrl) => jsonEncode(<String, Object?>{
      "schemaVersion": 3,
      "appName": "Example",
      "items": <Object?>[
        <String, Object?>{
          "version": "2.0.0",
          "buildNumber": 200,
          "platform": "linux",
          "channel": "stable",
          "mandatory": false,
          "release": releaseUrl.toString(),
        },
      ],
    });

String _descriptorJson(Uri artifactUrl) => jsonEncode(<String, Object?>{
      "schemaVersion": 3,
      "packageId": "com.example.app",
      "appName": "Example",
      "version": "2.0.0",
      "buildNumber": 200,
      "platform": "linux",
      "channel": "stable",
      "artifact": <String, Object?>{
        "kind": "zip",
        "url": artifactUrl.toString(),
        "sha256": "a" * 64,
        "length": 1,
      },
      "install": <String, Object?>{"strategy": "wholeBundleReplace"},
      "minimumUpdaterVersion": "2.0.0",
      "generatedAt": DateTime.utc(2026, 7, 13).toIso8601String(),
    });

ReleaseDescriptor _artifactDescriptor(Uri artifactUrl, {required int length}) {
  return ReleaseDescriptor(
    schemaVersion: 3,
    packageId: "com.example.app",
    appName: "Example",
    version: "2.0.0",
    buildNumber: 200,
    platform: "linux",
    channel: "stable",
    artifact: ReleaseArtifact(
      kind: "zip",
      url: artifactUrl,
      sha256: "a" * 64,
      length: length,
    ),
    install: const ReleaseInstall(strategy: "wholeBundleReplace"),
    minimumUpdaterVersion: "2.0.0",
    generatedAt: DateTime.utc(2026, 7, 13),
  );
}

Future<List<FileSystemEntity>> _ownedStages(Directory parent) {
  return parent
      .list()
      .where(
        (entity) =>
            path.basename(entity.path).startsWith("desktop_updater_stage_"),
      )
      .toList();
}

Future<ReleaseDescriptor> _zipDescriptor(
  File archive, {
  required String platform,
}) async {
  final bytes = await archive.readAsBytes();
  return ReleaseDescriptor(
    schemaVersion: 3,
    packageId: "com.example.app",
    appName: "Example.app",
    version: "2.0.0",
    buildNumber: 200,
    platform: platform,
    channel: "stable",
    artifact: ReleaseArtifact(
      kind: "zip",
      url: archive.uri,
      sha256: sha256.convert(bytes).toString(),
      length: bytes.length,
    ),
    install: const ReleaseInstall(strategy: "wholeBundleReplace"),
    minimumUpdaterVersion: "2.0.0",
    generatedAt: DateTime.utc(2026, 7, 13),
  );
}

Future<void> _expectMacZipRejectedBeforeDitto(
  List<int> bytes, {
  String? reason,
  Object? expectedError,
}) async {
  final root = await Directory.systemTemp.createTemp("mac_zip_metadata_");
  try {
    final archive = File(path.join(root.path, "artifact.zip"));
    await archive.writeAsBytes(bytes);
    final processCalls = <String>[];
    final client = UpdateClient(
      appArchiveUrl: Uri.file(path.join(root.path, "app-archive.json")),
      currentVersion: DesktopVersionInfo.parse("1.0.0"),
      platform: "macos",
      stagingParent: root,
      runProcess: (executable, arguments) async {
        processCalls.add(executable);
        return ProcessResult(0, 0, "", "");
      },
    );

    await expectLater(
      client.downloadVerifyAndStage(
        descriptor: await _zipDescriptor(archive, platform: "macos"),
      ),
      expectedError ?? throwsFormatException,
      reason: reason,
    );
    expect(processCalls, isEmpty, reason: reason);
  } finally {
    await root.delete(recursive: true);
  }
}

class _BoundedMapTransport implements BoundedUpdateTransport {
  _BoundedMapTransport(this.responses);

  final Map<Uri, String> responses;
  final List<Uri> unboundedSources = <Uri>[];
  final List<(Uri, int)> boundedCalls = <(Uri, int)>[];

  @override
  Future<void> download(
    Uri source,
    File destination, {
    void Function(int receivedBytes, int? totalBytes)? onProgress,
    Duration? timeout,
  }) async {
    unboundedSources.add(source);
    throw StateError("UpdateClient must use bounded metadata downloads.");
  }

  @override
  Future<void> downloadBounded(
    Uri source,
    File destination, {
    required int maximumBytes,
    void Function(int receivedBytes, int? totalBytes)? onProgress,
    Duration? timeout,
  }) async {
    boundedCalls.add((source, maximumBytes));
    final response = responses[source]!;
    await destination.create(recursive: true);
    await destination.writeAsString(response);
  }
}

class _LegacyMapTransport implements UpdateTransport {
  _LegacyMapTransport(this.responses);

  final Map<Uri, String> responses;
  final List<Uri> downloadedSources = <Uri>[];

  @override
  Future<void> download(
    Uri source,
    File destination, {
    void Function(int receivedBytes, int? totalBytes)? onProgress,
    Duration? timeout,
  }) async {
    downloadedSources.add(source);
    await destination.create(recursive: true);
    await destination.writeAsString(responses[source]!);
  }
}

class _ArtifactRecordingTransport implements BoundedUpdateTransport {
  _ArtifactRecordingTransport(this.artifactUrl);

  final Uri artifactUrl;
  final List<Uri> unboundedSources = <Uri>[];
  final List<(Uri, int)> boundedCalls = <(Uri, int)>[];

  @override
  Future<void> download(
    Uri source,
    File destination, {
    void Function(int receivedBytes, int? totalBytes)? onProgress,
    Duration? timeout,
  }) async {
    unboundedSources.add(source);
    throw StateError("Artifact download must be bounded.");
  }

  @override
  Future<void> downloadBounded(
    Uri source,
    File destination, {
    required int maximumBytes,
    void Function(int receivedBytes, int? totalBytes)? onProgress,
    Duration? timeout,
  }) async {
    boundedCalls.add((source, maximumBytes));
    if (source == artifactUrl) {
      throw _ArtifactTransferStopped();
    }
    throw StateError("Unexpected bounded source: $source");
  }
}

class _ArtifactTransferStopped implements Exception {}

class _LegacyArtifactTransport implements UpdateTransport {
  _LegacyArtifactTransport(this.bytes);

  final List<int> bytes;

  @override
  Future<void> download(
    Uri source,
    File destination, {
    void Function(int receivedBytes, int? totalBytes)? onProgress,
    Duration? timeout,
  }) async {
    await destination.create(recursive: true);
    await destination.writeAsBytes(bytes);
  }
}

class _ZipFixture {
  const _ZipFixture({
    required this.root,
    required this.archive,
    required this.destination,
  });

  final Directory root;
  final File archive;
  final Directory destination;

  static Future<_ZipFixture> create(Archive contents) {
    return fromBytes(ZipEncoder().encode(contents));
  }

  static Future<_ZipFixture> fromBytes(List<int> bytes) async {
    final root = await Directory.systemTemp.createTemp("zip_limit_");
    final archive = File(path.join(root.path, "fixture.zip"));
    await archive.writeAsBytes(bytes);
    return _ZipFixture(
      root: root,
      archive: archive,
      destination: Directory(path.join(root.path, "out")),
    );
  }

  Future<void> delete() => root.delete(recursive: true);
}

List<int> _zipWithZip64EntrySize(int? uncompressedSize) {
  const name = "empty";
  final local = BytesBuilder()
    ..add(_u32(0x04034b50))
    ..add(_u16(45))
    ..add(_u16(0))
    ..add(_u16(0))
    ..add(_u16(0))
    ..add(_u16(0))
    ..add(_u32(0))
    ..add(_u32(0))
    ..add(_u32(0))
    ..add(_u16(name.length))
    ..add(_u16(0))
    ..add(ascii.encode(name));
  final extra = BytesBuilder()
    ..add(_u16(1))
    ..add(_u16(uncompressedSize == null ? 4 : 8));
  if (uncompressedSize == null) {
    extra.add(_u32(0));
  } else {
    extra.add(_u64(uncompressedSize));
  }
  final extraBytes = extra.toBytes();
  final centralOffset = local.length;
  final central = BytesBuilder()
    ..add(_u32(0x02014b50))
    ..add(_u16(45))
    ..add(_u16(45))
    ..add(_u16(0))
    ..add(_u16(0))
    ..add(_u16(0))
    ..add(_u16(0))
    ..add(_u32(0))
    ..add(_u32(0))
    ..add(_u32(0xffffffff))
    ..add(_u16(name.length))
    ..add(_u16(extraBytes.length))
    ..add(_u16(0))
    ..add(_u16(0))
    ..add(_u16(0))
    ..add(_u32(0))
    ..add(_u32(0))
    ..add(ascii.encode(name))
    ..add(extraBytes);
  final centralBytes = central.toBytes();
  return (BytesBuilder()
        ..add(local.toBytes())
        ..add(centralBytes)
        ..add(
          _eocd(
            entries: 1,
            centralSize: centralBytes.length,
            centralOffset: centralOffset,
          ),
        ))
      .toBytes();
}

List<int> _zip64WithDeclaredEntryCount(int entries) {
  final normal = _zipWithZip64EntrySize(0);
  final eocdOffset = normal.length - 22;
  final withoutEocd = normal.sublist(0, eocdOffset);
  final centralOffset = _readU32(normal, eocdOffset + 16);
  final centralSize = _readU32(normal, eocdOffset + 12);
  final zip64Offset = withoutEocd.length;
  final zip64 = BytesBuilder()
    ..add(_u32(0x06064b50))
    ..add(_u64(44))
    ..add(_u16(45))
    ..add(_u16(45))
    ..add(_u32(0))
    ..add(_u32(0))
    ..add(_u64(entries))
    ..add(_u64(entries))
    ..add(_u64(centralSize))
    ..add(_u64(centralOffset));
  final locator = BytesBuilder()
    ..add(_u32(0x07064b50))
    ..add(_u32(0))
    ..add(_u64(zip64Offset))
    ..add(_u32(1));
  return (BytesBuilder()
        ..add(withoutEocd)
        ..add(zip64.toBytes())
        ..add(locator.toBytes())
        ..add(
          _eocd(
            entries: 0xffff,
            centralSize: centralSize,
            centralOffset: centralOffset,
          ),
        ))
      .toBytes();
}

List<int> _zipWithTruncatedLocalZip64Extra() {
  return _zipWithLocalZip64Extra(
    declaredSize: 8,
    values: <int>[0],
  );
}

List<int> _zipWithOverflowingLocalZip64Extra() {
  return _zipWithLocalZip64Extra(
    declaredSize: 16,
    values: <int>[0xffffffffffffffff, 0xffffffffffffffff],
  );
}

List<int> _zipWithLocalZip64Extra({
  required int declaredSize,
  required List<int> values,
}) {
  const name = "empty";
  final localExtra = BytesBuilder()
    ..add(_u16(1))
    ..add(_u16(declaredSize));
  for (final value in values) {
    localExtra.add(_u64(value));
  }
  final localExtraBytes = localExtra.toBytes();
  final local = BytesBuilder()
    ..add(_u32(0x04034b50))
    ..add(_u16(45))
    ..add(_u16(0))
    ..add(_u16(0))
    ..add(_u16(0))
    ..add(_u16(0))
    ..add(_u32(0))
    ..add(_u32(0xffffffff))
    ..add(_u32(0xffffffff))
    ..add(_u16(name.length))
    ..add(_u16(localExtraBytes.length))
    ..add(ascii.encode(name))
    ..add(localExtraBytes);
  final centralExtra = BytesBuilder()
    ..add(_u16(1))
    ..add(_u16(16))
    ..add(_u64(0))
    ..add(_u64(0));
  final centralExtraBytes = centralExtra.toBytes();
  final centralOffset = local.length;
  final central = BytesBuilder()
    ..add(_u32(0x02014b50))
    ..add(_u16(45))
    ..add(_u16(45))
    ..add(_u16(0))
    ..add(_u16(0))
    ..add(_u16(0))
    ..add(_u16(0))
    ..add(_u32(0))
    ..add(_u32(0xffffffff))
    ..add(_u32(0xffffffff))
    ..add(_u16(name.length))
    ..add(_u16(centralExtraBytes.length))
    ..add(_u16(0))
    ..add(_u16(0))
    ..add(_u16(0))
    ..add(_u32(0))
    ..add(_u32(0))
    ..add(ascii.encode(name))
    ..add(centralExtraBytes);
  final centralBytes = central.toBytes();
  return (BytesBuilder()
        ..add(local.toBytes())
        ..add(centralBytes)
        ..add(
          _eocd(
            entries: 1,
            centralSize: centralBytes.length,
            centralOffset: centralOffset,
          ),
        ))
      .toBytes();
}

List<int> _dataDescriptorZip({
  bool includeSignature = true,
  bool zip64 = false,
  int? centralCrc32,
  int? descriptorCrc32,
  int? descriptorCompressedBytes,
  int? descriptorUncompressedBytes,
  int truncateDescriptorBytes = 0,
}) {
  const name = "data.txt";
  const data = <int>[0x78];
  final crc = centralCrc32 ?? getCrc32(data);
  final descriptor = BytesBuilder();
  if (includeSignature) {
    descriptor.add(_u32(0x08074b50));
  }
  descriptor.add(_u32(descriptorCrc32 ?? crc));
  if (zip64) {
    descriptor
      ..add(_u64(descriptorCompressedBytes ?? data.length))
      ..add(_u64(descriptorUncompressedBytes ?? data.length));
  } else {
    descriptor
      ..add(_u32(descriptorCompressedBytes ?? data.length))
      ..add(_u32(descriptorUncompressedBytes ?? data.length));
  }
  final completeDescriptor = descriptor.toBytes();
  final descriptorBytes = completeDescriptor.sublist(
    0,
    completeDescriptor.length - truncateDescriptorBytes,
  );
  final local = BytesBuilder()
    ..add(_u32(0x04034b50))
    ..add(_u16(zip64 ? 45 : 20))
    ..add(_u16(0x08))
    ..add(_u16(0))
    ..add(_u16(0))
    ..add(_u16(0))
    ..add(_u32(0))
    ..add(_u32(0))
    ..add(_u32(0))
    ..add(_u16(name.length))
    ..add(_u16(0))
    ..add(ascii.encode(name))
    ..add(data)
    ..add(descriptorBytes);
  final centralOffset = local.length;
  final centralExtra = BytesBuilder();
  if (zip64) {
    centralExtra
      ..add(_u16(1))
      ..add(_u16(16))
      ..add(_u64(data.length))
      ..add(_u64(data.length));
  }
  final centralExtraBytes = centralExtra.toBytes();
  final central = BytesBuilder()
    ..add(_u32(0x02014b50))
    ..add(_u16(zip64 ? 45 : 20))
    ..add(_u16(zip64 ? 45 : 20))
    ..add(_u16(0x08))
    ..add(_u16(0))
    ..add(_u16(0))
    ..add(_u16(0))
    ..add(_u32(crc))
    ..add(_u32(zip64 ? 0xffffffff : data.length))
    ..add(_u32(zip64 ? 0xffffffff : data.length))
    ..add(_u16(name.length))
    ..add(_u16(centralExtraBytes.length))
    ..add(_u16(0))
    ..add(_u16(0))
    ..add(_u16(0))
    ..add(_u32(0))
    ..add(_u32(0))
    ..add(ascii.encode(name))
    ..add(centralExtraBytes);
  final centralBytes = central.toBytes();
  return (BytesBuilder()
        ..add(local.toBytes())
        ..add(centralBytes)
        ..add(
          _eocd(
            entries: 1,
            centralSize: centralBytes.length,
            centralOffset: centralOffset,
          ),
        ))
      .toBytes();
}

List<int> _storedZipWithName(List<int> nameBytes) {
  final local = BytesBuilder()
    ..add(_u32(0x04034b50))
    ..add(_u16(20))
    ..add(_u16(0))
    ..add(_u16(0))
    ..add(_u16(0))
    ..add(_u16(0))
    ..add(_u32(0))
    ..add(_u32(0))
    ..add(_u32(0))
    ..add(_u16(nameBytes.length))
    ..add(_u16(0))
    ..add(nameBytes);
  final centralOffset = local.length;
  final central = BytesBuilder()
    ..add(_u32(0x02014b50))
    ..add(_u16(20))
    ..add(_u16(20))
    ..add(_u16(0))
    ..add(_u16(0))
    ..add(_u16(0))
    ..add(_u16(0))
    ..add(_u32(0))
    ..add(_u32(0))
    ..add(_u32(0))
    ..add(_u16(nameBytes.length))
    ..add(_u16(0))
    ..add(_u16(0))
    ..add(_u16(0))
    ..add(_u16(0))
    ..add(_u32(0))
    ..add(_u32(0))
    ..add(nameBytes);
  final centralBytes = central.toBytes();
  return (BytesBuilder()
        ..add(local.toBytes())
        ..add(centralBytes)
        ..add(
          _eocd(
            entries: 1,
            centralSize: centralBytes.length,
            centralOffset: centralOffset,
          ),
        ))
      .toBytes();
}

List<int> _eocd({
  required int entries,
  required int centralSize,
  required int centralOffset,
}) {
  return (BytesBuilder()
        ..add(_u32(0x06054b50))
        ..add(_u16(0))
        ..add(_u16(0))
        ..add(_u16(entries))
        ..add(_u16(entries))
        ..add(_u32(centralSize))
        ..add(_u32(centralOffset))
        ..add(_u16(0)))
      .toBytes();
}

List<int> _u16(int value) {
  return (ByteData(2)..setUint16(0, value, Endian.little)).buffer.asUint8List();
}

List<int> _u32(int value) {
  return (ByteData(4)..setUint32(0, value, Endian.little)).buffer.asUint8List();
}

List<int> _u64(int value) {
  return (ByteData(8)..setUint64(0, value, Endian.little)).buffer.asUint8List();
}

int _readU32(List<int> bytes, int offset) {
  return ByteData.sublistView(Uint8List.fromList(bytes), offset, offset + 4)
      .getUint32(0, Endian.little);
}

int _readU16(List<int> bytes, int offset) {
  return ByteData.sublistView(Uint8List.fromList(bytes), offset, offset + 2)
      .getUint16(0, Endian.little);
}

int _findSignature(List<int> bytes, int signature) {
  for (var offset = 0; offset <= bytes.length - 4; offset += 1) {
    if (_readU32(bytes, offset) == signature) {
      return offset;
    }
  }
  throw StateError("ZIP signature not found: $signature");
}

List<int> _withUint16(List<int> bytes, int offset, int value) {
  return List<int>.of(bytes)..setRange(offset, offset + 2, _u16(value));
}

List<int> _withUint32(List<int> bytes, int offset, int value) {
  return List<int>.of(bytes)..setRange(offset, offset + 4, _u32(value));
}
