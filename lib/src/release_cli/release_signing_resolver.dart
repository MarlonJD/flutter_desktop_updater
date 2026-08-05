import "dart:convert";
import "dart:io";

import "package:args/args.dart";
import "package:cryptography_plus/cryptography_plus.dart";
import "package:desktop_updater/src/core/release_signature_verifier.dart";
import "package:desktop_updater/src/release_cli/keys/release_key_manager.dart";
import "package:desktop_updater/src/release_cli/keys/release_key_profile.dart";
import "package:desktop_updater/src/release_cli/keys/release_key_store.dart";
import "package:desktop_updater/src/release_cli/release_publisher.dart";
import "package:path/path.dart" as path;

/// Direct signing material retained for CI and existing 3.0 feeds.
final class DirectReleaseSigningMaterial {
  const DirectReleaseSigningMaterial({
    required this.publicKeyId,
    required this.privateSeed,
    required this.trustedPublicKeys,
  });

  final String publicKeyId;
  final List<int> privateSeed;
  final Map<String, String> trustedPublicKeys;
}

/// Resolves profile-backed or complete direct signing inputs without hybrids.
Future<ReleaseSigningOptions> resolveReleaseSigningOptions({
  required ArgResults results,
  required Directory projectRoot,
  required Map<String, String> environment,
  Uri? expectedFeedUrl,
  ReleaseKeySecretStore? keyStore,
  bool requirePublicKeys = true,
}) async {
  final direct = _hasAnyDirectOption(results);
  final profileValue = _option(results, "key-profile");
  if (direct && profileValue != null) {
    throw const FormatException(
      "Do not combine --key-profile with direct signing options.",
    );
  }
  if (direct) {
    final material = await readDirectReleaseSigningMaterial(
      results: results,
      projectRoot: projectRoot,
      environment: environment,
      requirePublicKeys: requirePublicKeys,
    );
    return ReleaseSigningOptions(
      publicKeyId: material.publicKeyId,
      privateKeyBase64: base64Encode(material.privateSeed),
      trustedReleasePublicKeys: material.trustedPublicKeys,
    );
  }

  final profileFile = _profileFile(projectRoot, profileValue);
  if (!await profileFile.exists()) {
    throw FormatException(
      requirePublicKeys
          ? "Canonical release publish requires signed metadata: provide "
              "--public-key-id, --public-keys-env, and exactly one of "
              "--private-key-env or --private-key-file, or run release keygen."
          : "No release key profile was found. Run release keygen or provide "
              "the complete direct signing inputs.",
    );
  }
  if (expectedFeedUrl == null) {
    throw const FormatException(
      "Profile-backed signing requires the publishing config so the exact "
      "app-archive.json feed can be verified.",
    );
  }
  final store = keyStore ?? defaultReleaseKeySecretStore();
  final manager = ReleaseKeyManager(
    projectRoot: projectRoot,
    feedUrl: expectedFeedUrl,
    profileFile: profileFile,
    store: store,
  );
  final profile = await manager.readProfile();
  final seed = await manager.seedForActive(profile);
  return ReleaseSigningOptions(
    publicKeyId: profile.activeKeyId,
    privateKeyBase64: base64Encode(seed),
    trustedReleasePublicKeys: profile.publicKeys,
  );
}

/// Resolves the public map for `release validate` without opening private
/// storage. Profile mode is bound to the manifest's exact app-archive URL.
Future<Map<String, String>?> resolveReleasePublicKeys({
  required ArgResults results,
  required Directory projectRoot,
  required Map<String, String> environment,
  required Uri expectedFeedUrl,
  required bool candidateOnly,
}) async {
  if (candidateOnly) return null;
  final profileValue = _option(results, "key-profile");
  final publicKeysEnv = _option(results, "public-keys-env");
  if (profileValue != null && publicKeysEnv != null) {
    throw const FormatException(
      "Do not combine --key-profile with --public-keys-env.",
    );
  }
  if (publicKeysEnv != null) {
    return decodeReleasePublicKeysJson(
        _readEnvironment(environment, publicKeysEnv));
  }
  final profileFile = _profileFile(projectRoot, profileValue);
  if (!await profileFile.exists()) {
    throw const FormatException(
      "Production validation requires --public-keys-env or a release key profile.",
    );
  }
  final profile = await readReleaseKeyProfile(profileFile);
  if (profile.feedUrl != expectedFeedUrl.toString()) {
    throw StateError(
      "Release key profile feed does not match the validation manifest.",
    );
  }
  return profile.publicKeys;
}

