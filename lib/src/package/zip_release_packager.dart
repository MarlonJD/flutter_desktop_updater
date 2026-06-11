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
        "${request.appName}-${request.version}-${request.platform}.zip",
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
    if (input is Directory) {
      await encoder.zipDirectory(
        input,
        filename: artifact.path,
        followLinks: false,
      );
    } else if (input is File) {
      encoder.create(artifact.path);
      await encoder.addFile(input);
      await encoder.close();
    } else {
      throw FileSystemException("Package input does not exist", input.path);
    }
  }
}
