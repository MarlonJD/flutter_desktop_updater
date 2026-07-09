import "dart:convert";
import "dart:io";

import "package:desktop_updater/src/release_cli/project_adapter.dart";
import "package:desktop_updater/src/release_cli/project_metadata_resolver.dart";
import "package:desktop_updater/src/release_cli/release_publish_config.dart";
import "package:path/path.dart" as path;

/// Preserves the existing Flutter build and artifact resolution behavior.
final class FlutterProjectAdapter implements ProjectAdapter {
  /// Creates the Flutter adapter used by the release publisher.
  const FlutterProjectAdapter({
    required this.overrides,
    required this.output,
    this.skipBuild = false,
    this.metadataResolver = const ProjectMetadataResolver(),
    this.startBuildProcess = defaultBuildProcessStarter,
  });

  /// Creates a marker-only adapter for project selection tests and discovery.
  const FlutterProjectAdapter.forSelection()
      : overrides = const ReleasePublishOverrides(),
        output = null,
        skipBuild = true,
        metadataResolver = const ProjectMetadataResolver(),
        startBuildProcess = defaultBuildProcessStarter;

  /// Metadata overrides forwarded by the publish request.
  final ReleasePublishOverrides overrides;

  /// Sink that receives the build subprocess output.
  final StringSink? output;

  /// Whether to resolve the existing output without starting Flutter.
  final bool skipBuild;

  /// Resolves Flutter project metadata and output layout.
  final ProjectMetadataResolver metadataResolver;

  /// Starts the Flutter build subprocess.
  final BuildProcessStarter startBuildProcess;

  @override
  String get type => "flutter";

  @override
  bool canHandle(Directory projectRoot) {
    return File(path.join(projectRoot.path, "pubspec.yaml")).existsSync();
  }

  @override
  Future<ProjectBuildResult> build(ProjectBuildRequest request) async {
    final metadata = await metadataResolver.resolve(
      projectRoot: request.projectRoot,
      platform: request.platform,
      overrides: overrides,
    );
    if (!skipBuild) {
      final sink = output;
      if (sink == null) {
        throw StateError("Flutter build output sink is required.");
      }
      await _buildFlutterProject(
        request: request,
        metadata: metadata,
        dartDefines: overrides.dartDefines,
        output: sink,
        startBuildProcess: startBuildProcess,
      );
    }
    return ProjectBuildResult(
      artifactRoot: metadata.input,
      appName: metadata.appName,
      packageId: metadata.packageId,
      version: metadata.version,
      buildNumber: metadata.buildNumber,
    );
  }
}

Future<void> _buildFlutterProject({
  required ProjectBuildRequest request,
  required ProjectMetadata metadata,
  required List<String> dartDefines,
  required StringSink output,
  required BuildProcessStarter startBuildProcess,
}) async {
  output.writeln("Building ${metadata.platform} release...");
  final flutterBuildArgs = [
    for (final argument in metadata.profile.flutterBuildArgs)
      if (request.releaseMode || argument != "--release") argument,
    for (final define in dartDefines) "--dart-define=$define",
  ];
  final process = await startBuildProcess(
    "flutter",
    flutterBuildArgs,
    workingDirectory: request.projectRoot.path,
    runInShell: _shouldRunFlutterBuildInShell(metadata.platform),
  );

  final stdoutDone =
      process.stdout.transform(utf8.decoder).forEach(output.write);
  final stderrDone =
      process.stderr.transform(utf8.decoder).forEach(output.write);
  final exitCode = await process.exitCode;
  await Future.wait([stdoutDone, stderrDone]);

  if (exitCode != 0) {
    throw ProcessException(
      "flutter",
      flutterBuildArgs,
      "Build failed with exit code $exitCode",
      exitCode,
    );
  }
}

bool _shouldRunFlutterBuildInShell(String platform) {
  return platform == "windows";
}
