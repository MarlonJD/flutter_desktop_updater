import "dart:convert";
import "dart:io";

import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:desktop_updater/src/package/release_packager.dart";
import "package:desktop_updater/src/release_cli/inno/inno_compiler.dart";
import "package:desktop_updater/src/release_cli/inno/inno_output_name.dart";
import "package:desktop_updater/src/release_cli/inno/inno_publish_config.dart";
import "package:desktop_updater/src/release_cli/inno/inno_script_builder.dart";
import "package:desktop_updater/src/release_cli/platform_release_profile.dart";
import "package:desktop_updater/src/release_cli/project_metadata_resolver.dart";
import "package:desktop_updater/src/release_manifest.dart";
import "package:path/path.dart" as path;

typedef CompileInnoForTest = Future<void> Function({
  required File scriptFile,
  required File outputExe,
});

class InnoInstallerPackager {
  const InnoInstallerPackager({
    this.compiler = const InnoCompiler(),
    this.scriptBuilder = const InnoScriptBuilder(),
    this.compileInno,
  });

  final InnoCompiler compiler;
  final InnoScriptBuilder scriptBuilder;
  final CompileInnoForTest? compileInno;

  Future<ReleasePackageResult> package(
    ReleasePackageRequest request, {
    required InnoPublishConfig config,
    String? outputBaseName,
  }) async {
    await request.outputDirectory.create(recursive: true);
    final resolvedOutputBaseName = outputBaseName ??
        await resolveInnoOutputBaseName(
          config: config,
          appName: request.appName,
          version: request.version,
          platform: request.platform,
        );
    final outputExe = File(
      path.join(request.outputDirectory.path, "$resolvedOutputBaseName.exe"),
    );
    final scriptFile = File(
      path.join(request.outputDirectory.path, "$resolvedOutputBaseName.iss"),
    );

    if (config.mode == "script") {
      await File(config.script!).copy(scriptFile.path);
    } else {
      final metadata = ProjectMetadata(
        version: request.version,
        buildNumber: request.buildNumber,
        appName: request.appName,
        packageId: request.packageId,
        platform: request.platform,
        profile: PlatformReleaseProfile.forPlatform(request.platform),
        input: request.input,
      );
      await scriptFile.writeAsString(
        scriptBuilder.build(
          metadata: metadata,
          config: config,
          outputDirectoryPath: request.outputDirectory.path,
          outputBaseName: resolvedOutputBaseName,
        ),
      );
    }

    final fakeCompiler = compileInno;
    if (fakeCompiler == null) {
      await compiler.compile(scriptFile: scriptFile, isccPath: config.isccPath);
    } else {
      await fakeCompiler(scriptFile: scriptFile, outputExe: outputExe);
    }

    if (!await outputExe.exists()) {
      throw FileSystemException(
        "Inno compiler did not produce installer.",
        outputExe.path,
      );
    }

    final descriptor = ReleaseDescriptor(
      schemaVersion: 3,
      packageId: request.packageId,
      appName: request.appName,
      version: request.version,
      buildNumber: request.buildNumber,
      platform: request.platform,
      channel: request.channel,
      artifact: ReleaseArtifact(
        kind: "innoInstaller",
        url: request.artifactUrl,
        sha256: await sha256File(outputExe),
        length: await outputExe.length(),
      ),
      install: ReleaseInstall(
        strategy: "innoInstaller",
        inno: ReleaseInnoInstall(
          silentArgs: config.silentArgs,
          inheritInstallDirectory: true,
          logFileName: "desktop_updater_inno_install.log",
          relaunchAfterInstall: true,
          requiresElevation: config.requiresElevation,
          authenticode: ReleaseAuthenticodePolicy(
            required: config.authenticodeThumbprints.isNotEmpty,
            sha256Thumbprints: config.authenticodeThumbprints,
          ),
        ),
      ),
      minimumUpdaterVersion: request.minimumUpdaterVersion,
      generatedAt: DateTime.now().toUtc(),
    );

    final releaseFile = File(
      path.join(request.outputDirectory.path, "release.json"),
    );
    await releaseFile.writeAsString(
      const JsonEncoder.withIndent("  ").convert(descriptor.toJson()),
    );

    return ReleasePackageResult(
      artifact: outputExe,
      releaseFile: releaseFile,
      descriptor: descriptor,
    );
  }
}
