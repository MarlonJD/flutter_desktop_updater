import "dart:async";
import "dart:io";

import "package:desktop_updater/src/io/update_transport.dart";
import "package:http/http.dart" as http;

class HttpUpdateTransport implements UpdateTransport {
  HttpUpdateTransport({http.Client? client})
      : _client = client ?? http.Client();

  final http.Client _client;

  @override
  Future<void> download(
    Uri source,
    File destination, {
    void Function(int receivedBytes, int? totalBytes)? onProgress,
    Duration? timeout,
  }) async {
    if (source.scheme != "http" && source.scheme != "https") {
      throw UnsupportedError("HTTP transport cannot fetch ${source.scheme}.");
    }

    await destination.parent.create(recursive: true);
    final partial = File("${destination.path}.part");
    if (await partial.exists()) {
      await partial.delete();
    }

    try {
      final request = http.Request("GET", source);
      final future = _client.send(request);
      final response =
          timeout == null ? await future : await future.timeout(timeout);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException(
          "Failed to download $source: HTTP ${response.statusCode}",
          uri: source,
        );
      }

      await _writeStream(
        response.stream,
        partial,
        totalBytes: response.contentLength,
        onProgress: onProgress,
      );

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

  void close() {
    _client.close();
  }
}

Future<void> _writeStream(
  Stream<List<int>> stream,
  File destination, {
  required int? totalBytes,
  void Function(int receivedBytes, int? totalBytes)? onProgress,
}) async {
  final sink = destination.openWrite();
  var receivedBytes = 0;

  try {
    await for (final chunk in stream) {
      receivedBytes += chunk.length;
      sink.add(chunk);
      onProgress?.call(receivedBytes, totalBytes);
    }
  } finally {
    await sink.close();
  }
}
