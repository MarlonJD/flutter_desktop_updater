import "dart:io";

import "package:path/path.dart" as path;

const releasePublishFixturePlatform = "linux";

Future<void> writeReleasePublishFixtureProject({
  required Directory root,
  required String config,
}) async {
  await File(path.join(root.path, "pubspec.yaml")).writeAsString("""
name: release_fixture
version: 2.0.1+201
""");
  await File(path.join(root.path, "desktop_updater.yaml"))
      .writeAsString(config);

  await _writeMacosFixture(root);
  await _writeLinuxFixture(root);
  await _writeWindowsFixture(root);
}

Future<void> _writeMacosFixture(Directory root) async {
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
}

Future<void> _writeLinuxFixture(Directory root) async {
  final linuxRoot = Directory(path.join(root.path, "linux"));
  await linuxRoot.create(recursive: true);
  await File(path.join(linuxRoot.path, "CMakeLists.txt")).writeAsString("""
set(APPLICATION_ID "com.example.release_fixture")
""");

  final bundle = Directory(
    path.join(
      root.path,
      "build",
      "linux",
      "x64",
      "release",
      "bundle",
    ),
  );
  await bundle.create(recursive: true);
  await File(path.join(bundle.path, "app.txt")).writeAsString("hello");
}

Future<void> _writeWindowsFixture(Directory root) async {
  final releaseDir = Directory(
    path.join(
      root.path,
      "build",
      "windows",
      "x64",
      "runner",
      "Release",
    ),
  );
  await releaseDir.create(recursive: true);
  await File(path.join(releaseDir.path, "app.txt")).writeAsString("hello");
}
