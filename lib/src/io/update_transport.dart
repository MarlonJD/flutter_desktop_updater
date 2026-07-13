import "dart:io";

/// Maximum size accepted for stable app archive and release metadata.
const int maximumStableMetadataBytes = 4 * 1024 * 1024;

/// Downloads update metadata and artifacts to local files.
abstract interface class UpdateTransport {
  /// Downloads [source] to [destination].
  Future<void> download(
    Uri source,
    File destination, {
    void Function(int receivedBytes, int? totalBytes)? onProgress,
    Duration? timeout,
  });
}

/// Optional capability for transports that can enforce a byte limit in flight.
///
/// This is separate from [UpdateTransport] so existing custom transports remain
/// source compatible.
abstract interface class BoundedUpdateTransport implements UpdateTransport {
  /// Downloads [source] while rejecting content above [maximumBytes].
  Future<void> downloadBounded(
    Uri source,
    File destination, {
    required int maximumBytes,
    void Function(int receivedBytes, int? totalBytes)? onProgress,
    Duration? timeout,
  });
}

/// A deterministic download failure caused by a configured byte limit.
class UpdateDownloadSizeLimitException implements Exception {
  /// Creates a size-limit failure for one update resource.
  const UpdateDownloadSizeLimitException({
    required this.source,
    required this.maximumBytes,
    required this.actualBytes,
  });

  /// Resource that exceeded the configured limit.
  final Uri source;

  /// Largest permitted byte count.
  final int maximumBytes;

  /// Declared or observed byte count that exceeded the limit.
  final int actualBytes;

  @override
  String toString() {
    return "Update download from $source exceeds the $maximumBytes-byte "
        "limit ($actualBytes bytes).";
  }
}
