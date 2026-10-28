import "package:path/path.dart" as path;

enum MacOSArtifactKind {
  zip,
  dmg,
  pkg,
}

class MacOSDmgPublishConfig {
  const MacOSDmgPublishConfig({
    required this.volumeName,
    required this.appBundleName,
    required this.applicationsAlias,
    this.fileName,
    this.usesDefaultVolumeName = false,
    this.usesDefaultAppBundleName = false,
  });

  factory MacOSDmgPublishConfig.defaultsForAppName(String appName) {
    final bundleName = _appBundleName(appName);
    return MacOSDmgPublishConfig(
      volumeName: _artifactNameStem(bundleName),
      appBundleName: bundleName,
      applicationsAlias: true,
      usesDefaultVolumeName: true,
      usesDefaultAppBundleName: true,
    );
  }

  final String volumeName;
  final String appBundleName;
  final bool applicationsAlias;

  /// Optional basename template; independent of the app name inside the DMG.
  final String? fileName;
  final bool usesDefaultVolumeName;
  final bool usesDefaultAppBundleName;

  MacOSDmgPublishConfig resolveDefaultsForAppName(String appName) {
    final defaults = MacOSDmgPublishConfig.defaultsForAppName(appName);
    final appBundleName =
        usesDefaultAppBundleName ? defaults.appBundleName : this.appBundleName;
    return MacOSDmgPublishConfig(
      volumeName:
          usesDefaultVolumeName ? _artifactNameStem(appBundleName) : volumeName,
      appBundleName: appBundleName,
      applicationsAlias: applicationsAlias,
      fileName: fileName,
      usesDefaultVolumeName: false,
      usesDefaultAppBundleName: false,
    );
  }

  /// Checks the configured basename and supported placeholders before building.
  void validateFileName() {
    if (fileName != null) {
      _validateDmgFileName(fileName!, allowPlaceholders: true);
    }
  }

  /// Resolves and validates the artifact basename for both layout and packaging.
  String resolveFileName({
    required String appName,
    required String version,
    required int? buildNumber,
    required String platform,
  }) {
    validateFileName();
    final template = fileName ?? "{appName}-{version}-{platform}.dmg";
    if (template.contains("{buildNumber}") && buildNumber == null) {
      throw const FormatException(
        "macos.dmg.fileName uses {buildNumber}, but the release has no build number.",
      );
    }
    final values = {
      "appName": _artifactNameStem(appName),
      "version": version,
      "buildNumber": buildNumber?.toString() ?? "",
      "platform": platform,
    };
    final resolved = template.replaceAllMapped(
      RegExp(r"\{(appName|version|buildNumber|platform)\}"),
      (match) => values[match[1]]!,
    );
    _validateDmgFileName(resolved, allowPlaceholders: false);
    return resolved;
  }
}

void _validateDmgFileName(String value, {required bool allowPlaceholders}) {
  final literal = allowPlaceholders
      ? value.replaceAll(
          RegExp(r"\{(appName|version|buildNumber|platform)\}"),
          "",
        )
      : value;
  if (value.trim() != value ||
      !value.endsWith(".dmg") ||
      value == ".dmg" ||
      RegExp(r'[<>:"/\\|?*%\x00-\x1f\x7f{}]').hasMatch(literal)) {
    throw const FormatException(
      "macos.dmg.fileName must be a safe .dmg file name, not a path. "
      "Supported placeholders: {appName}, {version}, {buildNumber}, {platform}.",
    );
  }
}

class MacOSPkgPublishConfig {
  const MacOSPkgPublishConfig({
    required this.packageIdentifier,
    required this.installLocation,
    this.signingIdentifier,
  });

  final String packageIdentifier;
  final String installLocation;
  final String? signingIdentifier;
}

String _appBundleName(String appName) {
  final basename = path.basename(appName.trim().isEmpty ? "App" : appName);
  return basename.endsWith(".app") ? basename : "$basename.app";
}

String _artifactNameStem(String appName) {
  var stem = path.basename(appName);
  if (stem.endsWith(".app")) {
    stem = stem.substring(0, stem.length - ".app".length);
  }
  return stem;
}
