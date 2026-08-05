import "dart:convert";
import "dart:io";

import "package:args/args.dart";
import "package:cryptography_plus/cryptography_plus.dart";
import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:desktop_updater/src/core/release_index.dart";
import "package:desktop_updater/src/release_cli/keys/release_key_profile.dart";
import "package:desktop_updater/src/release_cli/keys/release_key_store.dart";
import "package:desktop_updater/src/release_cli/release_publish_config.dart";
import "package:desktop_updater/src/release_cli/release_signing_resolver.dart";
import "package:path/path.dart" as path;

/// Builds the argument parser for `desktop_updater:release sign`.
ArgParser buildSignParser() {
  return ArgParser()
    ..addFlag("help", abbr: "h", negatable: false)
    ..addOption("release", help: "Path to the release.json file to sign.")
    ..addOption(
      "app-archive",
      help: "Path to the final app-archive.json file to sign.",
    )
    ..addOption("config",
        help: "Path to desktop_updater.yaml for profile mode.")
    ..addOption("base-url", help: "Override updates.baseUrl for profile mode.")
    ..addOption("key-profile", help: "Feed-bound public key profile.")
    ..addOption("public-key-id", help: "Pinned public key id to write.")
    ..addOption(
      "private-key-env",
      help: "Environment variable containing base64 raw Ed25519 private seed.",
    )
    ..addOption(
      "private-key-file",
      help: "External file containing base64 raw Ed25519 private seed.",
    );
}

/// Runs `release sign` for a local `release.json` descriptor.
///
/// The private key must come from [environment] or an external key file so
/// secrets do not need to live in package configuration.
Future<int> runSignCommand(
  ArgResults results, {
  required Directory projectRoot,
  required StringSink output,
  Map<String, String>? environment,
  ReleaseKeySecretStore? keyStore,
}) async {
  if (results["help"] as bool) {
    output.writeln(buildSignParser().usage);
    return 0;
  }

  final releaseValue = results["release"] as String?;
  final appArchiveValue = results["app-archive"] as String?;
  if ((releaseValue == null || releaseValue.trim().isEmpty) &&
      (appArchiveValue == null || appArchiveValue.trim().isEmpty)) {
    throw const FormatException(
      "Provide --release, --app-archive, or both.",
    );
  }
  final hasDirectSigningOption = const [
    "public-key-id",
    "private-key-env",
    "private-key-file",
  ].any((name) {
    final value = results[name] as String?;
    return value != null && value.trim().isNotEmpty;
  });
  final profileValue = (results["key-profile"] as String?)?.trim();
  final profileRequested = profileValue != null && profileValue.isNotEmpty;
  final profileDiscovered = !hasDirectSigningOption &&
      (profileRequested ||
          await defaultReleaseKeyProfileFile(projectRoot).exists());
  final config = profileDiscovered
      ? await ReleasePublishConfig.load(
          projectRoot: projectRoot,
          cliOverrides: ReleasePublishOverrides(
            configPath: results["config"] as String?,
            baseUrl: results["base-url"] as String?,
          ),
        )
      : null;
  final signing = await resolveReleaseSigningOptions(
    results: results,
    projectRoot: projectRoot,
    environment: environment ?? Platform.environment,
    expectedFeedUrl: config?.baseUrl.resolve("app-archive.json"),
    keyStore: keyStore,
    requirePublicKeys: false,
  );

  if (releaseValue != null && releaseValue.trim().isNotEmpty) {
    final releaseFile = _resolveFile(
      projectRoot: projectRoot,
      value: releaseValue,
    );
    await ReleaseDescriptorSigner().sign(
      releaseFile: releaseFile,
      publicKeyId: signing.publicKeyId,
      privateKeyBase64: signing.privateKeyBase64,
    );
    output
      ..writeln("Signed release descriptor:")
      ..writeln(releaseFile.path)
      ..writeln();
  }
  if (appArchiveValue != null && appArchiveValue.trim().isNotEmpty) {
    final appArchiveFile = _resolveFile(
      projectRoot: projectRoot,
      value: appArchiveValue,
    );
    await ReleaseIndexSigner().sign(
      appArchiveFile: appArchiveFile,
      publicKeyId: signing.publicKeyId,
      privateKeyBase64: signing.privateKeyBase64,
    );
    output
      ..writeln("Signed app archive:")
      ..writeln(appArchiveFile.path)
      ..writeln();
  }
  output
    ..writeln("Public key id:")
    ..writeln(signing.publicKeyId);
  return 0;
}

