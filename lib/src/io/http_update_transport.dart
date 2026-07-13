import "dart:async";
import "dart:io";

import "package:desktop_updater/src/core/update_retry_policy.dart";
import "package:desktop_updater/src/io/update_transport.dart";
import "package:http/http.dart" as http;

/// Provides app-owned HTTP headers for one update metadata or artifact request.
typedef UpdateRequestHeadersProvider = FutureOr<Map<String, String>> Function(
  Uri source,
);

/// Downloads update resources over HTTP with retry and resume support.
class HttpUpdateTransport implements BoundedUpdateTransport {
  /// Creates an HTTP update transport.
  HttpUpdateTransport({
    http.Client? client,
    UpdateRequestHeadersProvider? requestHeadersProvider,
    UpdateRetryPolicy retryPolicy = const UpdateRetryPolicy(),
    Future<void> Function(Duration duration) delay = _defaultDelay,
  })  : _client = client ?? http.Client(),
        _requestHeadersProvider = requestHeadersProvider,
        _retryPolicy = retryPolicy,
        _delay = delay;

  final http.Client _client;
  final UpdateRequestHeadersProvider? _requestHeadersProvider;
  final UpdateRetryPolicy _retryPolicy;
  final Future<void> Function(Duration duration) _delay;

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
    if (source.scheme != "http" && source.scheme != "https") {
      throw UnsupportedError("HTTP transport cannot fetch ${source.scheme}.");
    }

    await destination.parent.create(recursive: true);
    final partial = File("${destination.path}.part");

    var attempt = 0;
    try {
      while (true) {
        attempt += 1;
        try {
          await _downloadOnce(
            source,
            partial,
            maximumBytes: maximumBytes,
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

  Future<void> _downloadOnce(
    Uri source,
    File partial, {
    required int? maximumBytes,
    required void Function(int receivedBytes, int? totalBytes)? onProgress,
    required Duration? timeout,
  }) async {
    final resumeFrom = await partial.exists() ? await partial.length() : 0;
    if (maximumBytes != null && resumeFrom > maximumBytes) {
      throw UpdateDownloadSizeLimitException(
        source: source,
        maximumBytes: maximumBytes,
        actualBytes: resumeFrom,
      );
    }
    final request = http.Request("GET", source);
    final requestHeadersProvider = _requestHeadersProvider;
    if (requestHeadersProvider != null) {
      request.headers.addAll(await requestHeadersProvider(source));
    }
    if (resumeFrom > 0) {
      request.headers[HttpHeaders.rangeHeader] = "bytes=$resumeFrom-";
    }
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

    if (resumeFrom > 0 && response.statusCode == HttpStatus.partialContent) {
      final contentRange = await _validateContentRange(
        response,
        expectedStart: resumeFrom,
        source: source,
      );
      _checkDeclaredSize(
        source: source,
        maximumBytes: maximumBytes,
        actualBytes: contentRange.totalBytes,
      );
      await _writeStream(
        response.stream,
        partial,
        source: source,
        maximumBytes: maximumBytes,
        mode: FileMode.append,
        initialReceivedBytes: resumeFrom,
        totalBytes: contentRange.totalBytes,
        onProgress: onProgress,
      );
      return;
    }

    if (resumeFrom > 0 && response.statusCode != HttpStatus.ok) {
      await response.stream.drain<void>();
      throw HttpException(
        "Failed to resume $source: HTTP ${response.statusCode}",
        uri: source,
      );
    }

    if (resumeFrom > 0 && await partial.exists()) {
      await partial.delete();
    }
    _checkDeclaredSize(
      source: source,
      maximumBytes: maximumBytes,
      actualBytes: response.contentLength,
    );
    await _writeStream(
      response.stream,
      partial,
      source: source,
      maximumBytes: maximumBytes,
      mode: FileMode.write,
      totalBytes: response.contentLength,
      onProgress: onProgress,
    );
  }

  bool _canRetry(int attempt) {
    return attempt < _retryPolicy.maxAttempts;
  }

  /// Closes the underlying HTTP client.
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
  required Uri source,
  required int? maximumBytes,
  required FileMode mode,
  int initialReceivedBytes = 0,
  required int? totalBytes,
  void Function(int receivedBytes, int? totalBytes)? onProgress,
}) async {
  final sink = destination.openWrite(mode: mode);
  var receivedBytes = initialReceivedBytes;

  try {
    await for (final chunk in stream) {
      final nextReceivedBytes = receivedBytes + chunk.length;
      if (maximumBytes != null && nextReceivedBytes > maximumBytes) {
        throw UpdateDownloadSizeLimitException(
          source: source,
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

void _checkDeclaredSize({
  required Uri source,
  required int? maximumBytes,
  required int? actualBytes,
}) {
  if (maximumBytes != null &&
      actualBytes != null &&
      actualBytes > maximumBytes) {
    throw UpdateDownloadSizeLimitException(
      source: source,
      maximumBytes: maximumBytes,
      actualBytes: actualBytes,
    );
  }
}

Future<_ContentRange> _validateContentRange(
  http.StreamedResponse response, {
  required int expectedStart,
  required Uri source,
}) async {
  final header = response.headers[HttpHeaders.contentRangeHeader];
  final contentRange = _ContentRange.parse(header);
  if (contentRange == null ||
      contentRange.start != expectedStart ||
      contentRange.end < contentRange.start ||
      contentRange.totalBytes <= contentRange.end) {
    await response.stream.drain<void>();
    throw HttpException(
      "Invalid Content-Range for $source: ${header ?? "<missing>"}",
      uri: source,
    );
  }

  final rangeLength = contentRange.end - contentRange.start + 1;
  if (response.contentLength != null && response.contentLength != rangeLength) {
    await response.stream.drain<void>();
    throw HttpException(
      "Invalid Content-Range length for $source: ${header ?? "<missing>"}",
      uri: source,
    );
  }

  return contentRange;
}

class _ContentRange {
  const _ContentRange({
    required this.start,
    required this.end,
    required this.totalBytes,
  });

  final int start;
  final int end;
  final int totalBytes;

  static final _pattern = RegExp(r"^bytes\s+(\d+)-(\d+)/(\d+)$");

  static _ContentRange? parse(String? header) {
    if (header == null) {
      return null;
    }
    final match = _pattern.firstMatch(header.trim());
    if (match == null) {
      return null;
    }
    final start = int.tryParse(match.group(1)!);
    final end = int.tryParse(match.group(2)!);
    final totalBytes = int.tryParse(match.group(3)!);
    if (start == null || end == null || totalBytes == null) {
      return null;
    }
    return _ContentRange(
      start: start,
      end: end,
      totalBytes: totalBytes,
    );
  }
}
