import "dart:io";

import "package:args/args.dart";
import "package:desktop_updater/src/release_cli/release_publish_config.dart";
import "package:path/path.dart" as path;
import "package:yaml/yaml.dart";

/// Builds the argument parser for `desktop_updater:release doctor`.
ArgParser buildDoctorParser() {
  return ArgParser()
    ..addFlag("help", abbr: "h", negatable: false)
    ..addOption("platform", allowed: ["macos", "windows", "linux"])
    ..addOption("config");
}

/// Runs release configuration diagnostics for one target platform.
Future<int> runDoctorCommand(
  ArgResults results, {
  required Directory projectRoot,
  required StringSink output,
}) async {
  if (results["help"] as bool) {
    output.writeln(buildDoctorParser().usage);
    return 0;
  }

  final platform = _required(results, "platform");
  final configPath = _configPath(projectRoot, results["config"] as String?);

  output
    ..writeln("desktop_updater release doctor")
    ..writeln()
    ..writeln("Platform: $platform");

  try {
    final type = await FileSystemEntity.type(configPath);
    if (type == FileSystemEntityType.notFound) {
      _writeMissingConfigWarning(configPath, output);
      await _writeProjectMetadata(projectRoot, output);
      return 0;
    }
    if (type != FileSystemEntityType.file) {
      throw FileSystemException(
        "desktop_updater.yaml is not a regular file.",
        configPath,
      );
    }

    final yaml = await File(configPath).readAsString();
    final config = await ReleasePublishConfig.fromYaml(
      yaml,
      projectRoot: projectRoot,
      cliOverrides: ReleasePublishOverrides(
        configPath: results["config"] as String?,
      ),
    );
    output.writeln("OK: desktop_updater.yaml loaded.");
    await _writeProjectMetadata(projectRoot, output);
    _writeConfigDiagnostics(config, platform, output);
    return 0;
  } on FormatException catch (error) {
    output.writeln("ERROR: ${error.message}");
    return 64;
  } on Object catch (error) {
    output.writeln("ERROR: Unexpected release doctor failure: $error");
    return 1;
  }
}

String _configPath(Directory projectRoot, String? override) {
  if (override == null || override.trim().isEmpty) {
    return path.join(projectRoot.path, "desktop_updater.yaml");
  }
  final value = override.trim();
  return path.isAbsolute(value) ? value : path.join(projectRoot.path, value);
}

void _writeMissingConfigWarning(String configPath, StringSink output) {
  output
    ..writeln()
    ..writeln("WARNING: desktop_updater.yaml was not found.")
    ..writeln("Expected path:")
    ..writeln(configPath)
    ..writeln()
    ..writeln("Minimum desktop_updater.yaml:")
    ..writeln("updates:")
    ..writeln("  baseUrl: https://updates.example.com");
}

Future<void> _writeProjectMetadata(
  Directory projectRoot,
  StringSink output,
) async {
  final pubspec = File(path.join(projectRoot.path, "pubspec.yaml"));
  if (!await pubspec.exists()) {
    output.writeln("WARNING: pubspec.yaml was not found.");
    return;
  }

  final document = loadYaml(await pubspec.readAsString());
  if (document is! YamlMap) {
    output.writeln("WARNING: pubspec.yaml must contain a map.");
    return;
  }

  final name = document["name"]?.toString().trim();
  final version = document["version"]?.toString().trim();
  if (name == null || name.isEmpty) {
    output.writeln("WARNING: pubspec.yaml name is missing.");
  } else {
    output.writeln("INFO: Project name: $name");
  }
  if (version == null || version.isEmpty) {
    output.writeln("WARNING: pubspec.yaml version is missing.");
  } else {
    output.writeln("INFO: Project version: $version");
  }
}

void _writeConfigDiagnostics(
  ReleasePublishConfig config,
  String platform,
  StringSink output,
) {
  output.writeln("OK: updates.baseUrl = ${config.baseUrl}");
  if (config.baseUrl.scheme == "http") {
    output.writeln(
      "WARNING: updates.baseUrl uses http://. Use https:// for production releases.",
    );
  }

  if (config.uploadProvider.isManual) {
    output.writeln(
      "INFO: No upload provider configured; release publish will prepare a manual upload package.",
    );
  } else {
    output
        .writeln("OK: upload provider = ${config.uploadProvider.providerName}");
  }

  switch (platform) {
    case "windows":
      _writeWindowsDiagnostics(config, output);
    case "linux":
      _writeLinuxDiagnostics(config, output);
    case "macos":
      _writeMacOSDiagnostics(config, output);
  }
}

void _writeWindowsDiagnostics(
  ReleasePublishConfig config,
  StringSink output,
) {
  if (config.hooks.hasPrePackageHookFor("windows")) {
    output.writeln("OK: Windows pre-package hook configured.");
    return;
  }
  output.writeln(
    "WARNING: Windows production releases should configure a hooks.prePackage command for Authenticode signing.",
  );
}

void _writeLinuxDiagnostics(
  ReleasePublishConfig config,
  StringSink output,
) {
  if (config.hooks.hasPostPackageHookFor("linux")) {
    output.writeln("OK: Linux post-package release.json hook configured.");
    return;
  }
  output.writeln(
    "WARNING: Linux direct zip releases should sign release.json with a hooks.postPackage command or another pinned descriptor signature policy.",
  );
}

void _writeMacOSDiagnostics(
  ReleasePublishConfig config,
  StringSink output,
) {
  if (config.macos.notarize || config.hooks.hasPrePackageHookFor("macos")) {
    output.writeln("OK: macOS production trust gate configured.");
    return;
  }
  output.writeln(
    "WARNING: macOS production releases should enable macos.notarize or run an app-owned notarization gate before packaging. Unsigned/internal flows can use allowUnsignedMacOSUpdates, but are not production-trusted.",
  );
}

String _required(ArgResults results, String name) {
  final value = results[name] as String?;
  if (value == null || value.trim().isEmpty) {
    throw FormatException("Missing --$name.");
  }
  return value.trim();
}
