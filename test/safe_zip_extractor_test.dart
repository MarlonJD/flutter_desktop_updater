import "dart:io";

import "package:archive/archive.dart";
import "package:desktop_updater/src/core/safe_zip_extractor.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;

void main() {
  test("rejects parent traversal entries", () async {
    await _expectZipRejected(
        Archive()..addFile(ArchiveFile.string("../evil", "x")));
  });

  test("rejects absolute entries", () async {
    await _expectZipRejected(
        Archive()..addFile(ArchiveFile.string("/tmp/evil", "x")));
  });

  test("rejects Windows drive entries", () async {
    await _expectZipRejected(
        Archive()..addFile(ArchiveFile.string(r"C:\evil", "x")));
  });

  test("accepts nested valid paths", () async {
    final tempDir = await Directory.systemTemp.createTemp("zip_extract_");
    try {
      final archiveFile = await _writeZip(
        tempDir,
        Archive()..addFile(ArchiveFile.string("nested/file.txt", "ok")),
      );
      final destination = Directory(path.join(tempDir.path, "out"));

      await const SafeZipExtractor().extract(
        archiveFile: archiveFile,
        destination: destination,
        platform: "linux",
      );

      expect(
        File(path.join(destination.path, "nested", "file.txt"))
            .readAsStringSync(),
        "ok",
      );
    } finally {
      await tempDir.delete(recursive: true);
    }
  });

  test("rejects symlink entries on Windows and Linux by default", () async {
    if (Platform.isWindows) {
      return;
    }

    final tempDir = await Directory.systemTemp.createTemp("zip_extract_");
    try {
      File(path.join(tempDir.path, "target")).writeAsStringSync("target");
      await Link(path.join(tempDir.path, "link")).create("target");
      final archiveFile = File(path.join(tempDir.path, "fixture.zip"));
      final result = await Process.run(
        "zip",
        ["-yr", archiveFile.path, "link"],
        workingDirectory: tempDir.path,
      );
      expect(result.exitCode, 0, reason: result.stderr.toString());

      await expectLater(
        const SafeZipExtractor().extract(
          archiveFile: archiveFile,
          destination: Directory(path.join(tempDir.path, "out")),
          platform: "linux",
        ),
        throwsFormatException,
      );
    } finally {
      await tempDir.delete(recursive: true);
    }
  });

  test("macOS app zips are extracted only by ditto", () async {
    final tempDir = await Directory.systemTemp.createTemp("zip_extract_");
    try {
      final archiveFile = await _writeZip(
        tempDir,
        Archive()
          ..addFile(ArchiveFile.string("Example.app/Contents/Info.plist", "x")),
      );

      await expectLater(
        const SafeZipExtractor().extract(
          archiveFile: archiveFile,
          destination: Directory(path.join(tempDir.path, "out")),
          platform: "macos",
        ),
        throwsUnsupportedError,
      );
    } finally {
      await tempDir.delete(recursive: true);
    }
  });
}

Future<void> _expectZipRejected(Archive archive) async {
  final tempDir = await Directory.systemTemp.createTemp("zip_extract_");
  try {
    final archiveFile = await _writeZip(tempDir, archive);
    await expectLater(
      const SafeZipExtractor().extract(
        archiveFile: archiveFile,
        destination: Directory(path.join(tempDir.path, "out")),
        platform: "linux",
      ),
      throwsFormatException,
    );
  } finally {
    await tempDir.delete(recursive: true);
  }
}

Future<File> _writeZip(Directory tempDir, Archive archive) async {
  final file = File(path.join(tempDir.path, "fixture.zip"));
  file.writeAsBytesSync(ZipEncoder().encode(archive));
  return file;
}
