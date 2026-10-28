import "package:desktop_updater/src/release_cli/macos/macos_artifact_config.dart";
import "package:desktop_updater/src/release_cli/release_publish_config.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  MacOSDmgPublishConfig config(String? fileName) => MacOSDmgPublishConfig(
        volumeName: "Example",
        appBundleName: "Example.app",
        applicationsAlias: true,
        fileName: fileName,
      );

  String resolve(MacOSDmgPublishConfig config, {int? buildNumber = 1}) =>
      config.resolveFileName(
        appName: "Example.app",
        version: "1.0.0",
        buildNumber: buildNumber,
        platform: "macos",
      );

  test("preserves the default DMG filename", () {
    expect(resolve(config(null)), "Example-1.0.0-macos.dmg");
  });

  test("expands DMG filename placeholders without renaming the app", () {
    final configured =
        config("{appName}-v{version}({buildNumber})-{platform}.dmg")
            .resolveDefaultsForAppName("Another App");
    expect(resolve(configured), "Example-v1.0.0(1)-macos.dmg");
    expect(configured.appBundleName, "Example.app");
    expect(resolve(config("Custom Installer.dmg"), buildNumber: null),
        "Custom Installer.dmg");
  });

  test("requires build metadata only when the filename requests it", () {
    expect(resolve(config(null), buildNumber: null), "Example-1.0.0-macos.dmg");
    expect(
      () => resolve(config("Example-{buildNumber}.dmg"), buildNumber: null),
      throwsA(isA<FormatException>()),
    );
  });

  for (final fileName in [
    "",
    "../escape.dmg",
    r"..\escape.dmg",
    "/tmp/escape.dmg",
    "Example.zip",
    ".dmg",
    "Example.dmg ",
    "Example\n.dmg",
    "Example%2Fescape.dmg",
    "{unknown}.dmg",
    "{version.dmg",
    "Example?.dmg",
    "Example:stream.dmg",
  ]) {
    test("rejects unsafe or unresolved DMG filename $fileName", () {
      expect(() => resolve(config(fileName)), throwsA(isA<FormatException>()));
    });
  }

  test("validates expanded metadata as well as the template", () {
    expect(
      () => config("Example-{version}.dmg").resolveFileName(
        appName: "Example.app",
        version: "../../outside",
        buildNumber: 1,
        platform: "macos",
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test("loads a custom DMG filename from YAML", () async {
    final loaded = await ReleasePublishConfig.fromYaml('''
updates:
  baseUrl: https://updates.example.com
macos:
  artifact:
    kind: dmg
  dmg:
    fileName: "xxx-v{version}({buildNumber})-{platform}.dmg"
''');
    expect(resolve(loaded.macos.dmg), "xxx-v1.0.0(1)-macos.dmg");
    expect(loaded.macos.dmg.resolveDefaultsForAppName("Example.app").fileName,
        loaded.macos.dmg.fileName);
  });

  for (final value in [
    '"../outside.dmg"',
    '"{unknown}.dmg"',
    '""',
    '123',
    '[]'
  ]) {
    test("rejects invalid YAML DMG filename $value before building", () async {
      await expectLater(
        ReleasePublishConfig.fromYaml('''
updates:
  baseUrl: https://updates.example.com
macos:
  dmg:
    fileName: $value
'''),
        throwsA(isA<FormatException>()),
      );
    });
  }
}
