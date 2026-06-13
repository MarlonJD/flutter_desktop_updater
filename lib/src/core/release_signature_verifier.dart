import "dart:convert";

import "package:cryptography_plus/cryptography_plus.dart";
import "package:desktop_updater/src/core/release_descriptor.dart";

/// Verifies Ed25519 signatures embedded in release descriptors.
class Ed25519ReleaseSignatureVerifier {
  /// Creates a verifier with pinned public keys keyed by descriptor key id.
  Ed25519ReleaseSignatureVerifier(
    Map<String, String> publicKeys, {
    Ed25519? algorithm,
  })  : publicKeys = Map.unmodifiable(publicKeys),
        _algorithm = algorithm ?? Ed25519();

  /// Map of `publicKeyId` to base64 raw Ed25519 public key bytes.
  final Map<String, String> publicKeys;
  final Ed25519 _algorithm;

  /// Calls [verify] with already canonicalized descriptor bytes.
  Future<bool> call(
    ReleaseDescriptor descriptor,
    List<int> canonicalBytes,
  ) {
    return verify(descriptor, canonicalBytes);
  }

  /// Returns whether [descriptor] has a valid Ed25519 signature.
  ///
  /// Malformed base64, missing keys, unsupported algorithms, and cryptographic
  /// verification failures are reported as `false` rather than thrown.
  Future<bool> verify(
    ReleaseDescriptor descriptor, [
    List<int>? canonicalBytes,
  ]) async {
    final signature = descriptor.signature;
    if (signature == null ||
        signature.algorithm != "ed25519" ||
        signature.publicKeyId.trim().isEmpty ||
        signature.value.trim().isEmpty) {
      return false;
    }

    final publicKeyValue = publicKeys[signature.publicKeyId];
    if (publicKeyValue == null || publicKeyValue.trim().isEmpty) {
      return false;
    }

    try {
      final publicKeyBytes = base64Decode(publicKeyValue.trim());
      final signatureBytes = base64Decode(signature.value.trim());
      final publicKey = SimplePublicKey(
        publicKeyBytes,
        type: KeyPairType.ed25519,
      );
      return await _algorithm.verify(
        canonicalBytes ?? descriptor.canonicalSignatureBytes(),
        signature: Signature(signatureBytes, publicKey: publicKey),
      );
    } on Object {
      return false;
    }
  }
}

/// Decodes a JSON object containing pinned release public keys.
///
/// The expected shape is `{"key-id":"base64-raw-ed25519-public-key"}`.
Map<String, String> decodeReleasePublicKeysJson(String value) {
  final decoded = jsonDecode(value);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException(
      "Release public keys must be a JSON object.",
    );
  }

  final publicKeys = <String, String>{};
  for (final entry in decoded.entries) {
    final publicKeyId = entry.key.trim();
    final publicKeyValue = entry.value;
    if (publicKeyId.isEmpty || publicKeyValue is! String) {
      throw const FormatException(
        "Release public keys must map non-empty key ids to base64 strings.",
      );
    }
    publicKeys[publicKeyId] = publicKeyValue;
  }
  return publicKeys;
}
