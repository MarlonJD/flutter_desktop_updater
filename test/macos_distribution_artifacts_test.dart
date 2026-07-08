import "dart:io";

import "package:desktop_updater/src/core/macos_distribution_artifacts.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;

void main() {
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
