import "dart:convert";
import "dart:io";

import "package:archive/archive.dart";
import "package:crypto/crypto.dart" as crypto;
import "package:cryptography_plus/cryptography_plus.dart";
import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:desktop_updater/src/core/release_index.dart";
import "package:desktop_updater/src/core/staged_update_provenance.dart";
import "package:desktop_updater/src/core/update_client.dart";
import "package:desktop_updater/src/io/update_transport.dart";
import "package:desktop_updater/src/version_info.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;

void main() {
  test("requires expected package identity and strict trusted keys", () {
    final archiveUrl =
        Uri.parse("https://updates.example.com/app-archive.json");
    final currentVersion = DesktopVersionInfo.parse("1.0.0");

    expect(
      () => UpdateClient(
        appArchiveUrl: archiveUrl,
        currentVersion: currentVersion,
        expectedPackageId: "",
        trustedReleasePublicKeys: const {
          "release-2026": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
        },
      ),
      throwsArgumentError,
    );
    expect(
      () => UpdateClient(
        appArchiveUrl: archiveUrl,
        currentVersion: currentVersion,
        expectedPackageId: "com.example.app",
        trustedReleasePublicKeys: const {},
      ),
      throwsFormatException,
    );
    expect(
      () => UpdateClient(
        appArchiveUrl: archiveUrl,
        currentVersion: currentVersion,
        expectedPackageId: "com.example.app",
        trustedReleasePublicKeys: const {
          " release-2026 ": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
          "release-2026": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
        },
      ),
      throwsFormatException,
    );
  });

  test("unsigned archive fails before descriptor or artifact request",
      () async {
    final archiveUrl =
        Uri.parse("https://updates.example.com/app-archive.json");
    final releaseUrl = Uri.parse("https://updates.example.com/release.json");
    final artifactUrl = Uri.parse("https://updates.example.com/artifact.zip");
    final transport = _MapUpdateTransport({
      archiveUrl: jsonEncode(_indexJson(releaseUrl)),
      releaseUrl: jsonEncode(_descriptorJson(artifactUrl: artifactUrl)),
      artifactUrl: "artifact bytes",
    });
    final client = UpdateClient(
      appArchiveUrl: archiveUrl,
      currentVersion: DesktopVersionInfo.parse("1.0.0"),
      expectedPackageId: "com.example.app",
      trustedReleasePublicKeys: const {
        "release-2026": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
      },
      platform: "linux",
      transport: transport,
    );

    await expectLater(
      client.checkForUpdate(),
      throwsA(isA<FormatException>()),
    );
    expect(transport.downloadedSources, [archiveUrl]);
  });

  test("descriptor package mismatch fails before artifact request", () async {
    final archiveUrl =
        Uri.parse("https://updates.example.com/app-archive.json");
    final releaseUrl = Uri.parse("https://updates.example.com/release.json");
    final artifactUrl = Uri.parse("https://updates.example.com/artifact.zip");
    final signed = await _SignedUpdate.create(
      releaseUrl: releaseUrl,
      descriptor: _descriptor(
        artifactUrl: artifactUrl,
        packageId: "com.other.app",
      ),
    );
    final transport = _MapUpdateTransport({
      archiveUrl: signed.indexJson,
      releaseUrl: signed.descriptorJson,
      artifactUrl: "artifact bytes",
    });
    final client = UpdateClient(
      appArchiveUrl: archiveUrl,
      currentVersion: DesktopVersionInfo.parse("1.0.0"),
      expectedPackageId: "com.example.app",
      trustedReleasePublicKeys: signed.publicKeys,
      platform: "linux",
      transport: transport,
    );

    await expectLater(
      client.checkForUpdate(),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          "message",
          contains("packageId does not match expected package identity"),
        ),
      ),
    );
    expect(transport.downloadedSources, [archiveUrl, releaseUrl]);
  });

  test("unknown index signing key fails before descriptor or artifact request",
      () async {
    final archiveUrl =
        Uri.parse("https://updates.example.com/app-archive.json");
    final releaseUrl = Uri.parse("https://updates.example.com/release.json");
    final artifactUrl = Uri.parse("https://updates.example.com/artifact.zip");
    final signed = await _SignedUpdate.create(
      releaseUrl: releaseUrl,
      descriptor: _descriptor(artifactUrl: artifactUrl),
    );
    final index = jsonDecode(signed.indexJson) as Map<String, dynamic>;
    index["signature"] = {
      ...(index["signature"] as Map<String, dynamic>),
      "publicKeyId": "unknown-key",
    };
    final transport = _MapUpdateTransport({
      archiveUrl: jsonEncode(index),
      releaseUrl: signed.descriptorJson,
      artifactUrl: "artifact bytes",
    });
    final client = UpdateClient(
      appArchiveUrl: archiveUrl,
      currentVersion: DesktopVersionInfo.parse("1.0.0"),
      expectedPackageId: "com.example.app",
      trustedReleasePublicKeys: signed.publicKeys,
      platform: "linux",
      transport: transport,
    );

    await expectLater(client.checkForUpdate(), throwsFormatException);
    expect(transport.downloadedSources, [archiveUrl]);
  });

  test("invalid index signature fails before descriptor or artifact request",
      () async {
    final archiveUrl =
        Uri.parse("https://updates.example.com/app-archive.json");
    final releaseUrl = Uri.parse("https://updates.example.com/release.json");
    final artifactUrl = Uri.parse("https://updates.example.com/artifact.zip");
    final signed = await _SignedUpdate.create(
      releaseUrl: releaseUrl,
      descriptor: _descriptor(artifactUrl: artifactUrl),
    );
    final index = jsonDecode(signed.indexJson) as Map<String, dynamic>;
    index["signature"] = {
      ...(index["signature"] as Map<String, dynamic>),
      "value": base64Encode(List<int>.filled(64, 0)),
    };
    final transport = _MapUpdateTransport({
      archiveUrl: jsonEncode(index),
      releaseUrl: signed.descriptorJson,
      artifactUrl: "artifact bytes",
    });
    final client = UpdateClient(
      appArchiveUrl: archiveUrl,
      currentVersion: DesktopVersionInfo.parse("1.0.0"),
      expectedPackageId: "com.example.app",
      trustedReleasePublicKeys: signed.publicKeys,
      platform: "linux",
      transport: transport,
    );

    await expectLater(client.checkForUpdate(), throwsFormatException);
    expect(transport.downloadedSources, [archiveUrl]);
  });

  test("download consumes only the owning library-issued check result",
      () async {
    final root = await Directory.systemTemp.createTemp("owned_stage_");
    addTearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });
    final artifact = File(path.join(root.path, "artifact.zip"));
    final bytes = _zipBytes();
    await artifact.writeAsBytes(bytes);
    final archiveUrl =
        Uri.parse("https://updates.example.com/app-archive.json");
    final releaseUrl = Uri.parse("https://updates.example.com/release.json");
    final signed = await _SignedUpdate.create(
      releaseUrl: releaseUrl,
      descriptor: _descriptor(
        artifactUrl: artifact.uri,
        artifactSha256: crypto.sha256.convert(bytes).toString(),
        artifactLength: bytes.length,
      ),
    );
    final client = UpdateClient(
      appArchiveUrl: archiveUrl,
      currentVersion: DesktopVersionInfo.parse("1.0.0"),
      expectedPackageId: "com.example.app",
      trustedReleasePublicKeys: signed.publicKeys,
      platform: "linux",
      transport: _MapUpdateTransport({
        archiveUrl: signed.indexJson,
        releaseUrl: signed.descriptorJson,
        artifact.uri: bytes,
      }),
      stagingParent: root,
    );
    final foreignClient = UpdateClient(
      appArchiveUrl: archiveUrl,
      currentVersion: DesktopVersionInfo.parse("1.0.0"),
      expectedPackageId: "com.example.app",
      trustedReleasePublicKeys: signed.publicKeys,
      platform: "linux",
      transport: _MapUpdateTransport({
        archiveUrl: signed.indexJson,
        releaseUrl: signed.descriptorJson,
        artifact.uri: bytes,
      }),
      stagingParent: root,
    );

    final check = await client.checkForUpdate();
    expect(check, isNotNull);

    await expectLater(
      foreignClient.downloadVerifyAndStage(checkResult: check!),
      throwsStateError,
    );
    final freshCheck = await client.checkForUpdate();
    final staged = await client.downloadVerifyAndStage(
      checkResult: freshCheck!,
    );
    expect(staged.descriptor.packageId, "com.example.app");
    expect(staged.stageProvenanceSha256, matches(RegExp(r"^[0-9a-f]{64}$")));
    final provenance = await verifyStagedUpdateProvenance(
      stageRoot: Directory(staged.stagingPath),
      expectedMarkerSha256: staged.stageProvenanceSha256,
    );
    expect(provenance.packageId, "com.example.app");

    await expectLater(
      client.downloadVerifyAndStage(checkResult: freshCheck),
      throwsStateError,
    );
  });

  test(
      "download rejects check result from differently configured foreign "
      "client before artifact request", () async {
    final root = await Directory.systemTemp.createTemp("foreign_config_");
    addTearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });
    final artifact = File(path.join(root.path, "artifact.zip"));
    final bytes = _zipBytes();
    await artifact.writeAsBytes(bytes);
    final archiveUrl =
        Uri.parse("https://updates.example.com/app-archive.json");
    final releaseUrl = Uri.parse("https://updates.example.com/release.json");
    final signed = await _SignedUpdate.create(
      releaseUrl: releaseUrl,
      descriptor: _descriptor(
        artifactUrl: artifact.uri,
        artifactSha256: crypto.sha256.convert(bytes).toString(),
        artifactLength: bytes.length,
      ),
    );
    final ownerTransport = _MapUpdateTransport({
      archiveUrl: signed.indexJson,
      releaseUrl: signed.descriptorJson,
      artifact.uri: bytes,
    });
    final foreignTransport = _MapUpdateTransport({
      archiveUrl: signed.indexJson,
      releaseUrl: signed.descriptorJson,
      artifact.uri: bytes,
    });
    final client = UpdateClient(
      appArchiveUrl: archiveUrl,
      currentVersion: DesktopVersionInfo.parse("1.0.0"),
      expectedPackageId: "com.example.app",
      trustedReleasePublicKeys: signed.publicKeys,
      platform: "linux",
      channel: "stable",
      transport: ownerTransport,
      stagingParent: root,
    );
    final foreignClient = UpdateClient(
      appArchiveUrl: archiveUrl,
      currentVersion: DesktopVersionInfo.parse("1.0.0"),
      expectedPackageId: "com.other.app",
      trustedReleasePublicKeys: signed.publicKeys,
      platform: "linux",
      channel: "beta",
      transport: foreignTransport,
      stagingParent: root,
    );

    final check = await client.checkForUpdate();
    expect(check, isNotNull);

    await expectLater(
      foreignClient.downloadVerifyAndStage(checkResult: check!),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          "message",
          contains("different UpdateClient"),
        ),
      ),
    );
    expect(ownerTransport.downloadedSources, [archiveUrl, releaseUrl]);
    expect(foreignTransport.downloadedSources, isEmpty);
  });

  test("mutated descriptor/index binding fails before artifact request",
      () async {
    final archiveUrl =
        Uri.parse("https://updates.example.com/app-archive.json");
    final releaseUrl = Uri.parse("https://updates.example.com/release.json");
    final artifactUrl = Uri.parse("https://updates.example.com/artifact.zip");
    final signed = await _SignedUpdate.create(
      releaseUrl: releaseUrl,
      descriptor: _descriptor(
        artifactUrl: artifactUrl,
        buildNumber: 201,
      ),
    );
    final transport = _MapUpdateTransport({
      archiveUrl: signed.indexJson,
      releaseUrl: signed.descriptorJson,
      artifactUrl: "artifact bytes",
    });
    final client = UpdateClient(
      appArchiveUrl: archiveUrl,
      currentVersion: DesktopVersionInfo.parse("1.0.0"),
      expectedPackageId: "com.example.app",
      trustedReleasePublicKeys: signed.publicKeys,
      platform: "linux",
      transport: transport,
    );

    await expectLater(
      client.checkForUpdate(),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          "message",
          contains("buildNumber does not match app-archive.json"),
        ),
      ),
    );
    expect(transport.downloadedSources, [archiveUrl, releaseUrl]);
  });

  test("concurrent check results leave only the latest generation usable",
      () async {
    final root = await Directory.systemTemp.createTemp("concurrent_stage_");
    addTearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });
    final artifact = File(path.join(root.path, "artifact.zip"));
    final bytes = _zipBytes();
    await artifact.writeAsBytes(bytes);
    final archiveUrl =
        Uri.parse("https://updates.example.com/app-archive.json");
    final releaseUrl = Uri.parse("https://updates.example.com/release.json");
    final signed = await _SignedUpdate.create(
      releaseUrl: releaseUrl,
      descriptor: _descriptor(
        artifactUrl: artifact.uri,
        artifactSha256: crypto.sha256.convert(bytes).toString(),
        artifactLength: bytes.length,
      ),
    );
    final client = UpdateClient(
      appArchiveUrl: archiveUrl,
      currentVersion: DesktopVersionInfo.parse("1.0.0"),
      expectedPackageId: "com.example.app",
      trustedReleasePublicKeys: signed.publicKeys,
      platform: "linux",
      transport: _MapUpdateTransport({
        archiveUrl: signed.indexJson,
        releaseUrl: signed.descriptorJson,
        artifact.uri: bytes,
      }),
      stagingParent: root,
    );

    final checks = await Future.wait([
      client.checkForUpdate(),
      client.checkForUpdate(),
    ]);

    await expectLater(
      client.downloadVerifyAndStage(checkResult: checks.first!),
      throwsStateError,
    );
    final staged = await client.downloadVerifyAndStage(
      checkResult: checks.last!,
    );
    expect(staged.descriptor.packageId, "com.example.app");
  });
}

