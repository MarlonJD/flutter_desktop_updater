import "dart:io";

import "package:desktop_updater/src/release_cli/macos/macos_release_trust.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;

void main() {
  test("secretless ad hoc app is real Mach-O and codesign-verifiable",
      () async {
    if (!Platform.isMacOS) return;

    final root = await Directory.systemTemp.createTemp("macos_adhoc_trust_");
    addTearDown(() => root.delete(recursive: true));
    final app = Directory(path.join(root.path, "AdHocFixture.app"));
    final source = File(path.join(root.path, "main.c"));
    final executable = File(
      path.join(app.path, "Contents", "MacOS", "AdHocFixture"),
    );
    await executable.parent.create(recursive: true);
    await source.writeAsString("int main(void) { return 0; }\n");
    await File(path.join(app.path, "Contents", "Info.plist")).writeAsString('''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.example.adhoc.fixture</string>
<key>CFBundleExecutable</key><string>AdHocFixture</string>
</dict></plist>
''');

    await _run("/usr/bin/clang", ["-o", executable.path, source.path]);
    await _run("/usr/bin/codesign", [
      "--force",
      "--options",
      "runtime",
      "--sign",
      "-",
      app.path,
    ]);
    final inventory = await MacOSReleaseTrust().preflight(
      app: app,
      expectedApplicationIdentifier: "com.example.adhoc.fixture",
    );
    expect(inventory.applicationTarget.kind, MacOSCodeTargetKind.application);
    await _run("/usr/bin/codesign", [
      "--verify",
      "--deep",
      "--strict",
      app.path,
    ]);
  });
  test(
    "unsigned privacy bundle is sealed by its framework through ZIP packaging",
    () async {
      final root = await Directory.systemTemp.createTemp(
        "macos_privacy_trust_",
      );
      addTearDown(() => root.delete(recursive: true));
      final app = Directory(path.join(root.path, "PrivacyFixture.app"));
      final executable = File(
        path.join(app.path, "Contents", "MacOS", "PrivacyFixture"),
      );
      await executable.parent.create(recursive: true);
      await File(path.join(app.path, "Contents", "Info.plist"))
          .writeAsString('''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.example.privacy.fixture</string>
<key>CFBundleExecutable</key><string>PrivacyFixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
''');
      final source = File(path.join(root.path, "main.c"));
      await source.writeAsString("int main(void) { return 0; }\n");
      await _run("/usr/bin/clang", ["-o", executable.path, source.path]);

      final framework = Directory(
        path.join(app.path, "Contents", "Frameworks", "OrderedSet.framework"),
      );
      final version = Directory(path.join(framework.path, "Versions", "A"));
      final resources = Directory(path.join(version.path, "Resources"));
      await resources.create(recursive: true);
      await File(path.join(resources.path, "Info.plist")).writeAsString('''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.example.OrderedSet</string>
<key>CFBundleExecutable</key><string>OrderedSet</string>
<key>CFBundlePackageType</key><string>FMWK</string>
</dict></plist>
''');
      final librarySource = File(path.join(root.path, "library.c"));
      await librarySource.writeAsString("int fixture(void) { return 0; }\n");
      await _run("/usr/bin/clang", [
        "-dynamiclib",
        "-o",
        path.join(version.path, "OrderedSet"),
        librarySource.path,
      ]);
      await Link(path.join(framework.path, "Versions", "Current")).create("A");
      await Link(path.join(framework.path, "Resources"))
          .create("Versions/Current/Resources");
      await Link(path.join(framework.path, "OrderedSet"))
          .create("Versions/Current/OrderedSet");

      final bundle = Directory(
        path.join(resources.path, "OrderedSet_privacy.bundle"),
      );
      final privacy = File(
        path.join(
          bundle.path,
          "Contents",
          "Resources",
          "PrivacyInfo.xcprivacy",
        ),
      );
      await privacy.parent.create(recursive: true);
      await File(path.join(bundle.path, "Contents", "Info.plist"))
          .writeAsString('''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.cocoapods.OrderedSet-privacy</string>
<key>CFBundlePackageType</key><string>BNDL</string>
</dict></plist>
''');
      const manifest = """<?xml version="1.0"?>
<plist version="1.0"><dict><key>NSPrivacyTracking</key><false/></dict></plist>""";
      await privacy.writeAsString(manifest);
      final mode = (await privacy.stat()).mode;
      final unsigned = await Process.run("/usr/bin/codesign", [
        "-d",
        "--entitlements",
        ":-",
        bundle.path,
      ]);
      expect(unsigned.exitCode, isNot(0));

      final inventory = await MacOSReleaseTrust().preflight(app: app);
      expect(inventory.targets.map((target) => target.kind), [
        MacOSCodeTargetKind.framework,
        MacOSCodeTargetKind.application,
      ]);
      // Ad hoc signing proves resource sealing without a Developer ID. The
      // production signAndVerify Team ID gate is covered by process fixtures.
      for (final target in inventory.targets) {
        await _run("/usr/bin/codesign", [
          "--force",
          "--options",
          "runtime",
          "--sign",
          "-",
          target.path,
        ]);
        await _run("/usr/bin/codesign", ["--verify", "--strict", target.path]);
      }
      expect(await privacy.readAsString(), manifest);
      expect((await privacy.stat()).mode, mode);
      await _run("/usr/bin/codesign", [
        "--verify",
        "--deep",
        "--strict",
        app.path,
      ]);

      final zip = path.join(root.path, "PrivacyFixture.zip");
      final extracted = path.join(root.path, "extracted");
      await _run("/usr/bin/ditto", [
        "-c",
        "-k",
        "--sequesterRsrc",
        "--keepParent",
        app.path,
        zip,
      ]);
      await _run("/usr/bin/ditto", ["-x", "-k", zip, extracted]);
      final extractedApp = Directory(
        path.join(extracted, "PrivacyFixture.app"),
      );
      final extractedInventory = await MacOSReleaseTrust().preflight(
        app: extractedApp,
      );
      expect(extractedInventory.targets, hasLength(2));
      await _run("/usr/bin/codesign", [
        "--verify",
        "--deep",
        "--strict",
        extractedApp.path,
      ]);
      final extractedPrivacy = File(
        path.join(
          extractedApp.path,
          path.relative(privacy.path, from: app.path),
        ),
      );
      expect(await extractedPrivacy.readAsString(), manifest);
      await extractedPrivacy.writeAsString("$manifest\n");
      final tampered = await Process.run("/usr/bin/codesign", [
        "--verify",
        "--deep",
        "--strict",
        extractedApp.path,
      ]);
      expect(
        tampered.exitCode,
        isNot(0),
        reason: "Privacy manifest tampering must break the resource seal",
      );
    },
    skip:
        !Platform.isMacOS ? "Requires macOS codesign, clang, and ditto" : false,
  );
}

Future<void> _run(String executable, List<String> arguments) async {
  final result = await Process.run(executable, arguments);
  if (result.exitCode != 0) {
    throw ProcessException(
      executable,
      arguments,
      "${result.stdout}${result.stderr}",
      result.exitCode,
    );
  }
}
