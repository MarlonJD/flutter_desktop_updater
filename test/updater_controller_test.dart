import "dart:convert";
import "dart:io";

import "package:archive/archive.dart";
import "package:cryptography_plus/cryptography_plus.dart";
import "package:crypto/crypto.dart" as crypto;
import "package:desktop_updater/desktop_updater_platform_interface.dart";
import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:desktop_updater/src/core/release_index.dart";
import "package:desktop_updater/src/core/update_recovery.dart";
import "package:desktop_updater/src/core/update_state.dart";
import "package:desktop_updater/src/macos_install_location.dart";
import "package:desktop_updater/updater_controller.dart";
import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;
import "package:plugin_platform_interface/plugin_platform_interface.dart";

const MethodChannel _desktopUpdaterChannel = MethodChannel("desktop_updater");

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final initialPlatform = DesktopUpdaterPlatform.instance;

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_desktopUpdaterChannel, (call) async {
      if (call.method == "getCurrentVersionInfo") {
        return <String, String?>{"version": "1.0.0", "buildNumber": "100"};
      }
      if (call.method == "getCurrentVersion") {
        return "100";
      }
      return null;
    });
  });

  tearDown(() {
    DesktopUpdaterPlatform.instance = initialPlatform;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_desktopUpdaterChannel, null);
  });

  test("constructor requires expected identity, keys, and store", () {
    expect(
      () => DesktopUpdaterController(
        appArchiveUrl: null,
        expectedPackageId: "",
        trustedReleasePublicKeys: _trustedPublicKeys,
        recoveryStore: _MemoryRecoveryStore(),
        skipInitialVersionCheck: true,
      ),
      throwsArgumentError,
    );
    expect(
      () => DesktopUpdaterController(
        appArchiveUrl: null,
        expectedPackageId: "com.example.app",
        trustedReleasePublicKeys: const {},
        recoveryStore: _MemoryRecoveryStore(),
        skipInitialVersionCheck: true,
      ),
      throwsFormatException,
    );
  });

  test("check and download use signed metadata and retain ready state",
      () async {
    final fixture = await _ControllerFixture.create();
    addTearDown(fixture.delete);
    final controller = DesktopUpdaterController(
      appArchiveUrl: fixture.archiveFile.uri,
      expectedPackageId: "com.example.app",
      trustedReleasePublicKeys: fixture.publicKeys,
      recoveryStore: _MemoryRecoveryStore(),
      skipInitialVersionCheck: true,
    );

    await controller.checkVersion();
    expect(controller.state, isA<UpdateAvailable>());

    await controller.downloadUpdate();
    expect(controller.state, isA<UpdateReadyToInstall>());
  });

  test("recovery write/readback mismatch blocks platform dispatch", () async {
    final fixture = await _ControllerFixture.create();
    addTearDown(fixture.delete);
    final platform = _RecordingPlatform();
    DesktopUpdaterPlatform.instance = platform;
    final store = _MemoryRecoveryStore(mutateReadback: true);
    final controller = DesktopUpdaterController(
      appArchiveUrl: fixture.archiveFile.uri,
      expectedPackageId: "com.example.app",
      trustedReleasePublicKeys: fixture.publicKeys,
      recoveryStore: store,
      skipInitialVersionCheck: true,
    );

    await controller.checkVersion();
    await controller.downloadUpdate();
    await expectLater(controller.restartApp(), throwsA(isA<StateError>()));

    expect(platform.installRequests, isEmpty);
  });

  test("valid persisted receipt dispatches exactly one verified request",
      () async {
    final fixture = await _ControllerFixture.create();
    addTearDown(fixture.delete);
    final platform = _RecordingPlatform();
    DesktopUpdaterPlatform.instance = platform;
    final controller = DesktopUpdaterController(
      appArchiveUrl: fixture.archiveFile.uri,
      expectedPackageId: "com.example.app",
      trustedReleasePublicKeys: fixture.publicKeys,
      recoveryStore: _MemoryRecoveryStore(),
      skipInitialVersionCheck: true,
    );

    await controller.checkVersion();
    await controller.downloadUpdate();
    await controller.restartApp();

    expect(platform.installRequests, hasLength(1));
    final request = platform.installRequests.single;
    expect(request.expectedPackageId, "com.example.app");
    expect(request.expectedArtifactSha256, fixture.artifactSha256);
    expect(request.stageProvenanceSha256, matches(RegExp(r"^[0-9a-f]{64}$")));
    expect(request.transactionId, matches(RegExp(r"^[0-9a-f-]{36}$")));
  });
}

