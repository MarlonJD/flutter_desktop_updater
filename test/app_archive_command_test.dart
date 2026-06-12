import "dart:convert";
import "dart:io";

import "package:desktop_updater/src/package/app_archive_command.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;

void main() {
  test("upsert command writes an app archive item", () async {
    final tempDir = await Directory.systemTemp.createTemp(
      "app_archive_command_",
    );
    try {
      final archive = File(path.join(tempDir.path, "app-archive.json"));
      final output = StringBuffer();

      await runAppArchiveCommand(
        [
          "upsert",
          "--archive",
          archive.path,
          "--app-name",
          "Example App",
          "--version",
          "2.0.0",
          "--build-number",
          "200",
          "--platform",
          "macos",
          "--channel",
          "stable",
          "--mandatory",
          "--release-url",
          "https://updates.example.com/releases/2.0.0/macos/release.json",
        ],
        output: output,
      );

      final json =
          jsonDecode(await archive.readAsString()) as Map<String, dynamic>;
      final items = json["items"] as List<dynamic>;
      final firstItem = items.single as Map<String, dynamic>;
      expect(json["appName"], "Example App");
      expect(items, hasLength(1));
      expect(firstItem["mandatory"], isTrue);
      expect(
        output.toString(),
        contains("app-archive.json updated: ${archive.path}"),
      );
    } finally {
      await tempDir.delete(recursive: true);
    }
  });
}
