import "dart:convert";
import "dart:io";

import "package:args/args.dart";
import "package:desktop_updater/src/core/artifact_verifier.dart";
import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:desktop_updater/src/core/release_index.dart";
import "package:desktop_updater/src/core/release_signature_verifier.dart";
import "package:desktop_updater/src/release_cli/publish_manifest.dart";
import "package:desktop_updater/src/version_info.dart";
import "package:http/http.dart" as http;

ArgParser buildValidateParser() {
  return ArgParser()
    ..addFlag("help", abbr: "h", negatable: false)
    ..addOption("manifest")
    ..addOption("from-version")
    ..addFlag("require-signature", negatable: false)
    ..addOption(
      "public-keys-env",
      help: "Environment variable containing JSON public key map.",
    );
}

Future<int> runValidateCommand(
  ArgResults results, {
  required StringSink output,
  Map<String, String>? environment,
}) async {
  if (results["help"] as bool) {
    output.writeln(buildValidateParser().usage);
    return 0;
  }

  final manifestFile = File(_required(results, "manifest"));
  final fromVersion = results["from-version"] as String?;
  await ReleaseValidator(
    artifactVerifier: _artifactVerifier(
      results: results,
      environment: environment ?? Platform.environment,
    ),
  ).validate(
    manifestFile: manifestFile,
    fromVersion: fromVersion,
    output: output,
  );
  return 0;
}

ArtifactVerifier _artifactVerifier({
  required ArgResults results,
  required Map<String, String> environment,
}) {
  if (!(results["require-signature"] as bool)) {
    return const ArtifactVerifier();
  }

  final envName = _required(results, "public-keys-env");
  final value = environment[envName];
  if (value == null || value.trim().isEmpty) {
    throw FormatException("Missing environment variable $envName.");
  }
  return ArtifactVerifier(
    policy: ArtifactVerificationPolicy.requireEd25519Signature(
      publicKeys: decodeReleasePublicKeysJson(value),
    ),
  );
}

class ReleaseValidator {
  ReleaseValidator({
    http.Client? client,
    this.artifactVerifier = const ArtifactVerifier(),
  }) : client = client ?? http.Client();

  final http.Client client;
  final ArtifactVerifier artifactVerifier;

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
    output.writeln("Hosted app archive: OK");
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
    final artifactFile = await _downloadArtifact(descriptor.artifact.url);
    try {
      await artifactVerifier.verifyArtifactFile(
        artifact: descriptor.artifact,
        file: artifactFile,
      );
      output
        ..writeln("Hosted artifact length: OK")
        ..writeln("Hosted artifact SHA-256: OK");
    } finally {
      if (await artifactFile.exists()) {
        final tempDir = artifactFile.parent;
        await tempDir.delete(recursive: true);
      }
    }
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
    final file = File("${tempDir.path}/artifact.zip");
    await file.writeAsBytes(response.bodyBytes);
    return file;
  }
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
          (item) => item.release.toString() != manifest.release.url.toString())
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
