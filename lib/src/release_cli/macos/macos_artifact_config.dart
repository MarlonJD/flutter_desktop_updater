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
      usesDefaultVolumeName: false,
      usesDefaultAppBundleName: false,
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
