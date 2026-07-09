import "dart:io";

/// A request to build a complete deployable application artifact.
final class ProjectBuildRequest {
  /// Creates a project build request.
  const ProjectBuildRequest({
    required this.projectRoot,
    required this.platform,
    required this.releaseMode,
  });

  /// Root of the source project.
  final Directory projectRoot;

  /// Desktop target: `macos`, `windows`, or `linux`.
  final String platform;

  /// Whether the adapter should use its release configuration.
  final bool releaseMode;
}

/// Metadata and the complete artifact produced by a project adapter.
final class ProjectBuildResult {
  /// Creates a project build result.
  const ProjectBuildResult({
    required this.artifactRoot,
    required this.appName,
    required this.packageId,
    required this.version,
    this.buildNumber,
    this.executableRelativePath,
  });

  /// Complete directory or platform bundle that must be packaged.
  final FileSystemEntity artifactRoot;

  /// Display name used in release metadata.
  final String appName;

  /// Stable application package identity.
  final String packageId;

  /// Release version name.
  final String version;

  /// Optional monotonically increasing build number.
  final int? buildNumber;

  /// Executable path relative to [artifactRoot], when required for relaunch.
  final String? executableRelativePath;
}

/// Builds a deployable artifact from one supported project type.
abstract interface class ProjectAdapter {
  /// Stable adapter type used by explicit selection.
  String get type;

  /// Whether this adapter recognizes [projectRoot].
  bool canHandle(Directory projectRoot);

  /// Builds or resolves the artifact described by [request].
  Future<ProjectBuildResult> build(ProjectBuildRequest request);
}

/// Internal selection inputs used before Stage 8 exposes CLI flags.
final class ProjectAdapterSelectionRequest {
  /// Creates an adapter selection request.
  const ProjectAdapterSelectionRequest({
    required this.projectRoot,
    this.explicitType,
    this.manualArtifactRoot,
    this.manualAppName,
    this.manualPackageId,
    this.manualVersion,
    this.manualBuildNumber,
    this.manualExecutableRelativePath,
  });

  /// Root inspected for project markers.
  final Directory projectRoot;

  /// Explicit adapter type, when provided by an internal caller.
  final String? explicitType;

  /// Complete prebuilt artifact for manual publishing.
  final FileSystemEntity? manualArtifactRoot;

  /// Manual artifact application name.
  final String? manualAppName;

  /// Manual artifact package identity.
  final String? manualPackageId;

  /// Manual artifact version.
  final String? manualVersion;

  /// Manual artifact build number.
  final int? manualBuildNumber;

  /// Executable path relative to the manual artifact root.
  final String? manualExecutableRelativePath;
}

/// Selects a project adapter using an internal request.
abstract interface class ProjectAdapterSelector {
  /// Returns the selected adapter or throws a usage-oriented format error.
  ProjectAdapter select(ProjectAdapterSelectionRequest request);
}

/// Starts the Flutter build subprocess used by the Flutter adapter.
typedef BuildProcessStarter = Future<BuildProcess> Function(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  bool runInShell,
});

/// A started build subprocess.
abstract interface class BuildProcess {
  /// The process standard output stream.
  Stream<List<int>> get stdout;

  /// The process standard error stream.
  Stream<List<int>> get stderr;

  /// Completes with the process exit code.
  Future<int> get exitCode;
}

/// Adapter for a real `dart:io` process.
class StartedBuildProcess implements BuildProcess {
  /// Creates an adapter for [process].
  const StartedBuildProcess(this.process);

  /// The underlying process.
  final Process process;

  @override
  Stream<List<int>> get stdout => process.stdout;

  @override
  Stream<List<int>> get stderr => process.stderr;

  @override
  Future<int> get exitCode => process.exitCode;
}

/// Default Flutter build process starter.
Future<BuildProcess> defaultBuildProcessStarter(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  bool runInShell = false,
}) async {
  return StartedBuildProcess(
    await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      runInShell: runInShell,
    ),
  );
}
