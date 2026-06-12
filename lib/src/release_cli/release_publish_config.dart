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
  });

  final String? configPath;
  final String? baseUrl;
  final String? outputPath;
  final String? channel;
  final String? version;
  final int? buildNumber;
  final String? packageId;
  final String? appName;
}

class ReleasePublishConfig {
  const ReleasePublishConfig({
    required this.baseUrl,
    required this.outputDirectory,
    required this.channel,
    required this.uploadProvider,
  });

  final Uri baseUrl;
  final Directory outputDirectory;
  final String channel;
  final UploadConfig uploadProvider;

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
    );
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

bool? _boolValue(Map<String, dynamic> map, String key) {
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
  throw FormatException("$key must be true or false.");
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
