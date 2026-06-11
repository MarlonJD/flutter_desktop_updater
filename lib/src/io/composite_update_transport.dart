import "dart:io";

import "package:desktop_updater/src/io/file_update_transport.dart";
import "package:desktop_updater/src/io/http_update_transport.dart";
import "package:desktop_updater/src/io/update_transport.dart";

class CompositeUpdateTransport implements UpdateTransport {
  CompositeUpdateTransport({
    HttpUpdateTransport? httpTransport,
    FileUpdateTransport fileTransport = const FileUpdateTransport(),
  })  : _httpTransport = httpTransport ?? HttpUpdateTransport(),
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

  void close() {
    _httpTransport.close();
  }
}
