import "dart:convert";

import "package:cryptography_plus/cryptography_plus.dart";
import "package:desktop_updater/src/core/release_descriptor.dart";

/// Verifies Ed25519 signatures embedded in release descriptors.
class Ed25519ReleaseSignatureVerifier {
  /// Creates a verifier with pinned public keys keyed by descriptor key id.
  Ed25519ReleaseSignatureVerifier(
    Map<String, String> publicKeys, {
    Ed25519? algorithm,
  })  : publicKeys = normalizeReleasePublicKeys(publicKeys),
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

    final publicKeyValue = publicKeys[signature.publicKeyId.trim()];
    if (publicKeyValue == null || publicKeyValue.isEmpty) {
      return false;
    }

    try {
      final publicKeyBytes = base64Decode(publicKeyValue);
      final signatureBytes = base64Decode(signature.value.trim());
      if (signatureBytes.length != 64) {
        return false;
      }
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
    final publicKeyId = entry.key;
    final publicKeyValue = entry.value;
    if (publicKeyValue is! String) {
      throw const FormatException(
        "Release public keys must map non-empty key ids to base64 strings.",
      );
    }
    publicKeys[publicKeyId] = publicKeyValue;
  }
  return normalizeReleasePublicKeys(publicKeys);
}

/// Returns a normalized immutable copy of pinned raw Ed25519 public keys.
Map<String, String> normalizeReleasePublicKeys(Map<String, String> publicKeys) {
  if (publicKeys.isEmpty) {
    throw const FormatException(
      "Release public keys must contain at least one key.",
    );
  }
  final normalized = <String, String>{};
  for (final entry in publicKeys.entries) {
    final keyId = entry.key.trim();
    if (keyId.isEmpty) {
      throw const FormatException("Release public key ids must not be blank.");
    }
    if (normalized.containsKey(keyId)) {
      throw FormatException("Duplicate release public key id: $keyId.");
    }
    final value = entry.value.trim();
    if (value != entry.value || !_strictBase64.hasMatch(value)) {
      throw FormatException(
        "Release public key $keyId must be strict base64.",
      );
    }
    final bytes = base64Decode(value);
    if (bytes.length != 32) {
      throw FormatException(
        "Release public key $keyId must decode to 32 bytes.",
      );
    }
    normalized[keyId] = value;
  }
  return Map.unmodifiable(normalized);
}

final _strictBase64 =
    RegExp(r"^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$");
