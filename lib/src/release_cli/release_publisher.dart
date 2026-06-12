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

class ReleasePublisher {
  const ReleasePublisher({
    this.skipBuild = false,
    this.packager = const ZipReleasePackager(),
    this.metadataResolver = const ProjectMetadataResolver(),
    this.runProcess = defaultProcessRunner,
  });

  final bool skipBuild;
  final ReleasePackager packager;
  final ProjectMetadataResolver metadataResolver;
  final ProcessRunner runProcess;

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

    if (!skipBuild) {
      await _build(projectRoot, metadata, output);
    }

    if (platform == "macos" && config.macos.notarize) {
      await _notarizeMacOS(
        app: metadata.input,
        config: config.macos,
        runProcess: runProcess,
        output: output,
      );
    }

    output.writeln("Packaging update...");
    final layout = PublishLayout.create(
      outputDirectory: config.outputDirectory,
      baseUrl: config.baseUrl,
      version: metadata.version,
      platform: platform,
      appName: metadata.appName,
    );
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
        mandatory: false,
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
  await _runChecked(
    "/usr/bin/codesign",
    [
      "--force",
      "--options",
      "runtime",
      "--timestamp",
      "--sign",
      config.developerIdApplication!,
      app.path,
    ],
    runProcess,
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
    await _runChecked(
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
      ],
      runProcess,
    );
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

Future<void> _build(
  Directory projectRoot,
  ProjectMetadata metadata,
  StringSink output,
) async {
  output.writeln("Building ${metadata.platform} release...");
  final result = await Process.run(
    "flutter",
    metadata.profile.flutterBuildArgs,
    workingDirectory: projectRoot.path,
  );
  if (result.exitCode != 0) {
    throw ProcessException(
      "flutter",
      metadata.profile.flutterBuildArgs,
      "${result.stdout}\n${result.stderr}",
      result.exitCode,
    );
  }
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
