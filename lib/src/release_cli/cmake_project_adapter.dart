import "dart:io";

import "package:desktop_updater/src/macos_update.dart";
import "package:desktop_updater/src/release_cli/project_adapter.dart";
import "package:desktop_updater/src/release_cli/release_publish_config.dart";
import "package:path/path.dart" as path;

/// Builds a self-contained application install tree through CMake.
final class CMakeProjectAdapter implements ProjectAdapter {
  /// Creates a CMake adapter.
  const CMakeProjectAdapter({
    required this.overrides,
    required this.output,
    this.sourceDirectory,
    this.buildDirectory,
    this.buildTarget,
    this.installedArtifactRoot,
    this.executableRelativePath,
    this.skipBuild = false,
    this.runProcess = defaultProcessRunner,
  });

  /// Optional CMake source directory, defaulting to the project root.
  final String? sourceDirectory;

  /// Optional CMake build directory.
  final String? buildDirectory;

  /// Required application build target when no installed tree is supplied.
  final String? buildTarget;

  /// Optional complete, already installed application tree.
  final String? installedArtifactRoot;

  /// Required executable path relative to the install tree.
  final String? executableRelativePath;

  /// Metadata required because CMake has no standard app metadata contract.
  final ReleasePublishOverrides overrides;

  /// Receives CMake command output.
  final StringSink output;

  /// Whether to reuse an existing deterministic install tree.
  final bool skipBuild;

  /// Starts CMake commands.
  final ProcessRunner runProcess;

  @override
  String get type => "cmake";

  @override
  bool canHandle(Directory projectRoot) {
    return File(path.join(projectRoot.path, "CMakeLists.txt")).existsSync();
  }

  @override
  Future<ProjectBuildResult> build(ProjectBuildRequest request) async {
    if (request.platform != "windows" && request.platform != "linux") {
      throw const FormatException(
        "CMake publishing supports only Windows and Linux install trees.",
      );
    }
    final executable = _requiredValue(
      "CMake executableRelativePath",
      executableRelativePath,
    );
    _validateRelativeExecutable(executable);
    final appName = _requiredValue("CMake app name", overrides.appName);
    final packageId = _requiredValue("CMake package id", overrides.packageId);
    final version = _requiredValue("CMake version", overrides.version);

    final installedValue = _optionalValue(installedArtifactRoot);
    late final Directory installRoot;
    if (installedValue != null) {
      installRoot =
          Directory(_resolvePath(request.projectRoot, installedValue));
    } else {
      final target = _requiredValue("CMake build target", buildTarget);
      final source = _resolvePath(
        request.projectRoot,
        _optionalValue(sourceDirectory) ?? request.projectRoot.path,
      );
      if (!File(path.join(source, "CMakeLists.txt")).existsSync()) {
        throw FileSystemException(
          "CMake source directory does not contain CMakeLists.txt.",
          source,
        );
      }
      final buildRoot = _resolvePath(
        request.projectRoot,
        _optionalValue(buildDirectory) ??
            path.join(
              ".dart_tool",
              "desktop_updater",
              "cmake-build",
              request.platform,
            ),
      );
      installRoot = Directory(
        path.join(
          request.projectRoot.path,
          ".dart_tool",
          "desktop_updater",
          "cmake-install",
          request.platform,
        ),
      );
      final configuration = request.releaseMode ? "Release" : "Debug";
      if (!skipBuild) {
        if (await installRoot.exists()) {
          await installRoot.delete(recursive: true);
        }
        await _runChecked(
          executable: "cmake",
          arguments: [
            "-S",
            source,
            "-B",
            buildRoot,
            "-DCMAKE_BUILD_TYPE=$configuration",
          ],
          output: output,
          runProcess: runProcess,
        );
        await _runChecked(
          executable: "cmake",
          arguments: [
            "--build",
            buildRoot,
            "--config",
            configuration,
            "--target",
            target,
          ],
          output: output,
          runProcess: runProcess,
        );
        await _runChecked(
          executable: "cmake",
          arguments: [
            "--install",
            buildRoot,
            "--config",
            configuration,
            "--prefix",
            installRoot.path,
          ],
          output: output,
          runProcess: runProcess,
        );
      }
    }

    final installType = await FileSystemEntity.type(
      installRoot.path,
      followLinks: false,
    );
    if (installType != FileSystemEntityType.directory) {
      throw FileSystemException(
        "CMake publishing requires a complete installed application tree.",
        installRoot.path,
      );
    }
    final executablePath =
        path.normalize(path.join(installRoot.path, executable));
    final rootPath = path.normalize(installRoot.path);
    if (!path.isWithin(rootPath, executablePath)) {
      throw const FormatException(
        "CMake executableRelativePath must stay inside the install tree.",
      );
    }
    final executableType = await FileSystemEntity.type(
      executablePath,
      followLinks: false,
    );
    if (executableType != FileSystemEntityType.file) {
      throw FileSystemException(
        "CMake installed executable does not exist or is not a regular file.",
        executablePath,
      );
    }

    return ProjectBuildResult(
      artifactRoot: installRoot,
      appName: appName,
      packageId: packageId,
      version: version,
      buildNumber: overrides.buildNumber,
      executableRelativePath: executable,
    );
  }
}

void _validateRelativeExecutable(String value) {
  if (path.isAbsolute(value) ||
      path.split(value).any(
            (segment) => segment.isEmpty || segment == "." || segment == "..",
          )) {
    throw const FormatException(
      "CMake executableRelativePath must be a canonical relative path.",
    );
  }
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

Future<void> _runChecked({
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
}
