import "dart:io";

import "package:desktop_updater/src/release_cli/inno/inno_publish_config.dart";
import "package:desktop_updater/src/release_cli/macos/macos_artifact_config.dart";
import "package:path/path.dart" as path;
import "package:yaml/yaml.dart";

class ReleasePublishOverrides {
  const ReleasePublishOverrides({
    this.configPath,
    this.baseUrl,
    this.outputPath,
    this.channel,
    this.version,
    this.buildNumber,
    this.packageId,
    this.appName,
    this.projectType,
    this.artifactRoot,
    this.executableRelativePath,
    this.xcodeProject,
    this.xcodeWorkspace,
    this.xcodeScheme,
    this.xcodeDerivedDataPath,
    this.cmakeSourceDirectory,
    this.cmakeBuildDirectory,
    this.cmakeBuildTarget,
    this.dartDefines = const [],
    this.mandatory = false,
    this.minimumSupportedVersion,
    this.enforcedAfter,
    this.freshInstallUrl,
    this.freshInstallMessage,
    this.existingAppArchive,
    this.initializeFeed = false,
    this.notarize = false,
  });

  final String? configPath;
  final String? baseUrl;
  final String? outputPath;
  final String? channel;
  final String? version;
  final int? buildNumber;
  final String? packageId;
  final String? appName;

  /// Explicit project adapter type selected through the publish CLI.
  final String? projectType;

  /// Complete manual or already installed CMake artifact path.
  final String? artifactRoot;

  /// Executable path relative to a manual or CMake artifact root.
  final String? executableRelativePath;

  /// Explicit Xcode project path.
  final String? xcodeProject;

  /// Explicit Xcode workspace path.
  final String? xcodeWorkspace;

  /// Xcode scheme used for the Release build.
  final String? xcodeScheme;

  /// Optional deterministic Xcode derived-data directory.
  final String? xcodeDerivedDataPath;

  /// Optional CMake source directory.
  final String? cmakeSourceDirectory;

  /// Optional CMake build directory.
  final String? cmakeBuildDirectory;

  /// Required CMake application target when no installed tree is supplied.
  final String? cmakeBuildTarget;

  final List<String> dartDefines;

  /// Whether app-archive.json should mark this release as mandatory.
  final bool mandatory;
  final String? minimumSupportedVersion;
  final DateTime? enforcedAfter;
  final Uri? freshInstallUrl;
  final String? freshInstallMessage;
  final String? existingAppArchive;
  final bool initializeFeed;
  final bool notarize;
}

class ReleasePublishConfig {
  const ReleasePublishConfig({
    required this.baseUrl,
    required this.outputDirectory,
    required this.channel,
    required this.uploadProvider,
    required this.macos,
    required this.windows,
    required this.hooks,
    required this.additionalFiles,
  });

  final Uri baseUrl;
  final Directory outputDirectory;
  final String channel;
  final UploadConfig uploadProvider;
  final MacOSPublishConfig macos;
  final WindowsPublishConfig windows;
  final ReleaseHooksConfig hooks;

  /// Files copied into the platform release output before signing and zipping.
  final List<AdditionalReleaseFileConfig> additionalFiles;

  static Future<ReleasePublishConfig> load({
    required Directory projectRoot,
    required ReleasePublishOverrides cliOverrides,
    Map<String, String>? environment,
  }) async {
    final configPath = cliOverrides.configPath ??
        path.join(projectRoot.path, "desktop_updater.yaml");
    final configFile = File(configPath);
    final yaml =
        await configFile.exists() ? await configFile.readAsString() : "";
    return fromYaml(
      yaml,
      projectRoot: projectRoot,
      cliOverrides: cliOverrides,
      environment: environment,
    );
  }

