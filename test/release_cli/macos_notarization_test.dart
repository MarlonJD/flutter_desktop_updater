import "dart:io";

import "package:archive/archive.dart";
import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:desktop_updater/src/macos_update.dart";
import "package:desktop_updater/src/release_cli/macos/macos_release_trust.dart";
import "package:desktop_updater/src/package/release_packager.dart";
import "package:desktop_updater/src/release_cli/release_publish_config.dart";
import "package:desktop_updater/src/release_cli/release_publisher.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;

void main() {
  test("macOS notarization runs before packaging when explicitly enabled",
      () async {
    final root = await _createMacOSFixture();
    await _writeAdditionalFilesConfig(root);
    final commands = <String>[];
    final packager = _RecordingPackager(commands);
    try {
      final runProcess = (String executable, List<String> arguments) async {
        final extraCopied = await File(
          path.join(
            _macOSAppPath(root),
            "Contents",
            "Resources",
            "Manuals",
            "pilot-guide.pdf",
          ),
        ).exists();
        commands.add(
          [
            if (executable == "/usr/bin/codesign") "extraCopied=$extraCopied",
            executable,
            ...arguments,
          ].join(" "),
        );
        if (executable == "/usr/bin/xcrun" &&
            arguments.length >= 2 &&
            arguments[0] == "notarytool" &&
            arguments[1] == "submit") {
          return ProcessResult(
            0,
            0,
            '{"id":"fake-submission","status":"Accepted"}',
            "",
          );
        }
        if (executable == "/usr/bin/ditto" && arguments.first == "-c") {
          await File(arguments.last).writeAsBytes(<int>[1, 2, 3]);
        }
        if (executable == "/usr/bin/codesign" &&
            arguments.length == 2 &&
            arguments.first == "-dvvv") {
          return ProcessResult(
            0,
            0,
            _fakeCodeDetails(arguments.last),
            "",
          );
        }
        return ProcessResult(0, 0, "", "");
      };
      final publisher = ReleasePublisher(
        skipBuild: true,
        packager: packager,
        runProcess: runProcess,
        macOSReleaseTrust: _SkipFinalAuditTrust(runProcess),
        runHookCommand: (command, {required environment}) async {
          commands.add("HOOK $command");
          return ProcessResult(0, 0, "", "");
        },
      );

      await publisher.publish(
        projectRoot: root,
        platform: "macos",
        overrides: const ReleasePublishOverrides(),
        output: StringBuffer(),
      );

      final appPath = _macOSAppPath(root);
      final firstSign = commands.indexWhere(
        (command) => command.contains("/usr/bin/codesign --force"),
      );
      expect(commands, contains("HOOK ./tool/prepare_macos_release.sh"));
      expect(commands.indexOf("HOOK ./tool/prepare_macos_release.sh"),
          lessThan(firstSign));
      final signCommands = commands
          .where((command) => command.contains("/usr/bin/codesign --force"))
          .toList();
      expect(signCommands, hasLength(3));
      expect(signCommands[0], contains("extraCopied=true"));
      expect(
        signCommands[0],
        contains("Developer ID Application: Example Corp (TEAMID1234)"),
      );
      expect(
        signCommands[0],
        contains(path.join(appPath, "Contents", "Frameworks", "App.framework")),
      );
      expect(
        signCommands[1],
        contains(
          path.join(
            appPath,
            "Contents",
            "Frameworks",
            "FlutterMacOS.framework",
          ),
        ),
      );
      expect(signCommands[2], contains(appPath));
      final notaryIndex = commands.indexWhere(
        (command) => command.contains("/usr/bin/xcrun notarytool submit"),
      );
      expect(notaryIndex, greaterThan(firstSign));
      expect(
        commands[notaryIndex],
        contains("--keychain-profile desktop-updater-notary"),
      );
      expect(
        commands[notaryIndex],
        contains("--keychain /Users/me/Library/Keychains/login.keychain-db"),
      );
      expect(commands[notaryIndex], contains("--output-format json"));
      expect(
        commands.indexWhere(
          (command) => command.contains("/usr/bin/xcrun stapler staple"),
        ),
        greaterThan(notaryIndex),
      );
      expect(
        commands.indexWhere(
          (command) => command.contains("/usr/sbin/spctl --assess"),
        ),
        greaterThan(notaryIndex),
      );
      expect(
        commands.indexWhere((command) => command.startsWith("PACKAGE ")),
        greaterThan(notaryIndex),
      );
    } finally {
      await root.delete(recursive: true);
    }
  });

  test("macOS notarization stops before stapling when notary rejects archive",
      () async {
    final root = await _createMacOSFixture();
    final commands = <String>[];
    final packager = _RecordingPackager(commands);
    try {
      final publisher = ReleasePublisher(
        skipBuild: true,
        packager: packager,
        runProcess: (executable, arguments) async {
          commands.add([executable, ...arguments].join(" "));
          if (executable == "/usr/bin/xcrun" &&
              arguments.length >= 2 &&
              arguments[0] == "notarytool" &&
              arguments[1] == "submit") {
            return ProcessResult(
              0,
              0,
              '{"id":"fake-submission","status":"Invalid"}',
              "",
            );
          }
          if (executable == "/usr/bin/ditto" && arguments.first == "-c") {
            await File(arguments.last).writeAsBytes(<int>[1, 2, 3]);
          }
          if (executable == "/usr/bin/codesign" &&
              arguments.length == 2 &&
              arguments.first == "-dvvv") {
            return ProcessResult(
              0,
              0,
              _fakeCodeDetails(arguments.last),
              "",
            );
          }
          return ProcessResult(0, 0, "", "");
        },
      );

      await expectLater(
        publisher.publish(
          projectRoot: root,
          platform: "macos",
          overrides: const ReleasePublishOverrides(),
          output: StringBuffer(),
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            "message",
            contains("macOS notarization failed: Invalid"),
          ),
        ),
      );

      expect(
        commands.any((command) => command.contains("stapler")),
        isFalse,
      );
      expect(
        commands.any((command) => command.startsWith("PACKAGE ")),
        isFalse,
      );
    } finally {
      await root.delete(recursive: true);
    }
  });
}

