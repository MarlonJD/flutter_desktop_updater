import "dart:io";

import "package:desktop_updater/src/release_cli/project_adapter.dart";
import "package:path/path.dart" as path;

/// Resolves a caller-supplied complete application bundle without building it.
final class ManualProjectAdapter implements ProjectAdapter {
  /// Creates a manual bundle adapter with complete release metadata.
  const ManualProjectAdapter({
    required this.artifactRoot,
    required this.appName,
    required this.packageId,
    required this.version,
    this.buildNumber,
    this.executableRelativePath,
  });

  /// Complete prebuilt application directory or bundle.
  final FileSystemEntity artifactRoot;

  /// Display name written to release metadata.
  final String appName;

  /// Stable application identity written to release metadata.
  final String packageId;

  /// Release version written to release metadata.
  final String version;

  /// Optional build number written to release metadata.
  final int? buildNumber;

  /// Optional executable path relative to [artifactRoot].
  final String? executableRelativePath;

  @override
  String get type => "manual";

  @override
  bool canHandle(Directory projectRoot) => false;

  @override
  Future<ProjectBuildResult> build(ProjectBuildRequest request) async {
    _requireMetadata("app name", appName);
    _requireMetadata("package id", packageId);
    _requireMetadata("version", version);

    final artifactType = await FileSystemEntity.type(
      artifactRoot.path,
      followLinks: false,
    );
    if (artifactType == FileSystemEntityType.notFound) {
      throw FileSystemException(
        "Manual artifact root does not exist.",
        artifactRoot.path,
      );
    }
    if (artifactType == FileSystemEntityType.link) {
      throw FormatException(
        "Manual artifact root must not be a symbolic link: "
        "${artifactRoot.path}",
      );
    }
    if (artifactType != FileSystemEntityType.directory) {
      if (request.platform == "windows") {
        throw const FormatException(
          "Manual Windows publishing requires a complete Windows artifact "
          "directory, not a single executable.",
        );
      }
      if (request.platform == "linux") {
        throw const FormatException(
          "Manual Linux publishing requires a self-contained Linux artifact "
          "directory, not a single executable.",
        );
      }
      throw const FormatException(
        "Manual publishing requires a complete application bundle.",
      );
    }

    final executable = executableRelativePath?.trim();
    if (executable != null &&
        executable.isNotEmpty &&
        (path.isAbsolute(executable) ||
            path.split(executable).any((segment) => segment == ".."))) {
      throw const FormatException(
        "Manual executable path must stay relative to the artifact root.",
      );
    }

    return ProjectBuildResult(
      artifactRoot: Directory(artifactRoot.path),
      appName: appName.trim(),
      packageId: packageId.trim(),
      version: version.trim(),
      buildNumber: buildNumber,
      executableRelativePath:
          executable == null || executable.isEmpty ? null : executable,
    );
  }
}

/// Default deterministic adapter selector used by release publishing.
final class DefaultProjectAdapterSelector implements ProjectAdapterSelector {
  /// Creates a selector with Flutter and future native adapter candidates.
  const DefaultProjectAdapterSelector({this.adapters = const []});

  /// Adapters available for explicit or marker-based selection.
  final List<ProjectAdapter> adapters;

  @override
  ProjectAdapter select(ProjectAdapterSelectionRequest request) {
    final explicitType = request.explicitType?.trim();
    if (explicitType != null && explicitType.isNotEmpty) {
      if (explicitType == "manual") {
        return _manualAdapter(request);
      }
      final explicit = adapters.where(
        (adapter) => adapter.type == explicitType,
      );
      if (explicit.length == 1) {
        return explicit.single;
      }
      if (explicit.length > 1) {
        throw FormatException(
          "Multiple adapters are registered for project type $explicitType.",
        );
      }
      throw FormatException("Unsupported project type: $explicitType.");
    }

    if (_hasAnyManualInput(request)) {
      return _manualAdapter(request);
    }

    final flutterCandidates = adapters.where(
      (adapter) =>
          adapter.type == "flutter" && adapter.canHandle(request.projectRoot),
    );
    if (flutterCandidates.isNotEmpty) {
      if (flutterCandidates.length > 1) {
        throw const FormatException(
          "Multiple Flutter project adapters are registered.",
        );
      }
      return flutterCandidates.single;
    }

    final nativeCandidates = adapters.where(
      (adapter) =>
          adapter.type != "flutter" &&
          adapter.type != "manual" &&
          adapter.canHandle(request.projectRoot),
    );
    if (nativeCandidates.length == 1) {
      return nativeCandidates.single;
    }
    if (nativeCandidates.length > 1) {
      throw const FormatException(
        "Multiple project types were detected. Supply an explicit project "
        "type.",
      );
    }
    throw const FormatException(
      "Unable to infer a project type. Supply an explicit project type or a "
      "manual artifact root with app name, package id, and version.",
    );
  }
}

bool _hasAnyManualInput(ProjectAdapterSelectionRequest request) {
  return request.manualArtifactRoot != null ||
      request.manualAppName != null ||
      request.manualPackageId != null ||
      request.manualVersion != null ||
      request.manualBuildNumber != null ||
      request.manualExecutableRelativePath != null;
}

ManualProjectAdapter _manualAdapter(ProjectAdapterSelectionRequest request) {
  final artifactRoot = request.manualArtifactRoot;
  final appName = request.manualAppName?.trim();
  final packageId = request.manualPackageId?.trim();
  final version = request.manualVersion?.trim();
  if (artifactRoot == null ||
      appName == null ||
      appName.isEmpty ||
      packageId == null ||
      packageId.isEmpty ||
      version == null ||
      version.isEmpty) {
    throw const FormatException(
      "Manual publishing requires artifact root, app name, package id, and "
      "version.",
    );
  }
  return ManualProjectAdapter(
    artifactRoot: artifactRoot,
    appName: appName,
    packageId: packageId,
    version: version,
    buildNumber: request.manualBuildNumber,
    executableRelativePath: request.manualExecutableRelativePath,
  );
}

void _requireMetadata(String name, String value) {
  if (value.trim().isEmpty) {
    throw FormatException("Manual artifact $name is required.");
  }
}