  static Future<ReleasePublishConfig> fromYaml(
    String yaml, {
    Directory? projectRoot,
    ReleasePublishOverrides cliOverrides = const ReleasePublishOverrides(),
    Map<String, String>? environment,
  }) async {
    final root = projectRoot ?? Directory.current;
    final document = yaml.trim().isEmpty
        ? <String, dynamic>{}
        : _toStringMap(loadYaml(yaml));
    final updates = _mapValue(document, "updates");
    final baseUrlValue =
        cliOverrides.baseUrl ?? _stringValue(updates, "baseUrl");
    if (baseUrlValue == null || baseUrlValue.trim().isEmpty) {
      throw const FormatException("updates.baseUrl is required.");
    }

    final outputValue =
        cliOverrides.outputPath ?? _stringValue(updates, "output");
    final channelValue =
        cliOverrides.channel ?? _stringValue(updates, "channel") ?? "stable";
    final provider = _readUploadProvider(document);
    final macos = _readMacOSConfig(
      document,
      cliOverrides,
      environment: environment ?? Platform.environment,
    );
    final windows = _readWindowsConfig(document);
    final hooks = _readHooksConfig(document);
    if (macos.notarize && hooks.hasPostPackageHookFor("macos")) {
      throw const FormatException(
        "macOS postPackage hooks are not allowed when built-in notarization is enabled.",
      );
    }
    final additionalFiles = _readAdditionalFilesConfig(document);

    return ReleasePublishConfig(
      baseUrl: _normalizeBaseUrl(baseUrlValue),
      outputDirectory: Directory(
        outputValue == null || outputValue.trim().isEmpty
            ? path.join(root.path, "dist", "desktop_updater")
            : path.isAbsolute(outputValue)
                ? outputValue
                : path.join(root.path, outputValue),
      ),
      channel: channelValue,
      uploadProvider: provider,
      macos: macos,
      windows: windows,
      hooks: hooks,
      additionalFiles: additionalFiles,
    );
  }
}

/// App-owned files to copy into a release output before platform trust gates.
class AdditionalReleaseFileConfig {
  /// Creates an additional release file rule.
  const AdditionalReleaseFileConfig({
    required this.source,
    required this.destination,
    this.platforms = const [],
  });

  /// File, directory, or glob resolved from the app project root.
  final String source;

  /// Relative directory inside the platform release output.
  final String destination;

  /// Optional platform filter.
  final List<String> platforms;

  /// Whether this rule applies to [platform].
  bool appliesTo(String platform) {
    return platforms.isEmpty || platforms.contains(platform);
  }
}

class MacOSPublishConfig {
  const MacOSPublishConfig({
    required this.notarize,
    required this.artifactKind,
    required this.dmg,
    required this.pkg,
    required this.staple,
    required this.gatekeeperAssess,
    this.developerIdApplication,
    this.notaryProfile,
    this.keychain,
  });

  final bool notarize;
  final MacOSArtifactKind artifactKind;
  final MacOSDmgPublishConfig dmg;
  final MacOSPkgPublishConfig pkg;
  final String? developerIdApplication;
  final String? notaryProfile;
  final String? keychain;
  final bool staple;
  final bool gatekeeperAssess;
}

class ReleaseHooksConfig {
  const ReleaseHooksConfig({
    this.prePackage = const [],
    this.postPackage = const [],
  });

  final List<ReleaseHookConfig> prePackage;
  final List<ReleaseHookConfig> postPackage;

  bool hasPrePackageHookFor(String platform) {
    return prePackage.any((hook) => hook.appliesTo(platform));
  }

  bool hasPostPackageHookFor(String platform) {
    return postPackage.any((hook) => hook.appliesTo(platform));
  }
}

class ReleaseHookConfig {
  const ReleaseHookConfig({
    required this.command,
    this.platforms = const [],
  });

  final String command;
  final List<String> platforms;

  bool appliesTo(String platform) {
    return platforms.isEmpty || platforms.contains(platform);
  }
}

sealed class UploadConfig {
  const UploadConfig();

  String get providerName;

  bool get isManual => this is ManualUploadConfig;
}

class ManualUploadConfig extends UploadConfig {
  const ManualUploadConfig();

  @override
  String get providerName => "manual";
}

class S3UploadConfig extends UploadConfig {
  const S3UploadConfig({
    required this.bucket,
    this.prefix,
    this.region,
    this.endpoint,
    this.pathStyle = false,
    this.profile,
  });

  final String bucket;
  final String? prefix;
  final String? region;
  final String? endpoint;
  final bool pathStyle;
  final String? profile;

  @override
  String get providerName => "s3";
}

class SftpUploadConfig extends UploadConfig {
  const SftpUploadConfig({
    required this.host,
    required this.remotePath,
    required this.username,
    this.port = 22,
  });

  final String host;
  final int port;
  final String remotePath;
  final String username;

  @override
  String get providerName => "sftp";
}

class FtpUploadConfig extends UploadConfig {
  const FtpUploadConfig({
    required this.host,
    required this.remotePath,
    required this.username,
    required this.allowInsecure,
    this.port = 21,
  });

