import "dart:io";

import "package:desktop_updater/src/core/macos_distribution_artifacts.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;

void main() {
  test("macOS retail builds use the dedicated signed helper embed tooling", () {
    final embed = readRequiredFile(
      "macos/install_helper/embed_install_helper.sh",
    );
    final verify = readRequiredFile(
      "macos/install_helper/verify_install_helper_layout.sh",
    );
    final podspec = readRequiredFile("macos/desktop_updater.podspec");
    final package = readRequiredFile("macos/desktop_updater/Package.swift");
    final project = readRequiredFile(
      "example/macos/Runner.xcodeproj/project.pbxproj",
    );

    expect(embed, contains("swift build"));
    expect(embed, contains("-c release"));
    expect(embed, isNot(contains("/.build/debug/")));
    expect(embed, contains("DESKTOP_UPDATER_HELPER_INFO_TEMPLATE"));
    expect(embed, contains("DesktopUpdaterSealedPolicySHA256"));
    expect(embed, contains("DesktopUpdaterInstallPolicyID"));
    expect(embed, contains("SMPrivilegedExecutables"));
    expect(embed, contains("SMAuthorizedClients"));
    expect(embed, contains("escape_plist_buddy_string"));
    expect(embed, contains("application_requirement_for_plist_buddy"));
    expect(embed, contains("helper_requirement_for_plist_buddy"));
    expect(embed, contains("Contents/Helpers/DesktopUpdaterInstallHelper"));
    expect(embed, contains("Contents/Library/LaunchServices"));
    expect(embed, contains("codesign"));
    expect(embed, contains("verify_install_helper_layout.sh"));

    expect(verify, contains("cmp -s"));
    expect(verify, contains("codesign --verify --strict"));
    expect(verify, contains("codesign -d -r-"));
    expect(verify, contains("SMPrivilegedExecutables"));
    expect(verify, contains("SMAuthorizedClients"));
    expect(verify, contains("DesktopUpdaterSealedPolicy"));

    expect(podspec, contains("embed_install_helper.sh"));
    expect(package, contains("embed_install_helper.sh"));
    expect(package, contains('.library(name: "DesktopUpdaterKit"'));
    expect(project, contains("Embed Desktop Updater Install Helper"));
    expect(project, contains("embed_install_helper.sh"));
  });

  test("exposes top-level DMG helper surface with injected runner", () async {
    final commands = <String>[];
    final mounted = await mountDmgReadOnly(
      File("/tmp/Example.dmg"),
      runProcess: (executable, arguments) async {
        commands.add([executable, ...arguments].join(" "));
        return ProcessResult(
          0,
          0,
          "/dev/disk4\tApple_HFS\t/Volumes/Example\n",
          "",
        );
      },
    );

    expect(mounted.mountPoint, "/Volumes/Example");
    await detachDmg(
      mounted,
      runProcess: (executable, arguments) async {
        commands.add([executable, ...arguments].join(" "));
        return ProcessResult(0, 0, "", "");
      },
    );

    expect(commands, [
      "/usr/bin/hdiutil attach -readonly -nobrowse /tmp/Example.dmg",
      "/usr/bin/hdiutil detach /Volumes/Example",
    ]);
  });

  test("DMG verification assesses primary signature before attach", () async {
    final commands = <String>[];
    final verifier = MacOSDistributionVerifier(
      runProcess: (executable, arguments) async {
        commands.add([executable, ...arguments].join(" "));
        if (executable == "/usr/bin/hdiutil" && arguments.first == "attach") {
          return ProcessResult(
            0,
            0,
            "/dev/disk4\tApple_HFS\t/Volumes/Example\n",
            "",
          );
        }
        return ProcessResult(0, 0, "", "");
      },
    );

    final mounted = await verifier.mountVerifiedDmg(
      dmg: File("/tmp/Example.dmg"),
      verifyPrimarySignature: true,
    );

    expect(mounted.mountPoint, "/Volumes/Example");
    expect(commands, [
      startsWith(
        "/usr/sbin/spctl --assess --type open --context context:primary-signature",
      ),
      "/usr/bin/hdiutil attach -readonly -nobrowse /tmp/Example.dmg",
    ]);
  });

  test(
      "PKG verification runs package signature, install assessment, and stapler",
      () async {
    final root = await Directory.systemTemp.createTemp("pkg_expand_parent_");
    addTearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });

    final commands = <String>[];
    String? expandedPath;
    final verifier = MacOSDistributionVerifier(
      createTempDirectory: () async => root,
      runProcess: (executable, arguments) async {
        commands.add([executable, ...arguments].join(" "));
        if (executable == "/usr/sbin/pkgutil" &&
            arguments.first == "--expand-full") {
          expandedPath = arguments.last;
          expect(expandedPath, isNot(root.path));
          expect(Directory(expandedPath!).existsSync(), isFalse);
          await Directory(expandedPath!).create(recursive: true);
          await File(path.join(expandedPath!, "PackageInfo")).writeAsString(
            '<pkg-info identifier="com.example.app.pkg" />',
          );
        }
        return ProcessResult(0, 0, "", "");
      },
    );

    await verifier.verifyPkgInstaller(
      pkg: File("/tmp/Example.pkg"),
      expectedPackageIds: const ["com.example.app.pkg"],
    );

    expect(commands, [
      "/usr/sbin/pkgutil --check-signature /tmp/Example.pkg",
      "/usr/sbin/spctl --assess --type install --verbose=2 /tmp/Example.pkg",
      "/usr/bin/xcrun stapler validate /tmp/Example.pkg",
      "/usr/sbin/pkgutil --expand-full /tmp/Example.pkg $expandedPath",
    ]);
  });

  test("PKG verification rejects missing expected package identifiers",
      () async {
    final root = await Directory.systemTemp.createTemp("pkg_expand_parent_");
    addTearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });

    final verifier = MacOSDistributionVerifier(
      createTempDirectory: () async => root,
      runProcess: (executable, arguments) async {
        if (executable == "/usr/sbin/pkgutil" &&
            arguments.first == "--expand-full") {
          final expanded = Directory(arguments.last);
          await expanded.create(recursive: true);
          await File(path.join(expanded.path, "Distribution")).writeAsString(
            '<installer-gui-script><pkg-ref id="com.example.other.pkg" /></installer-gui-script>',
          );
        }
        return ProcessResult(0, 0, "", "");
      },
    );

    await expectLater(
      verifier.verifyPkgInstaller(
        pkg: File("/tmp/Example.pkg"),
        expectedPackageIds: const ["com.example.app.pkg"],
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          "message",
          contains("com.example.app.pkg"),
        ),
      ),
    );
  });

  test("PKG verification ignores unrelated XML id attributes", () async {
    final root = await Directory.systemTemp.createTemp("pkg_expand_parent_");
    addTearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });

    final verifier = MacOSDistributionVerifier(
      createTempDirectory: () async => root,
      runProcess: (executable, arguments) async {
        if (executable == "/usr/sbin/pkgutil" &&
            arguments.first == "--expand-full") {
          final expanded = Directory(arguments.last);
          await expanded.create(recursive: true);
          await File(path.join(expanded.path, "Distribution")).writeAsString(
            '<installer-gui-script><choice id="com.example.app.pkg" /></installer-gui-script>',
          );
        }
        return ProcessResult(0, 0, "", "");
      },
    );

    await expectLater(
      verifier.verifyPkgInstaller(
        pkg: File("/tmp/Example.pkg"),
        expectedPackageIds: const ["com.example.app.pkg"],
      ),
      throwsA(isA<StateError>()),
    );
  });

  test("detaches mounted DMG when app extraction fails", () async {
    final commands = <String>[];
    final verifier = MacOSDistributionVerifier(
      runProcess: (executable, arguments) async {
        commands.add([executable, ...arguments].join(" "));
        if (executable == "/usr/bin/hdiutil" && arguments.first == "attach") {
          return ProcessResult(
            0,
            0,
            "/dev/disk4\tApple_HFS\t/Volumes/Example\n",
            "",
          );
        }
        if (executable == "/usr/bin/ditto") {
          return ProcessResult(0, 1, "", "copy failed");
        }
        return ProcessResult(0, 0, "", "");
      },
    );

    final mounted = await verifier.mountVerifiedDmg(
      dmg: File("/tmp/Example.dmg"),
      verifyPrimarySignature: false,
    );
    await expectLater(
      verifier.copyAppFromMountedDmg(
        mounted: mounted,
        appBundleName: "Example.app",
        destinationParent: Directory("/tmp/stage"),
      ),
      throwsA(isA<ProcessException>()),
    );
    await verifier.detachDmg(mounted);

    expect(commands.last, "/usr/bin/hdiutil detach /Volumes/Example");
  });

  test("withMountedVerifiedDmg detaches mounted DMG when body fails", () async {
    final commands = <String>[];
    final verifier = MacOSDistributionVerifier(
      runProcess: (executable, arguments) async {
        commands.add([executable, ...arguments].join(" "));
        if (executable == "/usr/bin/hdiutil" && arguments.first == "attach") {
          return ProcessResult(
            0,
            0,
            "/dev/disk4\tApple_HFS\t/Volumes/Example\n",
            "",
          );
        }
        if (executable == "/usr/bin/ditto") {
          return ProcessResult(0, 1, "", "copy failed");
        }
        return ProcessResult(0, 0, "", "");
      },
    );

    await expectLater(
      verifier.withMountedVerifiedDmg<void>(
        dmg: File("/tmp/Example.dmg"),
        verifyPrimarySignature: false,
        body: (mounted) {
          return verifier.copyAppFromMountedDmg(
            mounted: mounted,
            appBundleName: "Example.app",
            destinationParent: Directory("/tmp/stage"),
          );
        },
      ),
      throwsA(isA<ProcessException>()),
    );

    expect(commands.last, "/usr/bin/hdiutil detach /Volumes/Example");
  });
}

String readRequiredFile(String path) {
  final file = File(path);
  expect(file.existsSync(), isTrue, reason: "$path must exist");
  return file.existsSync() ? file.readAsStringSync() : "";
}
