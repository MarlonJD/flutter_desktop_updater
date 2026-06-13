import "dart:async";
import "dart:io";

import "package:desktop_updater/src/core/update_retry_policy.dart";
import "package:desktop_updater/src/io/update_transport.dart";
import "package:http/http.dart" as http;

class HttpUpdateTransport implements UpdateTransport {
  HttpUpdateTransport({
    http.Client? client,
    UpdateRetryPolicy retryPolicy = const UpdateRetryPolicy(),
    Future<void> Function(Duration duration) delay = _defaultDelay,
  })  : _client = client ?? http.Client(),
        _retryPolicy = retryPolicy,
        _delay = delay;

  final http.Client _client;
  final UpdateRetryPolicy _retryPolicy;
  final Future<void> Function(Duration duration) _delay;

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

    var attempt = 0;
    try {
      while (true) {
        attempt += 1;
        try {
          await _downloadOnce(
            source,
            partial,
            onProgress: onProgress,
            timeout: timeout,
          );
          break;
        } on _RetryableHttpStatusException catch (error) {
          if (!_canRetry(attempt)) {
            throw error.toHttpException(source);
          }
          if (await partial.exists()) {
            await partial.delete();
          }
          await _delay(_retryPolicy.delayForAttempt(attempt));
        } on TimeoutException {
          if (!_canRetry(attempt)) {
            rethrow;
          }
          if (await partial.exists()) {
            await partial.delete();
          }
          await _delay(_retryPolicy.delayForAttempt(attempt));
        } on SocketException {
          if (!_canRetry(attempt)) {
            rethrow;
          }
          if (await partial.exists()) {
            await partial.delete();
          }
          await _delay(_retryPolicy.delayForAttempt(attempt));
        } on http.ClientException {
          if (!_canRetry(attempt)) {
            rethrow;
          }
          if (await partial.exists()) {
            await partial.delete();
          }
          await _delay(_retryPolicy.delayForAttempt(attempt));
        }
      }

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

  Future<void> _downloadOnce(
    Uri source,
    File partial, {
    required void Function(int receivedBytes, int? totalBytes)? onProgress,
    required Duration? timeout,
  }) async {
    final request = http.Request("GET", source);
    final future = _client.send(request);
    final response =
        timeout == null ? await future : await future.timeout(timeout);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      await response.stream.drain<void>();
      if (_retryPolicy.shouldRetryStatusCode(response.statusCode)) {
        throw _RetryableHttpStatusException(response.statusCode);
      }
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
  }

  bool _canRetry(int attempt) {
    return attempt < _retryPolicy.maxAttempts;
  }

  void close() {
    _client.close();
  }
}

class _RetryableHttpStatusException implements Exception {
  const _RetryableHttpStatusException(this.statusCode);

  final int statusCode;

  HttpException toHttpException(Uri source) {
    return HttpException(
      "Failed to download $source: HTTP $statusCode",
      uri: source,
    );
  }
}

Future<void> _defaultDelay(Duration duration) {
  return Future<void>.delayed(duration);
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