  final String host;
  final int port;
  final String remotePath;
  final String username;
  final bool allowInsecure;

  @override
  String get providerName => "ftp";
}

class CustomCommandUploadConfig extends UploadConfig {
  const CustomCommandUploadConfig({required this.command});

  final String command;

  @override
  String get providerName => "customCommand";
}

ReleaseHooksConfig _readHooksConfig(Map<String, dynamic> document) {
  final hooks = _mapValue(document, "hooks");
  if (hooks.isEmpty) {
    return const ReleaseHooksConfig();
  }
  return ReleaseHooksConfig(
    prePackage: _readHookList(hooks, "prePackage"),
    postPackage: _readHookList(hooks, "postPackage"),
  );
}

List<ReleaseHookConfig> _readHookList(
  Map<String, dynamic> hooks,
  String key,
) {
  final value = hooks[key];
  if (value == null) {
    return const [];
  }
  if (value is! List) {
    throw FormatException("hooks.$key must be a list.");
  }
  return [
    for (var i = 0; i < value.length; i += 1)
      _readHookConfig(
        _hookMap(value[i], "hooks.$key[$i]"),
        "hooks.$key[$i]",
      ),
  ];
}

ReleaseHookConfig _readHookConfig(
  Map<String, dynamic> hook,
  String displayName,
) {
  _rejectSecretHookKeys(hook, displayName);
  return ReleaseHookConfig(
    command: _requiredString(hook, "command", "$displayName.command"),
    platforms: _readHookPlatforms(hook, "$displayName.platforms"),
  );
}

Map<String, dynamic> _hookMap(Object? value, String displayName) {
  if (value is Map<String, dynamic>) {
    return value;
  }
  throw FormatException("$displayName must be a map.");
}

List<String> _readHookPlatforms(
  Map<String, dynamic> hook,
  String displayName,
) {
  return _readPlatformList(hook, displayName);
}

List<AdditionalReleaseFileConfig> _readAdditionalFilesConfig(
  Map<String, dynamic> document,
) {
  final value = document["additionalFiles"];
  if (value == null) {
    return const [];
  }
  if (value is! List) {
    throw const FormatException("additionalFiles must be a list.");
  }
  return [
    for (var i = 0; i < value.length; i += 1)
      _readAdditionalFileConfig(
        _additionalFileMap(value[i], "additionalFiles[$i]"),
        "additionalFiles[$i]",
      ),
  ];
}

AdditionalReleaseFileConfig _readAdditionalFileConfig(
  Map<String, dynamic> additionalFile,
  String displayName,
) {
  return AdditionalReleaseFileConfig(
    source: _requiredString(additionalFile, "source", "$displayName.source"),
    destination: _requiredString(
      additionalFile,
      "destination",
      "$displayName.destination",
    ),
    platforms: _readPlatformList(additionalFile, "$displayName.platforms"),
  );
}

Map<String, dynamic> _additionalFileMap(Object? value, String displayName) {
  if (value is Map<String, dynamic>) {
    return value;
  }
  throw FormatException("$displayName must be a map.");
}

List<String> _readPlatformList(
  Map<String, dynamic> map,
  String displayName,
) {
  final value = map["platforms"];
  if (value == null) {
    return const [];
  }
  if (value is! List) {
    throw FormatException("$displayName must be a list.");
  }
  const allowed = {"macos", "windows", "linux"};
  return [
    for (final item in value)
      if (allowed.contains(item.toString()))
        item.toString()
      else
        throw FormatException(
          "$displayName contains unsupported platform $item.",
        ),
  ];
}

void _rejectSecretHookKeys(
  Map<String, dynamic> hook,
  String displayName,
) {
  const forbiddenKeys = {
    "env",
    "environment",
    "secret",
    "secrets",
    "privateKey",
    "privateKeyEnv",
    "privateKeyFile",
  };
  for (final key in forbiddenKeys) {
    if (hook.containsKey(key)) {
      throw FormatException("$displayName.$key must not be set.");
    }
  }
}

