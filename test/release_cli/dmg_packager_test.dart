import "dart:convert";
import "dart:io";

import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:desktop_updater/src/package/release_packager.dart";
import "package:desktop_updater/src/release_cli/macos/dmg_packager.dart";
import "package:desktop_updater/src/release_cli/macos/macos_artifact_config.dart";
import "package:desktop_updater/src/release_cli/release_publish_config.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;

void main() {
  test("packages a macOS DMG descriptor", () async {
    final root = await Directory.systemTemp.createTemp("dmg_packager_");
    addTearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });
    final app = Directory(path.join(root.path, "Example.app"));
    await app.create();
    final output = Directory(path.join(root.path, "out"));
    final commands = <String>[];

    final result = await DmgPackager(
      runProcess: (executable, arguments) async {
        commands.add([executable, ...arguments].join(" "));
        if (executable == "/usr/bin/hdiutil" && arguments.first == "create") {
          await File(
            path.join(output.path, "Example-2.6.0-macos.dmg"),
          ).writeAsBytes([1, 2, 3]);
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
        artifactUrl: Uri.parse("https://cdn.example.com/Example.dmg"),
        installStrategy: "wholeBundleReplace",
        minimumUpdaterVersion: "2.6.0",
      ),
      config: const MacOSDmgPublishConfig(
        volumeName: "Example",
        appBundleName: "Example.app",
        applicationsAlias: true,
      ),
      publishConfig: const MacOSPublishConfig(
        notarize: true,
        artifactKind: MacOSArtifactKind.dmg,
        dmg: MacOSDmgPublishConfig(
          volumeName: "Example",
          appBundleName: "Example.app",
          applicationsAlias: true,
        ),
        pkg: MacOSPkgPublishConfig(
          packageIdentifier: "",
          installLocation: "/Applications",
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
    expect(result.artifact.path, endsWith(".dmg"));
    expect(descriptor.artifact.kind, "dmg");
    expect(descriptor.install.strategy, "wholeBundleReplace");
    expect(descriptor.install.macosDmg!.appBundleName, "Example.app");
    expect(descriptor.install.macosDmg!.verifyPrimarySignature, isTrue);
    expect(
      commands.any((command) => command.contains("hdiutil create")),
      isTrue,
    );
    expect(
      commands.any((command) => command.startsWith("/usr/bin/ditto")),
      isTrue,
    );
    expect(
      commands.any((command) => command.startsWith("/usr/bin/codesign")),
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
    expect(
      commands.any(
        (command) => command.startsWith("/usr/sbin/spctl --assess --type open"),
      ),
      isTrue,
    );
  });

  test("marks unsigned DMG descriptors as not requiring primary signature",
      () async {
    final root = await Directory.systemTemp.createTemp("dmg_packager_");
    addTearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });
    final app = Directory(path.join(root.path, "Example.app"));
    await app.create();
    final output = Directory(path.join(root.path, "out"));

    final result = await DmgPackager(
      runProcess: (executable, arguments) async {
        if (executable == "/usr/bin/hdiutil" && arguments.first == "create") {
          await File(
            path.join(output.path, "Example-2.6.0-macos.dmg"),
          ).writeAsBytes([1, 2, 3]);
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
        artifactUrl: Uri.parse("https://cdn.example.com/Example.dmg"),
        installStrategy: "wholeBundleReplace",
        minimumUpdaterVersion: "2.6.0",
      ),
      config: const MacOSDmgPublishConfig(
        volumeName: "Example",
        appBundleName: "Example.app",
        applicationsAlias: true,
      ),
    );

    expect(result.descriptor.install.macosDmg!.verifyPrimarySignature, isFalse);
  });
}
