import "dart:async";
import "dart:io";

import "package:desktop_updater/src/app_archive.dart";
import "package:desktop_updater/src/download.dart";
import "package:desktop_updater/src/update_progress.dart";

Future<Stream<UpdateProgress>> updateAppFunction({
  required String remoteUpdateFolder,
  required List<FileHashModel?> changes,
}) async {
  final files = changes.whereType<FileHashModel>().toList(growable: false);
  final stagingDirectory = await Directory.systemTemp.createTemp(
    "desktop_updater_stage_",
  );

  late StreamController<UpdateProgress> controller;

  controller = StreamController<UpdateProgress>(
    onListen: () {
      unawaited(
        _downloadChangedFiles(
          controller: controller,
          remoteUpdateFolder: remoteUpdateFolder,
          files: files,
          stagingDirectory: stagingDirectory,
        ),
      );
    },
  );

  return controller.stream;
}

Future<void> _downloadChangedFiles({
  required StreamController<UpdateProgress> controller,
  required String remoteUpdateFolder,
  required List<FileHashModel> files,
  required Directory stagingDirectory,
}) async {
  final totalBytes = files.fold<int>(
    0,
    (previousValue, element) => previousValue + element.length,
  );

  var completedFiles = 0;
  var completedBytes = 0;

  try {
    if (files.isEmpty) {
      controller.add(
        UpdateProgress(
          totalBytes: 0,
          receivedBytes: 0,
          currentFile: "",
          totalFiles: 0,
          completedFiles: 0,
          stagingDirectory: stagingDirectory.path,
        ),
      );
      return;
    }

    for (final fileHash in files) {
      var currentFileBytes = 0;

      await downloadFile(
        remoteUpdateFolder: remoteUpdateFolder,
        fileHash: fileHash,
        stagingDirectory: stagingDirectory,
        onProgress: (receivedBytes, _) {
          currentFileBytes = receivedBytes;
          controller.add(
            UpdateProgress(
              totalBytes: totalBytes.toDouble(),
              receivedBytes: (completedBytes + currentFileBytes).toDouble(),
              currentFile: fileHash.filePath,
              totalFiles: files.length,
              completedFiles: completedFiles,
              stagingDirectory: stagingDirectory.path,
            ),
          );
        },
      );

      completedFiles += 1;
      completedBytes +=
          fileHash.length > 0 ? fileHash.length : currentFileBytes;
      controller.add(
        UpdateProgress(
          totalBytes: totalBytes.toDouble(),
          receivedBytes: completedBytes.toDouble(),
          currentFile: fileHash.filePath,
          totalFiles: files.length,
          completedFiles: completedFiles,
          stagingDirectory: stagingDirectory.path,
        ),
      );
    }
  } catch (error, stackTrace) {
    if (await stagingDirectory.exists()) {
      await stagingDirectory.delete(recursive: true);
    }
    controller.addError(error, stackTrace);
  } finally {
    await controller.close();
  }
}
