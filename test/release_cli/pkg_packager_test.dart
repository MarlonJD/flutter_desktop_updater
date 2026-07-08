import "dart:convert";
import "dart:io";

import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:desktop_updater/src/package/release_packager.dart";
import "package:desktop_updater/src/release_cli/macos/macos_artifact_config.dart";
import "package:desktop_updater/src/release_cli/macos/pkg_packager.dart";
import "package:desktop_updater/src/release_cli/release_publish_config.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;

void main() {
  test("packages a signed macOS PKG descriptor", () async {
    final root = await Directory.systemTemp.createTemp("pkg_packager_");
    addTearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });
    final app = Directory(path.join(root.path, "Example.app"));
    await app.create();
    final output = Directory(path.join(root.path, "out"));
    final commands = <String>[];

    final result = await PkgPackager(
      runProcess: (executable, arguments) async {
        commands.add([executable, ...arguments].join(" "));
        if (executable == "/usr/bin/productbuild") {
          await File(
            path.join(output.path, "Example-2.6.0-macos.pkg"),
          ).writeAsBytes([1, 2, 3, 4]);
        }
        return ProcessResult(0, 0, "", "");
      },
    ).package(
      ReleasePackageRequest(
        input: app,
        outputDirectory: output,
        packageId: "com.example.app",
        appName: "Example.app",
        version: "2.6.0",
        buildNumber: 260,
        platform: "macos",
        channel: "stable",
        artifactUrl: Uri.parse("https://cdn.example.com/Example.pkg"),
        installStrategy: "pkgInstaller",
        minimumUpdaterVersion: "2.6.0",
      ),
      config: const MacOSPkgPublishConfig(
        packageIdentifier: "com.example.app.pkg",
        installLocation: "/Applications",
        signingIdentifier: "Developer ID Installer: Example Corp (TEAMID1234)",
      ),
      publishConfig: const MacOSPublishConfig(
        notarize: true,
        artifactKind: MacOSArtifactKind.pkg,
        dmg: MacOSDmgPublishConfig(
          volumeName: "Example",
          appBundleName: "Example.app",
          applicationsAlias: true,
        ),
        pkg: MacOSPkgPublishConfig(
          packageIdentifier: "com.example.app.pkg",
          installLocation: "/Applications",
          signingIdentifier:
              "Developer ID Installer: Example Corp (TEAMID1234)",
        ),
        developerIdApplication:
            "Developer ID Application: Example Corp (TEAMID1234)",
        notaryProfile: "desktop-updater-notary",
        keychain: "/Users/me/Library/Keychains/login.keychain-db",
        staple: true,
        gatekeeperAssess: true,
      ),
    );

    final descriptor = ReleaseDescriptor.fromJson(
      jsonDecode(await result.releaseFile.readAsString())
          as Map<String, dynamic>,
    );
    expect(result.artifact.path, endsWith(".pkg"));
    expect(descriptor.artifact.kind, "pkgInstaller");
    expect(descriptor.install.strategy, "pkgInstaller");
    expect(descriptor.install.macosPkg!.launchMode, "installerApp");
    expect(descriptor.install.macosPkg!.expectedPackageIds, [
      "com.example.app.pkg",
    ]);
    expect(
      commands.any((command) => command.startsWith("/usr/sbin/pkgbuild")),
      isFalse,
    );
    expect(
      commands.any((command) => command.startsWith("/usr/bin/pkgbuild")),
      isTrue,
    );
    expect(
      commands.any((command) => command.startsWith("/usr/bin/productbuild")),
      isTrue,
    );
    expect(
      commands.any(
        (command) => command.startsWith("/usr/sbin/pkgutil --check-signature"),
      ),
      isTrue,
    );
    expect(
      commands.any(
        (command) =>
            command.startsWith("/usr/sbin/spctl --assess --type install"),
      ),
      isTrue,
    );
    expect(
      commands.any((command) => command.contains("notarytool submit")),
      isTrue,
    );
    expect(
      commands.any((command) => command.startsWith("/usr/bin/xcrun stapler")),
      isTrue,
    );
  });
}