List<int> _zipBytes() {
  final archive = Archive()..addFile(ArchiveFile.string("bin/example", "bin"));
  return ZipEncoder().encode(archive);
}

Map<String, dynamic> _indexJson(Uri releaseUrl) {
  return {
    "schemaVersion": 3,
    "appName": "Example",
    "items": [
      {
        "version": "2.0.0",
        "buildNumber": 200,
        "platform": "linux",
        "channel": "stable",
        "mandatory": true,
        "release": releaseUrl.toString(),
      },
    ],
  };
}

Map<String, dynamic> _descriptorJson({
  required Uri artifactUrl,
  String packageId = "com.example.app",
  String? artifactSha256,
  int? artifactLength,
}) {
  return _descriptor(
    artifactUrl: artifactUrl,
    packageId: packageId,
    artifactSha256: artifactSha256,
    artifactLength: artifactLength,
  ).toJson();
}

ReleaseDescriptor _descriptor({
  required Uri artifactUrl,
  String packageId = "com.example.app",
  String version = "2.0.0",
  int buildNumber = 200,
  String platform = "linux",
  String channel = "stable",
  String? artifactSha256,
  int? artifactLength,
}) {
  return ReleaseDescriptor(
    schemaVersion: 3,
    packageId: packageId,
    appName: "Example",
    version: version,
    buildNumber: buildNumber,
    platform: platform,
    channel: channel,
    artifact: ReleaseArtifact(
      kind: "zip",
      url: artifactUrl,
      sha256: artifactSha256 ?? "a" * 64,
      length: artifactLength ?? 12,
    ),
    install: const ReleaseInstall(strategy: "wholeBundleReplace"),
    minimumUpdaterVersion: "2.0.0",
    generatedAt: DateTime.utc(2026, 8, 3),
  );
}

