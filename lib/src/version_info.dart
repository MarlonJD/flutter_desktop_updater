import "package:desktop_updater/src/app_archive.dart";
import "package:pub_semver/pub_semver.dart";

/// Parsed desktop app version metadata used for update ordering.
class DesktopVersionInfo {
  /// Creates parsed desktop app version metadata.
  const DesktopVersionInfo({
    required this.rawVersion,
    required this.versionName,
    required this.version,
    required this.buildNumber,
  });

  /// Parses a Flutter pubspec-style version string.
  factory DesktopVersionInfo.parse(String rawVersion) {
    return DesktopVersionInfo.fromParts(versionName: rawVersion);
  }

  /// Creates version metadata from separate platform version fields.
  factory DesktopVersionInfo.fromParts({
    String? versionName,
    String? buildNumber,
  }) {
    final trimmedVersion = versionName?.trim();
    final parsedVersion = _parseVersion(trimmedVersion);
    final parsedBuildNumber =
        _parseInt(buildNumber) ?? _parseBuildMetadata(parsedVersion);

    return DesktopVersionInfo(
      rawVersion: trimmedVersion,
      versionName: parsedVersion == null ? null : _versionName(parsedVersion),
      version: parsedVersion == null
          ? null
          : Version.parse(_versionName(parsedVersion)),
      buildNumber: parsedBuildNumber,
    );
  }

  /// Original version string, including build metadata when present.
  final String? rawVersion;

  /// Semantic version without build metadata.
  final String? versionName;

  /// Parsed semantic version without build metadata.
  final Version? version;

  /// Monotonic build number when the platform exposes one.
  final int? buildNumber;
}

/// Returns true when [archiveItem] is newer than [currentVersion].
bool isArchiveItemNewerThanCurrent(
  ItemModel archiveItem,
  DesktopVersionInfo currentVersion,
) {
  return compareArchiveItemToCurrent(archiveItem, currentVersion) > 0;
}

/// Compares two archive items using build numbers when possible.
int compareArchiveItems(ItemModel left, ItemModel right) {
  return compareDesktopVersions(
    _archiveVersionInfo(left),
    _archiveVersionInfo(right),
  );
}

/// Compares an archive item against the current app version.
int compareArchiveItemToCurrent(
  ItemModel archiveItem,
  DesktopVersionInfo currentVersion,
) {
  return compareDesktopVersions(
    _archiveVersionInfo(archiveItem),
    currentVersion,
  );
}

/// Compares two parsed desktop versions.
int compareDesktopVersions(
  DesktopVersionInfo candidate,
  DesktopVersionInfo current,
) {
  if (candidate.buildNumber != null && current.buildNumber != null) {
    return candidate.buildNumber!.compareTo(current.buildNumber!);
  }

  if (candidate.version != null && current.version != null) {
    final versionComparison = candidate.version!.compareTo(current.version!);
    if (versionComparison != 0) {
      return versionComparison;
    }
  }

  return 0;
}

/// Formats the release label used in generated artifact names.
String releaseVersionLabel(DesktopVersionInfo version) {
  if (version.versionName == null || version.versionName!.isEmpty) {
    throw const FormatException("Release version must include a version name.");
  }

  if (version.buildNumber == null) {
    return version.versionName!;
  }

  return "${version.versionName}+${version.buildNumber}";
}

/// Formats the parent folder used in generated artifact paths.
String releaseVersionFolder(DesktopVersionInfo version) {
  if (version.buildNumber == null) {
    return releaseVersionLabel(version);
  }

  return version.buildNumber.toString();
}

/// Extracts the version label from a generated archive directory name.
String? archiveVersionLabelFromName({
  required String archiveName,
  required String appName,
  required String platform,
}) {
  final normalizedArchiveName = archiveName.endsWith(".app")
      ? archiveName.substring(0, archiveName.length - ".app".length)
      : archiveName;
  final prefix = "$appName-";
  final suffix = "-$platform";
  if (!normalizedArchiveName.startsWith(prefix) ||
      !normalizedArchiveName.endsWith(suffix)) {
    return null;
  }

  final versionLabel = normalizedArchiveName.substring(
    prefix.length,
    normalizedArchiveName.length - suffix.length,
  );
  if (versionLabel.isEmpty) {
    return null;
  }

  DesktopVersionInfo.parse(versionLabel);
  return versionLabel;
}

DesktopVersionInfo _archiveVersionInfo(ItemModel item) {
  return DesktopVersionInfo.fromParts(
    versionName: item.version,
    buildNumber: item.hasShortVersion ? item.shortVersion.toString() : null,
  );
}

Version? _parseVersion(String? version) {
  if (version == null || version.isEmpty) {
    return null;
  }

  return Version.parse(version);
}

int? _parseBuildMetadata(Version? version) {
  if (version == null || version.build.isEmpty) {
    return null;
  }

  return int.tryParse(version.build.first.toString());
}

int? _parseInt(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) {
    return null;
  }

  return int.tryParse(trimmed);
}

String _versionName(Version version) {
  final base = "${version.major}.${version.minor}.${version.patch}";
  if (version.preRelease.isEmpty) {
    return base;
  }

  return "$base-${version.preRelease.join(".")}";
}
