import "dart:convert";
import "dart:io";

import "package:desktop_updater/src/release_cli/release_command.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;

void main() {
  test("publish without upload provider prints manual upload instructions",
      () async {
    final fixture = await createReleasePublishFixture(
      config: """
updates:
  baseUrl: https://updates.example.com
""",
    );
    try {
      final output = StringBuffer();

      final exitCode = await runReleaseCommand(
        ["publish", "--platform", "macos", "--skip-build-for-test"],
        projectRoot: fixture.root,
        output: output,
      );

      expect(exitCode, 0);
      expect(output.toString(), contains("Manual publish package is ready."));
      expect(output.toString(), contains("Not uploaded yet."));
      expect(output.toString(), contains("file://"));
      expect(output.toString(), contains("release validate --manifest"));
      expect(output.toString(), contains("docs/publishing.md"));

      final manifestFile = File(
        path.join(
          fixture.root.path,
          "dist",
          "desktop_updater",
          ".desktop_updater_publish.json",
        ),
      );
      expect(await manifestFile.exists(), isTrue);
      final manifest =
          jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>;
      expect(manifest["appArchive"], isA<Map<String, dynamic>>());
      expect(
        await File(
          path.join(
            fixture.root.path,
            "dist",
            "desktop_updater",
            "releases",
            "2.0.1",
            "macos",
            "release.json",
          ),
        ).exists(),
        isTrue,
      );
    } finally {
      await fixture.delete();
    }
  });
}

class ReleasePublishFixture {
  const ReleasePublishFixture(this.root);

  final Directory root;

  Future<void> delete() => root.delete(recursive: true);
}

Future<ReleasePublishFixture> createReleasePublishFixture({
  required String config,
}) async {
  final root = await Directory.systemTemp.createTemp("release_publish_");
  await File(path.join(root.path, "pubspec.yaml")).writeAsString("""
name: release_fixture
version: 2.0.1+201
""");
  await File(path.join(root.path, "desktop_updater.yaml"))
      .writeAsString(config);

  final configs = Directory(path.join(root.path, "macos", "Runner", "Configs"));
  await configs.create(recursive: true);
  await File(path.join(configs.path, "AppInfo.xcconfig")).writeAsString("""
PRODUCT_NAME = Release Fixture
PRODUCT_BUNDLE_IDENTIFIER = com.example.releaseFixture
""");

  final appBundle = Directory(
    path.join(
      root.path,
      "build",
      "macos",
      "Build",
      "Products",
      "Release",
      "Release Fixture.app",
    ),
  );
  await appBundle.create(recursive: true);
  await File(path.join(appBundle.path, "app.txt")).writeAsString("hello");

  return ReleasePublishFixture(root);
}
