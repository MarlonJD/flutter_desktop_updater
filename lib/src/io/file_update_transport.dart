import "dart:async";
import "dart:io";

import "package:desktop_updater/src/io/update_transport.dart";

class FileUpdateTransport implements UpdateTransport {
  const FileUpdateTransport();

  @override
  Future<void> download(
    Uri source,
    File destination, {
    void Function(int receivedBytes, int? totalBytes)? onProgress,
    Duration? timeout,
  }) async {
    if (source.scheme != "file") {
      throw UnsupportedError("File transport cannot fetch ${source.scheme}.");
    }

    final sourceFile = File(source.toFilePath(windows: Platform.isWindows));
    if (!await sourceFile.exists()) {
      throw FileSystemException("Update file not found", sourceFile.path);
    }

    await destination.parent.create(recursive: true);
    final partial = File("${destination.path}.part");
    if (await partial.exists()) {
      await partial.delete();
    }

    try {
      await _copy(
        sourceFile,
        partial,
        onProgress: onProgress,
      ).timeout(timeout ?? const Duration(days: 365));

      if (await destination.exists()) {
        await destination.delete();
      }
      await partial.rename(destination.path);
    } catch (_) {
      if (await partial.exists()) {
        await partial.delete();
      }
      rethrow;
    }
  }
}

Future<void> _copy(
  File source,
  File destination, {
  void Function(int receivedBytes, int? totalBytes)? onProgress,
}) async {
  final totalBytes = await source.length();
  final sink = destination.openWrite();
  var receivedBytes = 0;

  try {
    await for (final chunk in source.openRead()) {
      receivedBytes += chunk.length;
      sink.add(chunk);
      onProgress?.call(receivedBytes, totalBytes);
    }
  } finally {
    await sink.close();
  }
}
