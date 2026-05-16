import "dart:io";

import "package:desktop_updater/src/app_archive.dart";
import "package:desktop_updater/src/file_hash.dart";
import "package:desktop_updater/src/remote_file.dart";

Future<File> downloadFile({
  required String remoteUpdateFolder,
  required FileHashModel fileHash,
  required Directory stagingDirectory,
  void Function(int receivedBytes, int? totalBytes)? onProgress,
}) async {
  final destination = File(
    localPathForArchivePath(stagingDirectory.path, fileHash.filePath),
  );

  await downloadRemoteFileTo(
    base: remoteUpdateFolder,
    relativePath: fileHash.filePath,
    destination: destination,
    onProgress: onProgress,
  );

  final actualLength = await destination.length();
  if (fileHash.length > 0 && actualLength != fileHash.length) {
    await destination.delete();
    throw FileSystemException(
      "Downloaded file length does not match hashes.json",
      destination.path,
    );
  }

  final actualHash = await getFileHash(destination);
  if (actualHash != fileHash.calculatedHash) {
    await destination.delete();
    throw FileSystemException(
      "Downloaded file hash does not match hashes.json",
      destination.path,
    );
  }

  return destination;
}
