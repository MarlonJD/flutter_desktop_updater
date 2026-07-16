import "dart:io";
import "dart:typed_data";

import "package:archive/archive_io.dart";
import "package:desktop_updater/src/core/zip_archive_preflight.dart";
import "package:desktop_updater/src/io/archive_path.dart";
import "package:path/path.dart" as path;

const _unixExecuteMask = 0x49; // Octal 0111.
const _reservedUpdaterControlPlaneRoots = {
  ".desktop_updater_artifact.zip",
  ".desktop_updater_release_manifest.json",
  ".desktop_updater_stage_provenance.json",
};

/// Extracts zip artifacts while rejecting unsafe paths and symlinks.
class SafeZipExtractor {
  /// Creates a safe zip extractor.
  const SafeZipExtractor({
    this.maximumArchiveEntries = 100000,
    this.maximumUncompressedBytes = 8 * 1024 * 1024 * 1024,
    this.maximumSingleEntryBytes = 4 * 1024 * 1024 * 1024,
  })  : assert(
          maximumArchiveEntries >= 0,
          "maximumArchiveEntries must not be negative.",
        ),
        assert(
          maximumUncompressedBytes >= 0,
          "maximumUncompressedBytes must not be negative.",
        ),
        assert(
          maximumSingleEntryBytes >= 0,
          "maximumSingleEntryBytes must not be negative.",
        );

  /// Maximum number of entries accepted from one ZIP.
  final int maximumArchiveEntries;

  /// Maximum cumulative declared and decoded uncompressed byte count.
  final int maximumUncompressedBytes;

  /// Maximum declared and decoded byte count for one entry.
  final int maximumSingleEntryBytes;

  /// Checks archive metadata without decompressing or writing entries.
  Future<void> preflight(
    File archiveFile, {
    bool rejectSymlinks = false,
  }) {
    return preflightZipArchive(
      archiveFile: archiveFile,
      maximumArchiveEntries: maximumArchiveEntries,
      maximumUncompressedBytes: maximumUncompressedBytes,
      maximumSingleEntryBytes: maximumSingleEntryBytes,
      rejectSymlinks: rejectSymlinks,
    );
  }

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

    await preflight(archiveFile, rejectSymlinks: rejectSymlinks);
    final input = InputFileStream(archiveFile.path);
    try {
      final archive = ZipDecoder().decodeStream(input);
      _validateDecodedArchive(
        archive,
        destination: destination,
        rejectSymlinks: rejectSymlinks,
        maximumArchiveEntries: maximumArchiveEntries,
        maximumUncompressedBytes: maximumUncompressedBytes,
        maximumSingleEntryBytes: maximumSingleEntryBytes,
      );

      await destination.parent.create(recursive: true);
      final scratch = await destination.parent.createTemp(
        ".desktop_updater_extract_",
      );
      final root = path.normalize(path.absolute(scratch.path));
      final filePermissions = <int, List<String>>{};
      final directoryPermissions = <String, int>{};
      var decodedUncompressedBytes = 0;

      try {
        for (final entry in archive.files) {
          final relativePath = normalizeArchivePath(entry.name);
          if (relativePath.isEmpty) {
            continue;
          }
          final destinationPath = path.normalize(path.join(root, relativePath));

          if (entry.isDirectory) {
            await Directory(destinationPath).create(recursive: true);
            _recordDirectoryPermissions(
              directoryPermissions,
              destinationPath,
              entry.unixPermissions,
            );
            continue;
          }

          await Directory(path.dirname(destinationPath))
              .create(recursive: true);
          final output = OutputFileStream(destinationPath);
          final remainingTotal =
              maximumUncompressedBytes - decodedUncompressedBytes;
          final maximumEntryOutput = remainingTotal < maximumSingleEntryBytes
              ? remainingTotal
              : maximumSingleEntryBytes;
          final limited = _LimitedOutputStream(output, maximumEntryOutput);
          try {
            entry.writeContent(limited);
          } finally {
            limited.closeSync();
          }
          if (limited.length != entry.size) {
            throw FormatException(
              "ZIP entry decoded size differs from metadata: ${entry.name}",
            );
          }
          decodedUncompressedBytes += limited.length;
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
        await destination.create(recursive: true);
        await _mergeDirectory(scratch, destination);
      } finally {
        if (await scratch.exists()) {
          await scratch.delete(recursive: true);
        }
      }
    } finally {
      input.closeSync();
    }
  }
}

