import "dart:convert";
import "dart:io";

import "package:archive/archive_io.dart";
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

  test("publish writes support policy and fresh install flags", () async {
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
          "--minimum-supported-version",
          "2.4.0",
          "--enforced-after",
          "2026-07-15T00:00:00Z",
          "--fresh-install-url",
          "https://example.com/download/latest",
          "--fresh-install-message",
          "Install from a fresh download.",
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
      expect(archive["supportPolicy"], {
        "minimumSupportedVersion": "2.4.0",
        "enforcedAfter": "2026-07-15T00:00:00.000Z",
      });

      final items = archive["items"] as List<dynamic>;
      final firstItem = items.single as Map<String, dynamic>;
      expect(firstItem["mandatory"], isTrue);
      expect(firstItem["freshInstall"], {
        "downloadUrl": "https://example.com/download/latest",
        "message": "Install from a fresh download.",
      });
    } finally {
      await fixture.delete();
    }
  });

  test("publish rejects partial support policy flags", () async {
    final output = StringBuffer();

    final exitCode = await runReleaseCommand(
      const [
        "publish",
        "--platform",
        "macos",
        "--minimum-supported-version",
        "2.4.0",
      ],
      output: output,
    );

    expect(exitCode, 64);
    expect(
      output.toString(),
      contains("--minimum-supported-version and --enforced-after"),
    );
  });

  test("publish rejects fresh install message without URL", () async {
    final output = StringBuffer();

    final exitCode = await runReleaseCommand(
      const [
        "publish",
        "--platform",
        "macos",
        "--fresh-install-message",
        "Install from a fresh download.",
      ],
      output: output,
    );

    expect(exitCode, 64);
    expect(
      output.toString(),
      contains("--fresh-install-message requires --fresh-install-url"),
    );
  });

  test("publish accepts repeated dart define options", () async {
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
          "--dart-define",
          "MY_VAR=value",
          "--dart-define=FEATURE_FLAG=true",
          "--skip-build-for-test",
        ],
        projectRoot: fixture.root,
        output: output,
      );

      expect(exitCode, 0);
      expect(output.toString(), contains("Manual publish package is ready."));
    } finally {
      await fixture.delete();
    }
  });

  test("publish copies additional files into the packaged artifact", () async {
    final fixture = await createReleasePublishFixture(
      config: """
updates:
  baseUrl: https://updates.example.com

additionalFiles:
  - source: release-assets/manuals/*
    destination: docs/manuals
    platforms: [linux]
""",
    );
    try {
      final manuals = Directory(
        path.join(fixture.root.path, "release-assets", "manuals"),
      );
      await manuals.create(recursive: true);
      await File(path.join(manuals.path, "pilot-guide.pdf"))
          .writeAsString("manual");
      await File(path.join(manuals.path, "language-en.json"))
          .writeAsString("{}");
      final output = StringBuffer();

      final exitCode = await runReleaseCommand(
        ["publish", "--platform", fixture.platform, "--skip-build-for-test"],
        projectRoot: fixture.root,
        output: output,
      );

      expect(exitCode, 0);
      final artifact = File(
        path.join(
          fixture.root.path,
          "dist",
          "desktop_updater",
          "releases",
          "2.0.1",
          fixture.platform,
          "Release Fixture-2.0.1-${fixture.platform}.zip",
        ),
      );
      final archive = ZipDecoder().decodeBytes(await artifact.readAsBytes());
      final names = archive.files.map((file) => file.name).toSet();
      expect(names, contains("docs/manuals/pilot-guide.pdf"));
      expect(names, contains("docs/manuals/language-en.json"));
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

  test("publish help explains repeatable defines and mandatory behavior",
      () async {
    final output = StringBuffer();

    final exitCode = await runReleaseCommand(
      const ["publish", "--help"],
      output: output,
    );

    expect(exitCode, 0);
    expect(output.toString(), contains("--dart-define=<key=value>"));
    expect(output.toString(), contains("Repeat for multiple values."));
    expect(output.toString(), contains("--mandatory"));
    expect(output.toString(), contains("hides skip actions"));
    expect(output.toString(), contains("--minimum-supported-version"));
    expect(output.toString(), contains("--fresh-install-url"));
    expect(
      output.toString(),
      contains("keeps prompting until installed"),
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
