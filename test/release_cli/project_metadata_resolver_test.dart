import "dart:io";

import "package:desktop_updater/src/release_cli/platform_release_profile.dart";
import "package:desktop_updater/src/release_cli/project_metadata_resolver.dart";
import "package:desktop_updater/src/release_cli/release_publish_config.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;

void main() {
  test("resolves version and build number from pubspec", () async {
    final fixture = await createReleaseFixture(
      pubspecVersion: "2.0.1+201",
      platform: "macos",
    );
    try {
      final metadata = await const ProjectMetadataResolver().resolve(
        projectRoot: fixture.root,
        platform: "macos",
        overrides: const ReleasePublishOverrides(),
      );

      expect(metadata.version, "2.0.1");
      expect(metadata.buildNumber, 201);
    } finally {
      await fixture.delete();
    }
  });

  test("version override replaces pubspec version and build number", () async {
    final fixture = await createReleaseFixture(
      pubspecVersion: "2.0.1+201",
      platform: "macos",
    );
    try {
      final metadata = await const ProjectMetadataResolver().resolve(
        projectRoot: fixture.root,
        platform: "macos",
        overrides: const ReleasePublishOverrides(
          version: "2.1.0",
          buildNumber: 210,
        ),
      );

      expect(metadata.version, "2.1.0");
      expect(metadata.buildNumber, 210);
    } finally {
      await fixture.delete();
    }
  });

  test("build number override replaces pubspec build metadata", () async {
    final fixture = await createReleaseFixture(
      pubspecVersion: "2.0.1+201",
      platform: "macos",
    );
    try {
      final metadata = await const ProjectMetadataResolver().resolve(
        projectRoot: fixture.root,
        platform: "macos",
        overrides: const ReleasePublishOverrides(buildNumber: 210),
      );

      expect(metadata.version, "2.0.1");
      expect(metadata.buildNumber, 210);
    } finally {
      await fixture.delete();
    }
  });

  test("macOS metadata comes from AppInfo.xcconfig", () async {
    final fixture = await createReleaseFixture(
      pubspecVersion: "2.0.1",
      platform: "macos",
    );
    try {
      final metadata = await const ProjectMetadataResolver().resolve(
        projectRoot: fixture.root,
        platform: "macos",
        overrides: const ReleasePublishOverrides(),
      );

      expect(metadata.packageId, "com.example.releaseFixture");
      expect(metadata.appName, "Release Fixture.app");
    } finally {
      await fixture.delete();
    }
  });

  test("macOS profile uses Release app bundle output", () async {
    final profile = PlatformReleaseProfile.forPlatform("macos");

    expect(profile.flutterBuildArgs, ["build", "macos", "--release"]);
    expect(
      profile.defaultInputPath("Example"),
      endsWith("build/macos/Build/Products/Release/Example.app"),
    );
    expect(profile.installStrategy, "wholeBundleReplace");
  });
}

class ReleaseFixture {
  const ReleaseFixture(this.root);

  final Directory root;

  Future<void> delete() => root.delete(recursive: true);
}

Future<ReleaseFixture> createReleaseFixture({
  required String pubspecVersion,
  required String platform,
}) async {
  final root = await Directory.systemTemp.createTemp("release_fixture_");
  await File(path.join(root.path, "pubspec.yaml")).writeAsString("""
name: release_fixture
version: $pubspecVersion
""");

  if (platform == "macos") {
    final configs = Directory(
      path.join(root.path, "macos", "Runner", "Configs"),
    );
    await configs.create(recursive: true);
    await File(path.join(configs.path, "AppInfo.xcconfig")).writeAsString("""
PRODUCT_NAME = Release Fixture
PRODUCT_BUNDLE_IDENTIFIER = com.example.releaseFixture
""");
  }

  return ReleaseFixture(root);
}
