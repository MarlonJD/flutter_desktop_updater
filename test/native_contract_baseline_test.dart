import "dart:io";

import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  test("schema v3 keeps the complete desktop artifact baseline", () {
    final descriptors = <ReleaseDescriptor>[
      _descriptor(
        platform: "linux",
        artifactKind: "zip",
        install: const {"strategy": "wholeDirectoryReplace"},
      ),
      _descriptor(
        platform: "macos",
        artifactKind: "dmg",
        install: const {
          "strategy": "wholeBundleReplace",
          "macosDmg": {
            "appBundleName": "Example.app",
            "verifyPrimarySignature": true,
          },
        },
      ),
      _descriptor(
        platform: "macos",
        artifactKind: "pkgInstaller",
        install: const {
          "strategy": "pkgInstaller",
          "macosPkg": {
            "launchMode": "privilegedInstallerTool",
            "expectedPackageIds": ["com.example.app.pkg"],
            "relaunchAfterInstall": false,
          },
        },
      ),
      _descriptor(
        platform: "windows",
        artifactKind: "innoInstaller",
        install: const {
          "strategy": "innoInstaller",
          "inno": {
            "silentArgs": ["/VERYSILENT", "/NORESTART"],
            "inheritInstallDirectory": true,
            "logFileName": "desktop_updater_inno_install.log",
            "relaunchAfterInstall": true,
            "requiresElevation": "auto",
            "authenticode": {
              "required": true,
              "sha256Thumbprints": [
                "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF",
              ],
            },
          },
        },
      ),
    ];

    expect(
      descriptors.map((descriptor) => descriptor.artifact.kind),
      ["zip", "dmg", "pkgInstaller", "innoInstaller"],
    );
    for (final descriptor in descriptors) {
      expect(descriptor.schemaVersion, 3);
      expect(descriptor.buildNumber, isA<int>());
      expect(descriptor.install.strategy, isNotEmpty);
      expect(descriptor.minimumUpdaterVersion, isNotEmpty);
    }
  });

  test("native contract documents trust and Linux safety boundaries", () {
    final contract = File("docs/native-contract.md").readAsStringSync();

    expect(contract, contains("schema version 3"));
    expect(contract, contains("app-archive.json"));
    expect(contract, contains("not signed"));
    expect(contract, contains("publicKeyId"));
    expect(contract, contains("wholeBundleReplace"));
    expect(contract, contains("innoInstaller"));
    expect(contract, contains("protected shared/system roots"));
    expect(contract, contains("fresh installer"));
  });
}

ReleaseDescriptor _descriptor({
  required String platform,
  required String artifactKind,
  required Map<String, Object?> install,
}) {
  return ReleaseDescriptor.fromJson({
    "schemaVersion": 3,
    "packageId": "com.example.app",
    "appName": "Example",
    "version": "2.7.0",
    "buildNumber": 270,
    "platform": platform,
    "channel": "stable",
    "artifact": {
      "kind": artifactKind,
      "url": "https://updates.example.test/Example-$artifactKind",
      "sha256": "a" * 64,
      "length": 42,
    },
    "install": install,
    "minimumUpdaterVersion": "2.7.0",
    "generatedAt": "2026-07-10T00:00:00Z",
  });
}
