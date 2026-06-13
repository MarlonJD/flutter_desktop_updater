import "dart:convert";

import "package:cryptography_plus/cryptography_plus.dart";
import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:desktop_updater/src/core/release_signature_verifier.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  test("valid Ed25519 signature passes", () async {
    final signed = await _signedDescriptor();

    final verifier = Ed25519ReleaseSignatureVerifier({
      _publicKeyId: signed.publicKey,
    });

    expect(await verifier.verify(signed.descriptor), isTrue);
  });

  test("tampered descriptor fails", () async {
    final signed = await _signedDescriptor();
    final tamperedJson = signed.descriptor.toJson()..["version"] = "2.0.1";
    final tampered = ReleaseDescriptor.fromJson(tamperedJson);

    final verifier = Ed25519ReleaseSignatureVerifier({
      _publicKeyId: signed.publicKey,
    });

    expect(await verifier.verify(tampered), isFalse);
  });

  test("missing public key fails", () async {
    final signed = await _signedDescriptor();

    final verifier = Ed25519ReleaseSignatureVerifier(const {});

    expect(await verifier.verify(signed.descriptor), isFalse);
  });

  test("malformed base64 signature fails", () async {
    final signed = await _signedDescriptor();
    final malformed = ReleaseDescriptor.fromJson(
      signed.descriptor.toJson()
        ..["signature"] = {
          "algorithm": "ed25519",
          "publicKeyId": _publicKeyId,
          "value": "not base64!",
        },
    );

    final verifier = Ed25519ReleaseSignatureVerifier({
      _publicKeyId: signed.publicKey,
    });

    expect(await verifier.verify(malformed), isFalse);
  });

  test("unsupported algorithm fails", () async {
    final signed = await _signedDescriptor();
    final unsupported = ReleaseDescriptor.fromJson(
      signed.descriptor.toJson()
        ..["signature"] = {
          "algorithm": "rsa-pss-sha256",
          "publicKeyId": _publicKeyId,
          "value": signed.signature,
        },
    );

    final verifier = Ed25519ReleaseSignatureVerifier({
      _publicKeyId: signed.publicKey,
    });

    expect(await verifier.verify(unsupported), isFalse);
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

Future<_SignedDescriptor> _signedDescriptor() async {
  final algorithm = Ed25519();
  final keyPair = await algorithm.newKeyPairFromSeed(_privateSeed);
  final publicKey = await keyPair.extractPublicKey();
  final descriptorToSign = ReleaseDescriptor.fromJson({
    ..._descriptorJson(),
    "signature": {
      "algorithm": "ed25519",
      "publicKeyId": _publicKeyId,
      "value": "",
    },
  });
  final signature = await algorithm.sign(
    descriptorToSign.canonicalSignatureBytes(),
    keyPair: keyPair,
  );
  final descriptor = ReleaseDescriptor.fromJson({
    ..._descriptorJson(),
    "signature": {
      "algorithm": "ed25519",
      "publicKeyId": _publicKeyId,
      "value": base64Encode(signature.bytes),
    },
  });

  return _SignedDescriptor(
    descriptor: descriptor,
    publicKey: base64Encode(publicKey.bytes),
    signature: base64Encode(signature.bytes),
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

class _SignedDescriptor {
  const _SignedDescriptor({
    required this.descriptor,
    required this.publicKey,
    required this.signature,
  });

  final ReleaseDescriptor descriptor;
  final String publicKey;
  final String signature;
}
