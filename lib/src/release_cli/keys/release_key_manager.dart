import "dart:convert";
import "dart:io";
import "dart:math";

import "package:cryptography_plus/cryptography_plus.dart";
import "package:desktop_updater/src/release_cli/keys/release_key_bundle.dart";
import "package:desktop_updater/src/release_cli/keys/release_key_profile.dart";
import "package:desktop_updater/src/release_cli/keys/release_key_store.dart";

/// Coordinates profile lifecycle operations and private-key storage.
final class ReleaseKeyManager {
  ReleaseKeyManager({
    required this.projectRoot,
    required this.feedUrl,
    File? profileFile,
    ReleaseKeySecretStore? store,
    Ed25519? algorithm,
  })  : profileFile = profileFile ?? defaultReleaseKeyProfileFile(projectRoot),
        store = store ?? defaultReleaseKeySecretStore(),
        algorithm = algorithm ?? Ed25519();

  final Directory projectRoot;
  final Uri feedUrl;
  final File profileFile;
  final ReleaseKeySecretStore store;
  final Ed25519 algorithm;

  Future<ReleaseKeyProfile> readProfile() async {
    final profile = await readReleaseKeyProfile(profileFile);
    _checkFeed(profile);
    return profile;
  }

  Future<ReleaseKeyProfile> keygen(StringSink output) async {
    if (await profileFile.exists()) {
      final profile = await readProfile();
      final seed = await store.read(
        profileId: profile.profileId,
        keyId: profile.activeKeyId,
      );
      if (seed == null) {
        throw StateError(
          "The release key profile exists but its active secret is missing. "
          "Import an encrypted backup or use the existing direct signing flow; "
          "keygen will not regenerate it.",
        );
      }
      await verifySeed(profile.activeKeyId, seed, profile.publicKeys);
      _writeProfileSummary(output, profile, existing: true);
      return profile;
    }

    final seed = _randomBytes(32);
    final publicKey = await _publicKeyForSeed(seed);
    final keyId = releaseKeyIdForPublicKey(publicKey);
    final profile = ReleaseKeyProfile(
      profileId: _randomHex(16),
      feedUrl: feedUrl.toString(),
      activeKeyId: keyId,
      pendingKeyId: null,
      publicKeys: <String, String>{keyId: base64Encode(publicKey)},
    );
    await store.write(
      profileId: profile.profileId,
      keyId: keyId,
      seed: seed,
    );
    try {
      await writeReleaseKeyProfile(profileFile, profile, replace: false);
    } on Object {
      await store.delete(profileId: profile.profileId, keyId: keyId);
      rethrow;
    }
    _writeProfileSummary(output, profile, existing: false);
    return profile;
  }

  Future<ReleaseKeyProfile> adopt({
    required String publicKeyId,
    required String privateKeyBase64,
    required Map<String, String> trustedPublicKeys,
    required StringSink output,
  }) async {
    if (await profileFile.exists()) {
      throw StateError(
        "A release key profile already exists; refusing to overwrite it.",
      );
    }
    final seed = _decodeSeed(privateKeyBase64);
    final normalizedId = publicKeyId.trim();
    final normalizedKeys = Map<String, String>.unmodifiable(trustedPublicKeys);
    await verifySeed(normalizedId, seed, normalizedKeys);
    final profile = ReleaseKeyProfile(
      profileId: _randomHex(16),
      feedUrl: feedUrl.toString(),
      activeKeyId: normalizedId,
      pendingKeyId: null,
      publicKeys: normalizedKeys,
    );
    await store.write(
      profileId: profile.profileId,
      keyId: normalizedId,
      seed: seed,
    );
    try {
      await writeReleaseKeyProfile(profileFile, profile, replace: false);
    } on Object {
      await store.delete(profileId: profile.profileId, keyId: normalizedId);
      rethrow;
    }
    output
      ..writeln("Adopted existing release signing key.")
      ..writeln("Profile: ${profileFile.path}")
      ..writeln("Feed: ${profile.feedUrl}")
      ..writeln("Active key id: ${profile.activeKeyId}")
      ..writeln("Storage: ${store.description}")
      ..writeln("The existing key ID was preserved; no key was generated.");
    return profile;
  }

  Future<void> show(StringSink output) async {
    final profile = await readProfile();
    final active = await store.read(
      profileId: profile.profileId,
      keyId: profile.activeKeyId,
    );
    final pending = profile.pendingKeyId == null
        ? null
        : await store.read(
            profileId: profile.profileId,
            keyId: profile.pendingKeyId!,
          );
    output
      ..writeln("Release key profile: ${profileFile.path}")
      ..writeln("Profile ID: ${profile.profileId}")
      ..writeln("Feed: ${profile.feedUrl}")
      ..writeln("Active key id: ${profile.activeKeyId}")
      ..writeln("Active secret: ${active == null ? "missing" : "available"}")
      ..writeln("Pending key id: ${profile.pendingKeyId ?? "none"}")
      ..writeln(
          "Pending secret: ${pending == null ? "not applicable" : "available"}")
      ..writeln("Storage: ${store.description}")
      ..writeln("Public keys:")
      ..writeln(const JsonEncoder.withIndent("  ").convert(profile.publicKeys));
  }

