import "dart:convert";
import "dart:io";

import "package:desktop_updater/src/core/release_index.dart";
import "package:desktop_updater/src/macos_update.dart";
import "package:desktop_updater/src/package/app_archive_writer.dart";
import "package:desktop_updater/src/package/release_packager.dart";
import "package:desktop_updater/src/package/zip_release_packager.dart";
import "package:desktop_updater/src/release_cli/project_metadata_resolver.dart";
import "package:desktop_updater/src/release_cli/publish_layout.dart";
import "package:desktop_updater/src/release_cli/publish_manifest.dart";
import "package:desktop_updater/src/release_cli/release_publish_config.dart";
import "package:desktop_updater/src/release_cli/upload/custom_command_upload_provider.dart";
import "package:desktop_updater/src/release_cli/upload/ftp_upload_provider.dart";
import "package:desktop_updater/src/release_cli/upload/manual_upload_provider.dart";
import "package:desktop_updater/src/release_cli/upload/s3_upload_provider.dart";
import "package:desktop_updater/src/release_cli/upload/sftp_upload_provider.dart";
import "package:desktop_updater/src/release_cli/upload/upload_provider.dart";
import "package:desktop_updater/src/release_cli/validate_command.dart";
import "package:path/path.dart" as path;

/// Starts the Flutter build subprocess used by `release publish`.
typedef BuildProcessStarter = Future<BuildProcess> Function(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  bool runInShell,
});

