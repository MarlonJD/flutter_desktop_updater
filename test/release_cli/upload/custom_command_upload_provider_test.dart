import "dart:io";

import "package:desktop_updater/src/release_cli/publish_manifest.dart";
import "package:desktop_updater/src/release_cli/release_publish_config.dart";
import "package:desktop_updater/src/release_cli/upload/custom_command_upload_provider.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;

void main() {
  test("custom command receives publish manifest environment", () async {
    final tempDir = await Directory.systemTemp.createTemp("custom_upload_");
    try {
      final logFile = File(path.join(tempDir.path, "env.log"));
      final script = File(path.join(tempDir.path, "upload.sh"));
      await script.writeAsString("""
#!/bin/sh
printf '%s\\n' "\$DESKTOP_UPDATER_PUBLISH_MANIFEST" > "${logFile.path}"
""");
      if (!Platform.isWindows) {
        final chmod = await Process.run("chmod", ["+x", script.path]);
        expect(chmod.exitCode, 0);
      }

      final provider = CustomCommandUploadProvider();
      await provider.upload(
        localRoot: Directory(path.join(tempDir.path, "dist")),
        manifest:
            testPublishManifest(localRoot: path.join(tempDir.path, "dist")),
        config: CustomCommandUploadConfig(command: script.path),
        output: StringBuffer(),
      );

      expect(
        await logFile.readAsString(),
        contains(".desktop_updater_publish.json"),
      );
    } finally {
      await tempDir.delete(recursive: true);
    }
  });
}

PublishManifest testPublishManifest({required String localRoot}) {
  return PublishManifest(
    schemaVersion: 1,
    baseUrl: Uri.parse("https://updates.example.com/"),
    localRoot: localRoot,
    appArchive: PublishManifestFile(
      path: "app-archive.json",
      url: Uri.parse("https://updates.example.com/app-archive.json"),
    ),
    release: PublishManifestRelease(
      version: "2.0.1",
      buildNumber: 201,
      platform: "macos",
      channel: "stable",
      path: "releases/2.0.1/macos/release.json",
      url: Uri.parse(
        "https://updates.example.com/releases/2.0.1/macos/release.json",
      ),
    ),
    artifact: PublishManifestArtifact(
      path: "releases/2.0.1/macos/Example-2.0.1-macos.zip",
      url: Uri.parse(
        "https://updates.example.com/releases/2.0.1/macos/Example-2.0.1-macos.zip",
      ),
      sha256:
          "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      length: 12,
    ),
  );
}
