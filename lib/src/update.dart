import "dart:async";
import "dart:io";

import "package:desktop_updater/desktop_updater.dart";
import "package:desktop_updater/src/download.dart";
import "package:path/path.dart" as path;
import "package:path_provider/path_provider.dart";

/// Modified updateAppFunction to return a stream of UpdateProgress.
/// The stream emits total kilobytes, received kilobytes, and the currently downloading file's name.
Future<Stream<UpdateProgress>> updateAppFunction({
  required String remoteUpdateFolder,
  required List<FileHashModel?> changes,
}) async {
  Directory dir;

  if (Platform.isMacOS) {
    // Get the Application Support directory
    final appSupportDir = await getApplicationSupportDirectory();
    // Create a subdirectory for our application
    dir = Directory(path.join(appSupportDir.path, "updates"));
    // Make sure the directory exists
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
  } else {
    // For other platforms maintain original behavior
    final executablePath = Platform.resolvedExecutable;
    final directoryPath = executablePath.substring(
      0,
      executablePath.lastIndexOf(Platform.pathSeparator),
    );
    dir = Directory(directoryPath);
  }

  final responseStream = StreamController<UpdateProgress>();

  try {
    if (await dir.exists()) {
      if (changes.isEmpty) {
        print("No updates required.");
        await responseStream.close();
        return responseStream.stream;
      }

      var receivedBytes = 0.0;
      final totalFiles = changes.length;
      var completedFiles = 0;

      // Calculate total length in KB
      final totalLengthKB = changes.fold<double>(
        0,
        (previousValue, element) =>
            previousValue + ((element?.length ?? 0) / 1024.0),
      );

      final changesFutureList = <Future<dynamic>>[];

      for (final file in changes) {
        if (file != null) {
          changesFutureList.add(
            downloadFile(
              remoteUpdateFolder,
              file.filePath,
              dir.path,
              (received, total) {
                receivedBytes += received;
                responseStream.add(
                  UpdateProgress(
                    totalBytes: totalLengthKB,
                    receivedBytes: receivedBytes,
                    currentFile: file.filePath,
                    totalFiles: totalFiles,
                    completedFiles: completedFiles,
                  ),
                );
              },
            ).then((_) {
              completedFiles += 1;

              responseStream.add(
                UpdateProgress(
                  totalBytes: totalLengthKB,
                  receivedBytes: receivedBytes,
                  currentFile: file.filePath,
                  totalFiles: totalFiles,
                  completedFiles: completedFiles,
                ),
              );
              print("Completed: ${file.filePath}");
            }).catchError((error) {
              responseStream.addError(error);
              return null;
            }),
          );
        }
      }

      unawaited(
        Future.wait(changesFutureList).then((_) async {
          await responseStream.close();
        }),
      );

      return responseStream.stream;
    }
  } catch (e) {
    responseStream.addError(e);
    await responseStream.close();
  }

  return responseStream.stream;
}
