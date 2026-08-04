import "dart:convert";

import "package:cryptography_plus/cryptography_plus.dart";
import "package:desktop_updater/src/core/release_index.dart";
import "package:desktop_updater/src/core/release_signature_verifier.dart";

/// Verifies Ed25519 signatures embedded in app archive release indexes.
class Ed25519ReleaseIndexSignatureVerifier {
  /// Creates a verifier with pinned public keys keyed by signature key id.
  Ed25519ReleaseIndexSignatureVerifier(
    Map<String, String> publicKeys, {
    Ed25519? algorithm,
  })  : publicKeys = normalizeReleasePublicKeys(publicKeys),
        _algorithm = algorithm ?? Ed25519();

  /// Map of `publicKeyId` to base64 raw Ed25519 public key bytes.
  final Map<String, String> publicKeys;
  final Ed25519 _algorithm;

  /// Returns whether [index] has a valid signature from a pinned key.
  Future<bool> verify(ReleaseIndex index) async {
    final signature = index.signature;
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
      if (publicKeyBytes.length != 32 || signatureBytes.length != 64) {
        return false;
      }
      return await _algorithm.verify(
        index.canonicalSignatureBytes(),
        signature: Signature(
          signatureBytes,
          publicKey: SimplePublicKey(
            publicKeyBytes,
            type: KeyPairType.ed25519,
          ),
        ),
      );
    } on Object {
      return false;
    }
  }
}
