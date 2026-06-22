import "dart:io";

import "package:archive/archive_io.dart";
import "package:desktop_updater/src/io/archive_path.dart";
import "package:path/path.dart" as path;

const _unixExecuteMask = 0x49; // Octal 0111.

/// Extracts zip artifacts while rejecting unsafe paths and symlinks.
class SafeZipExtractor {
  /// Creates a safe zip extractor.
  const SafeZipExtractor();

  /// Extracts [archiveFile] into [destination].
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
    final filePermissions = <int, List<String>>{};
    final directoryPermissions = <String, int>{};

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
        _recordDirectoryPermissions(
          directoryPermissions,
          destinationPath,
          entry.unixPermissions,
        );
        continue;
      }

      await Directory(path.dirname(destinationPath)).create(recursive: true);
      await File(destinationPath).writeAsBytes(entry.content as List<int>);
      _recordFilePermissions(
        filePermissions,
        destinationPath,
        entry.unixPermissions,
      );
    }

    await _applyUnixPermissions(filePermissions, targetPlatform);

    final directories = directoryPermissions.entries.toList()
      ..sort((a, b) => b.key.length.compareTo(a.key.length));
    for (final directory in directories) {
      await _applyUnixPermissions(
        {
          directory.value: [directory.key],
        },
        targetPlatform,
      );
    }
  }
}

void _recordFilePermissions(
  Map<int, List<String>> permissionsByMode,
  String filePath,
  int permissions,
) {
  if (permissions == 0) {
    return;
  }
  permissionsByMode.putIfAbsent(permissions, () => <String>[]).add(filePath);
}

void _recordDirectoryPermissions(
  Map<String, int> directoryPermissions,
  String directoryPath,
  int permissions,
) {
  if (permissions == 0 || (permissions & _unixExecuteMask) == 0) {
    return;
  }
  directoryPermissions[directoryPath] = permissions;
}

Future<void> _applyUnixPermissions(
  Map<int, List<String>> permissionsByMode,
  String targetPlatform,
) async {
  if (permissionsByMode.isEmpty ||
      targetPlatform == "windows" ||
      Platform.isWindows) {
    return;
  }

  for (final entry in permissionsByMode.entries) {
    final mode = entry.key.toRadixString(8).padLeft(3, "0");
    for (final paths in _chunks(entry.value, 200)) {
      final result = await Process.run("chmod", [mode, ...paths]);
      if (result.exitCode != 0) {
        throw FileSystemException(
          "Unable to apply zip entry permissions: chmod $mode "
          "${result.stderr}",
          paths.first,
        );
      }
    }
  }
}

Iterable<List<T>> _chunks<T>(List<T> values, int size) sync* {
  for (var start = 0; start < values.length; start += size) {
    final end = start + size > values.length ? values.length : start + size;
    yield values.sublist(start, end);
  }
}
