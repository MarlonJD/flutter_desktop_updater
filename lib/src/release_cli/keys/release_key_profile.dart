import "dart:convert";
import "dart:io";

import "package:crypto/crypto.dart" as crypto;
import "package:desktop_updater/src/core/release_signature_verifier.dart";
import "package:desktop_updater/src/json/strict_json.dart";
import "package:path/path.dart" as path;

const _profileSchemaVersion = 1;
const _maxProfileBytes = 64 * 1024;
final _profileIdPattern = RegExp(r"^[0-9a-f]{32}$");
final _keyIdPattern = RegExp(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$");

/// Commit-safe public metadata for one update feed.
final class ReleaseKeyProfile {
  const ReleaseKeyProfile({
    required this.profileId,
    required this.feedUrl,
    required this.activeKeyId,
    required this.pendingKeyId,
    required this.publicKeys,
  });

  final String profileId;
  final String feedUrl;
  final String activeKeyId;
  final String? pendingKeyId;
  final Map<String, String> publicKeys;

  factory ReleaseKeyProfile.fromJson(Map<String, Object?> json) {
    _expectKeys(
      json,
      const {
        "schemaVersion",
        "profileId",
        "feedUrl",
        "activeKeyId",
        "pendingKeyId",
        "publicKeys",
      },
      required: const {
        "schemaVersion",
        "profileId",
        "feedUrl",
        "activeKeyId",
        "publicKeys",
      },
      name: "release key profile",
    );
    if (json["schemaVersion"] != _profileSchemaVersion) {
      throw const FormatException(
        "Release key profile schemaVersion must be 1.",
      );
    }
    final profileId = json["profileId"];
    if (profileId is! String || !_profileIdPattern.hasMatch(profileId)) {
      throw const FormatException(
        "Release key profile profileId must be 32 lowercase hex characters.",
      );
    }
    final feedUrl = json["feedUrl"];
    if (feedUrl is! String || !_isFeedUrl(feedUrl)) {
      throw const FormatException(
        "Release key profile feedUrl must be an absolute HTTP(S) URL.",
      );
    }
    final activeKeyId = _requiredKeyId(json["activeKeyId"], "activeKeyId");
    final pendingValue = json["pendingKeyId"];
    final pendingKeyId = pendingValue == null
        ? null
        : _requiredKeyId(pendingValue, "pendingKeyId");
    if (pendingKeyId == activeKeyId) {
      throw const FormatException(
        "Release key profile pendingKeyId must differ from activeKeyId.",
      );
    }
    final publicKeysValue = json["publicKeys"];
    if (publicKeysValue is! Map<String, Object?>) {
      throw const FormatException(
        "Release key profile publicKeys must be an object.",
      );
    }
    if (publicKeysValue.isEmpty || publicKeysValue.length > 32) {
      throw const FormatException(
        "Release key profile publicKeys must contain 1 to 32 keys.",
      );
    }
    final rawKeys = <String, String>{};
    for (final entry in publicKeysValue.entries) {
      final keyId = _requiredKeyId(entry.key, "publicKeys key");
      final value = entry.value;
      if (value is! String) {
        throw FormatException("Release key $keyId must be a base64 string.");
      }
      rawKeys[keyId] = value;
    }
    final publicKeys = normalizeReleasePublicKeys(rawKeys);
    if (!publicKeys.containsKey(activeKeyId)) {
      throw const FormatException(
        "Release key profile activeKeyId must exist in publicKeys.",
      );
    }
    if (pendingKeyId != null && !publicKeys.containsKey(pendingKeyId)) {
      throw const FormatException(
        "Release key profile pendingKeyId must exist in publicKeys.",
      );
    }
    return ReleaseKeyProfile(
      profileId: profileId,
      feedUrl: feedUrl,
      activeKeyId: activeKeyId,
      pendingKeyId: pendingKeyId,
      publicKeys: publicKeys,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        "schemaVersion": _profileSchemaVersion,
        "profileId": profileId,
        "feedUrl": feedUrl,
        "activeKeyId": activeKeyId,
        if (pendingKeyId != null) "pendingKeyId": pendingKeyId,
        "publicKeys": publicKeys,
      };

  ReleaseKeyProfile withPendingKey({
    required String keyId,
    required String publicKey,
  }) {
    if (pendingKeyId != null) {
      throw StateError("A release key profile already has a pending key.");
    }
    final updated = <String, String>{...publicKeys, keyId: publicKey};
    return ReleaseKeyProfile(
      profileId: profileId,
      feedUrl: feedUrl,
      activeKeyId: activeKeyId,
      pendingKeyId: keyId,
      publicKeys: normalizeReleasePublicKeys(updated),
    );
  }

  ReleaseKeyProfile activatePending() {
    final pending = pendingKeyId;
    if (pending == null) {
      throw StateError("Release key profile has no pending key.");
    }
    return ReleaseKeyProfile(
      profileId: profileId,
      feedUrl: feedUrl,
      activeKeyId: pending,
      pendingKeyId: null,
      publicKeys: publicKeys,
    );
  }

  ReleaseKeyProfile withPublicKeys(Map<String, String> keys) {
    return ReleaseKeyProfile(
      profileId: profileId,
      feedUrl: feedUrl,
      activeKeyId: activeKeyId,
      pendingKeyId: pendingKeyId,
      publicKeys: normalizeReleasePublicKeys(keys),
    );
  }
}

/// SHA-256 fingerprint of a raw Ed25519 public key.
String releaseKeyFingerprint(List<int> publicKeyBytes) {
  if (publicKeyBytes.length != 32) {
    throw const FormatException("Ed25519 public keys must contain 32 bytes.");
  }
  return "sha256:${crypto.sha256.convert(publicKeyBytes)}";
}

/// Generates a stable, readable key ID from the public-key fingerprint.
String releaseKeyIdForPublicKey(List<int> publicKeyBytes) {
  final fingerprint = releaseKeyFingerprint(publicKeyBytes);
  const prefix = "sha256:";
  return "release-${fingerprint.substring(prefix.length, prefix.length + 24)}";
}

/// Returns the default public profile path for an application project.
File defaultReleaseKeyProfileFile(Directory projectRoot) {
  return File(path.join(projectRoot.path, "desktop_updater.keys.json"));
}

/// Reads and validates a public profile with strict UTF-8 and JSON handling.
Future<ReleaseKeyProfile> readReleaseKeyProfile(File file) async {
  final bytes = await file.readAsBytes();
  if (bytes.length > _maxProfileBytes) {
    throw const FormatException("Release key profile is larger than 64 KiB.");
  }
  if (bytes.length >= 3 &&
      bytes[0] == 0xef &&
      bytes[1] == 0xbb &&
      bytes[2] == 0xbf) {
    throw const FormatException("Release key profile must not contain a BOM.");
  }
  late final String source;
  try {
    source = utf8.decode(bytes);
  } on FormatException {
    throw const FormatException("Release key profile must be strict UTF-8.");
  }
  final decoded = parseStrictJson(source);
  if (decoded is! Map<String, Object?>) {
    throw const FormatException("Release key profile must be a JSON object.");
  }
  return ReleaseKeyProfile.fromJson(decoded);
}

/// Atomically writes a public profile without silently overwriting a symlink.
Future<void> writeReleaseKeyProfile(
  File file,
  ReleaseKeyProfile profile, {
  bool replace = true,
}) async {
  final existingType = await FileSystemEntity.type(
    file.path,
    followLinks: false,
  );
  if (existingType == FileSystemEntityType.link) {
    throw const FormatException(
        "Release key profile path must not be a symlink.");
  }
  if (!replace && existingType != FileSystemEntityType.notFound) {
    throw StateError("Release key profile already exists.");
  }
  await file.parent.create(recursive: true);
  final temporary = File(
    "${file.path}.tmp-${DateTime.now().microsecondsSinceEpoch}",
  );
  try {
    await temporary.writeAsString(
      "${const JsonEncoder.withIndent("  ").convert(profile.toJson())}\n",
      flush: true,
    );
    await temporary.rename(file.path);
  } finally {
    if (await temporary.exists()) {
      await temporary.delete();
    }
  }
}

String _requiredKeyId(Object? value, String name) {
  if (value is! String || !_keyIdPattern.hasMatch(value)) {
    throw FormatException("Release key profile $name must be a safe key ID.");
  }
  return value;
}

bool _isFeedUrl(String value) {
  final uri = Uri.tryParse(value);
  return uri != null &&
      (uri.scheme == "https" || uri.scheme == "http") &&
      uri.host.isNotEmpty &&
      !value.contains("\n") &&
      !value.contains("\r");
}

void _expectKeys(
  Map<String, Object?> value,
  Set<String> allowed, {
  required Set<String> required,
  required String name,
}) {
  for (final key in value.keys) {
    if (!allowed.contains(key)) {
      throw FormatException("$name contains unknown key $key.");
    }
  }
  for (final key in required) {
    if (!value.containsKey(key)) {
      throw FormatException("$name is missing required key $key.");
    }
  }
}
