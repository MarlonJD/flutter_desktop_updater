import "dart:convert";
import "dart:io";

import "package:cryptography_plus/cryptography_plus.dart";
import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:desktop_updater/src/core/release_index.dart";
import "package:desktop_updater/src/core/release_index_signature_verifier.dart";
import "package:desktop_updater/src/core/release_signature_verifier.dart";
import "package:desktop_updater/src/release_cli/keys/release_key_profile.dart";
import "package:desktop_updater/src/release_cli/keys/release_key_store.dart";
import "package:desktop_updater/src/release_cli/release_command.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;

void main() {
  test("release sign reads the feed-bound profile and signs a descriptor",
      () async {
    final fixture = await _createReleaseFile();
    try {
      final output = StringBuffer();

      final exitCode = await runReleaseCommand(
        [
          "sign",
          "--release",
          fixture.releaseFile.path,
          "--key-profile",
          fixture.profileFile.path,
        ],
        projectRoot: fixture.root,
        output: output,
        keyStore: fixture.keyStore,
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

  test("release sign signs the final app archive with the profile key",
      () async {
    final fixture = await _createReleaseFile();
    try {
      final output = StringBuffer();

      final exitCode = await runReleaseCommand(
        [
          "sign",
          "--release",
          fixture.releaseFile.path,
          "--app-archive",
          fixture.appArchiveFile.path,
        ],
        projectRoot: fixture.root,
        output: output,
        keyStore: fixture.keyStore,
      );

      expect(exitCode, 0);
      expect(output.toString(), contains("Signed app archive:"));
      final index = ReleaseIndex.fromJson(
        jsonDecode(await fixture.appArchiveFile.readAsString())
            as Map<String, dynamic>,
      );
      expect(index.signature?.publicKeyId, _publicKeyId);
      expect(
        await Ed25519ReleaseIndexSignatureVerifier({
          _publicKeyId: fixture.publicKey,
        }).verify(index),
        isTrue,
      );
    } finally {
      await fixture.delete();
    }
  });

  test("release sign reports the migration path when the profile is missing",
      () async {
    final fixture = await _createReleaseFile();
    try {
      await fixture.profileFile.delete();
      final output = StringBuffer();

      final exitCode = await runReleaseCommand(
        ["sign", "--release", fixture.releaseFile.path],
        projectRoot: fixture.root,
        output: output,
        keyStore: fixture.keyStore,
      );

      expect(exitCode, 64);
      expect(output.toString(), contains("release key profile"));
      expect(output.toString(), contains("release keys adopt --input"));
      expect(output.toString(), contains("must be deleted"));
    } finally {
      await fixture.delete();
    }
  });

  test("release sign rejects removed direct signing options", () async {
    final fixture = await _createReleaseFile();
    try {
      for (final option in const [
        "--public-key-id",
        "--private-key-env",
        "--private-key-file",
      ]) {
        final output = StringBuffer();
        final exitCode = await runReleaseCommand(
          [
            "sign",
            "--release",
            fixture.releaseFile.path,
            option,
            "value",
          ],
          projectRoot: fixture.root,
          output: output,
          keyStore: fixture.keyStore,
        );

        expect(exitCode, 64);
        expect(output.toString(), contains("Could not find an option named"));
      }
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
  final appArchiveFile = File(path.join(root.path, "app-archive.json"));
  await appArchiveFile.writeAsString(
    "${const JsonEncoder.withIndent("  ").convert({
          "schemaVersion": 3,
          "appName": "Example",
          "items": [
            {
              "version": "2.0.0",
              "buildNumber": 200,
              "platform": "macos",
              "channel": "stable",
              "mandatory": true,
              "release": "https://cdn.example.com/release.json",
            },
          ],
        })}\n",
  );
  await File(path.join(root.path, "desktop_updater.yaml")).writeAsString(
    "updates:\n  baseUrl: https://cdn.example.com\n",
  );
  final profileFile = File(path.join(root.path, "desktop_updater.keys.json"));
  const profileId = "0123456789abcdef0123456789abcdef";
  await writeReleaseKeyProfile(
    profileFile,
    ReleaseKeyProfile(
      profileId: profileId,
      feedUrl: "https://cdn.example.com/app-archive.json",
      activeKeyId: _publicKeyId,
      pendingKeyId: null,
      publicKeys: {_publicKeyId: base64Encode(publicKey.bytes)},
    ),
  );
  final keyStore = LocalFileReleaseKeyStore(
    rootDirectory: Directory(path.join(root.path, ".release-key-store")),
  );
  await keyStore.write(
    profileId: profileId,
    keyId: _publicKeyId,
    seed: _privateSeed,
  );
  return _ReleaseSignFixture(
    root: root,
    releaseFile: releaseFile,
    appArchiveFile: appArchiveFile,
    profileFile: profileFile,
    keyStore: keyStore,
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
    required this.appArchiveFile,
    required this.profileFile,
    required this.keyStore,
    required this.publicKey,
  });

  final Directory root;
  final File releaseFile;
  final File appArchiveFile;
  final File profileFile;
  final ReleaseKeySecretStore keyStore;
  final String publicKey;

  Future<void> delete() => root.delete(recursive: true);
}
