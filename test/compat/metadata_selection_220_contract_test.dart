import "dart:convert";
import "dart:io";

import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:desktop_updater/src/core/release_index.dart";
import "package:desktop_updater/src/version_info.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  test("2.2.0 app archive and release fixtures parse unchanged", () {
    final index = ReleaseIndex.fromJson(
      jsonDecode(
        File("fixtures/compat/app-archive.schema-v3.json").readAsStringSync(),
      ) as Map<String, dynamic>,
    );
    final descriptor = ReleaseDescriptor.fromJson(
      jsonDecode(
        File("fixtures/compat/release.schema-v3.json").readAsStringSync(),
      ) as Map<String, dynamic>,
    );

    expect(index.schemaVersion, 3);
    expect(descriptor.schemaVersion, 3);
    expect(index.items.single.version, descriptor.version);
    expect(index.items.single.buildNumber, descriptor.buildNumber);
    expect(index.items.single.platform, descriptor.platform);
    expect(index.items.single.channel, descriptor.channel);
    expect(index.items.single.toJson(), {
      "version": "2.2.0",
      "buildNumber": 220,
      "platform": "macos",
      "channel": "stable",
      "mandatory": false,
      "release":
          "https://updates.example.com/releases/2.2.0/macos/release.json",
    });
    expect(descriptor.toJson(), {
      "schemaVersion": 3,
      "packageId": "com.example.app",
      "appName": "Example.app",
      "version": "2.2.0",
      "buildNumber": 220,
      "platform": "macos",
      "channel": "stable",
      "artifact": {
        "kind": "zip",
        "url": "https://updates.example.com/releases/2.2.0/macos/Example.zip",
        "sha256":
            "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03",
        "length": 6,
      },
      "install": {"strategy": "wholeBundleReplace"},
      "minimumUpdaterVersion": "2.2.0",
      "minimumOS": {"macos": "13.0"},
      "generatedAt": "2026-06-16T00:00:00.000Z",
    });
    expect(
      jsonEncode(descriptor.toCanonicalSignatureJson()),
      contains('"artifact"'),
    );
  });

  test("2.2.0 version ordering fixture remains stable", () {
    final cases = jsonDecode(
      File("fixtures/compat/version-ordering.json").readAsStringSync(),
    ) as List<dynamic>;

    for (final entry in cases.cast<Map<String, dynamic>>()) {
      final candidate = DesktopVersionInfo.parse(
        entry["candidate"] as String,
      );
      final current = DesktopVersionInfo.parse(entry["current"] as String);

      expect(
        compareDesktopVersions(candidate, current).sign,
        entry["result"],
        reason: entry["case"] as String?,
      );
    }
  });

  test("2.2.0 rollout selection fixture remains stable", () {
    final fixture = jsonDecode(
      File("fixtures/compat/rollout-selection.json").readAsStringSync(),
    ) as Map<String, dynamic>;
    final index = ReleaseIndex.fromJson(
      fixture["index"] as Map<String, dynamic>,
    );
    final current = DesktopVersionInfo.parse(
      fixture["currentVersion"] as String,
    );

    for (final entry
        in (fixture["cases"] as List<dynamic>).cast<Map<String, dynamic>>()) {
      final selected = selectReleaseIndexItem(
        index: index,
        platform: entry["platform"] as String,
        channel: entry["channel"] as String,
        currentVersion: current,
        installationIdentity: entry["identity"] as String?,
      );

      expect(
        selected?.version,
        entry["selectedVersion"],
        reason: entry["case"] as String?,
      );
    }
  });
}
