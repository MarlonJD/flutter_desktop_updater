import "dart:convert";
import "dart:io";

import "package:cryptography_plus/cryptography_plus.dart";
import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:desktop_updater/src/core/release_signature_verifier.dart";
import "package:desktop_updater/src/release_cli/release_command.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;

void main() {
  test(
      "release sign reads private key from env and writes descriptor signature",
      () async {
    final fixture = await _createReleaseFile();
    try {
      final output = StringBuffer();

      final exitCode = await runReleaseCommand(
        [
          "sign",
          "--release",
          fixture.releaseFile.path,
          "--public-key-id",
          _publicKeyId,
          "--private-key-env",
          "DESKTOP_UPDATER_RELEASE_PRIVATE_KEY",
        ],
        projectRoot: fixture.root,
        output: output,
        environment: {
          "DESKTOP_UPDATER_RELEASE_PRIVATE_KEY": fixture.privateKey,
        },
      );

      expect(exitCode, 0);
      expect(output.toString(), contains("Signed release descriptor:"));
      expect(output.toString(), contains(fixture.releaseFile.path));
      expect(output.toString(), contains("Public key id:"));
      expect(output.toString(), contains(_publicKeyId));

      final descriptor = ReleaseDescriptor.fromJson(
        jsonDecode(await fixture.releaseFile.readAsString())
            as Map<String, dynamic>,
      );
      expect(descriptor.signature?.algorithm, "ed25519");
      expect(descriptor.signature?.publicKeyId, _publicKeyId);
      expect(descriptor.signature?.value, isNotEmpty);
      expect(
        await Ed25519ReleaseSignatureVerifier({
          _publicKeyId: fixture.publicKey,
        }).verify(descriptor),
        isTrue,
      );
    } finally {
      await fixture.delete();
    }
  });

  test("release sign reads private key from external file path", () async {
    final fixture = await _createReleaseFile();
    try {
      final keyFile = File(path.join(fixture.root.path, "release.key"))
        ..writeAsStringSync("${fixture.privateKey}\n");
      final output = StringBuffer();

      final exitCode = await runReleaseCommand(
        [
          "sign",
          "--release",
          fixture.releaseFile.path,
          "--public-key-id",
          _publicKeyId,
          "--private-key-file",
          keyFile.path,
        ],
        projectRoot: fixture.root,
        output: output,
      );

      expect(exitCode, 0);
      final descriptor = ReleaseDescriptor.fromJson(
        jsonDecode(await fixture.releaseFile.readAsString())
            as Map<String, dynamic>,
      );
      expect(
        await Ed25519ReleaseSignatureVerifier({
          _publicKeyId: fixture.publicKey,
        }).verify(descriptor),
        isTrue,
      );
    } finally {
      await fixture.delete();
    }
  });

  test("release sign requires env or external file key source", () async {
    final fixture = await _createReleaseFile();
    try {
      final output = StringBuffer();

      final exitCode = await runReleaseCommand(
        [
          "sign",
          "--release",
          fixture.releaseFile.path,
          "--public-key-id",
          _publicKeyId,
        ],
        projectRoot: fixture.root,
        output: output,
      );

      expect(exitCode, 64);
      expect(
        output.toString(),
        contains(
          "Provide exactly one of --private-key-env or --private-key-file.",
        ),
      );
    } finally {
      await fixture.delete();
    }
  });
}

const _publicKeyId = "stable-2026";
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

Future<_ReleaseSignFixture> _createReleaseFile() async {
  final root = await Directory.systemTemp.createTemp("release_sign_");
  final algorithm = Ed25519();
  final keyPair = await algorithm.newKeyPairFromSeed(_privateSeed);
  final publicKey = await keyPair.extractPublicKey();
  final releaseFile = File(path.join(root.path, "release.json"));
  await releaseFile.writeAsString(
    "${const JsonEncoder.withIndent("  ").convert(_descriptorJson())}\n",
  );
  return _ReleaseSignFixture(
    root: root,
    releaseFile: releaseFile,
    privateKey: base64Encode(_privateSeed),
    publicKey: base64Encode(publicKey.bytes),
  );
}

Map<String, dynamic> _descriptorJson() {
  return {
    "schemaVersion": 3,
    "packageId": "com.example.app",
    "appName": "Example.app",
    "version": "2.0.0",
    "buildNumber": 200,
    "platform": "macos",
    "channel": "stable",
    "artifact": {
      "kind": "zip",
      "url": "https://cdn.example.com/Example.zip",
      "sha256": "a" * 64,
      "length": 12,
    },
    "install": {"strategy": "wholeBundleReplace"},
    "minimumUpdaterVersion": "2.0.0",
    "generatedAt": "2026-06-11T00:00:00Z",
  };
}

class _ReleaseSignFixture {
  const _ReleaseSignFixture({
    required this.root,
    required this.releaseFile,
    required this.privateKey,
    required this.publicKey,
  });

  final Directory root;
  final File releaseFile;
  final String privateKey;
  final String publicKey;

  Future<void> delete() => root.delete(recursive: true);
}
