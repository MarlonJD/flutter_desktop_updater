import "dart:convert";
import "dart:io";

import "package:args/args.dart";
import "package:desktop_updater/src/core/artifact_verifier.dart";
import "package:desktop_updater/src/core/macos_distribution_artifacts.dart";
import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:desktop_updater/src/core/release_index.dart";
import "package:desktop_updater/src/core/release_index_signature_verifier.dart";
import "package:desktop_updater/src/release_cli/publish_manifest.dart";
import "package:desktop_updater/src/release_cli/release_signing_resolver.dart";
import "package:desktop_updater/src/version_info.dart";
import "package:http/http.dart" as http;
import "package:path/path.dart" as path;

ArgParser buildValidateParser() {
  return ArgParser()
    ..addFlag("help", abbr: "h", negatable: false)
    ..addOption("manifest")
    ..addOption("from-version")
    ..addFlag(
      "candidate-only",
      negatable: false,
      help: "Validate an unsigned candidate without production trust checks.",
    )
    ..addOption(
      "key-profile",
      help:
          "Feed-bound public key profile; defaults to desktop_updater.keys.json.",
    );
}

Future<int> runValidateCommand(
  ArgResults results, {
  required Directory projectRoot,
  required StringSink output,
}) async {
  if (results["help"] as bool) {
    output.writeln(buildValidateParser().usage);
    return 0;
  }

  final manifestFile = _resolveManifestFile(
    projectRoot,
    _required(results, "manifest"),
  );
  final manifest = await PublishManifest.readFrom(manifestFile);
  final fromVersion = results["from-version"] as String?;
  final candidateOnly = results["candidate-only"] as bool;
  if (candidateOnly) {
    output.writeln(
      "candidate-only: unsigned validation; production validation "
      "requires a release key profile.",
    );
  }
  final publicKeys = await resolveReleasePublicKeys(
    results: results,
    projectRoot: projectRoot,
    candidateOnly: candidateOnly,
    expectedFeedUrl: manifest.appArchive.url,
  );
  await ReleaseValidator(
    artifactVerifier: !candidateOnly
        ? ArtifactVerifier(
            policy: ArtifactVerificationPolicy.requireEd25519Signature(
              publicKeys: publicKeys!,
            ),
          )
        : const ArtifactVerifier(),
    requireIndexSignature: !candidateOnly,
    indexSignatureVerifier: publicKeys == null
        ? null
        : Ed25519ReleaseIndexSignatureVerifier(publicKeys),
  ).validate(
    manifestFile: manifestFile,
    fromVersion: fromVersion,
    output: output,
  );
  return 0;
}

class ReleaseValidator {
  ReleaseValidator({
    http.Client? client,
    this.artifactVerifier = const ArtifactVerifier(),
    this.requireIndexSignature = false,
    this.indexSignatureVerifier,
    MacOSDistributionVerifier? macosVerifier,
    bool? isMacOSHost,
  })  : client = client ?? http.Client(),
        macosVerifier = macosVerifier ?? const MacOSDistributionVerifier(),
        isMacOSHost = isMacOSHost ?? Platform.isMacOS;

  final http.Client client;
  final ArtifactVerifier artifactVerifier;
  final bool requireIndexSignature;
  final Ed25519ReleaseIndexSignatureVerifier? indexSignatureVerifier;
  final MacOSDistributionVerifier macosVerifier;
  final bool isMacOSHost;

  Future<void> validate({
    required File manifestFile,
    required String? fromVersion,
    required StringSink output,
  }) async {
    final manifest = await PublishManifest.readFrom(manifestFile);
    final appArchiveResponse = await _get(manifest.appArchive.url);
    final index = ReleaseIndex.fromJson(
      jsonDecode(appArchiveResponse.body) as Map<String, dynamic>,
    );
    final shouldVerifyIndex = requireIndexSignature ||
        (index.signature != null && indexSignatureVerifier != null);
    if (shouldVerifyIndex &&
        (indexSignatureVerifier == null ||
            !await indexSignatureVerifier!.verify(index))) {
      throw StateError(
        "app-archive.json signature verification failed.",
      );
    }
    output.writeln("Hosted app archive: OK");
    if (shouldVerifyIndex) {
      output.writeln("Hosted app archive signature: OK");
    }
    _warnLongCacheControl(appArchiveResponse, output);

    final currentVersion = _currentVersionForValidation(
      index: index,
      manifest: manifest,
      fromVersion: fromVersion,
      output: output,
    );
    final selected = selectReleaseIndexItem(
      index: index,
      platform: manifest.release.platform,
      channel: manifest.release.channel,
      currentVersion: currentVersion,
    );
    if (selected == null) {
      throw StateError("Update selection failed: no hosted update selected.");
    }
    if (selected.release.toString() != manifest.release.url.toString()) {
      throw StateError(
        "Update selection mismatch: expected ${manifest.release.url}, got ${selected.release}.",
      );
    }
    output.writeln("Update selection: OK");

    await validateReleaseFiles(manifest: manifest, output: output);
  }

