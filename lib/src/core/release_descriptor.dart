import "dart:convert";

/// Parsed `release.json` metadata for one platform-specific update artifact.
///
/// Descriptors use schema version 3 and point at one platform-specific artifact
/// plus the install strategy needed by the native helper. Optional delta
/// artifact metadata can be published ahead of runtime support; the updater
/// continues to choose the full artifact until delta verification and patch
/// application are implemented.
class ReleaseDescriptor {
  /// Creates release metadata for one downloadable artifact.
  const ReleaseDescriptor({
    required this.schemaVersion,
    required this.packageId,
    required this.appName,
    required this.version,
    required this.buildNumber,
    required this.platform,
    required this.channel,
    required this.artifact,
    required this.install,
    required this.minimumUpdaterVersion,
    required this.generatedAt,
    this.minimumOS = const {},
    this.deltaArtifacts = const [],
    this.signature,
  });

  /// Parses and validates a schema-v3 release descriptor from JSON.
  factory ReleaseDescriptor.fromJson(Map<String, dynamic> json) {
    final descriptor = ReleaseDescriptor(
      schemaVersion: json["schemaVersion"] as int? ?? 0,
      packageId: json["packageId"] as String? ?? "",
      appName: json["appName"] as String? ?? "",
      version: json["version"] as String? ?? "",
      buildNumber: json["buildNumber"] as int?,
      platform: json["platform"] as String? ?? "",
      channel: json["channel"] as String? ?? "stable",
      artifact: ReleaseArtifact.fromJson(
        json["artifact"] as Map<String, dynamic>? ?? const {},
      ),
      install: ReleaseInstall.fromJson(
        json["install"] as Map<String, dynamic>? ?? const {},
      ),
      minimumOS: _parseMinimumOS(json["minimumOS"]),
      deltaArtifacts: _parseDeltaArtifacts(json["deltaArtifacts"]),
      signature: json["signature"] == null
          ? null
          : ReleaseSignature.fromJson(
              json["signature"] as Map<String, dynamic>,
            ),
      minimumUpdaterVersion: json["minimumUpdaterVersion"] as String? ?? "",
      generatedAt: DateTime.parse(
        json["generatedAt"] as String? ?? "1970-01-01T00:00:00Z",
      ),
    )..validate();
    return descriptor;
  }

  /// Descriptor schema version. This package currently supports version 3.
  final int schemaVersion;

  /// Stable package identifier used to match releases to an app.
  final String packageId;

  /// Human-readable app name shown by update UI and release tooling.
  final String appName;

  /// Semantic app version for this release.
  final String version;

  /// Optional platform build number used as a same-version tiebreaker.
  final int? buildNumber;

  /// Target platform identifier, such as `macos`, `windows`, or `linux`.
  final String platform;

  /// Release channel, such as `stable`.
  final String channel;

  /// Downloadable artifact described by this release.
  final ReleaseArtifact artifact;

  /// Install strategy for the staged artifact.
  final ReleaseInstall install;

  /// Optional detached descriptor signature metadata.
  final ReleaseSignature? signature;

  /// Minimum updater package version expected to handle this descriptor.
  final String minimumUpdaterVersion;

  /// Optional minimum OS versions keyed by platform.
  final Map<String, String> minimumOS;

  /// Optional descriptor metadata for future delta update artifacts.
  final List<ReleaseDeltaArtifact> deltaArtifacts;

  /// UTC timestamp for descriptor generation.
  final DateTime generatedAt;

  /// Converts this descriptor to the schema-v3 JSON shape.
  Map<String, dynamic> toJson() {
    return {
      "schemaVersion": schemaVersion,
      "packageId": packageId,
      "appName": appName,
      "version": version,
      if (buildNumber != null) "buildNumber": buildNumber,
      "platform": platform,
      "channel": channel,
      "artifact": artifact.toJson(),
      "install": install.toJson(),
      if (signature != null) "signature": signature!.toJson(),
      "minimumUpdaterVersion": minimumUpdaterVersion,
      if (minimumOS.isNotEmpty) "minimumOS": minimumOS,
      if (deltaArtifacts.isNotEmpty)
        "deltaArtifacts": [
          for (final artifact in deltaArtifacts) artifact.toJson(),
        ],
      "generatedAt": generatedAt.toUtc().toIso8601String(),
    };
  }

  /// Returns the minimum OS value for [platform], when descriptor metadata has
  /// one.
  String? minimumOSForPlatform(String platform) {
    return minimumOS[platform];
  }

  /// Returns the stable JSON payload used for signing and verification.
  ///
  /// When [signature] is present, its value is blanked before sorting so the
  /// signature signs the descriptor envelope rather than itself.
  Map<String, dynamic> toCanonicalSignatureJson() {
    final json = toJson();
    final existingSignature = signature;
    if (existingSignature != null) {
      json["signature"] = existingSignature.copyWith(value: "").toJson();
    }
    return sortJsonValue(json) as Map<String, dynamic>;
  }

