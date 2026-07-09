import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  test("parses a valid release descriptor", () {
    final descriptor = ReleaseDescriptor.fromJson(_descriptorJson());

    expect(descriptor.schemaVersion, 3);
    expect(descriptor.artifact.kind, "zip");
    expect(descriptor.install.strategy, "wholeBundleReplace");
  });

  test("parses a Windows Inno installer descriptor", () {
    final descriptor = ReleaseDescriptor.fromJson({
      ..._descriptorJson(),
      "appName": "Example",
      "platform": "windows",
      "artifact": {
        "kind": "innoInstaller",
        "url": "https://cdn.example.com/Example-2.5.0-setup.exe",
        "sha256": "b" * 64,
        "length": 42,
      },
      "install": {
        "strategy": "innoInstaller",
        "inno": {
          "silentArgs": ["/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART"],
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
      "minimumUpdaterVersion": "2.5.0",
    });

    expect(descriptor.artifact.kind, "innoInstaller");
    expect(descriptor.install.strategy, "innoInstaller");
    expect(descriptor.install.inno, isNotNull);
    expect(descriptor.install.inno!.silentArgs, [
      "/VERYSILENT",
      "/SUPPRESSMSGBOXES",
      "/NORESTART",
    ]);
    expect(descriptor.install.inno!.inheritInstallDirectory, isTrue);
    expect(descriptor.install.inno!.requiresElevation, "auto");
    expect(descriptor.install.inno!.authenticode.required, isTrue);
    expect(descriptor.toJson()["install"], {
      "strategy": "innoInstaller",
      "inno": {
        "silentArgs": ["/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART"],
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
    });
  });

  test("parses a macOS DMG update descriptor", () {
    final descriptor = ReleaseDescriptor.fromJson({
      ..._descriptorJson(),
      "platform": "macos",
      "artifact": {
        "kind": "dmg",
        "url": "https://cdn.example.com/Example-2.6.0.dmg",
        "sha256": "b" * 64,
        "length": 42,
      },
      "install": {
        "strategy": "wholeBundleReplace",
        "macosDmg": {
          "appBundleName": "Example.app",
          "verifyPrimarySignature": true,
        },
      },
      "minimumUpdaterVersion": "2.6.0",
    });

    expect(descriptor.artifact.kind, "dmg");
    expect(descriptor.install.strategy, "wholeBundleReplace");
    expect(descriptor.install.macosDmg!.appBundleName, "Example.app");
    expect(descriptor.install.macosDmg!.verifyPrimarySignature, isTrue);
  });

  test("parses a macOS PKG installer descriptor", () {
    final descriptor = ReleaseDescriptor.fromJson({
      ..._descriptorJson(),
      "platform": "macos",
      "artifact": {
        "kind": "pkgInstaller",
        "url": "https://cdn.example.com/Example-2.6.0.pkg",
        "sha256": "c" * 64,
        "length": 43,
      },
      "install": {
        "strategy": "pkgInstaller",
        "macosPkg": {
          "launchMode": "installerApp",
          "expectedPackageIds": ["com.example.app.pkg"],
          "relaunchAfterInstall": false,
        },
      },
      "minimumUpdaterVersion": "2.6.0",
    });

    expect(descriptor.artifact.kind, "pkgInstaller");
    expect(descriptor.install.strategy, "pkgInstaller");
    expect(descriptor.install.macosPkg!.launchMode, "installerApp");
    expect(descriptor.install.macosPkg!.expectedPackageIds, [
      "com.example.app.pkg",
    ]);
    expect(descriptor.install.macosPkg!.relaunchAfterInstall, isFalse);
  });

  test("rejects Inno installer descriptors without Windows platform", () {
    final json = {
      ..._descriptorJson(),
      "platform": "linux",
      "artifact": {
        "kind": "innoInstaller",
        "url": "https://cdn.example.com/Example-2.5.0-setup.exe",
        "sha256": "b" * 64,
        "length": 42,
      },
      "install": {
        "strategy": "innoInstaller",
        "inno": {
          "silentArgs": ["/VERYSILENT"],
          "requiresElevation": "auto",
        },
      },
    };

    expect(
      () => ReleaseDescriptor.fromJson(json),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          "message",
          contains("innoInstaller is only supported for windows"),
        ),
      ),
    );
  });

  test("rejects DMG artifacts outside macOS whole-bundle replacement", () {
    final json = {
      ..._descriptorJson(),
      "platform": "windows",
      "artifact": {
        "kind": "dmg",
        "url": "https://cdn.example.com/Example.dmg",
        "sha256": "b" * 64,
        "length": 42,
      },
      "install": {"strategy": "wholeBundleReplace"},
    };

    expect(
      () => ReleaseDescriptor.fromJson(json),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          "message",
          contains("dmg artifacts are only supported for macos"),
        ),
      ),
    );
  });

  test("rejects PKG artifacts without pkgInstaller strategy", () {
    final json = {
      ..._descriptorJson(),
      "platform": "macos",
      "artifact": {
        "kind": "pkgInstaller",
        "url": "https://cdn.example.com/Example.pkg",
        "sha256": "c" * 64,
        "length": 43,
      },
      "install": {"strategy": "wholeBundleReplace"},
    };

    expect(
      () => ReleaseDescriptor.fromJson(json),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          "message",
          contains(
            "pkgInstaller artifacts require install.strategy pkgInstaller",
          ),
        ),
      ),
    );
  });

  test("rejects pkgInstaller strategy without PKG artifact", () {
    final json = {
      ..._descriptorJson(),
      "platform": "macos",
      "artifact": {
        "kind": "zip",
        "url": "https://cdn.example.com/Example.zip",
        "sha256": "a" * 64,
        "length": 12,
      },
      "install": {
        "strategy": "pkgInstaller",
        "macosPkg": {
          "launchMode": "installerApp",
          "expectedPackageIds": ["com.example.app.pkg"],
        },
      },
    };

    expect(
      () => ReleaseDescriptor.fromJson(json),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          "message",
          contains(
            "pkgInstaller strategy is only supported for pkgInstaller "
            "artifacts",
          ),
        ),
      ),
    );
  });

  test("rejects Inno installer descriptors without Inno install metadata", () {
    final json = {
      ..._descriptorJson(),
      "platform": "windows",
      "artifact": {
        "kind": "innoInstaller",
        "url": "https://cdn.example.com/Example-2.5.0-setup.exe",
        "sha256": "b" * 64,
        "length": 42,
      },
      "install": {"strategy": "innoInstaller"},
    };

    expect(
      () => ReleaseDescriptor.fromJson(json),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          "message",
          contains("install.inno is required"),
        ),
      ),
    );
  });

  test("rejects missing artifact fields", () {
    final json = _descriptorJson()..remove("artifact");

    expect(
      () => ReleaseDescriptor.fromJson(json),
      throwsFormatException,
    );
  });

  test("keeps buildNumber optional in release descriptors", () {
    final descriptor = ReleaseDescriptor.fromJson(
      _descriptorJson()..remove("buildNumber"),
    );

    expect(descriptor.buildNumber, isNull);
    expect(descriptor.toJson(), isNot(contains("buildNumber")));
  });

  test("canonical signature json empties signature value", () {
    final descriptor = ReleaseDescriptor.fromJson({
      ..._descriptorJson(),
      "signature": {
        "algorithm": "ed25519",
        "publicKeyId": "stable-2026-06",
        "value": "abc",
      },
    });

    final signature = descriptor.toCanonicalSignatureJson()["signature"]
        as Map<String, dynamic>;
    expect(signature["value"], "");
  });

  test("parses optional minimum OS metadata", () {
    final descriptor = ReleaseDescriptor.fromJson({
      ..._descriptorJson(),
      "minimumOS": {
        "macos": "13.0",
        "windows": "10.0.19045",
        "linux": "glibc-2.35",
      },
    });

    expect(descriptor.minimumOS["macos"], "13.0");
    expect(descriptor.minimumOSForPlatform("linux"), "glibc-2.35");
    expect(descriptor.minimumOSForPlatform("freebsd"), isNull);
    expect(descriptor.toJson()["minimumOS"], {
      "macos": "13.0",
      "windows": "10.0.19045",
      "linux": "glibc-2.35",
    });
  });

  test("omits minimum OS when descriptor metadata does not provide it", () {
    final descriptor = ReleaseDescriptor.fromJson(_descriptorJson());

    expect(descriptor.minimumOS, isEmpty);
    expect(descriptor.toJson(), isNot(contains("minimumOS")));
  });

  test("parses optional delta artifact metadata behind unsupported gate", () {
    final descriptor = ReleaseDescriptor.fromJson({
      ..._descriptorJson(),
      "deltaArtifacts": [
        {
          "fromVersion": "2.1.4",
          "kind": "bsdiff",
          "url": "https://cdn.example.com/2.1.4-to-2.2.0.patch",
          "sha256": "b" * 64,
          "length": 456,
        },
      ],
    });

    final delta = descriptor.deltaArtifacts.single;
    expect(delta.fromVersion, "2.1.4");
    expect(delta.kind, "bsdiff");
    expect(
      delta.url,
      Uri.parse("https://cdn.example.com/2.1.4-to-2.2.0.patch"),
    );
    expect(delta.sha256, "b" * 64);
    expect(delta.length, 456);
    expect(descriptor.toJson()["deltaArtifacts"], [
      {
        "fromVersion": "2.1.4",
        "kind": "bsdiff",
        "url": "https://cdn.example.com/2.1.4-to-2.2.0.patch",
        "sha256": "b" * 64,
        "length": 456,
      },
    ]);
    expect(delta.ensureRuntimeSupported, throwsUnsupportedError);
  });
}

Map<String, dynamic> _descriptorJson() {
  return {
    "schemaVersion": 3,
    "packageId": "com.example.app",
    "appName": "Example.app",
    "version": "2.0.0",
    "buildNumber": 200,
    "platform": "macos",
    "channel": "stable",
    "artifact": {
      "kind": "zip",
      "url": "https://cdn.example.com/Example.zip",
      "sha256": "a" * 64,
      "length": 12,
    },
    "install": {"strategy": "wholeBundleReplace"},
    "minimumUpdaterVersion": "2.0.0",
    "generatedAt": "2026-06-11T00:00:00Z",
  };
}
