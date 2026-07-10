import "dart:convert";
import "dart:io";

import "package:archive/archive_io.dart";
import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:desktop_updater/src/macos_update.dart";
import "package:desktop_updater/src/package/release_packager.dart";
import "package:desktop_updater/src/release_manifest.dart";
import "package:path/path.dart" as path;

class ZipReleasePackager implements ReleasePackager {
  const ZipReleasePackager({this.runProcess = defaultProcessRunner});

  final ProcessRunner runProcess;

  @override
  Future<ReleasePackageResult> package(ReleasePackageRequest request) async {
    await request.outputDirectory.create(recursive: true);

    final artifact = File(
      path.join(
        request.outputDirectory.path,
        "${_artifactNameStem(request.appName)}-${request.version}-${request.platform}.zip",
      ),
    );

    await _createZip(request, artifact);
    final descriptor = ReleaseDescriptor(
      schemaVersion: 3,
      packageId: request.packageId,
      appName: request.appName,
      version: request.version,
      buildNumber: request.buildNumber,
      platform: request.platform,
      channel: request.channel,
      artifact: ReleaseArtifact(
        kind: "zip",
        url: request.artifactUrl,
        sha256: await sha256File(artifact),
        length: await artifact.length(),
      ),
      install: ReleaseInstall(strategy: request.installStrategy),
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

  Future<void> _createZip(
    ReleasePackageRequest request,
    File artifact,
  ) async {
    final addsInstalledIdentity =
        request.platform == "windows" || request.platform == "linux";
    if (addsInstalledIdentity) {
      await _rejectReservedInstalledIdentityMarker(
        request.input,
        caseInsensitive: request.platform == "windows",
      );
    }
    if (await artifact.exists()) {
      await artifact.delete();
    }

    if (request.platform == "macos" && request.input is Directory) {
      await runDittoCreateZip(
        appPath: request.input.path,
        archivePath: artifact.path,
        runProcess: runProcess,
      );
      return;
    }

    final encoder = ZipFileEncoder();
    final input = request.input;
    if (input is! Directory && input is! File) {
      throw FileSystemException("Package input does not exist", input.path);
    }
    if (addsInstalledIdentity) {
      final marker = File("${artifact.path}.install_identity.tmp");
      try {
        await marker.writeAsString(
          jsonEncode(<String, Object?>{
            "packageId": request.packageId,
            "schemaVersion": 1,
          }),
          flush: true,
        );
        encoder.create(artifact.path);
        if (input is Directory) {
          await encoder.addDirectory(
            input,
            includeDirName: false,
            followLinks: false,
          );
        } else {
          await encoder.addFile(input as File);
        }
        await encoder.addFile(marker, _installedIdentityMarkerName);
        await encoder.close();
      } finally {
        if (await marker.exists()) {
          await marker.delete();
        }
      }
    } else if (input is Directory) {
      await encoder.zipDirectory(
        input,
        filename: artifact.path,
        followLinks: false,
      );
    } else {
      encoder.create(artifact.path);
      await encoder.addFile(input as File);
      await encoder.close();
    }
  }
}

const String _installedIdentityMarkerName =
    ".desktop_updater_install_identity.json";

Future<void> _rejectReservedInstalledIdentityMarker(
  FileSystemEntity input, {
  required bool caseInsensitive,
}) async {
  bool isReserved(String candidate) => caseInsensitive
      ? candidate.toLowerCase() == _installedIdentityMarkerName.toLowerCase()
      : candidate == _installedIdentityMarkerName;

  if (isReserved(path.basename(input.path))) {
    throw StateError(
      "Package input contains the reserved installed identity marker.",
    );
  }
  if (input is Directory) {
    await for (final entity in input.list(
      recursive: true,
      followLinks: false,
    )) {
      if (isReserved(path.basename(entity.path))) {
        throw StateError(
          "Package input contains the reserved installed identity marker.",
        );
      } else {
        continue;
      }
    }
  }
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
