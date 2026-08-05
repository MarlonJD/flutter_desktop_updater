import "dart:convert";
import "dart:io";

import "package:args/args.dart";
import "package:desktop_updater/src/release_cli/keys/release_key_manager.dart";
import "package:desktop_updater/src/release_cli/keys/release_key_profile.dart";
import "package:desktop_updater/src/release_cli/keys/release_key_store.dart";
import "package:desktop_updater/src/release_cli/release_publisher.dart";
import "package:path/path.dart" as path;

/// Resolves the only supported release-signing source: a feed-bound profile.
Future<ReleaseSigningOptions> resolveReleaseSigningOptions({
  required ArgResults results,
  required Directory projectRoot,
  Uri? expectedFeedUrl,
  ReleaseKeySecretStore? keyStore,
}) async {
  final feedUrl = expectedFeedUrl;
  if (feedUrl == null) {
    throw const FormatException(
      "Profile-backed signing requires the publishing config so the exact "
      "app-archive.json feed can be verified.",
    );
  }
  final profileFile =
      _profileFile(projectRoot, _option(results, "key-profile"));
  if (!await profileFile.exists()) {
    throw FormatException(_missingProfileMessage(profileFile));
  }
  final manager = ReleaseKeyManager(
    projectRoot: projectRoot,
    feedUrl: feedUrl,
    profileFile: profileFile,
    store: keyStore,
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
  required Uri expectedFeedUrl,
  required bool candidateOnly,
}) async {
  if (candidateOnly) return null;
  final profileFile =
      _profileFile(projectRoot, _option(results, "key-profile"));
  if (!await profileFile.exists()) {
    throw FormatException(_missingProfileMessage(profileFile));
  }
  final profile = await readReleaseKeyProfile(profileFile);
  if (profile.feedUrl != expectedFeedUrl.toString()) {
    throw StateError(
      "Release key profile feed does not match the validation manifest.",
    );
  }
  return profile.publicKeys;
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

File _profileFile(Directory projectRoot, String? value) {
  if (value == null) return defaultReleaseKeyProfileFile(projectRoot);
  return File(
    path.isAbsolute(value) ? value : path.join(projectRoot.path, value),
  );
}

String _missingProfileMessage(File profileFile) {
  return "No release key profile was found at ${profileFile.path}. Run "
      "`release keygen` for a new feed, or run `release keys adopt --input "
      "<protected.json> --output <encrypted.dukey>` for an existing feed. "
      "The plaintext adoption input is migration-only and must be deleted "
      "after the encrypted bundle is exported.";
}