  Future<void> validateReleaseFiles({
    required PublishManifest manifest,
    required StringSink output,
  }) async {
    final descriptor = await _fetchReleaseDescriptor(manifest);
    output.writeln("Hosted release descriptor: OK");
    output.writeln("Artifact kind: ${descriptor.artifact.kind}");
    final artifactFile = await _downloadArtifact(descriptor.artifact.url);
    try {
      await artifactVerifier.verifyArtifactFile(
        artifact: descriptor.artifact,
        file: artifactFile,
      );
      output
        ..writeln("Hosted artifact length: OK")
        ..writeln("Hosted artifact SHA-256: OK");
      await _validateMacOSArtifactTrust(
        descriptor: descriptor,
        artifactFile: artifactFile,
        output: output,
      );
    } finally {
      if (await artifactFile.exists()) {
        final tempDir = artifactFile.parent;
        await tempDir.delete(recursive: true);
      }
    }
  }

  /// Validates the frozen local publication package before manual handoff.
  ///
  /// Manual upload is still candidate-only when this validator is configured
  /// without trust inputs, but the status is explicit in the caller's output.
  Future<void> validateLocalReleaseFiles({
    required Directory localRoot,
    required PublishManifest manifest,
    required StringSink output,
  }) async {
    final indexFile = File(path.join(localRoot.path, manifest.appArchive.path));
    final index = ReleaseIndex.fromJson(
      jsonDecode(await indexFile.readAsString()) as Map<String, dynamic>,
    );
    final shouldVerifyIndex = requireIndexSignature;
    if (shouldVerifyIndex &&
        (indexSignatureVerifier == null ||
            !await indexSignatureVerifier!.verify(index))) {
      throw StateError("Local app-archive.json signature verification failed.");
    }
    final matchingItem = index.items.any(
      (item) =>
          item.version == manifest.release.version &&
          item.buildNumber == manifest.release.buildNumber &&
          item.platform == manifest.release.platform &&
          item.channel == manifest.release.channel &&
          item.release.toString() == manifest.release.url.toString(),
    );
    if (!matchingItem) {
      throw StateError(
        "Local app-archive.json does not contain the frozen release item.",
      );
    }
    output.writeln("Local app archive: OK");
    if (shouldVerifyIndex) {
      output.writeln("Local app archive signature: OK");
    }

    final descriptorFile =
        File(path.join(localRoot.path, manifest.release.path));
    final descriptor = ReleaseDescriptor.fromJson(
      jsonDecode(await descriptorFile.readAsString()) as Map<String, dynamic>,
    );
    await artifactVerifier.verifyDescriptor(descriptor);
    _verifyDescriptorMatchesManifest(descriptor, manifest);
    output.writeln("Local release descriptor: OK");

    final artifactFile =
        File(path.join(localRoot.path, manifest.artifact.path));
    await artifactVerifier.verifyArtifactFile(
      artifact: descriptor.artifact,
      file: artifactFile,
    );
    output
      ..writeln("Local artifact length: OK")
      ..writeln("Local artifact SHA-256: OK");
    await _validateMacOSArtifactTrust(
      descriptor: descriptor,
      artifactFile: artifactFile,
      output: output,
    );
  }

  Future<ReleaseDescriptor> _fetchReleaseDescriptor(
    PublishManifest manifest,
  ) async {
    final releaseResponse = await _get(manifest.release.url);
    final descriptor = ReleaseDescriptor.fromJson(
      jsonDecode(releaseResponse.body) as Map<String, dynamic>,
    );
    await artifactVerifier.verifyDescriptor(descriptor);
    _verifyDescriptorMatchesManifest(descriptor, manifest);
    return descriptor;
  }

  Future<http.Response> _get(Uri url) async {
    final response = await client.get(url);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        "GET $url failed with HTTP ${response.statusCode}.",
        uri: url,
      );
    }
    return response;
  }

  Future<File> _downloadArtifact(Uri url) async {
    final response = await _get(url);
    final tempDir = await Directory.systemTemp.createTemp("release_validate_");
    final file = File(
      path.join(tempDir.path, "artifact${_artifactExtensionForUrl(url)}"),
    );
    await file.writeAsBytes(response.bodyBytes);
    return file;
  }

  Future<void> _validateMacOSArtifactTrust({
    required ReleaseDescriptor descriptor,
    required File artifactFile,
    required StringSink output,
  }) async {
    if (descriptor.platform != "macos" ||
        (descriptor.artifact.kind != "dmg" &&
            descriptor.artifact.kind != "pkgInstaller")) {
      return;
    }
    if (!isMacOSHost) {
      output.writeln(
        "macOS artifact trust validation: not run (requires macOS host)",
      );
      return;
    }

    switch (descriptor.artifact.kind) {
      case "dmg":
        if (descriptor.install.macosDmg?.verifyPrimarySignature == false) {
          output.writeln(
            "macOS DMG primary signature: not run (descriptor disabled)",
          );
          return;
        }
        await macosVerifier.verifyDmgPrimarySignature(artifactFile);
        output.writeln("macOS DMG primary signature: OK");
      case "pkgInstaller":
        await macosVerifier.verifyPkgInstaller(
          pkg: artifactFile,
          expectedPackageIds: descriptor.install.macosPkg!.expectedPackageIds,
        );
        output
          ..writeln("macOS PKG signature: OK")
          ..writeln("macOS PKG Gatekeeper install assessment: OK")
          ..writeln("macOS PKG stapler validation: OK");
    }
  }
}