UploadConfig _readUploadProvider(Map<String, dynamic> document) {
  final providerBlocks = ["s3", "sftp", "ftp", "customCommand"]
      .where((name) => document[name] != null)
      .toList(growable: false);
  if (providerBlocks.length > 1) {
    throw FormatException(
      "Only one upload provider can be configured. Found: ${providerBlocks.join(", ")}.",
    );
  }
  if (providerBlocks.isEmpty) {
    return const ManualUploadConfig();
  }

  final providerName = providerBlocks.single;
  final provider = _mapValue(document, providerName);
  switch (providerName) {
    case "s3":
      return S3UploadConfig(
        bucket: _requiredString(provider, "bucket", "s3.bucket"),
        prefix: _stringValue(provider, "prefix"),
        region: _stringValue(provider, "region"),
        endpoint: _stringValue(provider, "endpoint"),
        pathStyle: _boolValue(provider, "pathStyle") ?? false,
        profile: _stringValue(provider, "profile"),
      );
    case "sftp":
      return SftpUploadConfig(
        host: _requiredString(provider, "host", "sftp.host"),
        port: _intValue(provider, "port") ?? 22,
        remotePath: _requiredString(provider, "remotePath", "sftp.remotePath"),
        username: _requiredString(provider, "username", "sftp.username"),
      );
    case "ftp":
      final allowInsecure = _boolValue(provider, "allowInsecure") ?? false;
      if (!allowInsecure) {
        throw const FormatException("ftp.allowInsecure: true is required.");
      }
      return FtpUploadConfig(
        host: _requiredString(provider, "host", "ftp.host"),
        port: _intValue(provider, "port") ?? 21,
        remotePath: _requiredString(provider, "remotePath", "ftp.remotePath"),
        username: _requiredString(provider, "username", "ftp.username"),
        allowInsecure: allowInsecure,
      );
    case "customCommand":
      return CustomCommandUploadConfig(
        command: _requiredString(
          provider,
          "command",
          "customCommand.command",
        ),
      );
  }
  return const ManualUploadConfig();
}

MacOSPublishConfig _readMacOSConfig(
  Map<String, dynamic> document,
  ReleasePublishOverrides cliOverrides, {
  required Map<String, String> environment,
}) {
  final macos = _mapValue(document, "macos");
  final artifact = _mapValue(macos, "artifact");
  final artifactKind = _readMacOSArtifactKind(
    _stringValue(artifact, "kind") ?? "zip",
  );
  final appName = cliOverrides.appName ?? "App";
  final dmg = _readMacOSDmgConfig(macos, appName);
  final pkg = _readMacOSPkgConfig(macos);
  final notarize = cliOverrides.notarize ||
      (_boolValue(macos, "notarize", displayName: "macos.notarize") ?? false);
  final config = MacOSPublishConfig(
    notarize: notarize,
    artifactKind: artifactKind,
    dmg: dmg,
    pkg: pkg,
    developerIdApplication: _macOSReferenceValue(
      macos,
      "developerIdApplication",
      "macos.developerIdApplication",
      environment,
      "DESKTOP_UPDATER_MACOS_DEVELOPER_ID_APPLICATION",
    ),
    notaryProfile: _macOSReferenceValue(
      macos,
      "notaryProfile",
      "macos.notaryProfile",
      environment,
      "DESKTOP_UPDATER_MACOS_NOTARY_PROFILE",
    ),
    keychain: _macOSReferenceValue(
      macos,
      "keychain",
      "macos.keychain",
      environment,
      "DESKTOP_UPDATER_MACOS_KEYCHAIN",
    ),
    staple: _boolValue(macos, "staple", displayName: "macos.staple") ?? true,
    gatekeeperAssess: _boolValue(
          macos,
          "gatekeeperAssess",
          displayName: "macos.gatekeeperAssess",
        ) ??
        true,
  );

  if (config.notarize) {
    _requireConfigValue(
      config.developerIdApplication,
      "macos.developerIdApplication",
    );
    _requireConfigValue(config.notaryProfile, "macos.notaryProfile");
    _requireConfigValue(config.keychain, "macos.keychain");
    if (!config.staple) {
      throw const FormatException(
        "macos.staple must be true when macos.notarize is true.",
      );
    }
    if (!config.gatekeeperAssess) {
      throw const FormatException(
        "macos.gatekeeperAssess must be true when macos.notarize is true.",
      );
    }
  }

  if (config.artifactKind == MacOSArtifactKind.pkg &&
      config.pkg.packageIdentifier.trim().isEmpty) {
    throw const FormatException(
      "macos.pkg.packageIdentifier is required when macos.artifact.kind is pkg.",
    );
  }
  if (config.artifactKind == MacOSArtifactKind.pkg &&
      (config.pkg.signingIdentifier == null ||
          config.pkg.signingIdentifier!.trim().isEmpty)) {
    throw const FormatException(
      "macos.pkg.signingIdentifier is required when macos.artifact.kind is pkg.",
    );
  }
  if (config.artifactKind == MacOSArtifactKind.pkg && !config.notarize) {
    throw const FormatException(
      "macos.notarize: true is required when macos.artifact.kind is pkg.",
    );
  }
  if (config.artifactKind == MacOSArtifactKind.pkg && !config.staple) {
    throw const FormatException(
      "macos.staple must be true when macos.artifact.kind is pkg.",
    );
  }

  return config;
}

