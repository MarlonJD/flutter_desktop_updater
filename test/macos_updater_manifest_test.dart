import "dart:io";

import "package:desktop_updater/src/macos_update.dart";
import "package:desktop_updater/src/release_manifest.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;

void main() {
  group("macOS framework archives", () {
    test(
      "default zip-style dereferencing breaks framework symlinks",
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          "desktop_updater_zip_bad_",
        );
        try {
          final app = await _createFrameworkFixtureApp(tempDir);
          final archive = File(path.join(tempDir.path, "Default.zip"));
          final unzipDir = Directory(path.join(tempDir.path, "unzip"));

          final zipResult = await Process.run(
            "/usr/bin/zip",
            ["-r", archive.path, path.basename(app.path)],
            workingDirectory: tempDir.path,
          );
          expect(zipResult.exitCode, 0, reason: zipResult.stderr.toString());
          await unzipDir.create();
          final unzipResult = await Process.run(
            "/usr/bin/unzip",
            [archive.path],
            workingDirectory: unzipDir.path,
          );
          expect(
            unzipResult.exitCode,
            0,
            reason: unzipResult.stderr.toString(),
          );

          final frameworkPath = path.join(
            unzipDir.path,
            "Fixture.app",
            "Contents",
            "Frameworks",
            "Fixture.framework",
          );
          expect(
            FileSystemEntity.typeSync(
              path.join(frameworkPath, "Versions", "Current"),
              followLinks: false,
            ),
            isNot(FileSystemEntityType.link),
          );
          expect(
            FileSystemEntity.typeSync(
              path.join(frameworkPath, "Fixture"),
              followLinks: false,
            ),
            isNot(FileSystemEntityType.link),
          );
        } finally {
          await tempDir.delete(recursive: true);
        }
      },
      skip: !Platform.isMacOS,
    );

    test(
      "ditto archive and extraction preserves framework symlinks",
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          "desktop_updater_ditto_good_",
        );
        try {
          final app = await _createFrameworkFixtureApp(tempDir);
          final archive = File(path.join(tempDir.path, "Fixture.zip"));
          final extractDir = Directory(path.join(tempDir.path, "extract"));

          await runDittoCreateZip(appPath: app.path, archivePath: archive.path);
          await extractDir.create();
          await runDittoExtractZip(
            archivePath: archive.path,
            destination: extractDir.path,
          );

          final frameworkPath = path.join(
            extractDir.path,
            "Fixture.app",
            "Contents",
            "Frameworks",
            "Fixture.framework",
          );
          await _expectLinkTarget(
            path.join(frameworkPath, "Versions", "Current"),
            "A",
          );
          await _expectLinkTarget(
            path.join(frameworkPath, "Fixture"),
            "Versions/Current/Fixture",
          );
          await _expectLinkTarget(
            path.join(frameworkPath, "Resources"),
            "Versions/Current/Resources",
          );
        } finally {
          await tempDir.delete(recursive: true);
        }
      },
      skip: !Platform.isMacOS,
    );
  });

  group("macOS release manifest", () {
    test(
      "records framework symlinks as exact manifest entries",
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          "desktop_updater_manifest_",
        );
        try {
          final app = await _createFrameworkFixtureApp(tempDir);
          final manifest = await generateMacOSAppManifest(
            appDirectory: app,
            version: "1.0.0",
            shortVersion: 1,
            channel: "stable",
            bundleIdentifier: "com.example.fixture",
            teamIdentifier: "ABCDE12345",
          );

          final symlinks = {
            for (final entry in manifest.entries.where(
              (entry) => entry.type == ReleaseManifestEntryType.symlink,
            ))
              entry.path: entry.symlinkTarget,
          };

          expect(
            symlinks["Contents/Frameworks/Fixture.framework/Versions/Current"],
            "A",
          );
          expect(
            symlinks["Contents/Frameworks/Fixture.framework/Fixture"],
            "Versions/Current/Fixture",
          );
          expect(
            symlinks["Contents/Frameworks/Fixture.framework/Resources"],
            "Versions/Current/Resources",
          );
        } finally {
          await tempDir.delete(recursive: true);
        }
      },
      skip: !Platform.isMacOS,
    );

    test("rejects absolute symlink targets", () {
      expect(
        () => validateSymlinkTarget(
          appRoot: "/tmp/Fixture.app",
          linkRelativePath: "Contents/Frameworks/Fixture.framework/Fixture",
          target: "/Library/Frameworks/Fixture.framework",
        ),
        throwsFormatException,
      );
    });

    test("rejects symlink targets containing parent traversal", () {
      expect(
        () => validateSymlinkTarget(
          appRoot: "/tmp/Fixture.app",
          linkRelativePath: "Contents/Frameworks/Fixture.framework/Fixture",
          target: "../Fixture",
        ),
        throwsFormatException,
      );
    });

    test("rejects broken manifests", () {
      expect(
        () => ReleaseManifest.fromJson({
          "schemaVersion": 2,
          "platform": "macos",
          "version": "1.0.0",
          "shortVersion": 1,
          "channel": "stable",
          "appName": "Fixture.app",
          "bundleIdentifier": "com.example.fixture",
          "teamIdentifier": "ABCDE12345",
          "entries": [
            {
              "type": "file",
              "path": "Contents/MacOS/Fixture",
              "sha256": "not-a-sha",
              "length": 1,
              "mode": "755",
              "payload": "payloads/not-a-sha.gz",
            },
          ],
        }),
        throwsFormatException,
      );
    });

    test("rejects non content-addressed payload paths", () {
      final sha256 = "a" * 64;
      expect(
        () => ReleaseManifestEntry.file(
          path: "Contents/MacOS/Fixture",
          sha256: sha256,
          length: 1,
          mode: "755",
          payloadPath: "payloads/not-$sha256.gz",
        ),
        throwsFormatException,
      );
    });

    test("rejects unsafe symlink targets in manifest entries", () {
      expect(
        () => ReleaseManifestEntry.symlink(
          path: "Contents/Frameworks/Fixture.framework/Fixture",
          symlinkTarget: "../Fixture",
        ),
        throwsFormatException,
      );
    });

    test("rejects manifest identity mismatches", () {
      final manifest = ReleaseManifest(
        schemaVersion: 2,
        platform: "macos",
        version: "1.0.0",
        shortVersion: 1,
        channel: "stable",
        appName: "Fixture.app",
        bundleIdentifier: "com.example.fixture",
        teamIdentifier: "ABCDE12345",
        entries: [
          ReleaseManifestEntry.symlink(
            path: "Contents/Frameworks/Fixture.framework/Fixture",
            symlinkTarget: "Versions/Current/Fixture",
          ),
        ],
      );

      expect(
        () => verifyReleaseManifestIdentity(
          manifest: manifest,
          identity: const MacOSAppIdentity(
            bundleIdentifier: "com.example.fixture",
            teamIdentifier: "ZZZZZ99999",
          ),
        ),
        throwsA(isA<StateError>()),
      );
    });

    test(
      "rejects bad staged file hashes",
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          "desktop_updater_bad_hash_",
        );
        try {
          final app = await _createFrameworkFixtureApp(tempDir);
          final manifest = await generateMacOSAppManifest(
            appDirectory: app,
            version: "1.0.0",
            shortVersion: 1,
            channel: "stable",
            bundleIdentifier: "com.example.fixture",
            teamIdentifier: "ABCDE12345",
          );

          await File(path.join(app.path, "Contents", "MacOS", "Fixture"))
              .writeAsString("tampered");

          await expectLater(
            verifyStagedAppManifest(appDirectory: app, manifest: manifest),
            throwsA(isA<FileSystemException>()),
          );
        } finally {
          await tempDir.delete(recursive: true);
        }
      },
      skip: !Platform.isMacOS,
    );

    test(
      "rejects unexpected staged files",
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          "desktop_updater_unexpected_",
        );
        try {
          final app = await _createFrameworkFixtureApp(tempDir);
          final manifest = await generateMacOSAppManifest(
            appDirectory: app,
            version: "1.0.0",
            shortVersion: 1,
            channel: "stable",
            bundleIdentifier: "com.example.fixture",
            teamIdentifier: "ABCDE12345",
          );

          await File(path.join(app.path, "Contents", "extra.txt"))
              .writeAsString("extra");

          await expectLater(
            verifyStagedAppManifest(appDirectory: app, manifest: manifest),
            throwsA(isA<FileSystemException>()),
          );
        } finally {
          await tempDir.delete(recursive: true);
        }
      },
      skip: !Platform.isMacOS,
    );

    test("rejects wrong bundle identifiers", () async {
      await expectLater(
        verifyMacOSNativeGates(
          appDirectory: Directory("/tmp/Fixture.app"),
          expectedBundleIdentifier: "com.example.fixture",
          expectedTeamIdentifier: "ABCDE12345",
          runProcess: _fakeGateRunner(
            bundleIdentifier: "com.example.other",
            teamIdentifier: "ABCDE12345",
          ),
        ),
        throwsA(isA<StateError>()),
      );
    });

    test("rejects wrong team identifiers", () async {
      await expectLater(
        verifyMacOSNativeGates(
          appDirectory: Directory("/tmp/Fixture.app"),
          expectedBundleIdentifier: "com.example.fixture",
          expectedTeamIdentifier: "ABCDE12345",
          runProcess: _fakeGateRunner(
            bundleIdentifier: "com.example.fixture",
            teamIdentifier: "ZZZZZ99999",
          ),
        ),
        throwsA(isA<StateError>()),
      );
    });
  });
}

