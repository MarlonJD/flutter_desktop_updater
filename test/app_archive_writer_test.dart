import "dart:convert";
import "dart:io";

import "package:desktop_updater/src/core/release_index.dart";
import "package:desktop_updater/src/package/app_archive_writer.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;

void main() {
  test("creates a schema v3 app archive when the file is missing", () async {
    final tempDir = await Directory.systemTemp.createTemp("app_archive_");
    try {
      final archive = File(path.join(tempDir.path, "app-archive.json"));

      final index = await upsertAppArchive(
        archiveFile: archive,
        appName: "Example App",
        item: ReleaseIndexItem(
          version: "2.0.0",
          buildNumber: 200,
          platform: "macos",
          channel: "stable",
          mandatory: false,
          release: Uri.parse(
            "https://updates.example.com/releases/2.0.0/macos/release.json",
          ),
        ),
      );

      expect(index.schemaVersion, 3);
      expect(index.appName, "Example App");
      expect(index.items, hasLength(1));

      final json =
          jsonDecode(await archive.readAsString()) as Map<String, dynamic>;
      final items = json["items"] as List<dynamic>;
      final firstItem = items.single as Map<String, dynamic>;
      expect(json["schemaVersion"], 3);
      expect(items, hasLength(1));
      expect(firstItem["platform"], "macos");
    } finally {
      await tempDir.delete(recursive: true);
    }
  });

  test("updates an existing matching item without duplicating it", () async {
    final tempDir = await Directory.systemTemp.createTemp("app_archive_");
    try {
      final archive = File(path.join(tempDir.path, "app-archive.json"));
      await archive.writeAsString(
        const JsonEncoder.withIndent("  ").convert({
          "schemaVersion": 3,
          "appName": "Example App",
          "items": [
            {
              "version": "2.0.0",
              "buildNumber": 200,
              "platform": "macos",
              "channel": "stable",
              "mandatory": false,
              "release": "https://updates.example.com/old/release.json",
            },
            {
              "version": "2.0.0",
              "platform": "windows",
              "channel": "stable",
              "mandatory": false,
              "release": "https://updates.example.com/windows/release.json",
            },
          ],
        }),
      );

      final index = await upsertAppArchive(
        archiveFile: archive,
        appName: "Example App",
        item: ReleaseIndexItem(
          version: "2.0.0",
          buildNumber: 200,
          platform: "macos",
          channel: "stable",
          mandatory: true,
          release: Uri.parse(
            "https://updates.example.com/releases/2.0.0/macos/release.json",
          ),
        ),
      );

      expect(index.items, hasLength(2));
      final macosItem = index.items.singleWhere(
        (item) => item.platform == "macos",
      );
      expect(macosItem.mandatory, isTrue);
      expect(
        macosItem.release.toString(),
        "https://updates.example.com/releases/2.0.0/macos/release.json",
      );

      final json =
          jsonDecode(await archive.readAsString()) as Map<String, dynamic>;
      expect(json["items"] as List<dynamic>, hasLength(2));
    } finally {
      await tempDir.delete(recursive: true);
    }
  });

  test("writes support policy and fresh install metadata", () async {
    final tempDir = await Directory.systemTemp.createTemp("app_archive_");
    try {
      final archive = File(path.join(tempDir.path, "app-archive.json"));

      final index = await upsertAppArchive(
        archiveFile: archive,
        appName: "Example App",
        supportPolicy: ReleaseSupportPolicy(
          minimumSupportedVersion: "2.4.0",
          enforcedAfter: DateTime.utc(2026, 7, 15),
        ),
        item: ReleaseIndexItem(
          version: "2.4.0",
          buildNumber: 240,
          platform: "macos",
          channel: "stable",
          mandatory: true,
          freshInstall: ReleaseFreshInstall(
            downloadUrl: Uri.parse("https://example.com/download/latest"),
            message: "Install from a fresh download.",
          ),
          release: Uri.parse(
            "https://updates.example.com/releases/2.4.0/macos/release.json",
          ),
        ),
      );

      expect(index.supportPolicy?.minimumSupportedVersion, "2.4.0");
      expect(
        index.items.single.freshInstall?.downloadUrl.toString(),
        "https://example.com/download/latest",
      );

      final json =
          jsonDecode(await archive.readAsString()) as Map<String, dynamic>;
      expect(json["supportPolicy"], {
        "minimumSupportedVersion": "2.4.0",
        "enforcedAfter": "2026-07-15T00:00:00.000Z",
      });
      final items = json["items"] as List<dynamic>;
      expect((items.single as Map<String, dynamic>)["freshInstall"], {
        "downloadUrl": "https://example.com/download/latest",
        "message": "Install from a fresh download.",
      });
    } finally {
      await tempDir.delete(recursive: true);
    }
  });
}