MacOSArtifactKind _readMacOSArtifactKind(String kind) {
  switch (kind) {
    case "zip":
      return MacOSArtifactKind.zip;
    case "dmg":
      return MacOSArtifactKind.dmg;
    case "pkg":
      return MacOSArtifactKind.pkg;
  }
  throw const FormatException("macos.artifact.kind must be zip, dmg, or pkg.");
}

MacOSDmgPublishConfig _readMacOSDmgConfig(
  Map<String, dynamic> macos,
  String appName,
) {
  final defaults = MacOSDmgPublishConfig.defaultsForAppName(appName);
  final dmg = _mapValue(macos, "dmg");
  final explicitAppBundleName = _stringValue(dmg, "appBundleName");
  final appBundleName = explicitAppBundleName ?? defaults.appBundleName;
  final explicitVolumeName = _stringValue(dmg, "volumeName");
  return MacOSDmgPublishConfig(
    volumeName: explicitVolumeName ?? _macOSAppNameStem(appBundleName),
    appBundleName: appBundleName,
    applicationsAlias: _boolValue(
          dmg,
          "applicationsAlias",
          displayName: "macos.dmg.applicationsAlias",
        ) ??
        defaults.applicationsAlias,
    usesDefaultVolumeName: explicitVolumeName == null,
    usesDefaultAppBundleName: explicitAppBundleName == null,
  );
}

MacOSPkgPublishConfig _readMacOSPkgConfig(Map<String, dynamic> macos) {
  final pkg = _mapValue(macos, "pkg");
  return MacOSPkgPublishConfig(
    packageIdentifier: _stringValue(pkg, "packageIdentifier") ?? "",
    installLocation: _stringValue(pkg, "installLocation") ?? "/Applications",
    signingIdentifier: _stringValue(pkg, "signingIdentifier"),
  );
}

String _macOSAppNameStem(String appBundleName) {
  var stem = path.basename(appBundleName);
  if (stem.endsWith(".app")) {
    stem = stem.substring(0, stem.length - ".app".length);
  }
  return stem;
}

WindowsPublishConfig _readWindowsConfig(Map<String, dynamic> document) {
  final windows = _mapValue(document, "windows");
  final installer = _mapValue(windows, "installer");
  if (installer.isEmpty) {
    return const WindowsPublishConfig();
  }
  final kind = _stringValue(installer, "kind") ?? "";
  if (kind != "inno") {
    throw const FormatException("windows.installer.kind must be inno.");
  }
  final config = InnoPublishConfig(
    kind: kind,
    mode: _stringValue(installer, "mode") ?? "generated",
    script: _stringValue(installer, "script"),
    isccPath: _stringValue(installer, "isccPath"),
    outputBaseName: _stringValue(installer, "outputBaseName"),
    appId: _stringValue(installer, "appId"),
    publisher: _stringValue(installer, "publisher"),
    publisherUrl: _stringValue(installer, "publisherUrl"),
    supportUrl: _stringValue(installer, "supportUrl"),
    updatesUrl: _stringValue(installer, "updatesUrl"),
    privilegesRequired:
        _stringValue(installer, "privilegesRequired") ?? "lowest",
    protectedHelperInstallDir:
        _stringValue(installer, "protectedHelperInstallDir"),
    architecturesAllowed:
        _stringValue(installer, "architecturesAllowed") ?? "x64",
    architecturesInstallIn64BitMode:
        _stringValue(installer, "architecturesInstallIn64BitMode") ?? "x64",
    setupIcon: _stringValue(installer, "setupIcon"),
    licenseFile: _stringValue(installer, "licenseFile"),
    silentArgs: _stringListValue(installer, "silentArgs") ??
        const ["/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART"],
    requiresElevation: _stringValue(installer, "requiresElevation") ?? "auto",
    authenticodeThumbprints:
        _stringListValue(installer, "authenticodeThumbprints") ?? const [],
  );
  _validateInnoConfig(config);
  return WindowsPublishConfig(installer: config);
}

