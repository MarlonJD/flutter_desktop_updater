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
