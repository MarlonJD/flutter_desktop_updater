import "dart:convert";
import "dart:io";

import "package:args/args.dart";
import "package:desktop_updater/src/core/artifact_verifier.dart";
import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:desktop_updater/src/core/safe_zip_extractor.dart";
import "package:desktop_updater/src/io/composite_update_transport.dart";
import "package:path/path.dart" as path;

Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addFlag("help", abbr: "h", negatable: false)
    ..addOption("release", help: "Path or file URL to release.json.")
    ..addFlag(
      "require-signature",
      defaultsTo: false,
      help: "Fail when release.json has no configured production signature.",
    );

  final results = parser.parse(args);
  if (results["help"] as bool) {
    stdout.writeln(parser.usage);
    return;
  }

  final releasePath = results["release"] as String?;
  if (releasePath == null || releasePath.trim().isEmpty) {
    throw const FormatException("Missing --release.");
  }

  final releaseUri = Uri.parse(releasePath);
  final releaseFile = File(
    releaseUri.scheme.isNotEmpty ? releaseUri.toFilePath() : releasePath,
  );
  final descriptor = ReleaseDescriptor.fromJson(
    jsonDecode(await releaseFile.readAsString()) as Map<String, dynamic>,
  );
  final verifier = ArtifactVerifier(
    policy: ArtifactVerificationPolicy(
      requireSignature: results["require-signature"] as bool,
    ),
  );
  await verifier.verifyDescriptor(descriptor);

  final tempDir = await Directory.systemTemp.createTemp(
    "desktop_updater_verify_",
  );
  try {
    final artifactFile = File(path.join(tempDir.path, "artifact.zip"));
    await CompositeUpdateTransport().download(
      descriptor.artifact.url,
      artifactFile,
    );
    await verifier.verifyArtifactFile(
      artifact: descriptor.artifact,
      file: artifactFile,
    );

    if (descriptor.platform != "macos") {
      await const SafeZipExtractor().extract(
        archiveFile: artifactFile,
        destination: Directory(path.join(tempDir.path, "extract")),
        platform: descriptor.platform,
      );
    }
  } finally {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  }

  stdout.writeln("release.json verified");
}