void _validateInnoConfig(InnoPublishConfig config) {
  if (!const ["generated", "script"].contains(config.mode)) {
    throw const FormatException(
      "windows.installer.mode must be generated or script.",
    );
  }
  if (config.mode == "script" &&
      (config.script == null || config.script!.trim().isEmpty)) {
    throw const FormatException(
      "windows.installer.script is required when mode is script.",
    );
  }
  if (!const ["admin", "lowest"].contains(config.privilegesRequired)) {
    throw const FormatException(
      "windows.installer.privilegesRequired must be admin or lowest.",
    );
  }
  if (!const ["auto", "always", "never"].contains(config.requiresElevation)) {
    throw const FormatException(
      "windows.installer.requiresElevation must be auto, always, or never.",
    );
  }
  resolveGeneratedProtectedHelperInstallDir(config);
}

Uri _normalizeBaseUrl(String value) {
  final uri = Uri.parse(value.trim());
  if (!uri.hasScheme || uri.host.isEmpty) {
    throw const FormatException("updates.baseUrl must be an absolute URL.");
  }
  final text = uri.toString();
  return Uri.parse(text.endsWith("/") ? text : "$text/");
}

Map<String, dynamic> _toStringMap(Object? value) {
  if (value == null) {
    return <String, dynamic>{};
  }
  if (value is YamlMap) {
    return {
      for (final entry in value.entries)
        entry.key.toString(): _toPlainValue(entry.value),
    };
  }
  if (value is Map) {
    return {
      for (final entry in value.entries)
        entry.key.toString(): _toPlainValue(entry.value),
    };
  }
  throw const FormatException("desktop_updater.yaml must contain a map.");
}

Object? _toPlainValue(Object? value) {
  if (value is YamlMap || value is Map) {
    return _toStringMap(value);
  }
  if (value is YamlList) {
    return value.map(_toPlainValue).toList(growable: false);
  }
  return value;
}

Map<String, dynamic> _mapValue(Map<String, dynamic> map, String key) {
  final value = map[key];
  if (value == null) {
    return <String, dynamic>{};
  }
  if (value is Map<String, dynamic>) {
    return value;
  }
  throw FormatException("$key must be a map.");
}

String? _stringValue(Map<String, dynamic> map, String key) {
  final value = map[key];
  return value?.toString();
}

String? _macOSReferenceValue(
  Map<String, dynamic> map,
  String key,
  String displayName,
  Map<String, String> environment,
  String environmentKey,
) {
  if (map.containsKey(key)) {
    final value = map[key];
    if (value is! String || value.trim().isEmpty) {
      throw FormatException("$displayName must be a nonblank string.");
    }
    return value;
  }
  final value = environment[environmentKey]?.trim();
  return value == null || value.isEmpty ? null : value;
}

List<String>? _stringListValue(Map<String, dynamic> map, String key) {
  final value = map[key];
  if (value == null) {
    return null;
  }
  if (value is! List) {
    throw FormatException("$key must be a list.");
  }
  return List.unmodifiable([for (final entry in value) entry.toString()]);
}

String _requiredString(
  Map<String, dynamic> map,
  String key,
  String displayName,
) {
  final value = _stringValue(map, key);
  if (value == null || value.trim().isEmpty) {
    throw FormatException("$displayName is required.");
  }
  return value;
}

bool? _boolValue(
  Map<String, dynamic> map,
  String key, {
  String? displayName,
}) {
  final value = map[key];
  if (value == null) {
    return null;
  }
  if (value is bool) {
    return value;
  }
  if (value is String) {
    return value.toLowerCase() == "true";
  }
  throw FormatException("${displayName ?? key} must be true or false.");
}

int? _intValue(Map<String, dynamic> map, String key) {
  final value = map[key];
  if (value == null) {
    return null;
  }
  if (value is int) {
    return value;
  }
  return int.parse(value.toString());
}

void _requireConfigValue(String? value, String displayName) {
  if (value == null || value.trim().isEmpty) {
    throw FormatException(
      "$displayName is required when macos.notarize is true.",
    );
  }
}
