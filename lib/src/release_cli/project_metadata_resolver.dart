import "dart:io";

import "package:desktop_updater/src/release_cli/platform_release_profile.dart";
import "package:desktop_updater/src/release_cli/release_publish_config.dart";
import "package:desktop_updater/src/version_info.dart";
import "package:path/path.dart" as path;
import "package:yaml/yaml.dart";

class ProjectMetadata {
  const ProjectMetadata({
    required this.version,
    required this.buildNumber,
    required this.appName,
    required this.packageId,
    required this.platform,
    required this.profile,
    required this.input,
  });

  final String version;
  final int? buildNumber;
  final String appName;
  final String packageId;
  final String platform;
  final PlatformReleaseProfile profile;
  final FileSystemEntity input;
}

class ProjectMetadataResolver {
  const ProjectMetadataResolver();

  Future<ProjectMetadata> resolve({
    required Directory projectRoot,
    required String platform,
    required ReleasePublishOverrides overrides,
  }) async {
    final profile = PlatformReleaseProfile.forPlatform(platform);
    final pubspec = await _readPubspec(projectRoot);
    final version = _resolveVersion(pubspec, overrides);
    final appName = await _resolveAppName(
      projectRoot: projectRoot,
      platform: platform,
      pubspecName: pubspec.name,
      overrides: overrides,
    );
    final packageId = await _resolvePackageId(
      projectRoot: projectRoot,
      platform: platform,
      pubspecName: pubspec.name,
      overrides: overrides,
    );
    final inputPath = path.join(
      projectRoot.path,
      profile.defaultInputPath(appName),
    );

    return ProjectMetadata(
      version: version.versionName!,
      buildNumber: version.buildNumber,
      appName: appName,
      packageId: packageId,
      platform: platform,
      profile: profile,
      input: Directory(inputPath),
    );
  }
}

class _PubspecMetadata {
  const _PubspecMetadata({
    required this.name,
    required this.version,
  });

  final String name;
  final String version;
}

Future<_PubspecMetadata> _readPubspec(Directory projectRoot) async {
  final file = File(path.join(projectRoot.path, "pubspec.yaml"));
  if (!await file.exists()) {
    throw FileSystemException("pubspec.yaml is required.", file.path);
  }
  final yaml = loadYaml(await file.readAsString());
  if (yaml is! YamlMap) {
    throw const FormatException("pubspec.yaml must contain a map.");
  }
  final name = yaml["name"]?.toString().trim();
  final version = yaml["version"]?.toString().trim();
  if (name == null || name.isEmpty) {
    throw const FormatException("pubspec.yaml name is required.");
  }
  if (version == null || version.isEmpty) {
    throw const FormatException("pubspec.yaml version is required.");
  }
  return _PubspecMetadata(name: name, version: version);
}

DesktopVersionInfo _resolveVersion(
  _PubspecMetadata pubspec,
  ReleasePublishOverrides overrides,
) {
  final baseVersion = overrides.version ?? pubspec.version;
  final rawVersion = overrides.buildNumber == null
      ? baseVersion
      : "${DesktopVersionInfo.parse(baseVersion).versionName}+${overrides.buildNumber}";
  final parsed = DesktopVersionInfo.fromParts(
    versionName: rawVersion,
    buildNumber: overrides.buildNumber?.toString(),
  );
  if (parsed.versionName == null || parsed.versionName!.isEmpty) {
    throw const FormatException("Release version must be provided.");
  }
  return parsed;
}

Future<String> _resolveAppName({
  required Directory projectRoot,
  required String platform,
  required String pubspecName,
  required ReleasePublishOverrides overrides,
}) async {
  final override = overrides.appName;
  if (override != null && override.trim().isNotEmpty) {
    return _platformAppName(platform, override.trim());
  }

  if (platform == "macos") {
    final xcconfig = await _readMacosAppInfo(projectRoot);
    final productName = xcconfig["PRODUCT_NAME"];
    return _platformAppName(
      platform,
      productName == null || productName.isEmpty
          ? _titleFromPackageName(pubspecName)
          : productName,
    );
  }

  return _titleFromPackageName(pubspecName);
}

Future<String> _resolvePackageId({
  required Directory projectRoot,
  required String platform,
  required String pubspecName,
  required ReleasePublishOverrides overrides,
}) async {
  final override = overrides.packageId;
  if (override != null && override.trim().isNotEmpty) {
    return override.trim();
  }

  if (platform == "macos") {
    final xcconfig = await _readMacosAppInfo(projectRoot);
    final bundleId = xcconfig["PRODUCT_BUNDLE_IDENTIFIER"];
    if (bundleId != null && bundleId.isNotEmpty) {
      return bundleId;
    }
  }

  if (platform == "linux") {
    final applicationId = await _readLinuxApplicationId(projectRoot);
    if (applicationId != null && applicationId.isNotEmpty) {
      return applicationId;
    }
    throw const FormatException(
      "Linux package id could not be inferred. Pass --package-id.",
    );
  }

  return pubspecName;
}

Future<Map<String, String>> _readMacosAppInfo(Directory projectRoot) async {
  final file = File(
    path.join(
        projectRoot.path, "macos", "Runner", "Configs", "AppInfo.xcconfig"),
  );
  if (!await file.exists()) {
    return const {};
  }
  final values = <String, String>{};
  for (final line in await file.readAsLines()) {
    final index = line.indexOf("=");
    if (index == -1) {
      continue;
    }
    final key = line.substring(0, index).trim();
    final value = line.substring(index + 1).trim();
    if (key.isNotEmpty && value.isNotEmpty) {
      values[key] = value;
    }
  }
  return values;
}

Future<String?> _readLinuxApplicationId(Directory projectRoot) async {
  final file = File(path.join(projectRoot.path, "linux", "CMakeLists.txt"));
  if (!await file.exists()) {
    return null;
  }
  final content = await file.readAsString();
  final match = RegExp(
    r'set\s*\(\s*APPLICATION_ID\s+"?([^"\s\)]+)"?',
  ).firstMatch(content);
  return match?.group(1);
}

String _platformAppName(String platform, String appName) {
  if (platform == "macos" && !appName.endsWith(".app")) {
    return "$appName.app";
  }
  return appName;
}

String _titleFromPackageName(String name) {
  return name
      .split("_")
      .where((part) => part.isNotEmpty)
      .map((part) => part[0].toUpperCase() + part.substring(1))
      .join(" ");
}
