import "package:desktop_updater/src/version_info.dart";

class ReleaseIndex {
  const ReleaseIndex({
    required this.schemaVersion,
    required this.appName,
    required this.items,
  });

  factory ReleaseIndex.fromJson(Map<String, dynamic> json) {
    final schemaVersion = json["schemaVersion"] as int? ?? 1;
    return ReleaseIndex(
      schemaVersion: schemaVersion,
      appName: json["appName"] as String? ?? "",
      items: (json["items"] as List<dynamic>? ?? const [])
          .map(
            (item) => ReleaseIndexItem.fromJson(
              item as Map<String, dynamic>,
              schemaVersion: schemaVersion,
            ),
          )
          .toList(growable: false),
    );
  }

  final int schemaVersion;
  final String appName;
  final List<ReleaseIndexItem> items;

  Map<String, dynamic> toJson() {
    return {
      "schemaVersion": schemaVersion,
      "appName": appName,
      "items": items.map((item) => item.toJson()).toList(),
    };
  }
}

class ReleaseIndexItem {
  const ReleaseIndexItem({
    required this.version,
    required this.buildNumber,
    required this.platform,
    required this.channel,
    required this.mandatory,
    required this.release,
  });

  factory ReleaseIndexItem.fromJson(
    Map<String, dynamic> json, {
    int schemaVersion = 3,
  }) {
    final releaseValue = json["release"] ?? json["url"];
    if (schemaVersion == 3 && releaseValue == null) {
      throw const FormatException(
        "Release index schema v3 items must include release.",
      );
    }

    return ReleaseIndexItem(
      version: json["version"] as String? ?? "",
      buildNumber:
          (json["buildNumber"] as int?) ?? (json["shortVersion"] as int?) ?? 0,
      platform: json["platform"] as String? ?? "",
      channel: json["channel"] as String? ?? "stable",
      mandatory: json["mandatory"] as bool? ?? false,
      release: Uri.parse(releaseValue?.toString() ?? ""),
    );
  }

  final String version;
  final int buildNumber;
  final String platform;
  final String channel;
  final bool mandatory;
  final Uri release;

  Map<String, dynamic> toJson() {
    return {
      "version": version,
      "buildNumber": buildNumber,
      "platform": platform,
      "channel": channel,
      "mandatory": mandatory,
      "release": release.toString(),
    };
  }
}

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
      _indexVersionInfo(left), _indexVersionInfo(right));
}

DesktopVersionInfo _indexVersionInfo(ReleaseIndexItem item) {
  return DesktopVersionInfo.fromParts(
    versionName: item.version,
    buildNumber: item.buildNumber <= 0 ? null : item.buildNumber.toString(),
  );
}