  /// Encodes [toCanonicalSignatureJson] as UTF-8 bytes.
  List<int> canonicalSignatureBytes() {
    return utf8.encode(jsonEncode(toCanonicalSignatureJson()));
  }

  /// Validates required schema, identity, artifact, and install fields.
  void validate() {
    if (schemaVersion != 3) {
      throw FormatException(
        "Unsupported release descriptor schema version: $schemaVersion",
      );
    }
    if (packageId.trim().isEmpty) {
      throw const FormatException("release.json packageId is required.");
    }
    if (version.trim().isEmpty) {
      throw const FormatException("release.json version is required.");
    }
    if (platform.trim().isEmpty) {
      throw const FormatException("release.json platform is required.");
    }
    if (buildNumber != null && buildNumber! < 0) {
      throw const FormatException(
        "release.json buildNumber must be zero or greater when provided.",
      );
    }
    artifact.validate();
    for (final deltaArtifact in deltaArtifacts) {
      deltaArtifact.validate();
    }
    install.validate(platform: platform, artifactKind: artifact.kind);
  }
}

Map<String, String> _parseMinimumOS(Object? value) {
  if (value == null) {
    return const {};
  }
  if (value is! Map) {
    throw const FormatException("release.json minimumOS must be an object.");
  }

  final minimumOS = <String, String>{};
  for (final entry in value.entries) {
    final platform = entry.key.toString().trim();
    final version = entry.value?.toString().trim() ?? "";
    if (platform.isEmpty || version.isEmpty) {
      throw const FormatException(
        "release.json minimumOS entries must use non-empty strings.",
      );
    }
    minimumOS[platform] = version;
  }
  return Map.unmodifiable(minimumOS);
}

List<ReleaseDeltaArtifact> _parseDeltaArtifacts(Object? value) {
  if (value == null) {
    return const [];
  }
  if (value is! List) {
    throw const FormatException("release.json deltaArtifacts must be a list.");
  }

  final artifacts = <ReleaseDeltaArtifact>[];
  for (final entry in value) {
    if (entry is! Map) {
      throw const FormatException(
        "release.json deltaArtifacts entries must be objects.",
      );
    }
    artifacts.add(
      ReleaseDeltaArtifact.fromJson(Map<String, dynamic>.from(entry)),
    );
  }
  return List.unmodifiable(artifacts);
}

List<String> _parseStringList(Object? value, String displayName) {
  if (value == null) {
    return const [];
  }
  if (value is! List) {
    throw FormatException("release.json $displayName must be a list.");
  }
  return List.unmodifiable([for (final entry in value) entry.toString()]);
}

/// Download metadata for the artifact referenced by a descriptor.
class ReleaseArtifact {
  /// Creates artifact metadata.
  const ReleaseArtifact({
    required this.kind,
    required this.url,
    required this.sha256,
    required this.length,
  });

  /// Parses artifact metadata from the descriptor `artifact` object.
  factory ReleaseArtifact.fromJson(Map<String, dynamic> json) {
    return ReleaseArtifact(
      kind: json["kind"] as String? ?? "",
      url: Uri.parse(json["url"] as String? ?? ""),
      sha256: json["sha256"] as String? ?? "",
      length: json["length"] as int? ?? -1,
    );
  }

  /// Artifact type. Version 3 descriptors support `zip`, `dmg`, and
  /// `pkgInstaller`.
  final String kind;

  /// Absolute URL for downloading the artifact.
  final Uri url;

  /// Expected lowercase hexadecimal SHA-256 digest.
  final String sha256;

  /// Expected artifact length in bytes.
  final int length;

  /// Converts this artifact to descriptor JSON.
  Map<String, dynamic> toJson() {
    return {
      "kind": kind,
      "url": url.toString(),
      "sha256": sha256,
      "length": length,
    };
  }

  /// Validates artifact kind, digest shape, and byte length.
  void validate() {
    if (kind != "zip" && kind != "dmg" && kind != "pkgInstaller") {
      throw FormatException("Unsupported release artifact kind: $kind");
    }
    if (!RegExp(r"^[0-9a-f]{64}$").hasMatch(sha256)) {
      throw const FormatException(
        "release.json artifact.sha256 must be 64 lowercase hex characters.",
      );
    }
    if (length < 0) {
      throw const FormatException("release.json artifact.length is required.");
    }
  }
}

/// Descriptor metadata for a future delta update artifact.
class ReleaseDeltaArtifact {
  /// Creates delta artifact metadata.
  const ReleaseDeltaArtifact({
    required this.fromVersion,
    required this.kind,
    required this.url,
    required this.sha256,
    required this.length,
  });

