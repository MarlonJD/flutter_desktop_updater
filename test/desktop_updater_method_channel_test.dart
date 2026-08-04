import "dart:convert";
import "dart:io";

import "package:archive/archive.dart";
import "package:cryptography_plus/cryptography_plus.dart";
import "package:crypto/crypto.dart" as crypto;
import "package:desktop_updater/desktop_updater_method_channel.dart";
import "package:desktop_updater/desktop_updater_platform_interface.dart";
import "package:desktop_updater/src/core/install_handoff.dart";
import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:desktop_updater/src/core/release_index.dart";
import "package:desktop_updater/src/core/update_client.dart";
import "package:desktop_updater/src/core/update_recovery.dart";
import "package:desktop_updater/src/io/update_transport.dart";
import "package:desktop_updater/src/macos_install_location.dart";
import "package:desktop_updater/src/version_info.dart";
import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final platform = MethodChannelDesktopUpdater();
  const channel = MethodChannel("desktop_updater");

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      return "42";
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test("getPlatformVersion", () async {
    expect(await platform.getPlatformVersion(), "42");
  });

  test("getCurrentVersion keeps returning the legacy build string", () async {
    expect(await platform.getCurrentVersion(), "42");
  });

  test("openMacOSBackgroundItemsSettings forwards the native action", () async {
    late MethodCall capturedCall;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      capturedCall = methodCall;
      return null;
    });

    await platform.openMacOSBackgroundItemsSettings();

    expect(capturedCall.method, "openMacOSBackgroundItemsSettings");
    expect(capturedCall.arguments, isNull);
  });

  test("getCurrentVersionInfo returns structured version data separately",
      () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      if (methodCall.method == "getCurrentVersionInfo") {
        return <String, String?>{
          "version": "1.2.3",
          "buildNumber": null,
        };
      }
      return "42";
    });

    expect(await platform.getCurrentVersionInfo(), {
      "version": "1.2.3",
      "buildNumber": null,
    });
  });

  test("installVerifiedUpdate sends the complete descriptor-bound payload",
      () async {
    late MethodCall capturedCall;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      capturedCall = methodCall;
      return null;
    });

    final root = await Directory.systemTemp.createTemp("channel_stage_");
    addTearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });
    final artifact = File(path.join(root.path, "artifact.zip"));
    final bytes = _zipBytes();
    await artifact.writeAsBytes(bytes);
    final releaseUrl = Uri.parse("https://updates.example.test/release.json");
    final signed = await _SignedUpdate.create(
      releaseUrl: releaseUrl,
      descriptor: _descriptor(
        artifactUrl: artifact.uri,
        artifactSha256: crypto.sha256.convert(bytes).toString(),
        artifactLength: bytes.length,
      ),
    );
    final client = UpdateClient(
      appArchiveUrl: Uri.parse("https://updates.example.test/app-archive.json"),
      currentVersion: DesktopVersionInfo.parse("1.0.0"),
      expectedPackageId: "com.example.app",
      trustedReleasePublicKeys: signed.publicKeys,
      platform: "linux",
      stagingParent: root,
      transport: _MapTransport({
        Uri.parse("https://updates.example.test/app-archive.json"):
            signed.indexJson,
        releaseUrl: signed.descriptorJson,
        artifact.uri: bytes,
      }),
    );
    final check = await client.checkForUpdate();
    final staged = await client.downloadVerifyAndStage(checkResult: check!);
    final marker = UpdateInstallRecoveryMarker.pendingV3(
      createdAt: DateTime.utc(2026, 8, 3, 12),
      packageVersion: "3.0.0",
      platform: "linux",
      channel: "stable",
      appVersion: "1.0.0+100",
      updateVersion: staged.descriptor.version,
      updateBuildNumber: staged.descriptor.buildNumber,
      expectedPackageId: "com.example.app",
      stagingPath: staged.stagingPath,
      stageProvenanceSha256: staged.stageProvenanceSha256,
      diagnosticsText: "redacted",
      transactionId: "123e4567-e89b-42d3-a456-426614174000",
    );
    final request = await verifiedNativeInstallRequestFromStage(
      session: client,
      stageResult: staged,
      receipt: persistedInstallTransactionFromExactReadback(
        written: marker,
        readback: marker,
      ),
    );

    await platform.installVerifiedUpdate(request);

    expect(capturedCall.method, "installUpdate");
    expect(capturedCall.arguments, {
      "stagingPath": staged.stagingPath,
      "expectedPackageId": "com.example.app",
      "updateVersion": "2.0.0",
      "updateBuildNumber": "200",
      "platform": "linux",
      "channel": "stable",
      "expectedArtifactSha256": staged.descriptor.artifact.sha256,
      "stageProvenanceSha256": staged.stageProvenanceSha256,
      "transactionId": "123e4567-e89b-42d3-a456-426614174000",
    });
  });

  test("checkMacOSInstallLocation parses native status", () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      if (methodCall.method == "checkMacOSInstallLocation") {
        return {
          "kind": "diskImage",
          "bundlePath": "/Volumes/Example/Example.app",
          "targetPath": "/Applications/Example.app",
        };
      }
      return "42";
    });

    final status = await platform.checkMacOSInstallLocation();

    expect(status.kind, MacOSInstallLocationKind.diskImage);
    expect(status.targetPath, "/Applications/Example.app");
  });

  test("moveMacOSAppToApplications forwards replace policy", () async {
    late MethodCall capturedCall;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      capturedCall = methodCall;
      return null;
    });

    await platform.moveMacOSAppToApplications(replaceExisting: true);

    expect(capturedCall.method, "moveMacOSAppToApplications");
    expect(capturedCall.arguments, {"replaceExisting": true});
  });

  test("queryInstallTransaction forwards ID and parses helper status",
      () async {
    late MethodCall capturedCall;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      capturedCall = methodCall;
      return {
        "transactionId": "123e4567-e89b-42d3-a456-426614174000",
        "state": "completed",
        "resultCode": "succeeded",
        "detail": "Install completed.",
        "responseDigestSha256": "a" * 64,
        "helperEndpointIdentitySha256": "b" * 64,
      };
    });

    final status = await platform.queryInstallTransaction(
      "123e4567-e89b-42d3-a456-426614174000",
    );

    expect(capturedCall.method, "queryInstallTransaction");
    expect(capturedCall.arguments, {
      "transactionId": "123e4567-e89b-42d3-a456-426614174000",
    });
    expect(status.state, NativeInstallTransactionState.completed);
  });

  test("recoverPendingInstallTransaction uses compatible map shape", () async {
    late MethodCall capturedCall;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      capturedCall = methodCall;
      return {
        "transactionId": "123e4567-e89b-42d3-a456-426614174000",
        "state": "rolledBack",
        "resultCode": "rejected",
        "detail": "Rollback completed.",
        "responseDigestSha256": "a" * 64,
        "helperEndpointIdentitySha256": "b" * 64,
      };
    });

    final status = await platform.recoverPendingInstallTransaction(
      "123e4567-e89b-42d3-a456-426614174000",
    );

    expect(capturedCall.method, "recoverPendingInstallTransaction");
    expect(status.state, NativeInstallTransactionState.rolledBack);
  });

  test("resolvePendingInstallTransactionAfterExit uses one status exchange",
      () async {
    late MethodCall capturedCall;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      capturedCall = methodCall;
      return {
        "transactionId": "123e4567-e89b-42d3-a456-426614174000",
        "state": "prepared",
        "resultCode": "recoveryRequired",
        "detail": "Caller exit required.",
        "responseDigestSha256": "a" * 64,
        "helperEndpointIdentitySha256": "b" * 64,
      };
    });

    final status = await platform.resolvePendingInstallTransactionAfterExit(
      "123e4567-e89b-42d3-a456-426614174000",
    );

    expect(
      capturedCall.method,
      "resolvePendingInstallTransactionAfterExit",
    );
    expect(capturedCall.arguments, {
      "transactionId": "123e4567-e89b-42d3-a456-426614174000",
    });
    expect(status.requiresRecovery, isTrue);
  });

  test("transaction status rejects a changed transaction binding", () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async {
      return {
        "transactionId": "123e4567-e89b-42d3-a456-426614174001",
        "state": "completed",
        "resultCode": "succeeded",
        "detail": "Wrong transaction.",
        "responseDigestSha256": "a" * 64,
        "helperEndpointIdentitySha256": "b" * 64,
      };
    });

    await expectLater(
      platform.queryInstallTransaction(
        "123e4567-e89b-42d3-a456-426614174000",
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          "message",
          contains("transaction binding"),
        ),
      ),
    );
  });
}

List<int> _zipBytes() {
  final archive = Archive()
    ..addFile(ArchiveFile.string("bin/example", "binary"));
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

  @override
  Future<void> download(
    Uri source,
    File destination, {
    void Function(int receivedBytes, int? totalBytes)? onProgress,
    Duration? timeout,
  }) async {
    final response = responses[source];
    if (response == null) {
      throw StateError("No fake response for $source.");
    }
    await destination.parent.create(recursive: true);
    final bytes =
        response is String ? utf8.encode(response) : response as List<int>;
    await destination.writeAsBytes(bytes);
    onProgress?.call(bytes.length, bytes.length);
  }
}