const _publicKeyId = "release-2026";
const _privateSeed = <int>[
  0,
  1,
  2,
  3,
  4,
  5,
  6,
  7,
  8,
  9,
  10,
  11,
  12,
  13,
  14,
  15,
  16,
  17,
  18,
  19,
  20,
  21,
  22,
  23,
  24,
  25,
  26,
  27,
  28,
  29,
  30,
  31,
];

class _SignedUpdate {
  const _SignedUpdate({
    required this.indexJson,
    required this.descriptorJson,
    required this.publicKeys,
  });

  final String indexJson;
  final String descriptorJson;
  final Map<String, String> publicKeys;

  static Future<_SignedUpdate> create({
    required Uri releaseUrl,
    required ReleaseDescriptor descriptor,
  }) async {
    final algorithm = Ed25519();
    final keyPair = await algorithm.newKeyPairFromSeed(_privateSeed);
    final publicKey = await keyPair.extractPublicKey();
    final descriptorToSign = ReleaseDescriptor.fromJson({
      ...descriptor.toJson(),
      "signature": {
        "algorithm": "ed25519",
        "publicKeyId": _publicKeyId,
        "value": "",
      },
    });
    final descriptorSignature = await algorithm.sign(
      descriptorToSign.canonicalSignatureBytes(),
      keyPair: keyPair,
    );
    final signedDescriptor = ReleaseDescriptor.fromJson({
      ...descriptor.toJson(),
      "signature": {
        "algorithm": "ed25519",
        "publicKeyId": _publicKeyId,
        "value": base64Encode(descriptorSignature.bytes),
      },
    });
    final indexToSign = ReleaseIndex.fromJson({
      ..._indexJson(releaseUrl),
      "signature": {
        "algorithm": "ed25519",
        "publicKeyId": _publicKeyId,
        "value": "",
      },
    });
    final indexSignature = await algorithm.sign(
      indexToSign.canonicalSignatureBytes(),
      keyPair: keyPair,
    );
    final signedIndex = ReleaseIndex.fromJson({
      ...indexToSign.toJson(),
      "signature": {
        "algorithm": "ed25519",
        "publicKeyId": _publicKeyId,
        "value": base64Encode(indexSignature.bytes),
      },
    });
    return _SignedUpdate(
      indexJson: jsonEncode(signedIndex.toJson()),
      descriptorJson: jsonEncode(signedDescriptor.toJson()),
      publicKeys: {_publicKeyId: base64Encode(publicKey.bytes)},
    );
  }
}

class _MapUpdateTransport implements UpdateTransport {
  _MapUpdateTransport(this.responses);

  final Map<Uri, Object> responses;
  final List<Uri> downloadedSources = [];

  @override
  Future<void> download(
    Uri source,
    File destination, {
    void Function(int receivedBytes, int? totalBytes)? onProgress,
    Duration? timeout,
  }) async {
    downloadedSources.add(source);
    final response = responses[source];
    if (response == null) {
      throw StateError("No fake response for $source.");
    }
    final bytes =
        response is String ? utf8.encode(response) : response as List<int>;
    await destination.parent.create(recursive: true);
    await destination.writeAsBytes(bytes);
    onProgress?.call(bytes.length, bytes.length);
  }
}