void _validateDecodedArchive(
  Archive archive, {
  required Directory destination,
  required bool rejectSymlinks,
  required int maximumArchiveEntries,
  required int maximumUncompressedBytes,
  required int maximumSingleEntryBytes,
}) {
  if (archive.files.length > maximumArchiveEntries) {
    throw FormatException(
      "ZIP contains ${archive.files.length} entries; limit is "
      "$maximumArchiveEntries.",
    );
  }
  final root = path.normalize(path.absolute(destination.path));
  var totalUncompressedBytes = 0;
  for (final entry in archive.files) {
    if (entry.size < 0 || entry.size > maximumSingleEntryBytes) {
      throw FormatException("ZIP entry is too large: ${entry.name}");
    }
    totalUncompressedBytes += entry.size;
    if (totalUncompressedBytes > maximumUncompressedBytes) {
      throw const FormatException(
        "ZIP cumulative uncompressed size is too large.",
      );
    }
    final relativePath = normalizeArchivePath(entry.name);
    if (relativePath.isEmpty) {
      continue;
    }
    if (!relativePath.contains("/") &&
        _reservedUpdaterControlPlaneRoots
            .contains(relativePath.toLowerCase())) {
      throw FormatException(
        "ZIP entry uses a reserved updater control-plane file: ${entry.name}",
      );
    }
    if (entry.isSymbolicLink && rejectSymlinks) {
      throw FormatException("ZIP entry is a symbolic link: ${entry.name}");
    }
    final destinationPath = path.normalize(path.join(root, relativePath));
    if (destinationPath != root && !path.isWithin(root, destinationPath)) {
      throw FormatException("ZIP entry escapes staging root: ${entry.name}");
    }
  }
}

Future<void> _mergeDirectory(Directory source, Directory destination) async {
  await for (final entity in source.list(followLinks: false)) {
    final targetPath = path.join(destination.path, path.basename(entity.path));
    if (entity is Directory) {
      final target = Directory(targetPath);
      final targetType = await FileSystemEntity.type(
        targetPath,
        followLinks: false,
      );
      if (targetType == FileSystemEntityType.notFound) {
        await entity.rename(targetPath);
      } else if (targetType == FileSystemEntityType.directory) {
        await _mergeDirectory(entity, target);
      } else {
        await File(targetPath).delete();
        await entity.rename(targetPath);
      }
    } else if (entity is File) {
      final target = File(targetPath);
      if (await target.exists()) {
        await target.delete();
      }
      await entity.rename(targetPath);
    } else {
      throw FormatException("Unsupported extracted ZIP entity: ${entity.path}");
    }
  }
}

class _LimitedOutputStream extends OutputStream {
  _LimitedOutputStream(this._output, this.maximumBytes)
      : super(byteOrder: _output.byteOrder);

  final OutputStream _output;
  final int maximumBytes;

  @override
  int get length => _output.length;

  @override
  bool get isOpen => _output.isOpen;

  void _check(int additionalBytes) {
    if (additionalBytes < 0 || length + additionalBytes > maximumBytes) {
      throw FormatException(
        "Decoded ZIP entry exceeds the $maximumBytes-byte limit.",
      );
    }
  }

  @override
  void writeByte(int value) {
    _check(1);
    _output.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    final byteCount = length ?? bytes.length;
    _check(byteCount);
    _output.writeBytes(bytes, length: byteCount);
  }

  @override
  void writeStream(InputStream stream) {
    _check(stream.length);
    _output.writeStream(stream);
  }

  @override
  void flush() => _output.flush();

  @override
  void clear() {
    _output.clear();
  }

  @override
  Future<void> close() => _output.close();

  @override
  void closeSync() => _output.closeSync();

  @override
  Uint8List subset(int start, [int? end]) => _output.subset(start, end);
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
