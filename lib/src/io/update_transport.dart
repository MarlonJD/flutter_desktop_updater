import "dart:io";

abstract interface class UpdateTransport {
  Future<void> download(
    Uri source,
    File destination, {
    void Function(int receivedBytes, int? totalBytes)? onProgress,
    Duration? timeout,
  });
}
