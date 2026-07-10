import "dart:io";

import "package:desktop_updater/src/macos_update.dart";
import "package:desktop_updater/src/release_cli/project_adapter.dart";
import "package:desktop_updater/src/release_cli/release_publish_config.dart";
import "package:path/path.dart" as path;

/// Builds a complete macOS app bundle through an explicit Xcode container.
final class XcodeProjectAdapter implements ProjectAdapter {
  /// Creates an Xcode adapter.
  const XcodeProjectAdapter({
    required this.overrides,
    required this.output,
    this.projectPath,
    this.workspacePath,
    this.scheme,
    this.derivedDataPath,
    this.skipBuild = false,
    this.runProcess = defaultProcessRunner,
  });

  /// Optional `.xcodeproj` path, relative to the project root when needed.
  final String? projectPath;

  /// Optional `.xcworkspace` path, relative to the project root when needed.
  final String? workspacePath;

  /// Required Xcode scheme.
  final String? scheme;

  /// Optional deterministic derived-data directory override.
  final String? derivedDataPath;

  /// Metadata overrides shared with release publishing.
  final ReleasePublishOverrides overrides;

  /// Receives Xcode output.
  final StringSink output;

  /// Whether to reuse an existing build while still resolving build settings.
  final bool skipBuild;

  /// Starts Xcode commands.
  final ProcessRunner runProcess;

  @override
  String get type => "xcode";

  @override
  bool canHandle(Directory projectRoot) {
    if (!projectRoot.existsSync()) {
      return false;
    }
    return projectRoot.listSync(followLinks: false).any(
          (entity) =>
              entity is Directory &&
              (entity.path.endsWith(".xcodeproj") ||
                  entity.path.endsWith(".xcworkspace")),
        );
  }

  @override
  Future<ProjectBuildResult> build(ProjectBuildRequest request) async {
    if (request.platform != "macos") {
      throw const FormatException(
        "Xcode publishing is supported only for --platform macos.",
      );
    }
    final schemeValue = _requiredValue("Xcode scheme", scheme);
    final projectValue = _optionalValue(projectPath);
    final workspaceValue = _optionalValue(workspacePath);
    if ((projectValue == null) == (workspaceValue == null)) {
      throw const FormatException(
        "Xcode publishing requires exactly one project or workspace.",
      );
    }

    final containerFlag = projectValue == null ? "-workspace" : "-project";
    final containerPath = _resolvePath(
      request.projectRoot,
      projectValue ?? workspaceValue!,
    );
    final expectedSuffix = projectValue == null ? ".xcworkspace" : ".xcodeproj";
    if (!containerPath.endsWith(expectedSuffix) ||
        !Directory(containerPath).existsSync()) {
      throw FileSystemException(
        "Xcode container does not exist or has the wrong type.",
        containerPath,
      );
    }

    final configuration = request.releaseMode ? "Release" : "Debug";
    final derivedData = _resolvePath(
      request.projectRoot,
      _optionalValue(derivedDataPath) ??
          path.join(
            ".dart_tool",
            "desktop_updater",
            "xcode-derived-data",
            _safePathSegment(schemeValue),
          ),
    );
    final commonArguments = <String>[
      containerFlag,
      containerPath,
      "-scheme",
      schemeValue,
      "-configuration",
      configuration,
      "-destination",
      "platform=macOS",
      "-derivedDataPath",
      derivedData,
    ];

    if (!skipBuild) {
      await _runChecked(
        executable: "xcodebuild",
        arguments: [...commonArguments, "build"],
        output: output,
        runProcess: runProcess,
      );
    }
    final settingsResult = await _runChecked(
      executable: "xcodebuild",
      arguments: [...commonArguments, "-showBuildSettings"],
      output: output,
      runProcess: runProcess,
    );
    final settingsBlocks =
        _parseBuildSettings(settingsResult.stdout.toString());
    final appSettings = settingsBlocks.where(
      (settings) =>
          (settings["WRAPPER_NAME"] ?? settings["FULL_PRODUCT_NAME"] ?? "")
              .endsWith(".app"),
    );
    if (appSettings.length != 1) {
      throw const FormatException(
        "Xcode build settings must resolve exactly one .app target.",
      );
    }
    final settings = appSettings.single;
    final targetBuildDirectory = _requiredSetting(settings, "TARGET_BUILD_DIR");
    final wrapperName = settings["WRAPPER_NAME"] ??
        _requiredSetting(settings, "FULL_PRODUCT_NAME");
    if (!wrapperName.endsWith(".app")) {
      throw const FormatException(
        "Xcode build settings must resolve a complete .app bundle.",
      );
    }
    final bundle = Directory(path.join(targetBuildDirectory, wrapperName));
    final bundleType = await FileSystemEntity.type(
      bundle.path,
      followLinks: false,
    );
    if (bundleType != FileSystemEntityType.directory) {
      throw FileSystemException(
        "Xcode build did not produce the expected app bundle.",
        bundle.path,
      );
    }

    final appName = _optionalValue(overrides.appName) ?? wrapperName;
    final packageId = _optionalValue(overrides.packageId) ??
        _requiredSetting(settings, "PRODUCT_BUNDLE_IDENTIFIER");
    final version = _optionalValue(overrides.version) ??
        _requiredSetting(settings, "MARKETING_VERSION");
    final buildNumber = overrides.buildNumber ??
        int.tryParse(settings["CURRENT_PROJECT_VERSION"] ?? "");

    return ProjectBuildResult(
      artifactRoot: bundle,
      appName: appName,
      packageId: packageId,
      version: version,
      buildNumber: buildNumber,
    );
  }
}

List<Map<String, String>> _parseBuildSettings(String value) {
  final settingsBlocks = <Map<String, String>>[];
  var settings = <String, String>{};
  final expression = RegExp(r"^\s*([A-Z0-9_]+)\s*=\s*(.*?)\s*$");
  for (final line in value.split("\n")) {
    if (line.startsWith("Build settings for action")) {
      if (settings.isNotEmpty) {
        settingsBlocks.add(settings);
      }
      settings = <String, String>{};
      continue;
    }
    final match = expression.firstMatch(line);
    if (match != null) {
      settings[match.group(1)!] = match.group(2)!;
    }
  }
  if (settings.isNotEmpty) {
    settingsBlocks.add(settings);
  }
  return settingsBlocks;
}

String _requiredSetting(Map<String, String> settings, String key) {
  return _requiredValue("Xcode build setting $key", settings[key]);
}

String _safePathSegment(String value) {
  return value.replaceAll(RegExp(r"[^A-Za-z0-9._-]"), "_");
}

String _resolvePath(Directory root, String value) {
  return path.normalize(
    path.isAbsolute(value) ? value : path.join(root.path, value),
  );
}

String? _optionalValue(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

String _requiredValue(String name, String? value) {
  final result = _optionalValue(value);
  if (result == null) {
    throw FormatException("$name is required.");
  }
  return result;
}

Future<ProcessResult> _runChecked({
  required String executable,
  required List<String> arguments,
  required StringSink output,
  required ProcessRunner runProcess,
}) async {
  final result = await runProcess(executable, arguments);
  if (result.stdout.toString().isNotEmpty) {
    output.write(result.stdout);
  }
  if (result.stderr.toString().isNotEmpty) {
    output.write(result.stderr);
  }
  if (result.exitCode != 0) {
    throw ProcessException(
      executable,
      arguments,
      "Command failed with exit code ${result.exitCode}.",
      result.exitCode,
    );
  }
  return result;
}
