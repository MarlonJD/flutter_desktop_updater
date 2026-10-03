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
    final requestHeadersProvider = _requestHeadersProvider;
    final requestHeaders = requestHeadersProvider == null
        ? null
        : await requestHeadersProvider(source);
    final attempt = _HttpRequestAttempt(timeout);
    try {
      final request = http.AbortableRequest(
        "GET",
        source,
        abortTrigger: attempt.abortTrigger,
      );
      if (requestHeaders != null) {
        request.headers.addAll(requestHeaders);
      }
      if (resumeFrom > 0) {
        request.headers[HttpHeaders.rangeHeader] = "bytes=$resumeFrom-";
      }
      final response = await attempt.send(_client.send(request));
      await attempt.trackResponseStream(response.stream);
      attempt.checkActive();

      if (response.statusCode < 200 || response.statusCode >= 300) {
        await attempt.drain(response.stream);
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
          attempt: attempt,
          expectedStart: resumeFrom,
          source: source,
        );
        attempt.checkActive();
        _checkDeclaredSize(
          source: source,
          maximumBytes: maximumBytes,
          actualBytes: contentRange.totalBytes,
        );
        await _writeStream(
          response.stream,
          partial,
          attempt: attempt,
          source: source,
          maximumBytes: maximumBytes,
          mode: FileMode.append,
          initialReceivedBytes: resumeFrom,
          totalBytes: contentRange.totalBytes,
          onProgress: onProgress,
        );
        attempt.checkActive();
        return;
      }

      if (resumeFrom > 0 && response.statusCode != HttpStatus.ok) {
        await attempt.drain(response.stream);
        throw HttpException(
          "Failed to resume $source: HTTP ${response.statusCode}",
          uri: source,
        );
      }

      if (resumeFrom > 0 && await partial.exists()) {
        await partial.delete();
      }
      attempt.checkActive();
      _checkDeclaredSize(
        source: source,
        maximumBytes: maximumBytes,
        actualBytes: response.contentLength,
      );
      await _writeStream(
        response.stream,
        partial,
        attempt: attempt,
        source: source,
        maximumBytes: maximumBytes,
        mode: FileMode.write,
        totalBytes: response.contentLength,
        onProgress: onProgress,
      );
      attempt.checkActive();
    } finally {
      await attempt.close();
    }
  }

  bool _canRetry(int attempt) {
    return attempt < _retryPolicy.maxAttempts;
  }

  /// Closes the underlying HTTP client.
  void close() {
    _client.close();
  }
}

/// Bounds one HTTP request and owns cancellation for its response body.
class _HttpRequestAttempt {
  _HttpRequestAttempt(this._timeout) {
    if (_timeout != null) {
      _timer = Timer(_timeout, _expire);
    }
  }

  final Duration? _timeout;
  final Completer<void> _abortCompleter = Completer<void>();
  final Completer<Never> _timeoutCompleter = Completer<Never>();

  Timer? _timer;
  Stream<List<int>>? _pendingResponseStream;
  Future<void>? _pendingCancellation;
  StreamIterator<List<int>>? _bodyIterator;
  Future<void>? _bodyCancellation;
  bool _timedOut = false;

  Future<void> get abortTrigger => _abortCompleter.future;

