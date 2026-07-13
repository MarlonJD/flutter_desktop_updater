import "dart:io";

import "package:desktop_updater/src/io/file_update_transport.dart";
import "package:desktop_updater/src/io/http_update_transport.dart";
import "package:desktop_updater/src/io/update_transport.dart";

/// Routes HTTP and file update URLs to their built-in transports.
class CompositeUpdateTransport implements BoundedUpdateTransport {
  /// Creates a composite update transport.
  CompositeUpdateTransport({
    HttpUpdateTransport? httpTransport,
    UpdateRequestHeadersProvider? requestHeadersProvider,
    FileUpdateTransport fileTransport = const FileUpdateTransport(),
  })  : _httpTransport = httpTransport ??
            HttpUpdateTransport(requestHeadersProvider: requestHeadersProvider),
        _fileTransport = fileTransport;

  final HttpUpdateTransport _httpTransport;
  final FileUpdateTransport _fileTransport;

  @override
  Future<void> download(
    Uri source,
    File destination, {
    void Function(int receivedBytes, int? totalBytes)? onProgress,
    Duration? timeout,
  }) {
    if (source.scheme == "http" || source.scheme == "https") {
      return _httpTransport.download(
        source,
        destination,
        onProgress: onProgress,
        timeout: timeout,
      );
    }
    if (source.scheme == "file") {
      return _fileTransport.download(
        source,
        destination,
        onProgress: onProgress,
        timeout: timeout,
      );
    }
    throw UnsupportedError("Unsupported update URL scheme: ${source.scheme}");
  }

  @override
  Future<void> downloadBounded(
    Uri source,
    File destination, {
    required int maximumBytes,
    void Function(int receivedBytes, int? totalBytes)? onProgress,
    Duration? timeout,
  }) {
    if (source.scheme == "http" || source.scheme == "https") {
      return _httpTransport.downloadBounded(
        source,
        destination,
        maximumBytes: maximumBytes,
        onProgress: onProgress,
        timeout: timeout,
      );
    }
    if (source.scheme == "file") {
      return _fileTransport.downloadBounded(
        source,
        destination,
        maximumBytes: maximumBytes,
        onProgress: onProgress,
        timeout: timeout,
      );
    }
    throw UnsupportedError("Unsupported update URL scheme: ${source.scheme}");
  }

  /// Closes the owned HTTP transport.
  void close() {
    _httpTransport.close();
  }
}