/// Runs a configured release hook command.
typedef ReleaseHookCommandRunner = Future<ProcessResult> Function(
  String command, {
  required Map<String, String> environment,
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

class ReleasePublisher {
  const ReleasePublisher({
    this.skipBuild = false,
    this.packager = const ZipReleasePackager(),
    this.metadataResolver = const ProjectMetadataResolver(),
    this.runProcess = defaultProcessRunner,
    this.runHookCommand = defaultReleaseHookCommandRunner,
    BuildProcessStarter startBuildProcess = defaultBuildProcessStarter,
  }) : _startBuildProcess = startBuildProcess;

  final bool skipBuild;
  final ReleasePackager packager;
  final ProjectMetadataResolver metadataResolver;
  final ProcessRunner runProcess;
  final ReleaseHookCommandRunner runHookCommand;
  final BuildProcessStarter _startBuildProcess;

  Future<PublishManifest> publish({
    required Directory projectRoot,
    required String platform,
    required ReleasePublishOverrides overrides,
    required StringSink output,
  }) async {
    final config = await ReleasePublishConfig.load(
      projectRoot: projectRoot,
      cliOverrides: overrides,
    );
    if (overrides.notarize && platform != "macos") {
      throw const FormatException(
        "--notarize is only supported with --platform macos.",
      );
    }
    final metadata = await metadataResolver.resolve(
      projectRoot: projectRoot,
      platform: platform,
      overrides: overrides,
    );
    final layout = PublishLayout.create(
      outputDirectory: config.outputDirectory,
      baseUrl: config.baseUrl,
      version: metadata.version,
      platform: platform,
      appName: metadata.appName,
    );

    if (!skipBuild) {
      await _build(projectRoot, metadata, output, _startBuildProcess);
    }

    if (platform == "macos" && config.macos.notarize) {
      await _notarizeMacOS(
        app: metadata.input,
        config: config.macos,
        runProcess: runProcess,
        output: output,
      );
    }

    await _runReleaseHooks(
      hooks: config.hooks.prePackage,
      phase: "prePackage",
      projectRoot: projectRoot,
      config: config,
      metadata: metadata,
      layout: layout,
      runHookCommand: runHookCommand,
      output: output,
    );

    output.writeln("Packaging update...");
    final packageAppName = _artifactNameStem(metadata.appName);
    final packageResult = await packager.package(
      ReleasePackageRequest(
        input: metadata.input,
        outputDirectory: layout.releaseDirectory,
        packageId: metadata.packageId,
        appName: packageAppName,
        version: metadata.version,
        buildNumber: metadata.buildNumber,
        platform: platform,
        channel: config.channel,
        artifactUrl: layout.artifactUrl,
        installStrategy: metadata.profile.installStrategy,
      ),
    );

    await upsertAppArchive(
      archiveFile: layout.appArchiveFile,
      appName: packageAppName,
      item: ReleaseIndexItem(
        version: metadata.version,
        buildNumber: metadata.buildNumber,
        platform: platform,
        channel: config.channel,
        mandatory: overrides.mandatory,
        release: layout.releaseUrl,
      ),
    );

    final manifest = PublishManifest(
      schemaVersion: 1,
      baseUrl: config.baseUrl,
      localRoot: config.outputDirectory.path,
      appArchive: PublishManifestFile(
        path: layout.appArchiveRelativePath,
        url: layout.appArchiveUrl,
      ),
      release: PublishManifestRelease(
        version: metadata.version,
        buildNumber: metadata.buildNumber,
        platform: platform,
        channel: config.channel,
        path: layout.releaseRelativePath,
        url: layout.releaseUrl,
      ),
      artifact: PublishManifestArtifact(
        path: layout.artifactRelativePath,
        url: layout.artifactUrl,
        sha256: packageResult.descriptor.artifact.sha256,
        length: packageResult.descriptor.artifact.length,
      ),
    );
    await manifest.writeTo(layout.manifestFile);

    await _runReleaseHooks(
      hooks: config.hooks.postPackage,
      phase: "postPackage",
      projectRoot: projectRoot,
      config: config,
      metadata: metadata,
      layout: layout,
      runHookCommand: runHookCommand,
      output: output,
    );

    await _uploadAndValidate(
      provider: _providerFor(config.uploadProvider),
      config: config.uploadProvider,
      localRoot: config.outputDirectory,
      manifest: manifest,
      output: output,
    );

    return manifest;
  }
}

Future<void> _runReleaseHooks({
  required List<ReleaseHookConfig> hooks,
  required String phase,
  required Directory projectRoot,
  required ReleasePublishConfig config,
  required ProjectMetadata metadata,
  required PublishLayout layout,
  required ReleaseHookCommandRunner runHookCommand,
  required StringSink output,
}) async {
  for (final hook in hooks.where((hook) => hook.appliesTo(metadata.platform))) {
    output.writeln("Running $phase hook: ${hook.command}");
    final result = await runHookCommand(
      hook.command,
      environment: _releaseHookEnvironment(
        phase: phase,
        projectRoot: projectRoot,
        config: config,
        metadata: metadata,
        layout: layout,
      ),
    );
    if (result.stdout.toString().isNotEmpty) {
      output.write(result.stdout);
    }
    if (result.stderr.toString().isNotEmpty) {
      output.write(result.stderr);
    }
    if (result.exitCode != 0) {
      throw ProcessException(
        "release hook",
        [phase, hook.command],
        "${result.stdout}\n${result.stderr}",
        result.exitCode,
      );
    }
  }
}

Map<String, String> _releaseHookEnvironment({
  required String phase,
  required Directory projectRoot,
  required ReleasePublishConfig config,
  required ProjectMetadata metadata,
  required PublishLayout layout,
}) {
  return {
    ...Platform.environment,
    "DESKTOP_UPDATER_HOOK_PHASE": phase,
    "DESKTOP_UPDATER_PLATFORM": metadata.platform,
    "DESKTOP_UPDATER_PROJECT_ROOT": projectRoot.path,
    "DESKTOP_UPDATER_APP_PATH": metadata.input.path,
    "DESKTOP_UPDATER_BASE_URL": config.baseUrl.toString(),
    "DESKTOP_UPDATER_OUTPUT_ROOT": config.outputDirectory.path,
    "DESKTOP_UPDATER_CHANNEL": config.channel,
    "DESKTOP_UPDATER_APP_NAME": metadata.appName,
    "DESKTOP_UPDATER_PACKAGE_ID": metadata.packageId,
    "DESKTOP_UPDATER_VERSION": metadata.version,
    if (metadata.buildNumber != null)
      "DESKTOP_UPDATER_BUILD_NUMBER": metadata.buildNumber.toString(),
    "DESKTOP_UPDATER_PUBLISH_MANIFEST": layout.manifestFile.path,
    "DESKTOP_UPDATER_APP_ARCHIVE_FILE": layout.appArchiveFile.path,
    "DESKTOP_UPDATER_RELEASE_FILE": layout.releaseFile.path,
    "DESKTOP_UPDATER_ARTIFACT_FILE": layout.artifactFile.path,
    "DESKTOP_UPDATER_APP_ARCHIVE_URL": layout.appArchiveUrl.toString(),
    "DESKTOP_UPDATER_RELEASE_URL": layout.releaseUrl.toString(),
    "DESKTOP_UPDATER_ARTIFACT_URL": layout.artifactUrl.toString(),
  };
}

Future<void> _notarizeMacOS({
  required FileSystemEntity app,
  required MacOSPublishConfig config,
  required ProcessRunner runProcess,
  required StringSink output,
}) async {
  if (app is! Directory) {
    throw FileSystemException(
      "macOS notarization requires an .app directory",
      app.path,
    );
  }

  output.writeln("Signing macOS app...");
  await _signMacOSAppForNotarization(
    app: app,
    developerIdApplication: config.developerIdApplication!,
    runProcess: runProcess,
  );
  await _runChecked(
    "/usr/bin/codesign",
    ["--verify", "--deep", "--strict", "--verbose=2", app.path],
    runProcess,
  );

  final tempDir =
      await Directory.systemTemp.createTemp("desktop_updater_notary_");
  try {
    final notaryZip = path.join(tempDir.path, "notary.zip");
    output.writeln("Creating macOS notarization archive...");
    await runDittoCreateZip(
      appPath: app.path,
      archivePath: notaryZip,
      runProcess: runProcess,
    );

    output.writeln("Submitting macOS app for notarization...");
    final result = await _runChecked(
      "/usr/bin/xcrun",
      [
        "notarytool",
        "submit",
        notaryZip,
        "--keychain-profile",
        config.notaryProfile!,
        "--keychain",
        config.keychain!,
        "--wait",
        "--output-format",
        "json",
      ],
      runProcess,
    );
    _verifyNotarySubmissionAccepted(result.stdout.toString());
  } finally {
    await tempDir.delete(recursive: true);
  }

  if (config.staple) {
    output.writeln("Stapling macOS notarization ticket...");
    await _runChecked(
      "/usr/bin/xcrun",
      ["stapler", "staple", app.path],
      runProcess,
    );
    await _runChecked(
      "/usr/bin/xcrun",
      ["stapler", "validate", app.path],
      runProcess,
    );
  }

  if (config.gatekeeperAssess) {
    output.writeln("Assessing macOS app with Gatekeeper...");
    await _runChecked(
      "/usr/sbin/spctl",
      ["--assess", "--type", "execute", "--verbose=2", app.path],
      runProcess,
    );
  }
}

Future<void> _signMacOSAppForNotarization({
  required Directory app,
  required String developerIdApplication,
  required ProcessRunner runProcess,
}) async {
  final nestedCode = await _nestedMacOSCodeToSign(app);
  for (final entity in nestedCode) {
    await _runChecked(
      "/usr/bin/codesign",
      _codesignArguments(developerIdApplication, entity.path),
      runProcess,
    );
  }
  await _runChecked(
    "/usr/bin/codesign",
    _codesignArguments(developerIdApplication, app.path),
    runProcess,
  );
}

Future<List<FileSystemEntity>> _nestedMacOSCodeToSign(Directory app) async {
  final frameworks = Directory(path.join(app.path, "Contents", "Frameworks"));
  if (!await frameworks.exists()) {
    return const [];
  }

  final entities = <FileSystemEntity>[];
  await for (final entity in frameworks.list(
    recursive: true,
    followLinks: false,
  )) {
    if (_shouldSignNestedMacOSCode(entity)) {
      entities.add(entity);
    }
  }
  entities.sort((a, b) {
    final depthComparison =
        path.split(b.path).length.compareTo(path.split(a.path).length);
    if (depthComparison != 0) {
      return depthComparison;
    }
    return a.path.compareTo(b.path);
  });
  return entities;
}

bool _shouldSignNestedMacOSCode(FileSystemEntity entity) {
  final extension = path.extension(entity.path).toLowerCase();
  if (entity is Directory) {
    return const {".app", ".appex", ".framework", ".xpc"}.contains(extension);
  }
  if (entity is File) {
    return const {".dylib", ".so"}.contains(extension);
  }
  return false;
}

List<String> _codesignArguments(String identity, String target) {
  return [
    "--force",
    "--options",
    "runtime",
    "--timestamp",
    "--sign",
    identity,
    target,
  ];
}

void _verifyNotarySubmissionAccepted(String response) {
  late final Object? decoded;
  try {
    decoded = jsonDecode(response);
  } on FormatException catch (error) {
    throw StateError(
      "Unable to parse macOS notarization response: ${error.message}",
    );
  }
  if (decoded is! Map<String, Object?>) {
    throw StateError("Unable to parse macOS notarization response.");
  }

  final status = decoded["status"]?.toString();
  if (status == "Accepted") {
    return;
  }
  final id = decoded["id"]?.toString();
  final suffix = id == null || id.isEmpty ? "" : " for submission $id";
  throw StateError("macOS notarization failed: $status$suffix.");
}

Future<void> _build(
  Directory projectRoot,
  ProjectMetadata metadata,
  StringSink output,
  BuildProcessStarter startBuildProcess,
) async {
  output.writeln("Building ${metadata.platform} release...");
  final process = await startBuildProcess(
    "flutter",
    metadata.profile.flutterBuildArgs,
    workingDirectory: projectRoot.path,
    runInShell: _shouldRunFlutterBuildInShell(metadata.platform),
  );

  final stdoutDone = process.stdout.transform(utf8.decoder).forEach(
        output.write,
      );
  final stderrDone = process.stderr.transform(utf8.decoder).forEach(
        output.write,
      );
  final exitCode = await process.exitCode;
  await Future.wait([stdoutDone, stderrDone]);

  if (exitCode != 0) {
    throw ProcessException(
      "flutter",
      metadata.profile.flutterBuildArgs,
      "Build failed with exit code $exitCode",
      exitCode,
    );
  }
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

/// Default shell runner for configured release hook commands.
Future<ProcessResult> defaultReleaseHookCommandRunner(
  String command, {
  required Map<String, String> environment,
}) {
  if (Platform.isWindows) {
    return _runWindowsReleaseHook(command, environment);
  }
  return Process.run(
    "/bin/sh",
    ["-c", command],
    environment: environment,
  );
}

Future<ProcessResult> _runWindowsReleaseHook(
  String command,
  Map<String, String> environment,
) async {
  final tempDir =
      await Directory.systemTemp.createTemp("desktop_updater_hook_");
  try {
    final script = File(path.join(tempDir.path, "hook.cmd"));
    await script.writeAsString("@echo off\r\n$command\r\n");
    return await Process.run(
      "cmd",
      ["/d", "/e:off", "/v:off", "/c", script.path],
      environment: environment,
    );
  } finally {
    await tempDir.delete(recursive: true);
  }
}

bool _shouldRunFlutterBuildInShell(String platform) {
  return platform == "windows";
}

Future<ProcessResult> _runChecked(
  String executable,
  List<String> arguments,
  ProcessRunner runProcess,
) async {
  final result = await runProcess(executable, arguments);
  if (result.exitCode != 0) {
    throw ProcessException(
      executable,
      arguments,
      "Command failed with exit ${result.exitCode}: ${result.stderr}${result.stdout}",
      result.exitCode,
    );
  }
  return result;
}

UploadProvider _providerFor(UploadConfig config) {
  if (config is ManualUploadConfig) {
    return const ManualUploadProvider();
  }
  if (config is S3UploadConfig) {
    return const S3UploadProvider();
  }
  if (config is SftpUploadConfig) {
    return const SftpUploadProvider();
  }
  if (config is FtpUploadConfig) {
    return const FtpUploadProvider();
  }
  if (config is CustomCommandUploadConfig) {
    return const CustomCommandUploadProvider();
  }
  throw FormatException(
    "Upload provider ${config.providerName} is not implemented yet.",
  );
}

Future<void> _uploadAndValidate({
  required UploadProvider provider,
  required UploadConfig config,
  required Directory localRoot,
  required PublishManifest manifest,
  required StringSink output,
}) async {
  if (config is ManualUploadConfig) {
    await provider.upload(
      localRoot: localRoot,
      manifest: manifest,
      config: config,
      output: output,
    );
    return;
  }

  final validator = ReleaseValidator();
  if (provider is OrderedUploadProvider) {
    output.writeln("Uploading versioned files...");
    await provider.uploadVersionedFiles(
      localRoot: localRoot,
      manifest: manifest,
      config: config,
      output: output,
    );
    output.writeln("Validating hosted release descriptor...");
    await validator.validateReleaseFiles(manifest: manifest, output: output);
    output.writeln("Publishing app-archive.json last...");
    await provider.uploadAppArchive(
      localRoot: localRoot,
      manifest: manifest,
      config: config,
      output: output,
    );
  } else {
    output.writeln("Uploading release files...");
    await provider.upload(
      localRoot: localRoot,
      manifest: manifest,
      config: config,
      output: output,
    );
  }

  output.writeln("Validating hosted update selection...");
  await validator.validate(
    manifestFile:
        File(path.join(localRoot.path, ".desktop_updater_publish.json")),
    fromVersion: null,
    output: output,
  );
  output
    ..writeln()
    ..writeln("OK: Published and validated.")
    ..writeln()
    ..writeln("App archive:")
    ..writeln(manifest.appArchive.url)
    ..writeln()
    ..writeln("Release:")
    ..writeln(manifest.release.url)
    ..writeln()
    ..writeln("Artifact:")
    ..writeln(manifest.artifact.url);
}

String _artifactNameStem(String appName) {
  var stem = path.basename(appName);
  if (stem.endsWith(".app")) {
    stem = stem.substring(0, stem.length - ".app".length);
  }
  if (stem.endsWith(".exe")) {
    stem = stem.substring(0, stem.length - ".exe".length);
  }
  return stem;
}