class _RecordingPlatform
    with MockPlatformInterfaceMixin
    implements DesktopUpdaterPlatform {
  final installRequests = <VerifiedNativeInstallRequest>[];

  @override
  Future<String?> getPlatformVersion() async => "42";

  @override
  Future<void> restartApp() async {}

  @override
  Future<void> installVerifiedUpdate(
      VerifiedNativeInstallRequest request) async {
    installRequests.add(request);
  }

  @override
  Future<String?> getExecutablePath() async => null;

  @override
  Future<String?> getCurrentVersion() async => "100";

  @override
  Future<MacOSInstallLocationStatus> checkMacOSInstallLocation() async {
    return const MacOSInstallLocationStatus(
      kind: MacOSInstallLocationKind.unsupported,
      bundlePath: null,
      targetPath: null,
    );
  }

  @override
  Future<void> moveMacOSAppToApplications({
    bool replaceExisting = false,
  }) async {}

  @override
  Future<void> openMacOSBackgroundItemsSettings() async {}

  @override
  NativeInstallRecovery get nativeInstallRecovery =>
      QueryAndRecoverNativeInstallRecovery(
        query: (_) async => null,
        recover: (_) async => null,
      );
}

class _MemoryRecoveryStore implements UpdateRecoveryStore {
  _MemoryRecoveryStore({this.mutateReadback = false});

  final bool mutateReadback;
  final _markers = <String, UpdateInstallRecoveryMarker>{};

  @override
  Future<void> clearPendingInstall({required String channel}) async {
    _markers.remove(channel);
  }

  @override
  Future<UpdateInstallRecoveryMarker?> readPendingInstall({
    required String channel,
  }) async {
    final marker = _markers[channel];
    if (marker == null || !mutateReadback) {
      return marker;
    }
    return UpdateInstallRecoveryMarker.pendingV3(
      createdAt: marker.createdAt,
      packageVersion: marker.packageVersion,
      platform: marker.platform,
      channel: marker.channel,
      appVersion: marker.appVersion,
      updateVersion: marker.updateVersion!,
      updateBuildNumber: marker.updateBuildNumber,
      expectedPackageId: marker.expectedPackageId!,
      stagingPath: marker.stagingPath!,
      stageProvenanceSha256: "b" * 64,
      diagnosticsText: marker.diagnosticsText,
      transactionId: marker.transactionId!,
    );
  }

  @override
  Future<void> writePendingInstall(UpdateInstallRecoveryMarker marker) async {
    _markers[marker.channel] = marker;
  }
}

class _ControllerFixture {
  const _ControllerFixture({
    required this.root,
    required this.archiveFile,
    required this.publicKeys,
    required this.artifactSha256,
  });

  final Directory root;
  final File archiveFile;
  final Map<String, String> publicKeys;
  final String artifactSha256;

  static Future<_ControllerFixture> create() async {
    final root = await Directory.systemTemp.createTemp("controller_update_");
    final artifact = File(path.join(root.path, "artifact.zip"));
    final bytes = _zipBytes();
    await artifact.writeAsBytes(bytes);
    final artifactSha256 = crypto.sha256.convert(bytes).toString();
    final releaseFile = File(path.join(root.path, "release.json"));
    final archiveFile = File(path.join(root.path, "app-archive.json"));
    final descriptor = _descriptor(
      artifactUrl: artifact.uri,
      artifactSha256: artifactSha256,
      artifactLength: bytes.length,
    );
    final signed = await _SignedUpdate.create(
      releaseUrl: releaseFile.uri,
      descriptor: descriptor,
    );
    await releaseFile.writeAsString(signed.descriptorJson);
    await archiveFile.writeAsString(signed.indexJson);
    return _ControllerFixture(
      root: root,
      archiveFile: archiveFile,
      publicKeys: signed.publicKeys,
      artifactSha256: artifactSha256,
    );
  }

  Future<void> delete() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  }
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
    appName: "bin",
    version: "2.0.0",
    buildNumber: 200,
    platform: Platform.operatingSystem,
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

final _trustedPublicKeys = {
  _publicKeyId: "A6EHv/POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg=",
};

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
