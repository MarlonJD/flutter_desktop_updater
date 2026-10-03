import "dart:async";
import "dart:convert";
import "dart:io";

import "package:desktop_updater/src/core/update_retry_policy.dart";
import "package:desktop_updater/src/io/file_update_transport.dart";
import "package:desktop_updater/src/io/http_update_transport.dart";
import "package:flutter_test/flutter_test.dart";
import "package:http/http.dart" as http;
import "package:http/testing.dart";
import "package:path/path.dart" as path;

void main() {
  test("file transport copies exact file URLs with progress", () async {
    final tempDir = await Directory.systemTemp.createTemp("transport_");
    try {
      final source = File(path.join(tempDir.path, "source.txt"))
        ..writeAsStringSync("hello");
      final destination = File(path.join(tempDir.path, "out", "copy.txt"));
      final progress = <int>[];

      await const FileUpdateTransport().download(
        source.uri,
        destination,
        onProgress: (receivedBytes, _) => progress.add(receivedBytes),
      );

      expect(destination.readAsStringSync(), "hello");
      expect(progress.last, 5);
    } finally {
      await tempDir.delete(recursive: true);
    }
  });

  test("file transport rejects non-file URLs", () {
    expect(
      () => const FileUpdateTransport().download(
        Uri.parse("https://example.com/file.zip"),
        File("/tmp/file.zip"),
      ),
      throwsUnsupportedError,
    );
  });

  test("http transport retries transient statuses with backoff", () async {
    final tempDir = await Directory.systemTemp.createTemp("http_transport_");
    final delays = <Duration>[];
    var attempts = 0;
    try {
      final transport = HttpUpdateTransport(
        client: MockClient((request) async {
          attempts += 1;
          if (attempts < 3) {
            return http.Response("busy", HttpStatus.serviceUnavailable);
          }
          return http.Response("ok", HttpStatus.ok);
        }),
        retryPolicy: const UpdateRetryPolicy(),
        delay: (duration) async {
          delays.add(duration);
        },
      );
      final destination = File(path.join(tempDir.path, "download.txt"));

      await transport.download(
        Uri.parse("https://updates.example.com/download.txt"),
        destination,
      );

      expect(attempts, 3);
      expect(delays, [
        const Duration(milliseconds: 500),
        const Duration(seconds: 1),
      ]);
      expect(destination.readAsStringSync(), "ok");
    } finally {
      await tempDir.delete(recursive: true);
    }
  });

  test("http transport does not retry non-transient statuses", () async {
    final tempDir = await Directory.systemTemp.createTemp("http_transport_");
    final delays = <Duration>[];
    var attempts = 0;
    try {
      final transport = HttpUpdateTransport(
        client: MockClient((request) async {
          attempts += 1;
          return http.Response("missing", HttpStatus.notFound);
        }),
        delay: (duration) async {
          delays.add(duration);
        },
      );
      final destination = File(path.join(tempDir.path, "download.txt"));

      await expectLater(
        transport.download(
          Uri.parse("https://updates.example.com/download.txt"),
          destination,
        ),
        throwsA(isA<HttpException>()),
      );

      expect(attempts, 1);
      expect(delays, isEmpty);
    } finally {
      await tempDir.delete(recursive: true);
    }
  });

  test("http transport retries transient client failures", () async {
    final tempDir = await Directory.systemTemp.createTemp("http_transport_");
    var attempts = 0;
    try {
      final transport = HttpUpdateTransport(
        client: MockClient((request) async {
          attempts += 1;
          if (attempts == 1) {
            throw http.ClientException("connection reset", request.url);
          }
          return http.Response.bytes(utf8.encode("ok"), HttpStatus.ok);
        }),
        retryPolicy: const UpdateRetryPolicy(maxAttempts: 2),
        delay: (_) async {},
      );
      final destination = File(path.join(tempDir.path, "download.txt"));

      await transport.download(
        Uri.parse("https://updates.example.com/download.txt"),
        destination,
      );

      expect(attempts, 2);
      expect(destination.readAsStringSync(), "ok");
    } finally {
      await tempDir.delete(recursive: true);
    }
  });

  test("http body timeout cancels the stream before retry cleanup", () async {
    final tempDir = await Directory.systemTemp.createTemp("http_transport_");
    final cancellationStarted = Completer<void>();
    final allowCancellationToFinish = Completer<void>();
    final firstChunkReceived = Completer<void>();
    final aborted = Completer<void>();
    late final StreamController<List<int>> stalledBody;
    stalledBody = StreamController<List<int>>(
      onListen: () {
        scheduleMicrotask(() => stalledBody.add(utf8.encode("stale")));
      },
      onCancel: () {
        cancellationStarted.complete();
        return allowCancellationToFinish.future;
      },
    );
    var attempts = 0;
    final ranges = <String?>[];
    final transport = HttpUpdateTransport(
      client: _StreamResponseClient((request) async {
        ranges.add(request.headers[HttpHeaders.rangeHeader]);
        final attempt = ++attempts;
        if (attempt == 1) {
          _observeAbort(request, aborted);
          return http.StreamedResponse(stalledBody.stream, HttpStatus.ok);
        }
        return http.StreamedResponse(
          Stream<List<int>>.value(utf8.encode("fresh")),
          HttpStatus.ok,
          contentLength: 5,
        );
      }),
      retryPolicy: const UpdateRetryPolicy(maxAttempts: 2),
      delay: (_) async {},
    );
    final destination = File(path.join(tempDir.path, "download.txt"));

    try {
      final download = transport.download(
        Uri.parse("https://updates.example.com/download.txt"),
        destination,
        timeout: const Duration(milliseconds: 80),
        onProgress: (receivedBytes, _) {
          if (receivedBytes == 5 && !firstChunkReceived.isCompleted) {
            firstChunkReceived.complete();
          }
        },
      );
      await firstChunkReceived.future.timeout(const Duration(seconds: 2));
      await cancellationStarted.future.timeout(const Duration(seconds: 2));
      expect(attempts, 1);
      expect(File("${destination.path}.part").existsSync(), isTrue);
      allowCancellationToFinish.complete();
      await download.timeout(const Duration(seconds: 2));

      await aborted.future.timeout(const Duration(seconds: 1));
      expect(attempts, 2);
      expect(ranges, [null, null]);
      expect(destination.readAsStringSync(), "fresh");
      expect(File("${destination.path}.part").existsSync(), isFalse);

      stalledBody.add(utf8.encode(" late bytes"));
      await stalledBody.close();
      await Future<void>.delayed(Duration.zero);
      expect(destination.readAsStringSync(), "fresh");
    } finally {
      if (!allowCancellationToFinish.isCompleted) {
        allowCancellationToFinish.complete();
      }
      transport.close();
      await stalledBody.close();
      await tempDir.delete(recursive: true);
    }
  });

  test("http error drain timeout cancels the stream and retries", () async {
    final tempDir = await Directory.systemTemp.createTemp("http_transport_");
    final cancelled = Completer<void>();
    final firstChunkRead = Completer<void>();
    late final StreamController<List<int>> stalledBody;
    stalledBody = StreamController<List<int>>(
      onListen: () {
        if (!firstChunkRead.isCompleted) {
          firstChunkRead.complete();
        }
        scheduleMicrotask(() => stalledBody.add(utf8.encode("busy")));
      },
      onCancel: cancelled.complete,
    );
    var attempts = 0;
    final transport = HttpUpdateTransport(
      client: _StreamResponseClient((request) async {
        attempts += 1;
        if (attempts == 1) {
          return http.StreamedResponse(
            stalledBody.stream,
            HttpStatus.serviceUnavailable,
          );
        }
        return http.StreamedResponse(
          Stream<List<int>>.value(utf8.encode("recovered")),
          HttpStatus.ok,
          contentLength: 9,
        );
      }),
      retryPolicy: const UpdateRetryPolicy(maxAttempts: 2),
      delay: (_) async {},
    );
    final destination = File(path.join(tempDir.path, "download.txt"));

    try {
      final download = transport.download(
        Uri.parse("https://updates.example.com/download.txt"),
        destination,
        timeout: const Duration(milliseconds: 80),
      );
      // The controller is listened to by the drain before the timeout fires.
      await firstChunkRead.future.timeout(const Duration(seconds: 2));
      await download.timeout(const Duration(seconds: 2));

      await cancelled.future.timeout(const Duration(seconds: 1));
      expect(attempts, 2);
      expect(destination.readAsStringSync(), "recovered");
      expect(File("${destination.path}.part").existsSync(), isFalse);

      stalledBody.add(utf8.encode(" late error body"));
      await stalledBody.close();
      await Future<void>.delayed(Duration.zero);
      expect(destination.readAsStringSync(), "recovered");
    } finally {
      transport.close();
      await stalledBody.close();
      await tempDir.delete(recursive: true);
    }
  });

  test("invalid content range drain timeout cancels and cleans partial",
      () async {
    final tempDir = await Directory.systemTemp.createTemp("http_transport_");
    final cancelled = Completer<void>();
    late final StreamController<List<int>> stalledBody;
    stalledBody = StreamController<List<int>>(
      onListen: () {
        scheduleMicrotask(() => stalledBody.add(utf8.encode("ignored")));
      },
      onCancel: cancelled.complete,
    );
    var attempts = 0;
    final transport = HttpUpdateTransport(
      client: _StreamResponseClient((request) async {
        attempts += 1;
        return http.StreamedResponse(
          stalledBody.stream,
          HttpStatus.partialContent,
          headers: const {
            HttpHeaders.contentRangeHeader: "bytes 0-6/20",
          },
        );
      }),
      retryPolicy: const UpdateRetryPolicy(maxAttempts: 1),
      delay: (_) async {},
    );
    final destination = File(path.join(tempDir.path, "download.txt"));
    final partial = File("${destination.path}.part")
      ..createSync(recursive: true)
      ..writeAsStringSync("prefix");

    try {
      await expectLater(
        transport.download(
          Uri.parse("https://updates.example.com/download.txt"),
          destination,
          timeout: const Duration(milliseconds: 80),
        ),
        throwsA(isA<TimeoutException>()),
      );

      await cancelled.future.timeout(const Duration(seconds: 1));
      expect(attempts, 1);
      expect(partial.existsSync(), isFalse);
      expect(destination.existsSync(), isFalse);

      stalledBody.add(utf8.encode(" late invalid-range body"));
      await stalledBody.close();
      await Future<void>.delayed(Duration.zero);
      expect(destination.existsSync(), isFalse);
    } finally {
      transport.close();
      await stalledBody.close();
      await tempDir.delete(recursive: true);
    }
  });

  test("http header timeout aborts and discards a late response body",
      () async {
    final tempDir = await Directory.systemTemp.createTemp("http_transport_");
    final lateResponse = Completer<http.StreamedResponse>();
    final lateBodyCancelled = Completer<void>();
    final aborted = Completer<void>();
    late final StreamController<List<int>> lateBody;
    lateBody = StreamController<List<int>>(
      onCancel: lateBodyCancelled.complete,
    );
    var attempts = 0;
    final transport = HttpUpdateTransport(
      client: _StreamResponseClient((request) async {
        attempts += 1;
        if (attempts == 1) {
          _observeAbort(request, aborted);
          return lateResponse.future;
        }
        return http.StreamedResponse(
          Stream<List<int>>.value(utf8.encode("retry")),
          HttpStatus.ok,
          contentLength: 5,
        );
      }),
      retryPolicy: const UpdateRetryPolicy(maxAttempts: 2),
      delay: (_) async {},
    );
    final destination = File(path.join(tempDir.path, "download.txt"));

    try {
      await transport
          .download(
            Uri.parse("https://updates.example.com/download.txt"),
            destination,
            timeout: const Duration(milliseconds: 80),
          )
          .timeout(const Duration(seconds: 2));
      await aborted.future.timeout(const Duration(seconds: 1));
      expect(attempts, 2);
      expect(destination.readAsStringSync(), "retry");

      lateResponse.complete(
        http.StreamedResponse(lateBody.stream, HttpStatus.ok),
      );
      await lateBodyCancelled.future.timeout(const Duration(seconds: 1));
      lateBody.add(utf8.encode(" too late"));
      await lateBody.close();
      await Future<void>.delayed(Duration.zero);
      expect(destination.readAsStringSync(), "retry");
    } finally {
      transport.close();
      await lateBody.close();
      await tempDir.delete(recursive: true);
    }
  });

  test("http transport sends app-owned request headers", () async {
    final tempDir = await Directory.systemTemp.createTemp("http_transport_");
    Map<String, String>? capturedHeaders;
    try {
      final transport = HttpUpdateTransport(
        client: MockClient((request) async {
          capturedHeaders = Map<String, String>.of(request.headers);
          return http.Response("ok", HttpStatus.ok);
        }),
        requestHeadersProvider: (source) {
          return {
            HttpHeaders.authorizationHeader: "Bearer token",
            "x-update-host": source.host,
          };
        },
      );
      final destination = File(path.join(tempDir.path, "download.txt"));

      await transport.download(
        Uri.parse("https://updates.example.com/download.txt"),
        destination,
      );

      expect(
        capturedHeaders?[HttpHeaders.authorizationHeader],
        "Bearer token",
      );
      expect(capturedHeaders?["x-update-host"], "updates.example.com");
    } finally {
      await tempDir.delete(recursive: true);
    }
  });

  test("http transport resumes existing partial with valid range response",
      () async {
    final tempDir = await Directory.systemTemp.createTemp("http_transport_");
    final ranges = <String?>[];
    try {
      final transport = HttpUpdateTransport(
        client: MockClient((request) async {
          ranges.add(request.headers[HttpHeaders.rangeHeader]);
          return http.Response.bytes(
            utf8.encode("world"),
            HttpStatus.partialContent,
            headers: const {
              HttpHeaders.contentRangeHeader: "bytes 6-10/11",
            },
          );
        }),
      );
      final destination = File(path.join(tempDir.path, "download.txt"));
      final partial = File("${destination.path}.part")
        ..createSync(recursive: true)
        ..writeAsStringSync("hello ");

      await transport.download(
        Uri.parse("https://updates.example.com/download.txt"),
        destination,
      );

      expect(ranges, ["bytes=6-"]);
      expect(destination.readAsStringSync(), "hello world");
      expect(partial.existsSync(), isFalse);
    } finally {
      await tempDir.delete(recursive: true);
    }
  });

  test("http transport restarts when server ignores range request", () async {
    final tempDir = await Directory.systemTemp.createTemp("http_transport_");
    final ranges = <String?>[];
    try {
      final transport = HttpUpdateTransport(
        client: MockClient((request) async {
          ranges.add(request.headers[HttpHeaders.rangeHeader]);
          return http.Response("fresh bytes", HttpStatus.ok);
        }),
      );
      final destination = File(path.join(tempDir.path, "download.txt"));
      final partial = File("${destination.path}.part")
        ..createSync(recursive: true)
        ..writeAsStringSync("stale");

      await transport.download(
        Uri.parse("https://updates.example.com/download.txt"),
        destination,
      );

      expect(ranges, ["bytes=5-"]);
      expect(destination.readAsStringSync(), "fresh bytes");
      expect(partial.existsSync(), isFalse);
    } finally {
      await tempDir.delete(recursive: true);
    }
  });

  test("http transport deletes partial and fails on invalid content range",
      () async {
    final tempDir = await Directory.systemTemp.createTemp("http_transport_");
    final ranges = <String?>[];
    try {
      final transport = HttpUpdateTransport(
        client: MockClient((request) async {
          ranges.add(request.headers[HttpHeaders.rangeHeader]);
          return http.Response.bytes(
            utf8.encode("world"),
            HttpStatus.partialContent,
            headers: const {
              HttpHeaders.contentRangeHeader: "bytes 0-4/11",
            },
          );
        }),
      );
      final destination = File(path.join(tempDir.path, "download.txt"));
      final partial = File("${destination.path}.part")
        ..createSync(recursive: true)
        ..writeAsStringSync("hello ");

      await expectLater(
        transport.download(
          Uri.parse("https://updates.example.com/download.txt"),
          destination,
        ),
        throwsA(isA<HttpException>()),
      );

      expect(ranges, ["bytes=6-"]);
      expect(partial.existsSync(), isFalse);
      expect(destination.existsSync(), isFalse);
    } finally {
      await tempDir.delete(recursive: true);
    }
  });
}

class _StreamResponseClient extends http.BaseClient {
  _StreamResponseClient(this._handler);

  final Future<http.StreamedResponse> Function(http.BaseRequest request)
      _handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    await request.finalize().drain<void>();
    return _handler(request);
  }

  @override
  void close() {}
}

void _observeAbort(http.BaseRequest request, Completer<void> observed) {
  final abortTrigger = (request as http.AbortableRequest).abortTrigger;
  abortTrigger?.then((_) {
    if (!observed.isCompleted) {
      observed.complete();
    }
  });
}