Future<void> _writeAdditionalFilesConfig(Directory root) async {
  await File(path.join(root.path, "desktop_updater.yaml")).writeAsString("""
updates:
  baseUrl: https://updates.example.com

additionalFiles:
  - source: release-assets/manuals/*
    destination: Contents/Resources/Manuals
    platforms: [macos]

macos:
  notarize: true
  developerIdApplication: "Developer ID Application: Example Corp (TEAMID1234)"
  notaryProfile: desktop-updater-notary
  keychain: /Users/me/Library/Keychains/login.keychain-db

hooks:
  prePackage:
    - command: ./tool/prepare_macos_release.sh
      platforms: [macos]
""");
  final manuals = Directory(
    path.join(root.path, "release-assets", "manuals"),
  );
  await manuals.create(recursive: true);
  await File(path.join(manuals.path, "pilot-guide.pdf"))
      .writeAsString("manual");
}

Future<Directory> _createMacOSFixture() async {
  final root = await Directory.systemTemp.createTemp("notarize_publish_");
  await File(path.join(root.path, "pubspec.yaml")).writeAsString("""
name: notarize_fixture
version: 2.0.1+201
""");
  await File(path.join(root.path, "desktop_updater.yaml")).writeAsString("""
updates:
  baseUrl: https://updates.example.com

macos:
  notarize: true
  developerIdApplication: "Developer ID Application: Example Corp (TEAMID1234)"
  notaryProfile: desktop-updater-notary
  keychain: /Users/me/Library/Keychains/login.keychain-db
""");

  final configs = Directory(path.join(root.path, "macos", "Runner", "Configs"));
  await configs.create(recursive: true);
  await File(path.join(configs.path, "AppInfo.xcconfig")).writeAsString("""
PRODUCT_NAME = Notarize Fixture
PRODUCT_BUNDLE_IDENTIFIER = com.example.notarizeFixture
""");

  final app = Directory(_macOSAppPath(root));
  await app.create(recursive: true);
  await Directory(path.join(app.path, "Contents", "MacOS"))
      .create(recursive: true);
  await File(path.join(app.path, "Contents", "Info.plist")).writeAsString(
    _plist(
      bundleIdentifier: "com.example.notarizeFixture",
      executable: "NotarizeFixture",
    ),
  );
  await File(path.join(app.path, "Contents", "MacOS", "NotarizeFixture"))
      .writeAsBytes(_machOBytes);
  for (final frameworkName in [
    "App.framework",
    "FlutterMacOS.framework",
  ]) {
    final framework = Directory(
      path.join(app.path, "Contents", "Frameworks", frameworkName),
    );
    await framework.create(recursive: true);
    await Directory(path.join(framework.path, "Resources"))
        .create(recursive: true);
    final stem =
        frameworkName.substring(0, frameworkName.length - ".framework".length);
    await File(path.join(framework.path, "Resources", "Info.plist"))
        .writeAsString(
      _plist(
        bundleIdentifier: "com.example.$stem.framework",
        executable: stem,
      ),
    );
    await File(path.join(framework.path, stem)).writeAsBytes(_machOBytes);
  }

  return root;
}

