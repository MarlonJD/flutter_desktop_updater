import "dart:convert";

import "package:crypto/crypto.dart" as crypto;
import "package:desktop_updater/src/version_info.dart";

/// Parsed `app-archive.json` index for zip-first update discovery.
class ReleaseIndex {
  /// Creates a release index.
  const ReleaseIndex({
    required this.schemaVersion,
    required this.appName,
    required this.items,
  });

  /// Parses and validates a schema-v3 app archive index from JSON.
  factory ReleaseIndex.fromJson(Map<String, dynamic> json) {
    final schemaVersionValue = json["schemaVersion"] as int?;
    if (schemaVersionValue != 3) {
      throw const FormatException(
        "Release index must include schemaVersion 3.",
      );
    }
    const schemaVersion = 3;
    return ReleaseIndex(
      schemaVersion: schemaVersion,
      appName: json["appName"] as String? ?? "",
      items: (json["items"] as List<dynamic>? ?? const [])
          .map(
            (item) => ReleaseIndexItem.fromJson(
              item as Map<String, dynamic>,
            ),
          )
          .toList(growable: false),
    );
  }

  /// App archive schema version. This package currently supports version 3.
  final int schemaVersion;

  /// Human-readable app name shared by the indexed releases.
  final String appName;

  /// Release entries available for platforms and channels.
  final List<ReleaseIndexItem> items;

  /// Converts this app archive to JSON.
  Map<String, dynamic> toJson() {
    return {
      "schemaVersion": schemaVersion,
      "appName": appName,
      "items": items.map((item) => item.toJson()).toList(),
    };
  }
}

/// One selectable release entry inside an app archive index.
class ReleaseIndexItem {
  /// Creates an index item pointing to a versioned release descriptor.
  const ReleaseIndexItem({
    required this.version,
    required this.buildNumber,
    required this.platform,
    required this.channel,
    required this.mandatory,
    required this.release,
    this.rollout,
  });

  /// Parses a release index item from JSON.
  factory ReleaseIndexItem.fromJson(Map<String, dynamic> json) {
    final releaseValue = json["release"];
    if (releaseValue == null) {
      throw const FormatException(
        "Release index schema v3 items must include release.",
      );
    }

    return ReleaseIndexItem(
      version: json["version"] as String? ?? "",
      buildNumber:
          (json["buildNumber"] as int?) ?? (json["shortVersion"] as int?),
      platform: json["platform"] as String? ?? "",
      channel: json["channel"] as String? ?? "stable",
      mandatory: json["mandatory"] as bool? ?? false,
      release: Uri.parse(releaseValue?.toString() ?? ""),
      rollout: _parseReleaseRollout(json["rollout"]),
    );
  }

  /// Semantic app version for this release.
  final String version;

  /// Optional platform build number used as a same-version tiebreaker.
  final int? buildNumber;

  /// Target platform identifier, such as `macos`, `windows`, or `linux`.
  final String platform;

  /// Release channel, such as `stable`.
  final String channel;

  /// Whether the release should be treated as mandatory by UI.
  final bool mandatory;

  /// URL for the versioned `release.json` descriptor.
  final Uri release;

  /// Optional deterministic rollout gate for this release item.
  final ReleaseRollout? rollout;

  /// Converts this index item to JSON.
  Map<String, dynamic> toJson() {
    return {
      "version": version,
      if (buildNumber != null) "buildNumber": buildNumber,
      "platform": platform,
      "channel": channel,
      "mandatory": mandatory,
      "release": release.toString(),
      if (rollout != null) "rollout": rollout!.toJson(),
    };
  }
}

/// Deterministic staged rollout settings for a release index item.
class ReleaseRollout {
  /// Creates rollout metadata for a release index item.
  const ReleaseRollout({
    required this.percentage,
    required this.salt,
  });