  Future<http.StreamedResponse> send(
    Future<http.StreamedResponse> responseFuture,
  ) async {
    if (_timeout == null) {
      return responseFuture;
    }

    unawaited(
      responseFuture.then<void>(
        (response) {
          if (_timedOut) {
            unawaited(_cancelUnconsumed(response.stream));
          }
        },
        onError: (Object _, StackTrace __) {},
      ),
    );

    try {
      final response = await Future.any<http.StreamedResponse>([
        responseFuture,
        _timeoutCompleter.future,
      ]);
      if (_timedOut) {
        unawaited(_cancelUnconsumed(response.stream));
        throw _timeoutException();
      }
      return response;
    } catch (error, stackTrace) {
      if (_timedOut) {
        throw _timeoutException();
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> trackResponseStream(Stream<List<int>> stream) async {
    _pendingResponseStream = stream;
    if (_timedOut) {
      _pendingResponseStream = null;
      await _cancelUnconsumed(stream);
      throw _timeoutException();
    }
  }

  Future<void> drain(Stream<List<int>> stream) {
    return consume(stream, (_) {});
  }

  Future<void> consume(
    Stream<List<int>> stream,
    void Function(List<int> chunk) onChunk,
  ) async {
    checkActive();
    if (identical(_pendingResponseStream, stream)) {
      _pendingResponseStream = null;
    }

    final iterator = StreamIterator<List<int>>(stream);
    _bodyIterator = iterator;
    _bodyCancellation = null;
    try {
      while (await iterator.moveNext()) {
        checkActive();
        onChunk(iterator.current);
      }
      checkActive();
    } catch (_) {
      await _cancelBody(iterator);
      rethrow;
    } finally {
      await _cancelBody(iterator);
      if (identical(_bodyIterator, iterator)) {
        _bodyIterator = null;
        _bodyCancellation = null;
      }
    }
  }

  void checkActive() {
    if (_timedOut) {
      throw _timeoutException();
    }
  }

  Future<void> close() async {
    _timer?.cancel();
    final pendingCancellation = _pendingCancellation;
    _pendingCancellation = null;
    if (pendingCancellation != null) {
      await pendingCancellation;
    }
    final pendingStream = _pendingResponseStream;
    _pendingResponseStream = null;
    if (pendingStream != null) {
      await _cancelUnconsumed(pendingStream);
    }
  }

  void _expire() {
    if (_timedOut) {
      return;
    }
    _timedOut = true;
    _abortCompleter.complete();

    final iterator = _bodyIterator;
    if (iterator != null) {
      unawaited(_cancelBody(iterator));
      _completeTimeout();
      return;
    }

    final pendingStream = _pendingResponseStream;
    _pendingResponseStream = null;
    if (pendingStream != null) {
      _pendingCancellation = _cancelUnconsumed(pendingStream);
    }
    _completeTimeout();
  }

  Future<void> _cancelBody(StreamIterator<List<int>> iterator) {
    return _bodyCancellation ??= _ignoreCancellationErrors(iterator.cancel());
  }

  Future<void> _ignoreCancellationErrors(Future<void> cancellation) async {
    try {
      await cancellation;
    } on Object {
      // Preserve the download error or timeout that caused cancellation.
    }
  }

  Future<void> _cancelUnconsumed(Stream<List<int>> stream) async {
    try {
      final subscription = stream.listen(
        (_) {},
        onError: (Object _, StackTrace __) {},
      );
      await subscription.cancel();
    } on Object {
      // The original request error remains the useful failure to report.
    }
  }

  void _completeTimeout() {
    if (!_timeoutCompleter.isCompleted) {
      _timeoutCompleter.completeError(_timeoutException());
    }
  }

  TimeoutException _timeoutException() =>
      TimeoutException("HTTP request timed out.", _timeout);
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
  required _HttpRequestAttempt attempt,
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
    await attempt.consume(stream, (chunk) {
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
    });
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
  required _HttpRequestAttempt attempt,
  required int expectedStart,
  required Uri source,
}) async {
  final header = response.headers[HttpHeaders.contentRangeHeader];
  final contentRange = _ContentRange.parse(header);
  if (contentRange == null ||
      contentRange.start != expectedStart ||
      contentRange.end < contentRange.start ||
      contentRange.totalBytes <= contentRange.end) {
    await attempt.drain(response.stream);
    throw HttpException(
      "Invalid Content-Range for $source: ${header ?? "<missing>"}",
      uri: source,
    );
  }

  final rangeLength = contentRange.end - contentRange.start + 1;
  if (response.contentLength != null && response.contentLength != rangeLength) {
    await attempt.drain(response.stream);
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
