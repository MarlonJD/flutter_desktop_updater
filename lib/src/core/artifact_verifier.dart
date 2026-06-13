import "dart:io";

import "package:crypto/crypto.dart" as crypto;
import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:desktop_updater/src/core/release_signature_verifier.dart";

typedef DescriptorSignatureVerifier = Future<bool> Function(
  ReleaseDescriptor descriptor,
  List<int> canonicalBytes,
);

class ArtifactVerificationPolicy {
  const ArtifactVerificationPolicy({
    this.requireSignature = false,
    this.signatureVerifier,
  });

  factory ArtifactVerificationPolicy.requireEd25519Signature({
    required Map<String, String> publicKeys,
  }) {
    final verifier = Ed25519ReleaseSignatureVerifier(publicKeys);
    return ArtifactVerificationPolicy(
      requireSignature: true,
      signatureVerifier: verifier.verify,
    );
  }

  final bool requireSignature;
  final DescriptorSignatureVerifier? signatureVerifier;
}

class ArtifactVerifier {
  const ArtifactVerifier({
    this.policy = const ArtifactVerificationPolicy(),
  });

  final ArtifactVerificationPolicy policy;

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

void verifyArtifactUrl(Uri uri) {
  if (uri.scheme != "https" && uri.scheme != "http" && uri.scheme != "file") {
    throw UnsupportedError("Unsupported update URL scheme: ${uri.scheme}");
  }
  if (uri.scheme != "file" && uri.host.isEmpty) {
    throw FormatException("Artifact URL must be exact and absolute: $uri");
  }
}
