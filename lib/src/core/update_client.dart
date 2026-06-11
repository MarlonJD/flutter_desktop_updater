import "dart:convert";
import "dart:io";

import "package:desktop_updater/src/core/artifact_verifier.dart";
import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:desktop_updater/src/core/release_index.dart";
import "package:desktop_updater/src/core/safe_zip_extractor.dart";
import "package:desktop_updater/src/io/composite_update_transport.dart";
import "package:desktop_updater/src/io/update_transport.dart";
import "package:desktop_updater/src/macos_update.dart";
import "package:desktop_updater/src/version_info.dart";
import "package:path/path.dart" as path;

class UpdateClient {
  UpdateClient({
    required this.appArchiveUrl,
    required this.currentVersion,
    String? platform,
    this.channel = "stable",
    UpdateTransport? transport,
    ArtifactVerifier verifier = const ArtifactVerifier(),
    SafeZipExtractor extractor = const SafeZipExtractor(),
    Directory? stagingParent,
    ProcessRunner runProcess = defaultProcessRunner,
  })  : platform = platform ?? Platform.operatingSystem,
        _transport = transport ?? CompositeUpdateTransport(),
        _verifier = verifier,
        _extractor = extractor,
        _stagingParent = stagingParent,
        _runProcess = runProcess;

  final Uri appArchiveUrl;
  final DesktopVersionInfo currentVersion;
  final String platform;
  final String channel;
  final UpdateTransport _transport;
  final ArtifactVerifier _verifier;
  final SafeZipExtractor _extractor;
  final Directory? _stagingParent;
  final ProcessRunner _runProcess;

  Future<UpdateCheckResult?> checkForUpdate() async {
    final tempDir = await Directory.systemTemp.createTemp(
      "desktop_updater_index_",
    );

    try {
      final indexFile = File(path.join(tempDir.path, "app-archive.json"));
      await _transport.download(appArchiveUrl, indexFile);
      final index = ReleaseIndex.fromJson(
        jsonDecode(await indexFile.readAsString()) as Map<String, dynamic>,
      );
      if (index.schemaVersion != 3) {
        throw const LegacyReleaseIndexException();
      }

      final item = selectReleaseIndexItem(
        index: index,
        platform: platform,
        currentVersion: currentVersion,
        channel: channel,
      );
      if (item == null) {
        return null;
      }

      final descriptorFile = File(path.join(tempDir.path, "release.json"));
      await _transport.download(item.release, descriptorFile);
      final descriptor = ReleaseDescriptor.fromJson(
        jsonDecode(await descriptorFile.readAsString()) as Map<String, dynamic>,
      );
      await _verifier.verifyDescriptor(descriptor);

      if (descriptor.platform != platform || descriptor.channel != channel) {
        return null;
      }

      return UpdateCheckResult(
        index: index,
        item: item,
        descriptor: descriptor,
      );
    } finally {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    }
  }

  Future<UpdateStageResult> downloadVerifyAndStage({
    required ReleaseDescriptor descriptor,
    void Function(int receivedBytes, int? totalBytes)? onProgress,
  }) async {
    await _verifier.verifyDescriptor(descriptor);

    final stagingRoot = await (_stagingParent ?? Directory.systemTemp)
        .createTemp("desktop_updater_stage_");
    final artifactFile = File(path.join(stagingRoot.path, "artifact.zip"));

    try {
      await _transport.download(
        descriptor.artifact.url,
        artifactFile,
        onProgress: onProgress,
      );
      await _verifier.verifyArtifactFile(
        artifact: descriptor.artifact,
        file: artifactFile,
      );

      if (descriptor.platform == "macos") {
        await runDittoExtractZip(
          archivePath: artifactFile.path,
          destination: stagingRoot.path,
          runProcess: _runProcess,
        );
      } else {
        await _extractor.extract(
          archiveFile: artifactFile,
          destination: stagingRoot,
          platform: descriptor.platform,
        );
      }

      final stagedPath = descriptor.platform == "macos"
          ? path.join(stagingRoot.path, descriptor.appName)
          : stagingRoot.path;
      return UpdateStageResult(
        descriptor: descriptor,
        stagingPath: stagedPath,
      );
    } catch (_) {
      if (await stagingRoot.exists()) {
        await stagingRoot.delete(recursive: true);
      }
      rethrow;
    }
  }
}

class LegacyReleaseIndexException implements Exception {
  const LegacyReleaseIndexException();

  @override
  String toString() {
    return "Legacy release index does not use schemaVersion 3.";
  }
}

class UpdateCheckResult {
  const UpdateCheckResult({
    required this.index,
    required this.item,
    required this.descriptor,
  });

  final ReleaseIndex index;
  final ReleaseIndexItem item;
  final ReleaseDescriptor descriptor;
}

class UpdateStageResult {
  const UpdateStageResult({
    required this.descriptor,
    required this.stagingPath,
  });

  final ReleaseDescriptor descriptor;
  final String stagingPath;
}
