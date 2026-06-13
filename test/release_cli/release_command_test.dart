import "dart:convert";
import "dart:io";

import "package:desktop_updater/src/release_cli/release_command.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;

import "../fixtures/release_publish_project.dart";

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
        ["publish", "--platform", fixture.platform, "--skip-build-for-test"],
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
            fixture.platform,
            "release.json",
          ),
        ).exists(),
        isTrue,
      );
    } finally {
      await fixture.delete();
    }
  });

  test("notarize flag requires macOS notarization config", () async {
    final fixture = await createReleasePublishFixture(
      config: """
updates:
  baseUrl: https://updates.example.com
""",
    );
    try {
      final output = StringBuffer();

      final exitCode = await runReleaseCommand(
        [
          "publish",
          "--platform",
          "macos",
          "--skip-build-for-test",
          "--notarize",
        ],
        projectRoot: fixture.root,
        output: output,
      );

      expect(exitCode, 64);
      expect(
        output.toString(),
        contains("macos.developerIdApplication is required"),
      );
    } finally {
      await fixture.delete();
    }
  });

  test("mandatory flag marks the generated app archive item", () async {
    final fixture = await createReleasePublishFixture(
      config: """
updates:
  baseUrl: https://updates.example.com
""",
    );
    try {
      final output = StringBuffer();

      final exitCode = await runReleaseCommand(
        [
          "publish",
          "--platform",
          fixture.platform,
          "--skip-build-for-test",
          "--mandatory",
        ],
        projectRoot: fixture.root,
        output: output,
      );

      expect(exitCode, 0);
      final appArchive = File(
        path.join(
          fixture.root.path,
          "dist",
          "desktop_updater",
          "app-archive.json",
        ),
      );
      final archive =
          jsonDecode(await appArchive.readAsString()) as Map<String, dynamic>;
      final items = archive["items"] as List<dynamic>;
      final firstItem = items.single as Map<String, dynamic>;
      expect(firstItem["mandatory"], isTrue);
    } finally {
      await fixture.delete();
    }
  });

  test("notarize flag is only accepted for macOS", () async {
    final fixture = await createReleasePublishFixture(
      config: """
updates:
  baseUrl: https://updates.example.com

macos:
  developerIdApplication: "Developer ID Application: Example Corp (TEAMID1234)"
  notaryProfile: desktop-updater-notary
  keychain: /Users/me/Library/Keychains/login.keychain-db
""",
    );
    try {
      final output = StringBuffer();

      final exitCode = await runReleaseCommand(
        [
          "publish",
          "--platform",
          "windows",
          "--skip-build-for-test",
          "--notarize",
        ],
        projectRoot: fixture.root,
        output: output,
      );

      expect(exitCode, 64);
      expect(
        output.toString(),
        contains("--notarize is only supported with --platform macos"),
      );
    } finally {
      await fixture.delete();
    }
  });

  test("release help lists doctor command", () async {
    final output = StringBuffer();

    final exitCode = await runReleaseCommand(
      const ["--help"],
      output: output,
    );

    expect(exitCode, 0);
    expect(
      output.toString(),
      contains("dart run desktop_updater:release doctor --platform macos"),
    );
  });
}

class ReleasePublishFixture {
  const ReleasePublishFixture(this.root, this.platform);

  final Directory root;
  final String platform;

  Future<void> delete() => root.delete(recursive: true);
}

Future<ReleasePublishFixture> createReleasePublishFixture({
  required String config,
}) async {
  final root = await Directory.systemTemp.createTemp("release_publish_");
  await writeReleasePublishFixtureProject(root: root, config: config);

  return ReleasePublishFixture(root, releasePublishFixturePlatform);
}
