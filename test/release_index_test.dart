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

  test("parses optional rollout metadata on schema v3 index items", () {
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
          "rollout": {"percentage": 25, "salt": "stable-2026-06"},
        },
      ],
    });

    final rollout = index.items.single.rollout;
    expect(rollout, isNotNull);
    expect(rollout!.percentage, 25);
    expect(rollout.salt, "stable-2026-06");
    expect(index.items.single.toJson()["rollout"], {
      "percentage": 25,
      "salt": "stable-2026-06",
    });
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

  test("skips partial rollout items without identity and allows full rollout",
      () {
    final index = ReleaseIndex(
      schemaVersion: 3,
      appName: "Example App",
      items: [
        ReleaseIndexItem(
          version: "2.2.0",
          buildNumber: 220,
          platform: "macos",
          channel: "stable",
          mandatory: false,
          release: Uri.parse("https://updates.example.com/full.json"),
          rollout: const ReleaseRollout(
            percentage: 100,
            salt: "stable-2026-06",
          ),
        ),
        ReleaseIndexItem(
          version: "2.1.0",
          buildNumber: 210,
          platform: "macos",
          channel: "stable",
          mandatory: false,
          release: Uri.parse("https://updates.example.com/partial.json"),
          rollout: const ReleaseRollout(
            percentage: 25,
            salt: "stable-2026-06",
          ),
        ),
        ReleaseIndexItem(
          version: "2.0.1",
          buildNumber: 201,
          platform: "macos",
          channel: "stable",
          mandatory: false,
          release: Uri.parse("https://updates.example.com/general.json"),
        ),
      ],
    );

    final selected = selectReleaseIndexItem(
      index: index,
      platform: "macos",
      currentVersion: DesktopVersionInfo.fromParts(
        versionName: "2.0.0",
        buildNumber: "200",
      ),
    );

    expect(selected!.version, "2.2.0");
  });

  test(
      "selects partial rollout items deterministically by identity and channel",
      () {
    final index = ReleaseIndex(
      schemaVersion: 3,
      appName: "Example App",
      items: [
        ReleaseIndexItem(
          version: "2.1.0",
          buildNumber: 210,
          platform: "macos",
          channel: "stable",
          mandatory: false,
          release: Uri.parse("https://updates.example.com/partial.json"),
          rollout: const ReleaseRollout(
            percentage: 25,
            salt: "stable-2026-06",
          ),
        ),
        ReleaseIndexItem(
          version: "2.1.0",
          buildNumber: 210,
          platform: "macos",
          channel: "beta",
          mandatory: false,
          release: Uri.parse("https://updates.example.com/beta-partial.json"),
          rollout: const ReleaseRollout(
            percentage: 25,
            salt: "stable-2026-06",
          ),
        ),
      ],
    );
    final currentVersion = DesktopVersionInfo.fromParts(
      versionName: "2.0.0",
      buildNumber: "200",
    );

    final first = selectReleaseIndexItem(
      index: index,
      platform: "macos",
      currentVersion: currentVersion,
      installationIdentity: "pilot-a",
    );
    final second = selectReleaseIndexItem(
      index: index,
      platform: "macos",
      currentVersion: currentVersion,
      installationIdentity: "pilot-a",
    );
    final differentChannel = selectReleaseIndexItem(
      index: index,
      platform: "macos",
      currentVersion: currentVersion,
      channel: "beta",
      installationIdentity: "pilot-a",
    );
    final outsideRollout = selectReleaseIndexItem(
      index: index,
      platform: "macos",
      currentVersion: currentVersion,
      installationIdentity: "device-1",
    );

    expect(first, isNotNull);
    expect(second, same(first));
    expect(differentChannel, isNull);
    expect(outsideRollout, isNull);
  });
}
