import "dart:convert";
import "dart:io";

import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:desktop_updater/src/macos_update.dart";
import "package:desktop_updater/src/package/release_packager.dart";
import "package:desktop_updater/src/release_cli/macos/apple_trust_commands.dart";
import "package:desktop_updater/src/release_cli/macos/macos_artifact_config.dart";
import "package:desktop_updater/src/release_cli/release_publish_config.dart";
import "package:desktop_updater/src/release_manifest.dart";
import "package:path/path.dart" as path;

class PkgPackager {
  const PkgPackager({this.runProcess = defaultProcessRunner});

  final ProcessRunner runProcess;

  Future<ReleasePackageResult> package(
    ReleasePackageRequest request, {
    required MacOSPkgPublishConfig config,
    MacOSPublishConfig? publishConfig,
  }) async {
    if (config.signingIdentifier == null ||
        config.signingIdentifier!.trim().isEmpty) {
      throw const FormatException(
        "macos.pkg.signingIdentifier is required to build a signed macOS PKG.",
      );
    }
    await request.outputDirectory.create(recursive: true);
    final artifact = File(
      path.join(
        request.outputDirectory.path,
        "${_artifactNameStem(request.appName)}-${request.version}-${request.platform}.pkg",
      ),
    );
    final tempDir =
        await Directory.systemTemp.createTemp("desktop_updater_pkg_");
    try {
      final pkgRoot = Directory(path.join(tempDir.path, "root"));
      await pkgRoot.create();
      await _runChecked("/usr/bin/ditto", [
        request.input.path,
        path.join(pkgRoot.path, path.basename(request.input.path)),
      ]);
      final componentPkg = File(path.join(tempDir.path, "component.pkg"));
      await _runChecked("/usr/bin/pkgbuild", [
        "--root",
        pkgRoot.path,
        "--install-location",
        config.installLocation,
        "--identifier",
        config.packageIdentifier,
        "--version",
        request.version,
        componentPkg.path,
      ]);
      if (await artifact.exists()) {
        await artifact.delete();
      }
      await _runChecked("/usr/bin/productbuild", [
        "--package",
        componentPkg.path,
        "--sign",
        config.signingIdentifier!,
        artifact.path,
      ]);
    } finally {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    }

    if (!await artifact.exists()) {
      throw FileSystemException(
        "productbuild did not produce a PKG artifact.",
        artifact.path,
      );
    }

    final trust = AppleTrustCommands(runProcess: runProcess);
    if (publishConfig?.notarize ?? false) {
      await trust.submitForNotarization(
        archive: artifact,
        notaryProfile: publishConfig!.notaryProfile!,
        keychain: publishConfig.keychain,
      );
      if (publishConfig.staple) {
        await trust.staple(artifact);
        await trust.validateStaple(artifact);
      }
    }
    await trust.checkPkgSignature(artifact);
    await trust.assessInstall(artifact);

    final descriptor = ReleaseDescriptor(
      schemaVersion: 3,
      packageId: request.packageId,
      appName: request.appName,
      version: request.version,
      buildNumber: request.buildNumber,
      platform: request.platform,
      channel: request.channel,
      artifact: ReleaseArtifact(
        kind: "pkgInstaller",
        url: request.artifactUrl,
        sha256: await sha256File(artifact),
        length: await artifact.length(),
      ),
      install: ReleaseInstall(
        strategy: "pkgInstaller",
        macosPkg: ReleaseMacOSPkgInstall(
          launchMode: "installerApp",
          expectedPackageIds: [config.packageIdentifier],
          relaunchAfterInstall: false,
        ),
      ),
      minimumUpdaterVersion: request.minimumUpdaterVersion,
      generatedAt: DateTime.now().toUtc(),
    );
    final releaseFile =
        File(path.join(request.outputDirectory.path, "release.json"));
    await releaseFile.writeAsString(
      const JsonEncoder.withIndent("  ").convert(descriptor.toJson()),
    );
    return ReleasePackageResult(
      artifact: artifact,
      releaseFile: releaseFile,
      descriptor: descriptor,
    );
  }

  Future<ProcessResult> _runChecked(
    String executable,
    List<String> arguments,
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
}

String _artifactNameStem(String appName) {
  var stem = path.basename(appName);
  if (stem.endsWith(".app")) {
    stem = stem.substring(0, stem.length - ".app".length);
  }
  return stem;
}
