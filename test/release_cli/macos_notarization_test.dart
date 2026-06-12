import "dart:io";

import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:desktop_updater/src/package/release_packager.dart";
import "package:desktop_updater/src/release_cli/release_publish_config.dart";
import "package:desktop_updater/src/release_cli/release_publisher.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;

void main() {
  test("macOS notarization runs before packaging when explicitly enabled",
      () async {
    final root = await _createMacOSFixture();
    final commands = <String>[];
    final packager = _RecordingPackager(commands);
    try {
      final publisher = ReleasePublisher(
        skipBuild: true,
        packager: packager,
        runProcess: (executable, arguments) async {
          commands.add([executable, ...arguments].join(" "));
          return ProcessResult(0, 0, "", "");
        },
      );

      await publisher.publish(
        projectRoot: root,
        platform: "macos",
        overrides: const ReleasePublishOverrides(),
        output: StringBuffer(),
      );

      expect(commands[0], contains("/usr/bin/codesign --force"));
      expect(
        commands[0],
        contains("Developer ID Application: Example Corp (TEAMID1234)"),
      );
      expect(commands[1], contains("/usr/bin/codesign --verify"));
      expect(commands[2], contains("/usr/bin/ditto -c -k --keepParent"));
      expect(commands[3], contains("/usr/bin/xcrun notarytool submit"));
      expect(
        commands[3],
        contains("--keychain-profile desktop-updater-notary"),
      );
      expect(
        commands[3],
        contains("--keychain /Users/me/Library/Keychains/login.keychain-db"),
      );
      expect(commands[4], contains("/usr/bin/xcrun stapler staple"));
      expect(commands[5], contains("/usr/bin/xcrun stapler validate"));
      expect(commands[6], contains("/usr/sbin/spctl --assess"));
      expect(commands[7], startsWith("PACKAGE "));
    } finally {
      await root.delete(recursive: true);
    }
  });
}

Future<Directory> _createMacOSFixture() async {
  final root = await Directory.systemTemp.createTemp("notarize_publish_");
  await File(path.join(root.path, "pubspec.yaml")).writeAsString("""
name: notarize_fixture
version: 2.0.1+201
""");
  await File(path.join(root.path, "desktop_updater.yaml")).writeAsString("""
updates:
  baseUrl: https://updates.example.com

macos:
  notarize: true
  developerIdApplication: "Developer ID Application: Example Corp (TEAMID1234)"
  notaryProfile: desktop-updater-notary
  keychain: /Users/me/Library/Keychains/login.keychain-db
""");

  final configs = Directory(path.join(root.path, "macos", "Runner", "Configs"));
  await configs.create(recursive: true);
  await File(path.join(configs.path, "AppInfo.xcconfig")).writeAsString("""
PRODUCT_NAME = Notarize Fixture
PRODUCT_BUNDLE_IDENTIFIER = com.example.notarizeFixture
""");

  final app = Directory(
    path.join(
      root.path,
      "build",
      "macos",
      "Build",
      "Products",
      "Release",
      "Notarize Fixture.app",
    ),
  );
  await app.create(recursive: true);
  await File(path.join(app.path, "app.txt")).writeAsString("hello");

  return root;
}

class _RecordingPackager implements ReleasePackager {
  _RecordingPackager(this.commands);

  final List<String> commands;

  @override
  Future<ReleasePackageResult> package(ReleasePackageRequest request) async {
    commands.add("PACKAGE ${request.input.path}");
    await request.outputDirectory.create(recursive: true);
    final artifact = File(
      path.join(request.outputDirectory.path, "Notarize-2.0.1-macos.zip"),
    );
    await artifact.writeAsString("zip");
    final release =
        File(path.join(request.outputDirectory.path, "release.json"));
    final descriptor = ReleaseDescriptor(
      schemaVersion: 3,
      packageId: request.packageId,
      appName: request.appName,
      version: request.version,
      buildNumber: request.buildNumber,
      platform: request.platform,
      channel: request.channel,
      artifact: ReleaseArtifact(
        kind: "zip",
        url: request.artifactUrl,
        sha256: "a" * 64,
        length: await artifact.length(),
      ),
      install: ReleaseInstall(strategy: request.installStrategy),
      minimumUpdaterVersion: request.minimumUpdaterVersion,
      generatedAt: DateTime.utc(2026, 6, 12),
    );
    await release.writeAsString("{}");
    return ReleasePackageResult(
      artifact: artifact,
      releaseFile: release,
      descriptor: descriptor,
    );
  }
}
