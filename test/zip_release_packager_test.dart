import "dart:io";

import "package:archive/archive.dart";
import "package:desktop_updater/src/package/release_packager.dart";
import "package:desktop_updater/src/package/zip_release_packager.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;

void main() {
  test("zip packager writes release descriptor and artifact", () async {
    final tempDir = await Directory.systemTemp.createTemp("packager_");
    try {
      final input = Directory(path.join(tempDir.path, "input"));
      await input.create();
      File(path.join(input.path, "app.txt")).writeAsStringSync("hello");
      final output = Directory(path.join(tempDir.path, "out"));

      final result = await const ZipReleasePackager().package(
        ReleasePackageRequest(
          input: input,
          outputDirectory: output,
          packageId: "com.example.app",
          appName: "Example",
          version: "2.0.0",
          buildNumber: 200,
          platform: "linux",
          channel: "stable",
          artifactUrl: Uri.parse("https://cdn.example.com/Example.zip"),
          installStrategy: "wholeDirectoryReplace",
        ),
      );

      expect(await result.artifact.exists(), isTrue);
      expect(await result.releaseFile.exists(), isTrue);
      expect(result.descriptor.artifact.length, greaterThan(0));
    } finally {
      await tempDir.delete(recursive: true);
    }
  });

  test("zip packager omits buildNumber when it is not provided", () async {
    final tempDir = await Directory.systemTemp.createTemp("packager_");
    try {
      final input = Directory(path.join(tempDir.path, "input"));
      await input.create();
      File(path.join(input.path, "app.txt")).writeAsStringSync("hello");
      final output = Directory(path.join(tempDir.path, "out"));

      final result = await const ZipReleasePackager().package(
        ReleasePackageRequest(
          input: input,
          outputDirectory: output,
          packageId: "com.example.app",
          appName: "Example",
          version: "2.0.0",
          platform: "linux",
          channel: "stable",
          artifactUrl: Uri.parse("https://cdn.example.com/Example.zip"),
          installStrategy: "wholeDirectoryReplace",
        ),
      );

      expect(result.descriptor.buildNumber, isNull);
      expect(
        await result.releaseFile.readAsString(),
        isNot(contains("buildNumber")),
      );
    } finally {
      await tempDir.delete(recursive: true);
    }
  });

  test("Windows zip package carries an installed target identity marker",
      () async {
    final tempDir = await Directory.systemTemp.createTemp("packager_");
    try {
      final input = Directory(path.join(tempDir.path, "input"));
      await input.create();
      File(path.join(input.path, "Example.exe")).writeAsStringSync("binary");
      final result = await const ZipReleasePackager().package(
        ReleasePackageRequest(
          input: input,
          outputDirectory: Directory(path.join(tempDir.path, "out")),
          packageId: "com.example.app",
          appName: "Example",
          version: "2.0.0",
          platform: "windows",
          channel: "stable",
          artifactUrl: Uri.parse("https://cdn.example.com/Example.zip"),
          installStrategy: "wholeDirectoryReplace",
        ),
      );

      final archive = ZipDecoder().decodeBytes(
        await result.artifact.readAsBytes(),
      );
      final marker = archive.files.singleWhere(
        (entry) => entry.name == ".desktop_updater_install_identity.json",
      );
      expect(
        String.fromCharCodes(marker.content as List<int>),
        '{"packageId":"com.example.app","schemaVersion":1}',
      );
    } finally {
      await tempDir.delete(recursive: true);
    }
  });

  test("Windows and Linux file packages carry exactly one identity marker",
      () async {
    for (final platform in <String>["windows", "linux"]) {
      final tempDir = await Directory.systemTemp.createTemp("packager_");
      try {
        final input = File(path.join(tempDir.path, "Example.bin"));
        await input.writeAsString("binary");
        final result = await const ZipReleasePackager().package(
          ReleasePackageRequest(
            input: input,
            outputDirectory: Directory(path.join(tempDir.path, "out")),
            packageId: "com.example.app",
            appName: "Example",
            version: "2.0.0",
            platform: platform,
            channel: "stable",
            artifactUrl: Uri.parse("https://cdn.example.com/Example.zip"),
            installStrategy: "wholeDirectoryReplace",
          ),
        );

        final archive = ZipDecoder().decodeBytes(
          await result.artifact.readAsBytes(),
        );
        expect(
          archive.files
              .where(
                (entry) =>
                    entry.name == ".desktop_updater_install_identity.json",
              )
              .length,
          1,
          reason: platform,
        );
        expect(
          archive.files.map((entry) => entry.name),
          contains("Example.bin"),
          reason: platform,
        );
      } finally {
        await tempDir.delete(recursive: true);
      }
    }
  });

  test("packager rejects a pre-existing reserved identity marker", () async {
    final tempDir = await Directory.systemTemp.createTemp("packager_");
    try {
      final input = Directory(path.join(tempDir.path, "input"));
      await input.create();
      await File(
        path.join(input.path, ".desktop_updater_install_identity.json"),
      ).writeAsString('{"packageId":"forged","schemaVersion":1}');

      await expectLater(
        const ZipReleasePackager().package(
          ReleasePackageRequest(
            input: input,
            outputDirectory: Directory(path.join(tempDir.path, "out")),
            packageId: "com.example.app",
            appName: "Example",
            version: "2.0.0",
            platform: "windows",
            channel: "stable",
            artifactUrl: Uri.parse("https://cdn.example.com/Example.zip"),
            installStrategy: "wholeDirectoryReplace",
          ),
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            "message",
            contains("reserved installed identity marker"),
          ),
        ),
      );
    } finally {
      await tempDir.delete(recursive: true);
    }
  });

  test("macOS zip artifact filename strips .app but descriptor keeps it",
      () async {
    final tempDir = await Directory.systemTemp.createTemp("packager_");
    try {
      final input = Directory(path.join(tempDir.path, "Example.app"));
      await input.create();
      File(path.join(input.path, "app.txt")).writeAsStringSync("hello");
      final output = Directory(path.join(tempDir.path, "out"));

      final dittoCalls = <List<String>>[];
      final result = await ZipReleasePackager(
        runProcess: (executable, arguments) async {
          dittoCalls.add([executable, ...arguments]);
          await File(arguments.last).writeAsString("zip");
          return ProcessResult(0, 0, "", "");
        },
      ).package(
        ReleasePackageRequest(
          input: input,
          outputDirectory: output,
          packageId: "com.example.app",
          appName: "Example.app",
          version: "2.0.0",
          platform: "macos",
          channel: "stable",
          artifactUrl: Uri.parse(
            "https://cdn.example.com/Example-2.0.0-macos.zip",
          ),
          installStrategy: "wholeBundleReplace",
        ),
      );

      expect(path.basename(result.artifact.path), "Example-2.0.0-macos.zip");
      expect(result.descriptor.appName, "Example.app");
      expect(dittoCalls, hasLength(1));
      expect(dittoCalls.single.first, "/usr/bin/ditto");
    } finally {
      await tempDir.delete(recursive: true);
    }
  });
}
