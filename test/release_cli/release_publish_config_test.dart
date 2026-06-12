import "dart:io";

import "package:desktop_updater/src/release_cli/release_publish_config.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;

void main() {
  test("loads minimum updates baseUrl config", () async {
    final tempDir = await Directory.systemTemp.createTemp("release_config_");
    try {
      final configFile = File(path.join(tempDir.path, "desktop_updater.yaml"));
      await configFile.writeAsString("""
updates:
  baseUrl: https://updates.example.com
""");

      final config = await ReleasePublishConfig.load(
        projectRoot: tempDir,
        cliOverrides: const ReleasePublishOverrides(),
      );

      expect(config.baseUrl.toString(), "https://updates.example.com/");
      expect(config.uploadProvider, isA<ManualUploadConfig>());
      expect(
        config.outputDirectory.path,
        path.join(tempDir.path, "dist", "desktop_updater"),
      );
      expect(config.channel, "stable");
    } finally {
      await tempDir.delete(recursive: true);
    }
  });

  test("rejects missing baseUrl", () async {
    final tempDir = await Directory.systemTemp.createTemp("release_config_");
    try {
      await expectLater(
        ReleasePublishConfig.load(
          projectRoot: tempDir,
          cliOverrides: const ReleasePublishOverrides(),
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            "message",
            contains("updates.baseUrl is required"),
          ),
        ),
      );
    } finally {
      await tempDir.delete(recursive: true);
    }
  });
}