/// Reads the complete legacy environment/file signing contract.
Future<DirectReleaseSigningMaterial> readDirectReleaseSigningMaterial({
  required ArgResults results,
  required Directory projectRoot,
  required Map<String, String> environment,
  required bool requirePublicKeys,
}) async {
  final publicKeyId = _option(results, "public-key-id");
  final privateEnv = _option(results, "private-key-env");
  final privateFile = _option(results, "private-key-file");
  final publicKeysEnv = _option(results, "public-keys-env");
  if (publicKeyId == null) {
    throw const FormatException("Direct signing requires --public-key-id.");
  }
  if ((privateEnv == null) == (privateFile == null)) {
    throw const FormatException(
      "Provide exactly one of --private-key-env or --private-key-file.",
    );
  }
  if (requirePublicKeys && publicKeysEnv == null) {
    throw const FormatException(
      "Direct publishing requires --public-keys-env.",
    );
  }
  if (!requirePublicKeys && publicKeysEnv != null) {
    throw const FormatException(
      "--public-keys-env is only supported by release publish and keys adopt.",
    );
  }
  final privateValue = privateEnv == null
      ? await _readKeyFile(projectRoot, privateFile!)
      : _readEnvironment(environment, privateEnv);
  final privateSeed = _decodePrivateSeed(privateValue);
  final trustedPublicKeys = publicKeysEnv == null
      ? await _derivedPublicKeyMap(publicKeyId, privateSeed)
      : decodeReleasePublicKeysJson(
          _readEnvironment(environment, publicKeysEnv));
  if (!trustedPublicKeys.containsKey(publicKeyId)) {
    throw StateError(
        "Direct signing public key map does not contain $publicKeyId.");
  }
  final derived = await _derivedPublicKeyMap(publicKeyId, privateSeed);
  if (derived[publicKeyId] != trustedPublicKeys[publicKeyId]) {
    throw StateError("Private key $publicKeyId does not match its public key.");
  }
  return DirectReleaseSigningMaterial(
    publicKeyId: publicKeyId,
    privateSeed: privateSeed,
    trustedPublicKeys: trustedPublicKeys,
  );
}

String? _option(ArgResults results, String name) {
  dynamic value;
  try {
    value = results[name];
  } on ArgumentError {
    return null;
  }
  final trimmed = (value as String?)?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

bool _hasAnyDirectOption(ArgResults results) {
  return [
    "public-key-id",
    "private-key-env",
    "private-key-file",
    "public-keys-env",
  ].any((name) => _option(results, name) != null);
}

File _profileFile(Directory projectRoot, String? value) {
  if (value == null) return defaultReleaseKeyProfileFile(projectRoot);
  return File(
    path.isAbsolute(value) ? value : path.join(projectRoot.path, value),
  );
}

String _readEnvironment(Map<String, String> environment, String name) {
  final value = environment[name];
  if (value == null || value.trim().isEmpty) {
    throw FormatException("Missing environment variable $name.");
  }
  return value;
}

Future<String> _readKeyFile(Directory projectRoot, String value) async {
  final file = File(
    path.isAbsolute(value) ? value : path.join(projectRoot.path, value),
  );
  return file.readAsString();
}

List<int> _decodePrivateSeed(String value) {
  try {
    final seed = base64Decode(value.trim());
    if (seed.length != 32) throw const FormatException();
    return seed;
  } on FormatException {
    throw const FormatException(
      "Ed25519 private key must be 32 raw bytes encoded as base64.",
    );
  }
}

Future<Map<String, String>> _derivedPublicKeyMap(
  String publicKeyId,
  List<int> seed,
) async {
  final keyPair = await Ed25519().newKeyPairFromSeed(seed);
  try {
    final publicKey = await keyPair.extractPublicKey();
    return <String, String>{publicKeyId: base64Encode(publicKey.bytes)};
  } finally {
    keyPair.destroy();
  }
}
