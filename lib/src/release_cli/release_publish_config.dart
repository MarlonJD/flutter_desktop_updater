import "dart:io";

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
    this.mandatory = false,
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

  /// Whether app-archive.json should mark this release as mandatory.
  final bool mandatory;
  final bool notarize;
}

class ReleasePublishConfig {
  const ReleasePublishConfig({
    required this.baseUrl,
    required this.outputDirectory,
    required this.channel,
    required this.uploadProvider,
    required this.macos,
    required this.hooks,
  });

  final Uri baseUrl;
  final Directory outputDirectory;
  final String channel;
  final UploadConfig uploadProvider;
  final MacOSPublishConfig macos;
  final ReleaseHooksConfig hooks;

  static Future<ReleasePublishConfig> load({
    required Directory projectRoot,
    required ReleasePublishOverrides cliOverrides,
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
    );
  }

  static Future<ReleasePublishConfig> fromYaml(
    String yaml, {
    Directory? projectRoot,
    ReleasePublishOverrides cliOverrides = const ReleasePublishOverrides(),
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
    final macos = _readMacOSConfig(document, cliOverrides);
    final hooks = _readHooksConfig(document);

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
      hooks: hooks,
    );
  }
}

class MacOSPublishConfig {
  const MacOSPublishConfig({
    required this.notarize,
    required this.staple,
    required this.gatekeeperAssess,
    this.developerIdApplication,
    this.notaryProfile,
    this.keychain,
  });

  final bool notarize;
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
  final value = hook["platforms"];
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
          "$displayName contains unsupported platform ${item.toString()}.",
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
  ReleasePublishOverrides cliOverrides,
) {
  final macos = _mapValue(document, "macos");
  final notarize = cliOverrides.notarize ||
      (_boolValue(macos, "notarize", displayName: "macos.notarize") ?? false);
  final config = MacOSPublishConfig(
    notarize: notarize,
    developerIdApplication: _stringValue(macos, "developerIdApplication"),
    notaryProfile: _stringValue(macos, "notaryProfile"),
    keychain: _stringValue(macos, "keychain"),
    staple: _boolValue(macos, "staple", displayName: "macos.staple") ?? true,
    gatekeeperAssess: _boolValue(macos, "gatekeeperAssess",
            displayName: "macos.gatekeeperAssess") ??
        true,
  );

  if (config.notarize) {
    _requireConfigValue(
      config.developerIdApplication,
      "macos.developerIdApplication",
    );
    _requireConfigValue(config.notaryProfile, "macos.notaryProfile");
    _requireConfigValue(config.keychain, "macos.keychain");
  }

  return config;
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
  return value == null ? null : value.toString();
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
        "$displayName is required when macos.notarize is true.");
  }
}