  Future<void> export({
    required File outputFile,
    required String passphrase,
    required bool publicOnly,
    required bool force,
  }) async {
    final profile = await readProfile();
    if (publicOnly) {
      await _writeOutput(outputFile, profile.toJson(), force: force);
      return;
    }
    final privateKeys = <String, String>{};
    for (final keyId in profile.publicKeys.keys) {
      final seed = await store.read(
        profileId: profile.profileId,
        keyId: keyId,
      );
      if (seed == null) {
        if (keyId == profile.activeKeyId || keyId == profile.pendingKeyId) {
          throw StateError("The private key for $keyId is missing.");
        }
        continue;
      }
      await verifySeed(keyId, seed, profile.publicKeys);
      privateKeys[keyId] = base64Encode(seed);
    }
    final bundle = await const ReleaseKeyBundleCodec().encrypt(
      payload: <String, Object?>{
        "schemaVersion": 1,
        "profile": profile.toJson(),
        "privateKeys": privateKeys,
      },
      passphrase: passphrase,
    );
    await _writeRawOutput(outputFile, utf8.encode(bundle), force: force);
  }

  Future<ReleaseKeyProfile> importBundle({
    required File inputFile,
    required String passphrase,
    required StringSink output,
  }) async {
    final envelope = await inputFile.readAsString();
    final payload = await const ReleaseKeyBundleCodec().decrypt(
      envelope: envelope,
      passphrase: passphrase,
    );
    _expectBundlePayload(payload);
    final profileJson = payload["profile"]! as Map<String, Object?>;
    final profile = ReleaseKeyProfile.fromJson(profileJson);
    _checkFeed(profile);
    final privateKeysJson = payload["privateKeys"]! as Map<String, Object?>;
    final seeds = <String, List<int>>{};
    for (final entry in privateKeysJson.entries) {
      if (!profile.publicKeys.containsKey(entry.key) ||
          entry.value is! String) {
        throw const FormatException(
            "Release key bundle contains invalid key data.");
      }
      final seed = _decodeSeed(entry.value! as String);
      await verifySeed(entry.key, seed, profile.publicKeys);
      seeds[entry.key] = seed;
    }
    for (final requiredKey in <String?>[
      profile.activeKeyId,
      profile.pendingKeyId,
    ]) {
      if (requiredKey != null && !seeds.containsKey(requiredKey)) {
        throw StateError(
            "The bundle is missing required private key $requiredKey.");
      }
    }

    ReleaseKeyProfile? existing;
    if (await profileFile.exists()) {
      existing = await readProfile();
      if (!_sameProfile(existing, profile)) {
        throw StateError(
          "The imported profile conflicts with the existing project profile.",
        );
      }
    }
    final newlyWritten = <String>[];
    try {
      for (final entry in seeds.entries) {
        final old = await store.read(
          profileId: profile.profileId,
          keyId: entry.key,
        );
        await store.write(
          profileId: profile.profileId,
          keyId: entry.key,
          seed: entry.value,
        );
        if (old == null) newlyWritten.add(entry.key);
      }
      if (existing == null) {
        await writeReleaseKeyProfile(profileFile, profile, replace: false);
      }
    } on Object {
      for (final keyId in newlyWritten) {
        await store.delete(profileId: profile.profileId, keyId: keyId);
      }
      rethrow;
    }
    output
      ..writeln("Imported release key profile.")
      ..writeln("Profile: ${profileFile.path}")
      ..writeln("Active key id: ${profile.activeKeyId}")
      ..writeln("Storage: ${store.description}");
    return profile;
  }

  Future<ReleaseKeyProfile> rotate(StringSink output) async {
    final profile = await readProfile();
    final activeSeed = await store.read(
      profileId: profile.profileId,
      keyId: profile.activeKeyId,
    );
    if (activeSeed == null) {
      throw StateError("The active release secret is missing.");
    }
    await verifySeed(profile.activeKeyId, activeSeed, profile.publicKeys);
    if (profile.pendingKeyId != null) {
      output.writeln(
        "A pending key already exists: ${profile.pendingKeyId}. "
        "Publish its public key to clients, then run keys activate.",
      );
      return profile;
    }
    final seed = _randomBytes(32);
    final publicKey = await _publicKeyForSeed(seed);
    final keyId = releaseKeyIdForPublicKey(publicKey);
    await store.write(profileId: profile.profileId, keyId: keyId, seed: seed);
    try {
      await writeReleaseKeyProfile(
        profileFile,
        profile.withPendingKey(
          keyId: keyId,
          publicKey: base64Encode(publicKey),
        ),
      );
    } on Object {
      await store.delete(profileId: profile.profileId, keyId: keyId);
      rethrow;
    }
    final updated = await readProfile();
    output
      ..writeln("Prepared pending release key: $keyId")
      ..writeln("The active key remains ${updated.activeKeyId}.")
      ..writeln("Embed both public keys in clients before keys activate.");
    return updated;
  }

