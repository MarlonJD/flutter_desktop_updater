import "dart:io";

import "package:archive/archive_io.dart";
import "package:desktop_updater/src/io/archive_path.dart";
import "package:path/path.dart" as path;

class SafeZipExtractor {
  const SafeZipExtractor();

  Future<void> extract({
    required File archiveFile,
    required Directory destination,
    String platform = "",
    bool rejectSymlinks = true,
    bool requireDittoForMacOS = true,
  }) async {
    final targetPlatform =
        platform.isEmpty ? Platform.operatingSystem : platform;
    if (targetPlatform == "macos" && requireDittoForMacOS) {
      throw UnsupportedError(
        "macOS app zips must be extracted with /usr/bin/ditto.",
      );
    }

    await destination.create(recursive: true);
    final root = path.normalize(path.absolute(destination.path));
    final archive = ZipDecoder().decodeBytes(await archiveFile.readAsBytes());

    for (final entry in archive.files) {
      final relativePath = normalizeArchivePath(entry.name);
      if (relativePath.isEmpty) {
        continue;
      }
      if (entry.isSymbolicLink && rejectSymlinks) {
        throw FormatException("Zip entry is a symbolic link: ${entry.name}");
      }

      final destinationPath = path.normalize(path.join(root, relativePath));
      if (destinationPath != root && !path.isWithin(root, destinationPath)) {
        throw FormatException("Zip entry escapes staging root: ${entry.name}");
      }

      if (entry.isDirectory) {
        await Directory(destinationPath).create(recursive: true);
        continue;
      }

      await Directory(path.dirname(destinationPath)).create(recursive: true);
      await File(destinationPath).writeAsBytes(entry.content as List<int>);
    }
  }
}
