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
        if (executable == "/usr/sbin/pkgutil" &&
            arguments.first == "--expand-full") {
          await Directory(
            path.join(
              arguments.last,
              "component.pkg",
              "Payload",
              "Example.app",
            ),
          ).create(recursive: true);
        }
        if (executable == "/usr/bin/xcrun" &&
            arguments.contains("notarytool")) {
          return ProcessResult(
            0,
            0,
            jsonEncode({"id": "pkg-notary-test", "status": "Accepted"}),
            "",
          );
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
      commands.any(
        (command) => command.startsWith(
          "/usr/bin/pkgbuild --analyze --root",
        ),
      ),
      isTrue,
    );
    expect(
      commands.any((command) => command.contains("--component-plist")),
      isTrue,
    );
    for (final key in [
      "0.BundleIsVersionChecked",
      "0.BundleIsRelocatable",
      "0.BundleHasStrictIdentifier",
      "0.BundleOverwriteAction",
    ]) {
      expect(
        commands.any(
          (command) => command.startsWith(
            "/usr/bin/plutil -replace $key ",
          ),
        ),
        isTrue,
        reason: key,
      );
    }
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
    final strictVerifies = commands
        .where(
          (command) => command.startsWith(
            "/usr/bin/codesign --verify --strict --verbose=2",
          ),
        )
        .toList();
    expect(strictVerifies, hasLength(1));
    expect(strictVerifies.first, contains("Example.app"));
    final deepVerifies = commands
        .where(
          (command) => command.startsWith(
            "/usr/bin/codesign --verify --deep --strict --verbose=2",
          ),
        )
        .toList();
    expect(deepVerifies, hasLength(1));
    expect(commands, contains(contains("/usr/sbin/pkgutil --expand-full")));
    expect(
      deepVerifies.single,
      contains("expanded/component.pkg/Payload/Example.app"),
    );
    expect(
      commands.indexOf(deepVerifies.single),
      lessThan(commands
          .indexWhere((command) => command.contains("notarytool submit"))),
    );
  }, skip: Platform.isWindows ? "Requires POSIX file modes." : false);

  test("does not notarize a PKG whose expanded payload fails verification",
      () async {
    final root = await Directory.systemTemp.createTemp("pkg_payload_trust_");
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final app = Directory(path.join(root.path, "Example.app"));
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

    await expectLater(
      PkgPackager(
        runProcess: (executable, arguments) async {
          final command = [executable, ...arguments].join(" ");
          commands.add(command);
          if (executable == "/usr/bin/plutil") {
            return ProcessResult(
              0,
              0,
              jsonEncode({
                "CFBundleIdentifier": "com.example.app",
                "CFBundleExecutable": "Example",
                "CFBundleShortVersionString": "2.7.0",
                "CFBundleVersion": "270",
              }),
              "",
            );
          }
          if (executable == "/usr/bin/productbuild") {
            await File(
              path.join(output.path, "Example-2.7.0-macos.pkg"),
            ).writeAsBytes([1, 2, 3, 4]);
          }
          if (executable == "/usr/sbin/pkgutil" &&
              arguments.first == "--expand-full") {
            await Directory(
              path.join(
                arguments.last,
                "component.pkg",
                "Payload",
                "Example.app",
              ),
            ).create(recursive: true);
          }
          if (command.startsWith(
                "/usr/bin/codesign --verify --deep --strict --verbose=2",
              ) &&
              command.contains("expanded/component.pkg/Payload/Example.app")) {
            return ProcessResult(0, 23, "", "invalid nested signature");
          }
          return ProcessResult(0, 0, "", "");
        },
      ).package(
        ReleasePackageRequest(
          input: app,
          outputDirectory: output,
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
            signingIdentifier: "Developer ID Installer: Example (TEAMID1234)",
          ),
          developerIdApplication:
              "Developer ID Application: Example (TEAMID1234)",
          notaryProfile: "desktop-updater-notary",
          staple: true,
          gatekeeperAssess: true,
        ),
      ),
      throwsA(isA<ProcessException>()),
    );
    expect(
      commands.any((command) => command.contains("notarytool submit")),
      isFalse,
    );
  }, skip: Platform.isWindows ? "Requires POSIX file modes." : false);

  test("rejects a top-level source application symlink", () async {
    final root = await Directory.systemTemp.createTemp("pkg_source_link_");
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final target = await _createValidApplication(
      Directory(path.join(root.path, "target")),
    );
    final inputLink = Link(path.join(root.path, "Example.app"));
    await inputLink.create(target.path);
    final output = Directory(path.join(root.path, "out"));
    final commands = <String>[];

    await expectLater(
      PkgPackager(
        runProcess: (executable, arguments) async {
          commands.add([executable, ...arguments].join(" "));
          if (executable == "/usr/bin/plutil") {
            return ProcessResult(
              0,
              0,
              jsonEncode({
                "CFBundleIdentifier": "com.example.app",
                "CFBundleExecutable": "Example",
                "CFBundleShortVersionString": "2.7.0",
                "CFBundleVersion": "270",
              }),
              "",
            );
          }
          if (executable == "/usr/bin/productbuild") {
            await File(
              path.join(output.path, "Example-2.7.0-macos.pkg"),
            ).writeAsBytes([1, 2, 3, 4]);
          }
          if (executable == "/usr/sbin/pkgutil" &&
              arguments.first == "--expand-full") {
            await Directory(
              path.join(
                arguments.last,
                "component.pkg",
                "Payload",
                "Example.app",
              ),
            ).create(recursive: true);
          }
          return ProcessResult(0, 0, "", "");
        },
      ).package(
        _packageRequest(
          input: Directory(inputLink.path),
          output: output,
        ),
        config: _pkgConfig,
      ),
      throwsA(
        isA<FileSystemException>().having(
          (error) => error.message,
          "message",
          contains("source application must be a directory"),
        ),
      ),
    );
    expect(commands, isEmpty);
  }, skip: Platform.isWindows ? "Requires POSIX symlinks." : false);

  test("rejects a top-level expanded payload application symlink", () async {
    final root = await Directory.systemTemp.createTemp("pkg_payload_link_");
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final app = await _createValidApplication(
      Directory(path.join(root.path, "Example.app")),
    );
    final outside = Directory(path.join(root.path, "outside.app"));
    await outside.create();
    final output = Directory(path.join(root.path, "out"));
    final commands = <String>[];

    await expectLater(
      PkgPackager(
        runProcess: (executable, arguments) async {
          commands.add([executable, ...arguments].join(" "));
          if (executable == "/usr/bin/plutil") {
            return ProcessResult(
              0,
              0,
              jsonEncode({
                "CFBundleIdentifier": "com.example.app",
                "CFBundleExecutable": "Example",
                "CFBundleShortVersionString": "2.7.0",
                "CFBundleVersion": "270",
              }),
              "",
            );
          }
          if (executable == "/usr/bin/productbuild") {
            await File(
              path.join(output.path, "Example-2.7.0-macos.pkg"),
            ).writeAsBytes([1, 2, 3, 4]);
          }
          if (executable == "/usr/sbin/pkgutil" &&
              arguments.first == "--expand-full") {
            final payloadParent = Directory(
              path.join(arguments.last, "component.pkg", "Payload"),
            );
            await payloadParent.create(recursive: true);
            await Link(path.join(payloadParent.path, "Example.app"))
                .create(outside.path);
          }
          return ProcessResult(0, 0, "", "");
        },
      ).package(
        _packageRequest(input: app, output: output),
        config: _pkgConfig,
      ),
      throwsA(
        isA<FileSystemException>().having(
          (error) => error.message,
          "message",
          contains("expected application payload directory"),
        ),
      ),
    );
    expect(
      commands.any(
        (command) => command.contains(
          "expanded/component.pkg/Payload/Example.app",
        ),
      ),
      isFalse,
    );
  }, skip: Platform.isWindows ? "Requires POSIX symlinks." : false);

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
  }, skip: Platform.isWindows ? "Requires POSIX file modes." : false);
}

const _pkgConfig = MacOSPkgPublishConfig(
  packageIdentifier: "com.example.app.pkg",
  installLocation: "/Applications",
  signingIdentifier: "Developer ID Installer: Example (TEAMID1234)",
);

ReleasePackageRequest _packageRequest({
  required Directory input,
  required Directory output,
}) {
  return ReleasePackageRequest(
    input: input,
    outputDirectory: output,
    packageId: "com.example.app",
    appName: "Example.app",
    version: "2.7.0",
    buildNumber: 270,
    platform: "macos",
    channel: "stable",
    artifactUrl: Uri.parse("https://cdn.example.com/Example.pkg"),
    installStrategy: "pkgInstaller",
    minimumUpdaterVersion: "2.7.0",
  );
}

Future<Directory> _createValidApplication(Directory app) async {
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
  final chmod = await Process.run("/bin/chmod", [
    "755",
    mainExecutable.path,
    helper.path,
  ]);
  if (chmod.exitCode != 0) {
    throw ProcessException(
      "/bin/chmod",
      ["755", mainExecutable.path, helper.path],
      chmod.stderr.toString(),
      chmod.exitCode,
    );
  }
  return app;
}
