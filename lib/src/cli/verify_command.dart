import "dart:convert";
import "dart:io";

import "package:args/args.dart";
import "package:desktop_updater/src/core/artifact_verifier.dart";
import "package:desktop_updater/src/core/macos_distribution_artifacts.dart";
import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:desktop_updater/src/core/release_signature_verifier.dart";
import "package:desktop_updater/src/core/safe_zip_extractor.dart";
import "package:desktop_updater/src/io/composite_update_transport.dart";
import "package:desktop_updater/src/release_cli/macos/apple_trust_commands.dart";
import "package:path/path.dart" as path;

/// Builds the parser shared by the verify entrypoints.
ArgParser buildVerifyParser() {
  return ArgParser()
    ..addFlag("help", abbr: "h", negatable: false)
    ..addOption("release", help: "Path or file URL to release.json.")
    ..addFlag(
      "candidate-only",
      negatable: false,
      help: "Verify an unsigned candidate without production trust checks.",
    )
    ..addOption(
      "public-keys-env",
      help: "Environment variable containing JSON public key map.",
    );
}

/// Runs the verify command shared by the standalone and legacy entrypoints.
Future<int> runVerifyCommand(
  List<String> args, {
  StringSink? output,
  Map<String, String>? environment,
}) async {
  final out = output ?? stdout;
  final parser = buildVerifyParser();
  final results = parser.parse(args);
  if (results["help"] as bool) {
    out.writeln(parser.usage);
    return 0;
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
  final candidateOnly = results["candidate-only"] as bool;
  if (candidateOnly) {
    out.writeln(
      "candidate-only: unsigned verification; production verification "
      "requires --public-keys-env.",
    );
  }
  final publicKeys = candidateOnly
      ? null
      : _verifyPublicKeys(
          results: results,
          environment: environment ?? Platform.environment,
        );
  final verifier = candidateOnly
      ? const ArtifactVerifier()
      : ArtifactVerifier(
          policy: ArtifactVerificationPolicy.requireEd25519Signature(
            publicKeys: publicKeys!,
          ),
        );
  await verifier.verifyDescriptor(descriptor);

  final tempDir = await Directory.systemTemp.createTemp(
    "desktop_updater_verify_",
  );
  try {
    final artifactFile = File(
      path.join(
        tempDir.path,
        "artifact${_artifactExtensionForKind(descriptor.artifact.kind)}",
      ),
    );
    await CompositeUpdateTransport().download(
      descriptor.artifact.url,
      artifactFile,
    );
    await verifier.verifyArtifactFile(
      artifact: descriptor.artifact,
      file: artifactFile,
    );

    if (descriptor.artifact.kind == "innoInstaller") {
      out.writeln("Installer artifact verified.");
      return 0;
    }

    if (descriptor.artifact.kind == "dmg") {
      await _verifyMacOSDmgArtifact(
        descriptor: descriptor,
        artifactFile: artifactFile,
        tempDir: tempDir,
        output: out,
      );
      out.writeln("release.json verified");
      return 0;
    }

    if (descriptor.artifact.kind == "pkgInstaller") {
      await _verifyMacOSPkgArtifact(
        descriptor: descriptor,
        artifactFile: artifactFile,
        output: out,
      );
      out.writeln("release.json verified");
      return 0;
    }

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

  out.writeln("release.json verified");
  return 0;
}

Map<String, String> _verifyPublicKeys({
  required ArgResults results,
  required Map<String, String> environment,
}) {
  final envName = results["public-keys-env"] as String?;
  if (envName == null || envName.trim().isEmpty) {
    throw const FormatException(
      "Production verification requires --public-keys-env, or use "
      "--candidate-only explicitly.",
    );
  }
  final value = environment[envName];
  if (value == null || value.trim().isEmpty) {
    throw FormatException("Missing environment variable $envName.");
  }
  return decodeReleasePublicKeysJson(value);
}

Future<void> _verifyMacOSDmgArtifact({
  required ReleaseDescriptor descriptor,
  required File artifactFile,
  required Directory tempDir,
  required StringSink output,
}) async {
  if (!Platform.isMacOS) {
    output.writeln(
      "macOS artifact trust validation: not run (requires macOS host)",
    );
    return;
  }
  const verifier = MacOSDistributionVerifier();
  final copiedApp = await verifier.withMountedVerifiedDmg(
    dmg: artifactFile,
    verifyPrimarySignature:
        descriptor.install.macosDmg?.verifyPrimarySignature ?? true,
    body: (mounted) {
      return verifier.copyAppFromMountedDmg(
        mounted: mounted,
        appBundleName: descriptor.install.macosDmg!.appBundleName,
        destinationParent: Directory(path.join(tempDir.path, "dmg-app")),
      );
    },
  );
  const trust = AppleTrustCommands();
  await trust.verifyApp(copiedApp);
  await trust.assessExecute(copiedApp);
  await trust.validateStaple(copiedApp);
  output.writeln("macOS DMG artifact verified.");
}

Future<void> _verifyMacOSPkgArtifact({
  required ReleaseDescriptor descriptor,
  required File artifactFile,
  required StringSink output,
}) async {
  if (!Platform.isMacOS) {
    output.writeln(
      "macOS artifact trust validation: not run (requires macOS host)",
    );
    return;
  }
  await const MacOSDistributionVerifier().verifyPkgInstaller(
    pkg: artifactFile,
    expectedPackageIds: descriptor.install.macosPkg!.expectedPackageIds,
  );
  output.writeln("macOS PKG artifact verified.");
}

String _artifactExtensionForKind(String artifactKind) {
  switch (artifactKind) {
    case "dmg":
      return ".dmg";
    case "pkgInstaller":
      return ".pkg";
    case "innoInstaller":
      return ".exe";
  }
  return ".zip";
}
