import "dart:convert";

import "package:cryptography_plus/cryptography_plus.dart";
import "package:desktop_updater/src/core/release_descriptor.dart";

class Ed25519ReleaseSignatureVerifier {
  Ed25519ReleaseSignatureVerifier(
    Map<String, String> publicKeys, {
    Ed25519? algorithm,
  })  : publicKeys = Map.unmodifiable(publicKeys),
        _algorithm = algorithm ?? Ed25519();

  final Map<String, String> publicKeys;
  final Ed25519 _algorithm;

  Future<bool> call(
    ReleaseDescriptor descriptor,
    List<int> canonicalBytes,
  ) {
    return verify(descriptor, canonicalBytes);
  }

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
