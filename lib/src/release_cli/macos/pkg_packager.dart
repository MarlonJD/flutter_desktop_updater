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
import "package:pub_semver/pub_semver.dart";

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
    final buildNumber = request.buildNumber;
    if (buildNumber == null || buildNumber < 0) {
      throw const FormatException(
        "macOS PKG publishing requires an explicit integer build number.",
      );
    }
    await _validateInputApplication(request, buildNumber: buildNumber);
    final trust = AppleTrustCommands(runProcess: runProcess);
    await trust.verifyApp(request.input as Directory);
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
      if (!await artifact.exists()) {
        throw FileSystemException(
          "productbuild did not produce a PKG artifact.",
          artifact.path,
        );
      }
      final expanded = Directory(path.join(tempDir.path, "expanded"));
      await _runChecked("/usr/sbin/pkgutil", [
        "--expand-full",
        artifact.path,
        expanded.path,
      ]);
      final payloadApp = Directory(
        path.join(
          expanded.path,
          "component.pkg",
          "Payload",
          request.appName,
        ),
      );
      if (await FileSystemEntity.type(
            payloadApp.path,
            followLinks: false,
          ) !=
          FileSystemEntityType.directory) {
        throw FileSystemException(
          "Signed PKG does not contain the expected application payload directory.",
          payloadApp.path,
        );
      }
      await trust.verifyApp(payloadApp);
    } finally {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    }

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
          launchMode: "privilegedInstallerTool",
          expectedPackageIds: [config.packageIdentifier],
          relaunchAfterInstall: false,
        ),
      ),
      minimumUpdaterVersion: _pkgMinimumUpdaterVersion(
        request.minimumUpdaterVersion,
      ),
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

  Future<void> _validateInputApplication(
    ReleasePackageRequest request, {
    required int buildNumber,
  }) async {
    final inputName = path.basename(path.normalize(request.input.path));
    if (request.input is! Directory ||
        !inputName.endsWith(".app") ||
        request.appName != inputName ||
        path.basename(request.appName) != request.appName ||
        path.normalize(request.appName) != request.appName) {
      throw const FormatException(
        "macOS PKG appName must match the input application bundle name.",
      );
    }
    if (await FileSystemEntity.type(
          request.input.path,
          followLinks: false,
        ) !=
        FileSystemEntityType.directory) {
      throw FileSystemException(
        "macOS PKG source application must be a directory, not a symbolic link.",
        request.input.path,
      );
    }
    await _validateBundleModes(request.input as Directory);
    final infoFile = File(
      path.join(request.input.path, "Contents", "Info.plist"),
    );
    if (!await infoFile.exists()) {
      throw FileSystemException(
        "macOS PKG input is missing Contents/Info.plist.",
        infoFile.path,
      );
    }
    final result = await _runChecked("/usr/bin/plutil", [
      "-convert",
      "json",
      "-o",
      "-",
      infoFile.path,
    ]);
    final decoded = jsonDecode(result.stdout.toString());
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException("macOS PKG Info.plist is invalid.");
    }
    final executableName = decoded["CFBundleExecutable"]?.toString();
    if (decoded["CFBundleIdentifier"] != request.packageId ||
        decoded["CFBundleShortVersionString"] != request.version ||
        decoded["CFBundleVersion"]?.toString() != buildNumber.toString() ||
        executableName == null ||
        executableName.isEmpty ||
        executableName == "." ||
        executableName == ".." ||
        executableName.contains("/") ||
        executableName.contains("\\")) {
      throw const FormatException(
        "macOS PKG Info.plist identity must match release metadata.",
      );
    }
    final mainExecutable = File(
      path.join(
        request.input.path,
        "Contents",
        "MacOS",
        executableName,
      ),
    );
    final helper = File(
      path.join(
        request.input.path,
        "Contents",
        "Helpers",
        "DesktopUpdaterInstallHelper",
      ),
    );
    for (final executable in [mainExecutable, helper]) {
      if (await FileSystemEntity.type(executable.path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw FileSystemException(
          "macOS PKG input is missing a required executable.",
          executable.path,
        );
      }
      final stat = await executable.stat();
      if (stat.mode & 0x41 != 0x41 ||
          stat.mode & 0x12 != 0 ||
          stat.mode & 0xE00 != 0) {
        throw FileSystemException(
          "macOS PKG input executable has unsafe permissions.",
          executable.path,
        );
      }
    }
  }

  Future<void> _validateBundleModes(Directory bundle) async {
    Future<void> validate(FileSystemEntity entity) async {
      final type = await FileSystemEntity.type(
        entity.path,
        followLinks: false,
      );
      if (type == FileSystemEntityType.link) return;
      if (type != FileSystemEntityType.directory &&
          type != FileSystemEntityType.file) {
        throw FileSystemException(
          "macOS PKG input contains an unsupported filesystem node.",
          entity.path,
        );
      }
      final mode = (await entity.stat()).mode;
      final isDirectory = type == FileSystemEntityType.directory;
      final accessible = isDirectory
          ? mode & 0x5 == 0x5
          : mode & 0x4 == 0x4 && (mode & 0x49 == 0 || mode & 0x41 == 0x41);
      if (!accessible || mode & 0x12 != 0 || mode & 0xE00 != 0) {
        throw FileSystemException(
          "macOS PKG input contains unsafe or inaccessible permissions.",
          entity.path,
        );
      }
    }

    await validate(bundle);
    await for (final entity in bundle.list(
      recursive: true,
      followLinks: false,
    )) {
      await validate(entity);
    }
  }
}

String _pkgMinimumUpdaterVersion(String requested) {
  final requestedVersion = Version.parse(requested);
  final floor = Version(2, 7, 0);
  return requestedVersion < floor ? floor.toString() : requested;
}

String _artifactNameStem(String appName) {
  var stem = path.basename(appName);
  if (stem.endsWith(".app")) {
    stem = stem.substring(0, stem.length - ".app".length);
  }
  return stem;
}