/// Signs release descriptors with Ed25519 metadata.
class ReleaseDescriptorSigner {
  /// Creates a descriptor signer.
  ReleaseDescriptorSigner({Ed25519? algorithm})
      : _algorithm = algorithm ?? Ed25519();

  final Ed25519 _algorithm;

  /// Signs [releaseFile] and writes the signature into its `signature` field.
  Future<void> sign({
    required File releaseFile,
    required String publicKeyId,
    required String privateKeyBase64,
  }) async {
    final seed = _decodePrivateSeed(privateKeyBase64);
    final json = jsonDecode(await releaseFile.readAsString());
    if (json is! Map<String, dynamic>) {
      throw const FormatException("release.json must be a JSON object.");
    }

    final descriptorToSign = ReleaseDescriptor.fromJson({
      ...json,
      "signature": {
        "algorithm": "ed25519",
        "publicKeyId": publicKeyId,
        "value": "",
      },
    });
    final keyPair = await _algorithm.newKeyPairFromSeed(seed);
    final signature = await _algorithm.sign(
      descriptorToSign.canonicalSignatureBytes(),
      keyPair: keyPair,
    );
    final signedJson = descriptorToSign.toJson()
      ..["signature"] = ReleaseSignature(
        algorithm: "ed25519",
        publicKeyId: publicKeyId,
        value: base64Encode(signature.bytes),
      ).toJson();

    await releaseFile.writeAsString(
      "${const JsonEncoder.withIndent("  ").convert(signedJson)}\n",
    );
  }
}

/// Signs normalized app archive indexes with Ed25519 metadata.
class ReleaseIndexSigner {
  /// Creates an index signer.
  ReleaseIndexSigner({Ed25519? algorithm})
      : _algorithm = algorithm ?? Ed25519();

  final Ed25519 _algorithm;

  /// Signs the parsed final app archive and writes its signature envelope.
  Future<void> sign({
    required File appArchiveFile,
    required String publicKeyId,
    required String privateKeyBase64,
  }) async {
    final json = jsonDecode(await appArchiveFile.readAsString());
    if (json is! Map<String, dynamic>) {
      throw const FormatException("app-archive.json must be a JSON object.");
    }
    final signedIndex = await signIndex(
      index: ReleaseIndex.fromJson({
        ...json,
        "signature": {
          "algorithm": "ed25519",
          "publicKeyId": publicKeyId,
          "value": "",
        },
      }),
      publicKeyId: publicKeyId,
      privateKeyBase64: privateKeyBase64,
    );
    await appArchiveFile.writeAsString(
      "${const JsonEncoder.withIndent("  ").convert(signedIndex.toJson())}\n",
    );
  }

  /// Returns [index] with a signature produced from its canonical bytes.
  Future<ReleaseIndex> signIndex({
    required ReleaseIndex index,
    required String publicKeyId,
    required String privateKeyBase64,
  }) async {
    final normalizedPublicKeyId = publicKeyId.trim();
    if (normalizedPublicKeyId.isEmpty) {
      throw const FormatException("Ed25519 public key id must not be blank.");
    }
    final unsigned = ReleaseIndex.fromJson({
      ...index.toJson(),
      "signature": {
        "algorithm": "ed25519",
        "publicKeyId": normalizedPublicKeyId,
        "value": "",
      },
    });
    final keyPair = await _algorithm.newKeyPairFromSeed(
      _decodePrivateSeed(privateKeyBase64),
    );
    final signature = await _algorithm.sign(
      unsigned.canonicalSignatureBytes(),
      keyPair: keyPair,
    );
    return ReleaseIndex.fromJson({
      ...unsigned.toJson(),
      "signature": ReleaseSignature(
        algorithm: "ed25519",
        publicKeyId: normalizedPublicKeyId,
        value: base64Encode(signature.bytes),
      ).toJson(),
    });
  }
}

List<int> _decodePrivateSeed(String value) {
  final seed = base64Decode(value.trim());
  if (seed.length != 32) {
    throw const FormatException(
      "Ed25519 private key must be 32 raw bytes encoded as base64.",
    );
  }
  return seed;
}

File _resolveFile({
  required Directory projectRoot,
  required String value,
}) {
  final expanded = value.trim();
  if (path.isAbsolute(expanded)) {
    return File(expanded);
  }
  return File(path.join(projectRoot.path, expanded));
}
