import "package:desktop_updater/src/core/release_index.dart";
import "package:desktop_updater/src/version_info.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  test("parses a schema v3 release index", () {
    final index = ReleaseIndex.fromJson({
      "schemaVersion": 3,
      "appName": "Example App",
      "items": [
        {
          "version": "2.0.0",
          "buildNumber": 200,
          "platform": "macos",
          "channel": "stable",
          "mandatory": false,
          "release": "https://updates.example.com/release.json",
        },
      ],
    });

    expect(index.schemaVersion, 3);
    expect(index.items.single.release.path, "/release.json");
  });

  test("rejects indexes without the 2.x schema", () {
    expect(
      () => ReleaseIndex.fromJson({
        "appName": "Example App",
        "items": [
          {
            "version": "1.4.0",
            "shortVersion": 140,
            "platform": "linux",
            "mandatory": false,
            "url": "https://updates.example.com/linux/",
          },
        ],
      }),
      throwsFormatException,
    );
  });

  test("keeps buildNumber optional in schema v3 indexes", () {
    final index = ReleaseIndex.fromJson({
      "schemaVersion": 3,
      "appName": "Example App",
      "items": [
        {
          "version": "2.0.0",
          "platform": "linux",
          "channel": "stable",
          "mandatory": false,
          "release": "https://updates.example.com/linux.json",
        },
      ],
    });

    expect(index.items.single.buildNumber, isNull);
    expect(index.items.single.toJson(), isNot(contains("buildNumber")));
  });

  test("rejects schema v3 items without release", () {
    expect(
      () => ReleaseIndex.fromJson({
        "schemaVersion": 3,
        "appName": "Example App",
        "items": [
          {
            "version": "2.0.0",
            "buildNumber": 200,
            "platform": "macos",
            "channel": "stable",
            "mandatory": false,
          },
        ],
      }),
      throwsFormatException,
    );
  });

  test("ignores unsupported platforms and downgrades", () {
    final index = ReleaseIndex.fromJson({
      "schemaVersion": 3,
      "appName": "Example App",
      "items": [
        {
          "version": "1.0.0",
          "buildNumber": 1,
          "platform": "macos",
          "channel": "stable",
          "mandatory": false,
          "release": "https://updates.example.com/old.json",
        },
        {
          "version": "3.0.0",
          "buildNumber": 300,
          "platform": "windows",
          "channel": "stable",
          "mandatory": false,
          "release": "https://updates.example.com/windows.json",
        },
      ],
    });

    final selected = selectReleaseIndexItem(
      index: index,
      platform: "macos",
      currentVersion: DesktopVersionInfo.fromParts(
        versionName: "2.0.0",
        buildNumber: "200",
      ),
    );

    expect(selected, isNull);
  });
}
