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

class DmgPackager {
  const DmgPackager({this.runProcess = defaultProcessRunner});

  final ProcessRunner runProcess;

  Future<ReleasePackageResult> package(
    ReleasePackageRequest request, {
    required MacOSDmgPublishConfig config,
    MacOSPublishConfig? publishConfig,
  }) async {
    await request.outputDirectory.create(recursive: true);
    final effectiveConfig = config.resolveDefaultsForAppName(request.appName);
    final artifact = File(
      path.join(
        request.outputDirectory.path,
        "${_artifactNameStem(request.appName)}-${request.version}-${request.platform}.dmg",
      ),
    );
    final dmgRoot =
        await Directory.systemTemp.createTemp("desktop_updater_dmg_");
    try {
      final stagedApp = path.join(dmgRoot.path, effectiveConfig.appBundleName);
      await _runChecked("/usr/bin/ditto", [request.input.path, stagedApp]);
      if (effectiveConfig.applicationsAlias) {
        await Link(path.join(dmgRoot.path, "Applications"))
            .create("/Applications");
      }
      if (await artifact.exists()) {
        await artifact.delete();
      }
      await _runChecked("/usr/bin/hdiutil", [
        "create",
        "-volname",
        effectiveConfig.volumeName,
        "-srcfolder",
        dmgRoot.path,
        "-ov",
        "-format",
        "UDZO",
        artifact.path,
      ]);
    } finally {
      if (await dmgRoot.exists()) {
        await dmgRoot.delete(recursive: true);
      }
    }

    if (!await artifact.exists()) {
      throw FileSystemException(
        "hdiutil did not produce a DMG artifact.",
        artifact.path,
      );
    }

    final verifyPrimarySignature = publishConfig?.notarize ?? false;
    if (publishConfig?.notarize ?? false) {
      final trust = AppleTrustCommands(runProcess: runProcess);
      await trust.codesignArtifact(
        artifact: artifact,
        identity: publishConfig!.developerIdApplication!,
      );
      await trust.submitForNotarization(
        archive: artifact,
        notaryProfile: publishConfig.notaryProfile!,
        keychain: publishConfig.keychain,
      );
      if (publishConfig.staple) {
        await trust.staple(artifact);
        await trust.validateStaple(artifact);
      }
      if (publishConfig.gatekeeperAssess) {
        await trust.assessDmg(artifact);
      }
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
        kind: "dmg",
        url: request.artifactUrl,
        sha256: await sha256File(artifact),
        length: await artifact.length(),
      ),
      install: ReleaseInstall(
        strategy: "wholeBundleReplace",
        macosDmg: ReleaseMacOSDmgInstall(
          appBundleName: effectiveConfig.appBundleName,
          verifyPrimarySignature: verifyPrimarySignature,
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
