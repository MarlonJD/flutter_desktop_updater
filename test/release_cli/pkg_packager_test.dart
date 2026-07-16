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
    await app.create(recursive: true);
    final mainExecutable = File(
      path.join(app.path, "Contents", "MacOS", "Example"),
    );
    final helper = File(
      path.join(
        app.path,
        "Contents",
        "Helpers",
        "DesktopUpdaterInstallHelper",
      ),
    );
    await mainExecutable.parent.create(recursive: true);
    await helper.parent.create(recursive: true);
    await mainExecutable.writeAsString("main");
    await helper.writeAsString("helper");
    await File(path.join(app.path, "Contents", "Info.plist"))
        .writeAsString("plist");
    expect(
      (await Process.run("/bin/chmod", [
        "755",
        mainExecutable.path,
        helper.path,
      ]))
          .exitCode,
      0,
    );
    final output = Directory(path.join(root.path, "out"));
    final commands = <String>[];

    final result = await PkgPackager(
      runProcess: (executable, arguments) async {
        commands.add([executable, ...arguments].join(" "));
        if (executable == "/usr/bin/plutil") {
          return ProcessResult(
            0,
            0,
            jsonEncode({
              "CFBundleIdentifier": "com.example.app",
              "CFBundleExecutable": "Example",
              "CFBundleShortVersionString": "2.6.0",
              "CFBundleVersion": "260",
            }),
            "",
          );
        }
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
    expect(
      descriptor.install.macosPkg!.launchMode,
      "privilegedInstallerTool",
    );
    expect(descriptor.install.macosPkg!.expectedPackageIds, [
      "com.example.app.pkg",
    ]);
    expect(descriptor.minimumUpdaterVersion, "2.7.0");
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
      commands.any((command) => command.startsWith("/usr/bin/plutil")),
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

  test("rejects PKG publication without a numeric build number", () async {
    final root = await Directory.systemTemp.createTemp("pkg_build_number_");
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    await expectLater(
      PkgPackager(
        runProcess: (executable, arguments) async =>
            ProcessResult(0, 0, "", ""),
      ).package(
        ReleasePackageRequest(
          input: Directory(path.join(root.path, "Example.app")),
          outputDirectory: Directory(path.join(root.path, "out")),
          packageId: "com.example.app",
          appName: "Example.app",
          version: "2.7.0",
          buildNumber: null,
          platform: "macos",
          channel: "stable",
          artifactUrl: Uri.parse("https://cdn.example.com/Example.pkg"),
          installStrategy: "pkgInstaller",
          minimumUpdaterVersion: "2.7.0",
        ),
        config: const MacOSPkgPublishConfig(
          packageIdentifier: "com.example.app.pkg",
          installLocation: "/Applications",
          signingIdentifier: "Developer ID Installer: Example (TEAMID1234)",
        ),
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test("rejects PKG app names that do not bind the input bundle", () async {
    final root = await Directory.systemTemp.createTemp("pkg_app_name_");
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final input = Directory(path.join(root.path, "Example.app"));
    await input.create(recursive: true);

    for (final appName in ["Other.app", "Example"]) {
      final commands = <String>[];
      await expectLater(
        PkgPackager(
          runProcess: (executable, arguments) async {
            commands.add(executable);
            return ProcessResult(0, 0, "", "");
          },
        ).package(
          ReleasePackageRequest(
            input: input,
            outputDirectory: Directory(path.join(root.path, "out")),
            packageId: "com.example.app",
            appName: appName,
            version: "2.7.0",
            buildNumber: 270,
            platform: "macos",
            channel: "stable",
            artifactUrl: Uri.parse("https://cdn.example.com/Example.pkg"),
            installStrategy: "pkgInstaller",
            minimumUpdaterVersion: "2.7.0",
          ),
          config: const MacOSPkgPublishConfig(
            packageIdentifier: "com.example.app.pkg",
            installLocation: "/Applications",
            signingIdentifier: "Developer ID Installer: Example (TEAMID1234)",
          ),
        ),
        throwsA(isA<FormatException>()),
        reason: appName,
      );
      expect(commands, isEmpty, reason: appName);
    }
  });

  test("rejects inaccessible PKG bundle modes before commands", () async {
    for (final invalid in [
      ("Contents/MacOS/Example", "710"),
      ("Contents/Helpers/DesktopUpdaterInstallHelper", "710"),
      ("Contents", "700"),
      ("Contents/Info.plist", "600"),
    ]) {
      final root = await Directory.systemTemp.createTemp("pkg_modes_");
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final app = Directory(path.join(root.path, "Example.app"));
      final main = File(path.join(app.path, "Contents", "MacOS", "Example"));
      final helper = File(
        path.join(
          app.path,
          "Contents",
          "Helpers",
          "DesktopUpdaterInstallHelper",
        ),
      );
      final info = File(path.join(app.path, "Contents", "Info.plist"));
      await main.parent.create(recursive: true);
      await helper.parent.create(recursive: true);
      await main.writeAsString("main");
      await helper.writeAsString("helper");
      await info.writeAsString("plist");
      expect(
        (await Process.run("/bin/chmod", [
          "755",
          main.path,
          helper.path,
          path.join(app.path, "Contents"),
        ]))
            .exitCode,
        0,
      );
      expect(
        (await Process.run("/bin/chmod", [
          "644",
          info.path,
        ]))
            .exitCode,
        0,
      );
      expect(
        (await Process.run("/bin/chmod", [
          invalid.$2,
          path.join(app.path, invalid.$1),
        ]))
            .exitCode,
        0,
      );
      final commands = <String>[];

      await expectLater(
        PkgPackager(
          runProcess: (executable, arguments) async {
            commands.add(executable);
            return ProcessResult(0, 0, "", "");
          },
        ).package(
          ReleasePackageRequest(
            input: app,
            outputDirectory: Directory(path.join(root.path, "out")),
            packageId: "com.example.app",
            appName: "Example.app",
            version: "2.7.0",
            buildNumber: 270,
            platform: "macos",
            channel: "stable",
            artifactUrl: Uri.parse("https://cdn.example.com/Example.pkg"),
            installStrategy: "pkgInstaller",
            minimumUpdaterVersion: "2.7.0",
          ),
          config: const MacOSPkgPublishConfig(
            packageIdentifier: "com.example.app.pkg",
            installLocation: "/Applications",
            signingIdentifier: "Developer ID Installer: Example (TEAMID1234)",
          ),
        ),
        throwsA(isA<FileSystemException>()),
        reason: invalid.$1,
      );
      expect(commands, isEmpty, reason: invalid.$1);
    }
  });
}