Future<Directory> _createFrameworkFixtureApp(Directory parent) async {
  final app = Directory(path.join(parent.path, "Fixture.app"));
  final macOSDir = Directory(path.join(app.path, "Contents", "MacOS"));
  final framework = Directory(
    path.join(
      app.path,
      "Contents",
      "Frameworks",
      "Fixture.framework",
    ),
  );
  final versionA = Directory(path.join(framework.path, "Versions", "A"));
  await Directory(path.join(versionA.path, "Resources"))
      .create(recursive: true);
  await macOSDir.create(recursive: true);
  await File(path.join(app.path, "Contents", "Info.plist")).writeAsString('''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>com.example.fixture</string>
  <key>CFBundleExecutable</key>
  <string>Fixture</string>
</dict>
</plist>
''');
  await File(path.join(macOSDir.path, "Fixture")).writeAsString("executable");
  await File(path.join(versionA.path, "Fixture")).writeAsString("framework");
  await Link(path.join(framework.path, "Versions", "Current")).create("A");
  await Link(path.join(framework.path, "Fixture"))
      .create("Versions/Current/Fixture");
  await Link(path.join(framework.path, "Resources"))
      .create("Versions/Current/Resources");
  await Process.run("/bin/chmod", ["755", path.join(macOSDir.path, "Fixture")]);
  return app;
}

Future<void> _expectLinkTarget(String linkPath, String target) async {
  expect(
    FileSystemEntity.typeSync(linkPath, followLinks: false),
    FileSystemEntityType.link,
  );
  expect(await Link(linkPath).target(), target);
}

ProcessRunner _fakeGateRunner({
  required String bundleIdentifier,
  required String teamIdentifier,
}) {
  return (executable, arguments) async {
    if (executable == "/usr/bin/plutil") {
      return ProcessResult(1, 0, "$bundleIdentifier\n", "");
    }
    if (executable == "/usr/bin/codesign" && arguments.first == "-dv") {
      return ProcessResult(
        2,
        0,
        "",
        "Executable=/tmp/Fixture.app\nTeamIdentifier=$teamIdentifier\n",
      );
    }
    return ProcessResult(3, 0, "", "");
  };
}