  /// Parses delta artifact metadata from a descriptor entry.
  factory ReleaseDeltaArtifact.fromJson(Map<String, dynamic> json) {
    return ReleaseDeltaArtifact(
      fromVersion: json["fromVersion"] as String? ?? "",
      kind: json["kind"] as String? ?? "",
      url: Uri.parse(json["url"] as String? ?? ""),
      sha256: json["sha256"] as String? ?? "",
      length: json["length"] as int? ?? -1,
    );
  }

  /// Source app version that this delta can patch from.
  final String fromVersion;

  /// Delta artifact type. Version 3 descriptors currently reserve `bsdiff`.
  final String kind;

  /// Absolute URL for downloading the delta artifact.
  final Uri url;

  /// Expected lowercase hexadecimal SHA-256 digest.
  final String sha256;

  /// Expected delta artifact length in bytes.
  final int length;

  /// Converts this delta artifact to descriptor JSON.
  Map<String, dynamic> toJson() {
    return {
      "fromVersion": fromVersion,
      "kind": kind,
      "url": url.toString(),
      "sha256": sha256,
      "length": length,
    };
  }

  /// Throws because runtime delta verification is not implemented yet.
  void ensureRuntimeSupported() {
    throw UnsupportedError(
      "Delta update artifacts are not supported yet; use the full zip "
      "artifact.",
    );
  }

  /// Validates delta metadata shape without enabling runtime application.
  void validate() {
    if (fromVersion.trim().isEmpty) {
      throw const FormatException(
        "release.json deltaArtifacts.fromVersion is required.",
      );
    }
    if (kind != "bsdiff") {
      throw FormatException("Unsupported release delta artifact kind: $kind");
    }
    if (!RegExp(r"^[0-9a-f]{64}$").hasMatch(sha256)) {
      throw const FormatException(
        "release.json deltaArtifacts.sha256 must be 64 lowercase hex "
        "characters.",
      );
    }
    if (length < 0) {
      throw const FormatException(
        "release.json deltaArtifacts.length is required.",
      );
    }
  }
}

/// Install metadata for a staged release artifact.
class ReleaseInstall {
  /// Creates install metadata with the requested [strategy].
  const ReleaseInstall({required this.strategy, this.macosDmg, this.macosPkg});

  /// Parses install metadata from the descriptor `install` object.
  factory ReleaseInstall.fromJson(Map<String, dynamic> json) {
    return ReleaseInstall(
      strategy: json["strategy"] as String? ?? "",
      macosDmg: json["macosDmg"] == null
          ? null
          : ReleaseMacOSDmgInstall.fromJson(
              json["macosDmg"] as Map<String, dynamic>,
            ),
      macosPkg: json["macosPkg"] == null
          ? null
          : ReleaseMacOSPkgInstall.fromJson(
              json["macosPkg"] as Map<String, dynamic>,
            ),
    );
  }

  /// Native helper strategy used to install the staged artifact.
  final String strategy;

  /// macOS DMG update metadata.
  final ReleaseMacOSDmgInstall? macosDmg;

  /// macOS PKG installer metadata.
  final ReleaseMacOSPkgInstall? macosPkg;

  /// Converts this install metadata to descriptor JSON.
  Map<String, dynamic> toJson() {
    return {
      "strategy": strategy,
      if (macosDmg != null) "macosDmg": macosDmg!.toJson(),
      if (macosPkg != null) "macosPkg": macosPkg!.toJson(),
    };
  }

  /// Validates that an install strategy is present.
  void validate({String? platform, String? artifactKind}) {
    if (strategy.trim().isEmpty) {
      throw const FormatException("release.json install.strategy is required.");
    }
    if (artifactKind == "dmg") {
      if (platform != "macos" || strategy != "wholeBundleReplace") {
        throw const FormatException(
          "release.json dmg artifacts are only supported for macos "
          "wholeBundleReplace.",
        );
      }
      if (macosDmg == null) {
        throw const FormatException(
          "release.json install.macosDmg is required for dmg artifacts.",
        );
      }
      macosDmg!.validate();
    }
    if (artifactKind == "pkgInstaller") {
      if (platform != "macos" || strategy != "pkgInstaller") {
        throw const FormatException(
          "release.json pkgInstaller artifacts require install.strategy "
          "pkgInstaller on macos.",
        );
      }
      if (macosPkg == null) {
        throw const FormatException(
          "release.json install.macosPkg is required for pkgInstaller.",
        );
      }
      macosPkg!.validate();
    }
    if (strategy == "pkgInstaller" && artifactKind != "pkgInstaller") {
      throw const FormatException(
        "release.json pkgInstaller strategy is only supported for "
        "pkgInstaller artifacts.",
      );
    }
  }
}

