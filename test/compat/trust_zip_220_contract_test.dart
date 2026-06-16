import "dart:convert";
import "dart:io";

import "package:archive/archive.dart";
import "package:crypto/crypto.dart" as crypto;
import "package:desktop_updater/src/core/artifact_verifier.dart";
import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:desktop_updater/src/core/release_signature_verifier.dart";
import "package:desktop_updater/src/core/safe_zip_extractor.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;

void main() {
  test("artifact hash and length checks remain fail-closed", () async {
    final validBytes = File(
      "fixtures/compat/artifact-valid.txt",
    ).readAsBytesSync();
    final hashMismatchBytes = File(
      "fixtures/compat/artifact-hash-mismatch.txt",
    ).readAsBytesSync();
    final lengthMismatchBytes = File(
      "fixtures/compat/artifact-length-mismatch.txt",
    ).readAsBytesSync();
    final valid = ReleaseArtifact(
      kind: "zip",
      url: Uri.parse("https://updates.example.com/artifact.zip"),
      sha256: crypto.sha256.convert(validBytes).toString(),
      length: validBytes.length,
    );

    final tempDir = await Directory.systemTemp.createTemp("compat_trust_");
    try {
      final artifact = File(path.join(tempDir.path, "artifact.txt"))
        ..writeAsBytesSync(validBytes);
      await const ArtifactVerifier().verifyArtifactFile(
        artifact: valid,
        file: artifact,
      );

      final hashMismatch = File(
        path.join(tempDir.path, "artifact-hash-mismatch.txt"),
      )..writeAsBytesSync(hashMismatchBytes);
      await expectLater(
        const ArtifactVerifier().verifyArtifactFile(
          artifact: valid,
          file: hashMismatch,
        ),
        throwsA(isA<FileSystemException>()),
      );

      final lengthMismatch = File(
        path.join(tempDir.path, "artifact-length-mismatch.txt"),
      )..writeAsBytesSync(lengthMismatchBytes);
      await expectLater(
        const ArtifactVerifier().verifyArtifactFile(
          artifact: valid,
          file: lengthMismatch,
        ),
        throwsA(isA<FileSystemException>()),
      );
    } finally {
      await tempDir.delete(recursive: true);
    }
  });

  test("Ed25519 descriptor signing fixture verifies and fails closed",
      () async {
    final fixture = jsonDecode(
      File("fixtures/compat/signing-ed25519.json").readAsStringSync(),
    ) as Map<String, dynamic>;
    final publicKeyId = fixture["publicKeyId"] as String;
    final publicKeys = {publicKeyId: fixture["publicKey"] as String};
    final verifier = Ed25519ReleaseSignatureVerifier(publicKeys);
    final validDescriptor = ReleaseDescriptor.fromJson(
      fixture["validDescriptor"] as Map<String, dynamic>,
    );
    final invalidDescriptor = ReleaseDescriptor.fromJson(
      fixture["invalidDescriptor"] as Map<String, dynamic>,
    );

    expect(await verifier.verify(validDescriptor), isTrue);
    expect(await verifier.verify(invalidDescriptor), isFalse);

    await ArtifactVerifier(
      policy: ArtifactVerificationPolicy.requireEd25519Signature(
        publicKeys: publicKeys,
      ),
    ).verifyDescriptor(validDescriptor);
    await expectLater(
      ArtifactVerifier(
        policy: ArtifactVerificationPolicy.requireEd25519Signature(
          publicKeys: publicKeys,
        ),
      ).verifyDescriptor(invalidDescriptor),
      throwsA(isA<StateError>()),
    );
  });

  test("safe zip policy fixture documents current extraction boundaries",
      () async {
    final policy = File("fixtures/compat/zip-safety.md").readAsStringSync();

    expect(policy, contains("parent traversal"));
    expect(policy, contains("absolute paths"));
    expect(policy, contains("Windows drive paths"));
    expect(policy, contains("macOS app bundles use ditto"));

    await _expectZipRejected(
      Archive()..addFile(ArchiveFile.string("../evil", "x")),
    );
    await _expectZipRejected(
      Archive()..addFile(ArchiveFile.string("/tmp/evil", "x")),
    );
    await _expectZipRejected(
      Archive()..addFile(ArchiveFile.string(r"C:\evil", "x")),
    );

    final tempDir = await Directory.systemTemp.createTemp("compat_zip_");
    try {
      final archiveFile = await _writeZip(
        tempDir,
        Archive()
          ..addFile(ArchiveFile.string("Example.app/Contents/Info.plist", "x")),
      );

      await expectLater(
        const SafeZipExtractor().extract(
          archiveFile: archiveFile,
          destination: Directory(path.join(tempDir.path, "out")),
          platform: "macos",
        ),
        throwsUnsupportedError,
      );
    } finally {
      await tempDir.delete(recursive: true);
    }
  });
}

Future<void> _expectZipRejected(Archive archive) async {
  final tempDir = await Directory.systemTemp.createTemp("compat_zip_");
  try {
    final archiveFile = await _writeZip(tempDir, archive);
    await expectLater(
      const SafeZipExtractor().extract(
        archiveFile: archiveFile,
        destination: Directory(path.join(tempDir.path, "out")),
        platform: "linux",
      ),
      throwsFormatException,
    );
  } finally {
    await tempDir.delete(recursive: true);
  }
}

Future<File> _writeZip(Directory tempDir, Archive archive) async {
  return File(path.join(tempDir.path, "fixture.zip"))
    ..writeAsBytesSync(ZipEncoder().encode(archive));
}
