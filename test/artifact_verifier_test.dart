import "dart:convert";
import "dart:io";

import "package:crypto/crypto.dart" as crypto;
import "package:cryptography_plus/cryptography_plus.dart";
import "package:desktop_updater/src/core/artifact_verifier.dart";
import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  test("length mismatch fails before extraction", () async {
    final tempDir = await Directory.systemTemp.createTemp("artifact_test_");
    try {
      final file = File("${tempDir.path}/artifact.zip")
        ..writeAsStringSync("hello");
      final artifact = _artifact(length: 6, sha256: _sha256("hello"));

      await expectLater(
        const ArtifactVerifier().verifyArtifactFile(
          artifact: artifact,
          file: file,
        ),
        throwsA(isA<FileSystemException>()),
      );
    } finally {
      await tempDir.delete(recursive: true);
    }
  });

  test("SHA-256 mismatch fails before extraction", () async {
    final tempDir = await Directory.systemTemp.createTemp("artifact_test_");
    try {
      final file = File("${tempDir.path}/artifact.zip")
        ..writeAsStringSync("hello");
      final artifact = _artifact(length: 5, sha256: "a" * 64);

      await expectLater(
        const ArtifactVerifier().verifyArtifactFile(
          artifact: artifact,
          file: file,
        ),
        throwsA(isA<FileSystemException>()),
      );
    } finally {
      await tempDir.delete(recursive: true);
    }
  });

  test("unsupported URL scheme fails", () {
    expect(
      () => verifyArtifactUrl(Uri.parse("ftp://example.com/app.zip")),
      throwsUnsupportedError,
    );
  });

  test("missing artifact fails", () {
    expect(
      () => ReleaseDescriptor.fromJson({
        "schemaVersion": 3,
        "packageId": "com.example.app",
        "appName": "Example.app",
        "version": "2.0.0",
        "buildNumber": 200,
        "platform": "macos",
        "channel": "stable",
        "install": {"strategy": "wholeBundleReplace"},
        "minimumUpdaterVersion": "2.0.0",
        "generatedAt": "2026-06-11T00:00:00Z",
      }),
      throwsFormatException,
    );
  });

  test("signed descriptor verification fails closed in production mode",
      () async {
    final descriptor = ReleaseDescriptor.fromJson({
      "schemaVersion": 3,
      "packageId": "com.example.app",
      "appName": "Example.app",
      "version": "2.0.0",
      "buildNumber": 200,
      "platform": "macos",
      "channel": "stable",
      "artifact": _artifact(length: 5, sha256: _sha256("hello")).toJson(),
      "install": {"strategy": "wholeBundleReplace"},
      "minimumUpdaterVersion": "2.0.0",
      "generatedAt": "2026-06-11T00:00:00Z",
    });

    await expectLater(
      const ArtifactVerifier(
        policy: ArtifactVerificationPolicy(requireSignature: true),
      ).verifyDescriptor(descriptor),
      throwsA(isA<StateError>()),
    );
  });

  test("signed descriptor verification passes with pinned Ed25519 public key",
      () async {
    final signed = await _signedDescriptor();

    await const ArtifactVerifier().verifyDescriptor(
      _descriptor(),
    );
    await ArtifactVerifier(
      policy: ArtifactVerificationPolicy.requireEd25519Signature(
        publicKeys: {_publicKeyId: signed.publicKey},
      ),
    ).verifyDescriptor(signed.descriptor);
  });

  test("signed descriptor verification fails with unknown pinned public key",
      () async {
    final signed = await _signedDescriptor();

    await expectLater(
      ArtifactVerifier(
        policy: ArtifactVerificationPolicy.requireEd25519Signature(
          publicKeys: const {"other-key": "abc"},
        ),
      ).verifyDescriptor(signed.descriptor),
      throwsA(isA<StateError>()),
    );
  });
}

ReleaseArtifact _artifact({required int length, required String sha256}) {
  return ReleaseArtifact(
    kind: "zip",
    url: Uri.parse("https://cdn.example.com/app.zip"),
    sha256: sha256,
    length: length,
  );
}

String _sha256(String value) {
  return crypto.sha256.convert(utf8.encode(value)).toString();
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

ReleaseDescriptor _descriptor({ReleaseSignature? signature}) {
  return ReleaseDescriptor(
    schemaVersion: 3,
    packageId: "com.example.app",
    appName: "Example.app",
    version: "2.0.0",
    buildNumber: 200,
    platform: "macos",
    channel: "stable",
    artifact: _artifact(length: 5, sha256: _sha256("hello")),
    install: const ReleaseInstall(strategy: "wholeBundleReplace"),
    signature: signature,
    minimumUpdaterVersion: "2.0.0",
    generatedAt: DateTime.utc(2026, 6, 11),
  );
}

Future<_SignedDescriptor> _signedDescriptor() async {
  final algorithm = Ed25519();
  final keyPair = await algorithm.newKeyPairFromSeed(_privateSeed);
  final publicKey = await keyPair.extractPublicKey();
  final descriptorToSign = _descriptor(
    signature: const ReleaseSignature(
      algorithm: "ed25519",
      publicKeyId: _publicKeyId,
      value: "",
    ),
  );
  final signature = await algorithm.sign(
    descriptorToSign.canonicalSignatureBytes(),
    keyPair: keyPair,
  );

  return _SignedDescriptor(
    descriptor: _descriptor(
      signature: ReleaseSignature(
        algorithm: "ed25519",
        publicKeyId: _publicKeyId,
        value: base64Encode(signature.bytes),
      ),
    ),
    publicKey: base64Encode(publicKey.bytes),
  );
}

class _SignedDescriptor {
  const _SignedDescriptor({
    required this.descriptor,
    required this.publicKey,
  });

  final ReleaseDescriptor descriptor;
  final String publicKey;
}
