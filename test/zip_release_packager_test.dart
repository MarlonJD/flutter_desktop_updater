import "dart:io";

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
}