/// macOS DMG update metadata from `release.json`.
class ReleaseMacOSDmgInstall {
  /// Creates DMG update metadata.
  const ReleaseMacOSDmgInstall({
    required this.appBundleName,
    required this.verifyPrimarySignature,
  });

  /// Parses DMG update metadata.
  factory ReleaseMacOSDmgInstall.fromJson(Map<String, dynamic> json) {
    return ReleaseMacOSDmgInstall(
      appBundleName: json["appBundleName"] as String? ?? "",
      verifyPrimarySignature: json["verifyPrimarySignature"] as bool? ?? true,
    );
  }

  /// Simple `.app` bundle name expected in the mounted DMG.
  final String appBundleName;

  /// Whether to assess the DMG primary signature before mounting.
  final bool verifyPrimarySignature;

  /// Converts this policy to descriptor JSON.
  Map<String, dynamic> toJson() {
    return {
      "appBundleName": appBundleName,
      "verifyPrimarySignature": verifyPrimarySignature,
    };
  }

  /// Validates the DMG policy.
  void validate() {
    if (!appBundleName.endsWith(".app") || appBundleName.contains("/")) {
      throw const FormatException(
        "release.json install.macosDmg.appBundleName must be a simple .app "
        "name.",
      );
    }
  }
}

/// macOS PKG installer metadata from `release.json`.
class ReleaseMacOSPkgInstall {
  /// Creates PKG installer metadata.
  const ReleaseMacOSPkgInstall({
    required this.launchMode,
    required this.expectedPackageIds,
    required this.relaunchAfterInstall,
  });

  /// Parses PKG installer metadata.
  factory ReleaseMacOSPkgInstall.fromJson(Map<String, dynamic> json) {
    return ReleaseMacOSPkgInstall(
      launchMode: json["launchMode"] as String? ?? "installerApp",
      expectedPackageIds: _parseStringList(
        json["expectedPackageIds"],
        "install.macosPkg.expectedPackageIds",
      ),
      relaunchAfterInstall: json["relaunchAfterInstall"] as bool? ?? false,
    );
  }

  /// Native handoff mode. The runtime currently supports Installer.app only.
  final String launchMode;

  /// Package identifiers expected inside the installer package metadata.
  final List<String> expectedPackageIds;

  /// Whether the app should relaunch after Installer.app completes.
  final bool relaunchAfterInstall;

  /// Converts this policy to descriptor JSON.
  Map<String, dynamic> toJson() {
    return {
      "launchMode": launchMode,
      "expectedPackageIds": expectedPackageIds,
      "relaunchAfterInstall": relaunchAfterInstall,
    };
  }

  /// Validates the PKG policy.
  void validate() {
    if (launchMode != "installerApp") {
      throw const FormatException(
        "release.json install.macosPkg.launchMode must be installerApp.",
      );
    }
    if (expectedPackageIds.isEmpty) {
      throw const FormatException(
        "release.json install.macosPkg.expectedPackageIds must not be empty.",
      );
    }
  }
}

/// Signature metadata embedded in a release descriptor.
class ReleaseSignature {
  /// Creates descriptor signature metadata.
  const ReleaseSignature({
    required this.algorithm,
    required this.publicKeyId,
    required this.value,
  });

  /// Parses signature metadata from the descriptor `signature` object.
  factory ReleaseSignature.fromJson(Map<String, dynamic> json) {
    return ReleaseSignature(
      algorithm: json["algorithm"] as String? ?? "",
      publicKeyId: json["publicKeyId"] as String? ?? "",
      value: json["value"] as String? ?? "",
    );
  }

  /// Signature algorithm identifier, currently expected to be `ed25519`.
  final String algorithm;

  /// Identifier for the pinned public key that should verify [value].
  final String publicKeyId;

  /// Base64-encoded signature bytes.
  final String value;

  /// Converts this signature metadata to descriptor JSON.
  Map<String, dynamic> toJson() {
    return {"algorithm": algorithm, "publicKeyId": publicKeyId, "value": value};
  }

  /// Returns a copy with a replacement signature [value].
  ReleaseSignature copyWith({String? value}) {
    return ReleaseSignature(
      algorithm: algorithm,
      publicKeyId: publicKeyId,
      value: value ?? this.value,
    );
  }
}

/// Recursively sorts JSON map keys for deterministic descriptor signing.
Object? sortJsonValue(Object? value) {
  if (value is Map) {
    final sorted = <String, dynamic>{};
    final keys = value.keys.map((key) => key.toString()).toList()..sort();
    for (final key in keys) {
      sorted[key] = sortJsonValue(value[key]);
    }
    return sorted;
  }

  if (value is List) {
    return value.map(sortJsonValue).toList(growable: false);
  }

  return value;
}