String _macOSAppPath(Directory root) {
  return path.join(
    root.path,
    "build",
    "macos",
    "Build",
    "Products",
    "Release",
    "Notarize Fixture.app",
  );
}

class _RecordingPackager implements ReleasePackager {
  _RecordingPackager(this.commands);

  final List<String> commands;

  @override
  Future<ReleasePackageResult> package(ReleasePackageRequest request) async {
    commands.add("PACKAGE ${request.input.path}");
    await request.outputDirectory.create(recursive: true);
    final artifact = File(
      path.join(request.outputDirectory.path, "Notarize-2.0.1-macos.zip"),
    );
    final archive = Archive();
    final input = request.input as Directory;
    await for (final entity in input.list(recursive: true)) {
      if (entity is File) {
        archive.addFile(
          ArchiveFile.bytes(
            path.relative(entity.path, from: input.parent.path),
            await entity.readAsBytes(),
          ),
        );
      }
    }
    await artifact.writeAsBytes(ZipEncoder().encode(archive));
    final release =
        File(path.join(request.outputDirectory.path, "release.json"));
    final descriptor = ReleaseDescriptor(
      schemaVersion: 3,
      packageId: request.packageId,
      appName: request.appName,
      version: request.version,
      buildNumber: request.buildNumber,
      platform: request.platform,
      channel: request.channel,
      artifact: ReleaseArtifact(
        kind: "zip",
        url: request.artifactUrl,
        sha256: "a" * 64,
        length: await artifact.length(),
      ),
      install: ReleaseInstall(strategy: request.installStrategy),
      minimumUpdaterVersion: request.minimumUpdaterVersion,
      generatedAt: DateTime.utc(2026, 6, 12),
    );
    await release.writeAsString("{}");
    return ReleasePackageResult(
      artifact: artifact,
      releaseFile: release,
      descriptor: descriptor,
    );
  }
}

const _machOBytes = [0xfe, 0xed, 0xfa, 0xcf, 0x00, 0x00, 0x00, 0x00];

String _plist({required String bundleIdentifier, required String executable}) {
  return """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$bundleIdentifier</string>
<key>CFBundleExecutable</key><string>$executable</string>
</dict></plist>
""";
}

String _fakeCodeDetails(String target) {
  final identifier = target.endsWith("Notarize Fixture.app")
      ? "com.example.notarizeFixture"
      : target.contains("App.framework")
          ? "com.example.App.framework"
          : "com.example.FlutterMacOS.framework";
  return "Identifier=$identifier\nTeamIdentifier=TEAMID1234\nflags=0x10000(runtime)";
}

final class _SkipFinalAuditTrust extends MacOSReleaseTrust {
  _SkipFinalAuditTrust(ProcessRunner runProcess)
      : super(runProcess: runProcess);

  @override
  Future<void> auditFinalArtifact({
    required File artifact,
    required String kind,
    required String appBundleName,
    required String expectedApplicationIdentifier,
  }) async {}
}
