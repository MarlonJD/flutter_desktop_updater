import "dart:async";
import "dart:io";

import "package:desktop_updater/src/io/update_transport.dart";

/// Copies update resources from local file URLs.
class FileUpdateTransport implements BoundedUpdateTransport {
  /// Creates a file update transport.
  const FileUpdateTransport();

  @override
  Future<void> download(
    Uri source,
    File destination, {
    void Function(int receivedBytes, int? totalBytes)? onProgress,
    Duration? timeout,
  }) {
    return _download(
      source,
      destination,
      onProgress: onProgress,
      timeout: timeout,
    );
  }

  @override
  Future<void> downloadBounded(
    Uri source,
    File destination, {
    required int maximumBytes,
    void Function(int receivedBytes, int? totalBytes)? onProgress,
    Duration? timeout,
  }) {
    if (maximumBytes < 0) {
      throw ArgumentError.value(maximumBytes, "maximumBytes");
    }
    return _download(
      source,
      destination,
      maximumBytes: maximumBytes,
      onProgress: onProgress,
      timeout: timeout,
    );
  }

  Future<void> _download(
    Uri source,
    File destination, {
    int? maximumBytes,
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

    final sourceBytes = await sourceFile.length();
    if (maximumBytes != null && sourceBytes > maximumBytes) {
      if (await destination.exists()) {
        await destination.delete();
      }
      final partial = File("${destination.path}.part");
      if (await partial.exists()) {
        await partial.delete();
      }
      throw UpdateDownloadSizeLimitException(
        source: source,
        maximumBytes: maximumBytes,
        actualBytes: sourceBytes,
      );
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
        sourceUri: source,
        maximumBytes: maximumBytes,
        onProgress: onProgress,
      ).timeout(timeout ?? const Duration(days: 365));

      if (await destination.exists()) {
        await destination.delete();
      }
      await partial.rename(destination.path);
    } catch (error) {
      if (await partial.exists()) {
        await partial.delete();
      }
      if (error is UpdateDownloadSizeLimitException &&
          await destination.exists()) {
        await destination.delete();
      }
      rethrow;
    }
  }
}

Future<void> _copy(
  File source,
  File destination, {
  required Uri sourceUri,
  required int? maximumBytes,
  void Function(int receivedBytes, int? totalBytes)? onProgress,
}) async {
  final totalBytes = await source.length();
  final sink = destination.openWrite();
  var receivedBytes = 0;

  try {
    await for (final chunk in source.openRead()) {
      final nextReceivedBytes = receivedBytes + chunk.length;
      if (maximumBytes != null && nextReceivedBytes > maximumBytes) {
        throw UpdateDownloadSizeLimitException(
          source: sourceUri,
          maximumBytes: maximumBytes,
          actualBytes: nextReceivedBytes,
        );
      }
      sink.add(chunk);
      receivedBytes = nextReceivedBytes;
      onProgress?.call(receivedBytes, totalBytes);
    }
  } finally {
    await sink.close();
  }
}
