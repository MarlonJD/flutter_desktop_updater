import "dart:io";

import "package:desktop_updater/src/io/file_update_transport.dart";
import "package:flutter_test/flutter_test.dart";
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
}