  Future<ReleaseKeyProfile> activate(StringSink output) async {
    final profile = await readProfile();
    final pending = profile.pendingKeyId;
    if (pending == null) {
      throw StateError("The release key profile has no pending key.");
    }
    final seed = await store.read(profileId: profile.profileId, keyId: pending);
    if (seed == null)
      throw StateError("The pending private key $pending is missing.");
    await verifySeed(pending, seed, profile.publicKeys);
    final updated = profile.activatePending();
    await writeReleaseKeyProfile(profileFile, updated);
    output
      ..writeln("Activated release key: ${updated.activeKeyId}")
      ..writeln("Retained previous public key: ${profile.activeKeyId}");
    return updated;
  }

  Future<void> verifySeed(
    String keyId,
    List<int> seed,
    Map<String, String> publicKeys,
  ) async {
    if (seed.length != 32) {
      throw const FormatException(
          "Ed25519 private seeds must contain 32 bytes.");
    }
    final publicKey = await _publicKeyForSeed(seed);
    if (base64Encode(publicKey) != publicKeys[keyId]) {
      throw StateError("Private key $keyId does not match its public key.");
    }
  }

  Future<List<int>> seedForActive(ReleaseKeyProfile profile) async {
    final seed = await store.read(
      profileId: profile.profileId,
      keyId: profile.activeKeyId,
    );
    if (seed == null) throw StateError("The active release secret is missing.");
    await verifySeed(profile.activeKeyId, seed, profile.publicKeys);
    return seed;
  }

  Future<List<int>> _publicKeyForSeed(List<int> seed) async {
    final pair = await algorithm.newKeyPairFromSeed(seed);
    try {
      return (await pair.extractPublicKey()).bytes;
    } finally {
      pair.destroy();
    }
  }

  void _checkFeed(ReleaseKeyProfile profile) {
    if (profile.feedUrl != feedUrl.toString()) {
      throw StateError(
        "Release key profile feed does not match the configured app archive: "
        "${profile.feedUrl} != $feedUrl.",
      );
    }
  }

  void _writeProfileSummary(
    StringSink output,
    ReleaseKeyProfile profile, {
    required bool existing,
  }) {
    output
      ..writeln(existing
          ? "Release key profile already exists; identity unchanged."
          : "Generated release signing key profile.")
      ..writeln("Profile: ${profileFile.path}")
      ..writeln("Feed: ${profile.feedUrl}")
      ..writeln("Active key id: ${profile.activeKeyId}")
      ..writeln("Storage: ${store.description}")
      ..writeln("Public key map:")
      ..writeln(const JsonEncoder.withIndent("  ").convert(profile.publicKeys))
      ..writeln("Back up with: release keys export --output release-key.dukey");
  }
}

void _expectBundlePayload(Map<String, Object?> payload) {
  if (payload.length != 3 ||
      payload["schemaVersion"] != 1 ||
      payload["profile"] is! Map<String, Object?> ||
      payload["privateKeys"] is! Map<String, Object?>) {
    throw const FormatException("Release key bundle payload is invalid.");
  }
}

bool _sameProfile(ReleaseKeyProfile left, ReleaseKeyProfile right) {
  if (left.profileId != right.profileId ||
      left.feedUrl != right.feedUrl ||
      left.activeKeyId != right.activeKeyId ||
      left.pendingKeyId != right.pendingKeyId ||
      left.publicKeys.length != right.publicKeys.length) {
    return false;
  }
  for (final entry in left.publicKeys.entries) {
    if (right.publicKeys[entry.key] != entry.value) return false;
  }
  return true;
}

List<int> _decodeSeed(String value) {
  try {
    final seed = base64Decode(value.trim());
    if (seed.length != 32) throw const FormatException();
    return seed;
  } on FormatException {
    throw const FormatException(
      "Ed25519 private seeds must be 32 raw bytes encoded as base64.",
    );
  }
}

List<int> _randomBytes(int length) {
  final random = Random.secure();
  return List<int>.generate(length, (_) => random.nextInt(256));
}

String _randomHex(int length) {
  return _randomBytes(length)
      .map((byte) => byte.toRadixString(16).padLeft(2, "0"))
      .join();
}

Future<void> _writeOutput(
  File file,
  Map<String, Object?> value, {
  required bool force,
}) async {
  await _writeRawOutput(
    file,
    utf8.encode("${const JsonEncoder.withIndent("  ").convert(value)}\n"),
    force: force,
  );
}

Future<void> _writeRawOutput(
  File file,
  List<int> bytes, {
  required bool force,
}) async {
  if (await file.exists() && !force) {
    throw StateError("Refusing to overwrite ${file.path}; pass --force.");
  }
  await file.parent.create(recursive: true);
  final temporary = File(
    "${file.path}.tmp-${DateTime.now().microsecondsSinceEpoch}",
  );
  try {
    await temporary.writeAsBytes(bytes, flush: true);
    if (Platform.isLinux || Platform.isMacOS) {
      final result = await Process.run("/bin/chmod", ["600", temporary.path]);
      if (result.exitCode != 0) {
        throw StateError("Unable to protect the key bundle output.");
      }
    }
    await temporary.rename(file.path);
  } finally {
    if (await temporary.exists()) await temporary.delete();
  }
}
