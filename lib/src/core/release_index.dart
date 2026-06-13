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

  /// Converts this index item to JSON.
  Map<String, dynamic> toJson() {
    return {
      "version": version,
      if (buildNumber != null) "buildNumber": buildNumber,
      "platform": platform,
      "channel": channel,
      "mandatory": mandatory,
      "release": release.toString(),
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
}) {
  final candidates = index.items
      .where((item) => item.platform == platform)
      .where((item) => item.channel == channel)
      .where((item) => _isReleaseIndexItemNewer(item, currentVersion))
      .toList(growable: false);

  if (candidates.isEmpty) {
    return null;
  }

  candidates.sort(_compareReleaseIndexItems);
  return candidates.last;
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
