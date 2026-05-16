import "dart:io";

import "package:desktop_updater/src/app_archive.dart";
import "package:desktop_updater/src/file_hash.dart";
import "package:desktop_updater/src/remote_file.dart";
import "package:path/path.dart" as path;

Future<List<FileHashModel?>> prepareUpdateAppFunction({
  required String remoteUpdateFolder,
}) async {
  final tempDir = await Directory.systemTemp.createTemp("desktop_updater_");

  try {
    final newHashFile = File(path.join(tempDir.path, "hashes.json"));
    await downloadRemoteFileTo(
      base: remoteUpdateFolder,
      relativePath: "hashes.json",
      destination: newHashFile,
    );

    final oldHashFilePath = await genFileHashes();
    return verifyFileHashes(oldHashFilePath, newHashFile.path);
  } finally {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  }
}
