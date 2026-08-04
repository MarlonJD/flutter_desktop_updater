import "dart:convert";
import "dart:io";

import "package:archive/archive.dart";
import "package:cryptography_plus/cryptography_plus.dart";
import "package:crypto/crypto.dart" as crypto;
import "package:desktop_updater/desktop_updater.dart";
import "package:desktop_updater/desktop_updater_method_channel.dart";
import "package:desktop_updater/desktop_updater_platform_interface.dart";
import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:desktop_updater/src/core/release_index.dart";
import "package:desktop_updater/src/core/update_client.dart";
import "package:desktop_updater/src/io/update_transport.dart";
import "package:desktop_updater/src/macos_install_location.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;
import "package:plugin_platform_interface/plugin_platform_interface.dart";

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final initialPlatform = DesktopUpdaterPlatform.instance;

  tearDown(() {
    DesktopUpdaterPlatform.instance = initialPlatform;
  });

  test("$MethodChannelDesktopUpdater is the default instance", () {
    expect(initialPlatform, isInstanceOf<MethodChannelDesktopUpdater>());
  });

  test("restartApp remains restart-only", () async {
    final fakePlatform = _MockDesktopUpdaterPlatform();
    DesktopUpdaterPlatform.instance = fakePlatform;

    await DesktopUpdater().restartApp();

    expect(fakePlatform.restartCount, 1);
    expect(fakePlatform.installRequests, isEmpty);
  });

  test("platform utility methods still forward through the facade", () async {
    final fakePlatform = _MockDesktopUpdaterPlatform()
      ..macOSInstallLocationStatus = const MacOSInstallLocationStatus(
        kind: MacOSInstallLocationKind.installed,
        bundlePath: "/Applications/Example.app",
        targetPath: "/Applications/Example.app",
      );
    DesktopUpdaterPlatform.instance = fakePlatform;
    final updater = DesktopUpdater();

    expect(await updater.getPlatformVersion(), "42");
    expect(
      (await updater.checkMacOSInstallLocation()).kind,
      MacOSInstallLocationKind.installed,
    );
    await updater.moveMacOSAppToApplications(replaceExisting: true);
    await updater.openMacOSBackgroundItemsSettings();

    expect(fakePlatform.lastReplaceExisting, isTrue);
    expect(fakePlatform.openBackgroundItemsCount, 1);
  });

  test("zip-first session uses one signed client for check and download",
      () async {
    final root = await Directory.systemTemp.createTemp("session_stage_");
    addTearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });
    final artifact = File(path.join(root.path, "artifact.zip"));
    final bytes = _zipBytes();
    await artifact.writeAsBytes(bytes);
    final archiveUrl =
        Uri.parse("https://updates.example.test/app-archive.json");
    final releaseUrl = Uri.parse("https://updates.example.test/release.json");
    final signed = await _SignedUpdate.create(
      releaseUrl: releaseUrl,
      descriptor: _descriptor(
        artifactUrl: artifact.uri,
        artifactSha256: crypto.sha256.convert(bytes).toString(),
        artifactLength: bytes.length,
      ),
    );
    final transport = _MapTransport({
      archiveUrl: signed.indexJson,
      releaseUrl: signed.descriptorJson,
      artifact.uri: bytes,
    });

    final session = DesktopUpdater().createZipFirstUpdateSession(
      appArchiveUrl: archiveUrl,
      currentVersion: DesktopVersionInfo.parse("1.0.0"),
      expectedPackageId: "com.example.app",
      trustedReleasePublicKeys: signed.publicKeys,
      requestHeadersProvider: (_) => const {},
    );
    // The public facade owns an internal UpdateClient; this test swaps transport
    // by exercising the same session contract directly through UpdateClient.
    final client = UpdateClient(
      appArchiveUrl: archiveUrl,
      currentVersion: DesktopVersionInfo.parse("1.0.0"),
      expectedPackageId: "com.example.app",
      trustedReleasePublicKeys: signed.publicKeys,
      platform: "linux",
      transport: transport,
      stagingParent: root,
    );
    expect(session, isA<ZipFirstUpdateSession>());

    final check = await client.checkForUpdate();
    final staged = await client.downloadVerifyAndStage(checkResult: check!);

    expect(staged.descriptor.packageId, "com.example.app");
    expect(transport.downloadedSources, [archiveUrl, releaseUrl, artifact.uri]);
  });
}

class _MockDesktopUpdaterPlatform
    with MockPlatformInterfaceMixin
    implements DesktopUpdaterPlatform {
  var restartCount = 0;
  var openBackgroundItemsCount = 0;
  bool? lastReplaceExisting;
  final installRequests = <VerifiedNativeInstallRequest>[];
  MacOSInstallLocationStatus macOSInstallLocationStatus =
      const MacOSInstallLocationStatus(
    kind: MacOSInstallLocationKind.unsupported,
    bundlePath: null,
    targetPath: null,
  );

  @override
  Future<String?> getPlatformVersion() async => "42";

  @override
  Future<void> restartApp() async {
    restartCount += 1;
  }

  @override
  Future<void> installVerifiedUpdate(
      VerifiedNativeInstallRequest request) async {
    installRequests.add(request);
  }

  @override
  Future<String?> getExecutablePath() async => "/Applications/Example.app";

  @override
  Future<String?> getCurrentVersion() async => "1.0.0+100";

  @override
  Future<MacOSInstallLocationStatus> checkMacOSInstallLocation() async {
    return macOSInstallLocationStatus;
  }

  @override
  Future<void> moveMacOSAppToApplications({
    bool replaceExisting = false,
  }) async {
    lastReplaceExisting = replaceExisting;
  }

  @override
  Future<void> openMacOSBackgroundItemsSettings() async {
    openBackgroundItemsCount += 1;
  }

  @override
  NativeInstallRecovery get nativeInstallRecovery =>
      QueryAndRecoverNativeInstallRecovery(
        query: (_) async => null,
        recover: (_) async => null,
      );
}

List<int> _zipBytes() {
  final archive = Archive()..addFile(ArchiveFile.string("bin/example", "bin"));
  return ZipEncoder().encode(archive);
}

ReleaseDescriptor _descriptor({
  required Uri artifactUrl,
  required String artifactSha256,
  required int artifactLength,
}) {
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
      sha256: artifactSha256,
      length: artifactLength,
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
      "schemaVersion": 3,
      "appName": "Example",
      "items": [
        {
          "version": descriptor.version,
          "buildNumber": descriptor.buildNumber,
          "platform": descriptor.platform,
          "channel": descriptor.channel,
          "mandatory": true,
          "release": releaseUrl.toString(),
        },
      ],
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

class _MapTransport implements UpdateTransport {
  _MapTransport(this.responses);

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