  /// Parses rollout metadata from `app-archive.json`.
  factory ReleaseRollout.fromJson(Map<String, dynamic> json) {
    final percentageValue = json["percentage"];
    if (percentageValue is! int ||
        percentageValue < 0 ||
        percentageValue > 100) {
      throw const FormatException(
        "Release rollout percentage must be an integer from 0 to 100.",
      );
    }

    final saltValue = json["salt"];
    if (saltValue is! String || saltValue.trim().isEmpty) {
      throw const FormatException(
        "Release rollout salt must be a non-empty string.",
      );
    }

    return ReleaseRollout(
      percentage: percentageValue,
      salt: saltValue,
    );
  }

  /// Percentage of installations eligible for this item, from 0 to 100.
  final int percentage;

  /// App-owned stable salt for this rollout cohort.
  final String salt;

  /// Whether this rollout includes [installationIdentity] on [channel].
  bool includes({
    required String channel,
    required String? installationIdentity,
  }) {
    if (percentage >= 100) {
      return true;
    }
    if (percentage <= 0) {
      return false;
    }

    final identity = installationIdentity?.trim();
    if (identity == null || identity.isEmpty) {
      return false;
    }

    return _rolloutBucket(
          salt: salt,
          channel: channel,
          installationIdentity: identity,
        ) <
        percentage;
  }

  /// Converts this rollout metadata to JSON.
  Map<String, dynamic> toJson() {
    return {
      "percentage": percentage,
      "salt": salt,
    };
  }
}

/// Selects the newest matching release for [platform], [channel], and version.
///
/// Returns `null` when the index has no release newer than [currentVersion].
ReleaseIndexItem? selectReleaseIndexItem({
  required ReleaseIndex index,
  required String platform,
  required DesktopVersionInfo currentVersion,
  String channel = "stable",
  String? installationIdentity,
}) {
  final candidates = index.items
      .where((item) => item.platform == platform)
      .where((item) => item.channel == channel)
      .where((item) => _isRolloutEligible(item, installationIdentity))
      .where((item) => _isReleaseIndexItemNewer(item, currentVersion))
      .toList(growable: false);

  if (candidates.isEmpty) {
    return null;
  }

  candidates.sort(_compareReleaseIndexItems);
  return candidates.last;
}

ReleaseRollout? _parseReleaseRollout(Object? value) {
  if (value == null) {
    return null;
  }
  if (value is! Map<String, dynamic>) {
    throw const FormatException(
      "Release index rollout must be an object.",
    );
  }
  return ReleaseRollout.fromJson(value);
}

bool _isRolloutEligible(
  ReleaseIndexItem item,
  String? installationIdentity,
) {
  final rollout = item.rollout;
  if (rollout == null) {
    return true;
  }
  return rollout.includes(
    channel: item.channel,
    installationIdentity: installationIdentity,
  );
}

int _rolloutBucket({
  required String salt,
  required String channel,
  required String installationIdentity,
}) {
  final digest = crypto.sha256.convert(
    utf8.encode("$salt\n$channel\n$installationIdentity"),
  );
  final bytes = digest.bytes;
  final value = bytes.take(4).fold<int>(
        0,
        (previous, byte) => (previous << 8) + byte,
      );
  return value % 100;
}

bool _isReleaseIndexItemNewer(
  ReleaseIndexItem item,
  DesktopVersionInfo currentVersion,
) {
  return compareDesktopVersions(_indexVersionInfo(item), currentVersion) > 0;
}

int _compareReleaseIndexItems(ReleaseIndexItem left, ReleaseIndexItem right) {
  return compareDesktopVersions(
    _indexVersionInfo(left),
    _indexVersionInfo(right),
  );
}

DesktopVersionInfo _indexVersionInfo(ReleaseIndexItem item) {
  return DesktopVersionInfo.fromParts(
    versionName: item.version,
    buildNumber: item.buildNumber == null || item.buildNumber! <= 0
        ? null
        : item.buildNumber.toString(),
  );
}