String _artifactExtensionForUrl(Uri url) {
  final extension = path.extension(url.path);
  return extension.isEmpty ? ".bin" : extension;
}

File _resolveManifestFile(Directory projectRoot, String value) {
  final trimmed = value.trim();
  return File(
    path.isAbsolute(trimmed) ? trimmed : path.join(projectRoot.path, trimmed),
  );
}

DesktopVersionInfo _currentVersionForValidation({
  required ReleaseIndex index,
  required PublishManifest manifest,
  required String? fromVersion,
  required StringSink output,
}) {
  if (fromVersion != null && fromVersion.trim().isNotEmpty) {
    return DesktopVersionInfo.parse(fromVersion);
  }

  final previous = index.items
      .where((item) => item.platform == manifest.release.platform)
      .where((item) => item.channel == manifest.release.channel)
      .where(
        (item) => item.release.toString() != manifest.release.url.toString(),
      )
      .toList(growable: false)
    ..sort((left, right) {
      return compareDesktopVersions(
        DesktopVersionInfo.fromParts(
          versionName: left.version,
          buildNumber: left.buildNumber?.toString(),
        ),
        DesktopVersionInfo.fromParts(
          versionName: right.version,
          buildNumber: right.buildNumber?.toString(),
        ),
      );
    });

  if (previous.isNotEmpty) {
    final item = previous.last;
    return DesktopVersionInfo.fromParts(
      versionName: item.version,
      buildNumber: item.buildNumber?.toString(),
    );
  }

  output.writeln("First release synthetic version check");
  return DesktopVersionInfo.parse("0.0.0");
}

void _verifyDescriptorMatchesManifest(
  ReleaseDescriptor descriptor,
  PublishManifest manifest,
) {
  if (descriptor.version != manifest.release.version) {
    throw StateError(
      "release.json version mismatch: expected ${manifest.release.version}, got ${descriptor.version}.",
    );
  }
  if (descriptor.buildNumber != manifest.release.buildNumber) {
    throw StateError(
      "release.json buildNumber mismatch: expected ${manifest.release.buildNumber}, got ${descriptor.buildNumber}.",
    );
  }
  if (descriptor.platform != manifest.release.platform) {
    throw StateError(
      "release.json platform mismatch: expected ${manifest.release.platform}, got ${descriptor.platform}.",
    );
  }
  if (descriptor.channel != manifest.release.channel) {
    throw StateError(
      "release.json channel mismatch: expected ${manifest.release.channel}, got ${descriptor.channel}.",
    );
  }
  if (descriptor.artifact.url.toString() != manifest.artifact.url.toString()) {
    throw StateError(
      "release.json artifact URL mismatch: expected ${manifest.artifact.url}, got ${descriptor.artifact.url}.",
    );
  }
  if (descriptor.artifact.kind != manifest.artifact.kind) {
    throw StateError(
      "release.json artifact kind mismatch: expected ${manifest.artifact.kind}, got ${descriptor.artifact.kind}.",
    );
  }
  if (descriptor.artifact.sha256 != manifest.artifact.sha256) {
    throw StateError(
      "release.json artifact SHA-256 mismatch: expected ${manifest.artifact.sha256}, got ${descriptor.artifact.sha256}.",
    );
  }
  if (descriptor.artifact.length != manifest.artifact.length) {
    throw StateError(
      "release.json artifact length mismatch: expected ${manifest.artifact.length}, got ${descriptor.artifact.length}.",
    );
  }
}

void _warnLongCacheControl(http.Response response, StringSink output) {
  final cacheControl = response.headers["cache-control"];
  if (cacheControl == null) {
    return;
  }
  final match = RegExp(r"max-age=(\d+)").firstMatch(cacheControl);
  final maxAge = match == null ? null : int.tryParse(match.group(1)!);
  if (maxAge != null && maxAge > 300) {
    output.writeln(
      "Warning: hosted app-archive.json Cache-Control max-age is greater than 300 seconds.",
    );
  }
}

String _required(ArgResults results, String name) {
  final value = results[name] as String?;
  if (value == null || value.trim().isEmpty) {
    throw FormatException("Missing --$name.");
  }
  return value;
}
