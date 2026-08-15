import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  test("parses a valid release descriptor", () {
    final descriptor = ReleaseDescriptor.fromJson(_descriptorJson());

    expect(descriptor.schemaVersion, 3);
    expect(descriptor.artifact.kind, "zip");
    expect(descriptor.install.strategy, "wholeBundleReplace");
  });

  test("normalizes descriptor identity and install strategy", () {
    final descriptor = ReleaseDescriptor.fromJson({
      ..._descriptorJson(),
      "packageId": " com.example.app ",
      "version": " 2.0.0 ",
      "platform": " macos ",
      "channel": " stable ",
      "install": {"strategy": " wholeBundleReplace "},
    });

    expect(descriptor.packageId, "com.example.app");
    expect(descriptor.version, "2.0.0");
    expect(descriptor.platform, "macos");
    expect(descriptor.channel, "stable");
    expect(descriptor.install.strategy, "wholeBundleReplace");
    expect(
      descriptor.toCanonicalSignatureJson(),
      containsPair("packageId", "com.example.app"),
    );
    expect(
      descriptor.toCanonicalSignatureJson()["install"],
      {"strategy": "wholeBundleReplace"},
    );
  });

  test("rejects a blank app name", () {
    expect(
      () => ReleaseDescriptor.fromJson({
        ..._descriptorJson(),
        "appName": " \n ",
      }),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          "message",
          contains("appName is required"),
        ),
      ),
    );
  });

  test("parses a Windows Inno installer descriptor", () {
    final descriptor = ReleaseDescriptor.fromJson(_innoDescriptorJson());

    expect(descriptor.artifact.kind, "innoInstaller");
    expect(descriptor.install.strategy, "innoInstaller");
    expect(descriptor.install.inno, isNotNull);
    expect(descriptor.install.inno!.silentArgs, [
      "/VERYSILENT",
      "/SUPPRESSMSGBOXES",
      "/NORESTART",
    ]);
    expect(descriptor.install.inno!.inheritInstallDirectory, isTrue);
    expect(
      descriptor.install.inno!.installedExecutableRelativePath,
      "Example.exe",
    );
    expect(descriptor.install.inno!.installedExecutableSha256, "c" * 64);
    expect(descriptor.install.inno!.requiresElevation, "always");
    expect(descriptor.install.inno!.authenticode.required, isTrue);
    expect(descriptor.toJson()["install"], {
      "strategy": "innoInstaller",
      "inno": {
        "silentArgs": ["/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART"],
        "inheritInstallDirectory": true,
        "installedExecutableRelativePath": "Example.exe",
        "installedExecutableSha256": "c" * 64,
        "logFileName": "desktop_updater_inno_install.log",
        "relaunchAfterInstall": true,
        "requiresElevation": "always",
        "authenticode": {
          "required": true,
          "sha256Thumbprints": [
            "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF",
          ],
        },
      },
    });
  });

  test("rejects Inno descriptors without protected elevation", () {
    final json = _innoDescriptorJson();
    final install = json["install"]! as Map<String, dynamic>;
    final inno = install["inno"]! as Map<String, dynamic>;
    inno["requiresElevation"] = "auto";

    expect(
      () => ReleaseDescriptor.fromJson(json),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          "message",
          contains("requires protected elevation"),
        ),
      ),
    );
  });

  test("rejects Inno descriptors without required Authenticode", () {
    final json = _innoDescriptorJson();
    final install = json["install"]! as Map<String, dynamic>;
    final inno = install["inno"]! as Map<String, dynamic>;
    final authenticode = inno["authenticode"]! as Map<String, dynamic>;
    authenticode["required"] = false;

    expect(
      () => ReleaseDescriptor.fromJson(json),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          "message",
          contains("requires Authenticode"),
        ),
      ),
    );
  });

  test("rejects Inno metadata without an exact installed executable", () {
    expect(
      () => ReleaseDescriptor.fromJson({
        ..._descriptorJson(),
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
            "silentArgs": ["/VERYSILENT", "/NORESTART"],
            "inheritInstallDirectory": true,
            "logFileName": "desktop_updater_inno_install.log",
            "relaunchAfterInstall": true,
            "requiresElevation": "always",
            "authenticode": {
              "required": true,
              "sha256Thumbprints": ["a" * 64],
            },
          },
        },
        "minimumUpdaterVersion": "2.5.0",
      }),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          "message",
          contains("installedExecutable"),
        ),
      ),
    );
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
          "launchMode": "privilegedInstallerTool",
          "expectedPackageIds": ["com.example.app.pkg"],
          "relaunchAfterInstall": false,
        },
      },
      "minimumUpdaterVersion": "2.6.0",
    });

    expect(descriptor.artifact.kind, "pkgInstaller");
    expect(descriptor.install.strategy, "pkgInstaller");
    expect(
      descriptor.install.macosPkg!.launchMode,
      "privilegedInstallerTool",
    );
    expect(descriptor.install.macosPkg!.expectedPackageIds, [
      "com.example.app.pkg",
    ]);
    expect(descriptor.install.macosPkg!.relaunchAfterInstall, isFalse);
  });

  test("normalizes the schema-v3 legacy PKG launch token", () {
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

    expect(
      descriptor.install.macosPkg!.launchMode,
      "privilegedInstallerTool",
    );
    expect(
      descriptor.toJson()["install"],
      containsPair(
        "macosPkg",
        containsPair("launchMode", "installerApp"),
      ),
    );
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
          "launchMode": "privilegedInstallerTool",
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

  test("rejects non-absolute artifact URLs", () {
    final json = _descriptorJson();
    (json["artifact"]! as Map<String, dynamic>)["url"] = "relative/update.zip";

    expect(
      () => ReleaseDescriptor.fromJson(json),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          "message",
          contains("artifact.url must be absolute"),
        ),
      ),
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

  test("rejects non-absolute delta artifact URLs", () {
    final json = {
      ..._descriptorJson(),
      "deltaArtifacts": [
        {
          "fromVersion": "2.1.4",
          "kind": "bsdiff",
          "url": "relative/update.patch",
          "sha256": "b" * 64,
          "length": 456,
        },
      ],
    };

    expect(
      () => ReleaseDescriptor.fromJson(json),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          "message",
          contains("deltaArtifacts.url must be absolute"),
        ),
      ),
    );
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

Map<String, dynamic> _innoDescriptorJson() {
  return {
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
        "installedExecutableRelativePath": "Example.exe",
        "installedExecutableSha256": "c" * 64,
        "logFileName": "desktop_updater_inno_install.log",
        "relaunchAfterInstall": true,
        "requiresElevation": "always",
        "authenticode": {
          "required": true,
          "sha256Thumbprints": [
            "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF",
          ],
        },
      },
    },
    "minimumUpdaterVersion": "2.5.0",
  };
}
