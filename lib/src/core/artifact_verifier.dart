import "dart:io";

import "package:crypto/crypto.dart" as crypto;
import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:desktop_updater/src/core/release_signature_verifier.dart";

/// Callback used to verify signed descriptor bytes.
typedef DescriptorSignatureVerifier = Future<bool> Function(
  /// Descriptor whose [ReleaseDescriptor.signature] should be checked.
  ReleaseDescriptor descriptor,

  /// Canonical descriptor bytes produced for signature verification.
  List<int> canonicalBytes,
);

/// Verification requirements applied before an update artifact is trusted.
class ArtifactVerificationPolicy {
  /// Creates an artifact verification policy.
  const ArtifactVerificationPolicy({
    this.requireSignature = false,
    this.signatureVerifier,
  });

  /// Creates a policy that requires Ed25519 descriptor signatures.
  factory ArtifactVerificationPolicy.requireEd25519Signature({
    /// Map of `publicKeyId` to base64 raw Ed25519 public key bytes.
    required Map<String, String> publicKeys,
  }) {
    final verifier = Ed25519ReleaseSignatureVerifier(publicKeys);
    return ArtifactVerificationPolicy(
      requireSignature: true,
      signatureVerifier: verifier.verify,
    );
  }

  /// Whether a descriptor signature is required before artifact download.
  final bool requireSignature;

  /// Verifier used when [requireSignature] is true.
  final DescriptorSignatureVerifier? signatureVerifier;
}

/// Verifies release descriptors and downloaded update artifact files.
class ArtifactVerifier {
  /// Creates an artifact verifier using [policy].
  const ArtifactVerifier({
    this.policy = const ArtifactVerificationPolicy(),
  });

  /// Verification policy applied by this verifier.
  final ArtifactVerificationPolicy policy;

  /// Validates descriptor fields, URL shape, and optional descriptor signature.
  Future<void> verifyDescriptor(ReleaseDescriptor descriptor) async {
    descriptor.validate();
    verifyArtifactUrl(descriptor.artifact.url);

    if (!policy.requireSignature) {
      return;
    }

    final signature = descriptor.signature;
    if (signature == null || signature.value.trim().isEmpty) {
      throw StateError(
        "release.json signature is required in production mode.",
      );
    }
    if (signature.algorithm != "ed25519") {
      throw StateError(
        "Unsupported release.json signature algorithm: ${signature.algorithm}",
      );
    }

    final verifier = policy.signatureVerifier;
    if (verifier == null) {
      throw StateError(
        "No release signature verifier is configured for production mode.",
      );
    }

    final verified = await verifier(
      descriptor,
      descriptor.canonicalSignatureBytes(),
    );
    if (!verified) {
      throw StateError("release.json signature verification failed.");
    }
  }

  /// Verifies that [file] matches the expected artifact length and SHA-256.
  Future<void> verifyArtifactFile({
    required ReleaseArtifact artifact,
    required File file,
  }) async {
    verifyArtifactUrl(artifact.url);

    final actualLength = await file.length();
    if (actualLength != artifact.length) {
      throw FileSystemException(
        "Artifact length mismatch: expected ${artifact.length}, got $actualLength",
        file.path,
      );
    }

    final digest = await crypto.sha256.bind(file.openRead()).first;
    if (digest.toString() != artifact.sha256) {
      throw FileSystemException(
        "Artifact SHA-256 mismatch: expected ${artifact.sha256}, got $digest",
        file.path,
      );
    }
  }
}

/// Validates that an artifact URL is absolute and uses a supported scheme.
void verifyArtifactUrl(Uri uri) {
  if (uri.scheme != "https" && uri.scheme != "http" && uri.scheme != "file") {
    throw UnsupportedError("Unsupported update URL scheme: ${uri.scheme}");
  }
  if (uri.scheme != "file" && uri.host.isEmpty) {
    throw FormatException("Artifact URL must be exact and absolute: $uri");
  }
}
