import "dart:convert";
import "dart:io";

import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:desktop_updater/src/package/release_packager.dart";
import "package:desktop_updater/src/release_cli/macos/apple_trust_commands.dart";
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
      final publisher = ReleasePublisher(
        skipBuild: true,
        packager: packager,
        runProcess: (executable, arguments) async {
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
      expect(
        commands.take(3),
        everyElement(contains("--preserve-metadata=entitlements")),
      );
      expect(commands[0], contains("extraCopied=true"));
      expect(commands[0], contains("/usr/bin/codesign --force"));
      expect(
        commands[0],
        contains("Developer ID Application: Example Corp (TEAMID1234)"),
      );
      expect(
        commands[0],
        contains(path.join(appPath, "Contents", "Frameworks", "App.framework")),
      );
      expect(commands[1], contains("/usr/bin/codesign --force"));
      expect(
        commands[1],
        contains(
          path.join(
            appPath,
            "Contents",
            "Frameworks",
            "FlutterMacOS.framework",
          ),
        ),
      );
      expect(commands[2], contains("/usr/bin/codesign --force"));
      expect(commands[2], contains(appPath));
      expect(commands[3], contains("/usr/bin/codesign --verify"));
      expect(commands[4], contains("/usr/bin/ditto -c -k --keepParent"));
      expect(commands[5], contains("/usr/bin/xcrun notarytool submit"));
      expect(
        commands[5],
        contains("--keychain-profile desktop-updater-notary"),
      );
      expect(
        commands[5],
        contains("--keychain /Users/me/Library/Keychains/login.keychain-db"),
      );
      expect(commands[5], contains("--output-format json"));
      expect(commands[6], contains("/usr/bin/xcrun stapler staple"));
      expect(commands[7], contains("/usr/bin/xcrun stapler validate"));
      expect(commands[8], contains("/usr/sbin/spctl --assess"));
      expect(commands[9], startsWith("PACKAGE "));
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

  test(
    "native macOS signing preserves each target's own entitlements",
    () async {
      final root = await _createMacOSFixture();
      addTearDown(() => root.delete(recursive: true));
      final app = Directory(_macOSAppPath(root));
      await app.delete(recursive: true);
      final nested = Directory(
        path.join(app.path, "Contents", "Frameworks", "Nested.app"),
      );
      final framework = Directory(
        path.join(app.path, "Contents", "Frameworks", "App.framework"),
      );
      await _createNativeBundle(app, "Outer", framework: false);
      await _createNativeBundle(nested, "Nested", framework: false);
      await _createNativeBundle(framework, "App", framework: true);
      final resource =
          File(path.join(framework.path, "Resources", "t-rex.css"));
      await resource.writeAsString("#main-frame-error { display: block; }\n");
      await _runNative("chmod", ["755", resource.path]);
      final resourceMode = (await resource.stat()).mode;
      final resourceBytes = await resource.readAsBytes();
      const outerXml = "<key>com.apple.security.app-sandbox</key><true/>"
          "<key>com.apple.security.files.user-selected.read-write</key><true/>"
          "<key>com.apple.security.network.client</key><true/>";
      const nestedXml = "<key>com.apple.security.app-sandbox</key><true/>"
          "<key>com.apple.security.files.user-selected.read-only</key><true/>"
          "<key>com.apple.security.application-groups</key><array><string>com.example.group</string></array>";
      final outerEntitlements = File(path.join(root.path, "outer.plist"));
      final nestedEntitlements = File(path.join(root.path, "nested.plist"));
      await outerEntitlements.writeAsString(_nativePlist(outerXml));
      await nestedEntitlements.writeAsString(_nativePlist(nestedXml));
      await _runNative("/usr/bin/codesign", [
        "--force",
        "--sign",
        "-",
        "--entitlements",
        nestedEntitlements.path,
        nested.path,
      ]);
      await _runNative(
        "/usr/bin/codesign",
        ["--force", "--sign", "-", framework.path],
      );
      await _runNative("/usr/bin/codesign", [
        "--force",
        "--sign",
        "-",
        "--entitlements",
        outerEntitlements.path,
        app.path,
      ]);
      final outerBefore = await _nativeEntitlements(app, root);
      final nestedBefore = await _nativeEntitlements(nested, root);
      expect(
        outerBefore,
        containsPair(
          "com.apple.security.files.user-selected.read-write",
          true,
        ),
      );
      expect(
        nestedBefore,
        containsPair("com.apple.security.files.user-selected.read-only", true),
      );
      expect(nestedBefore, isNot(equals(outerBefore)));
      final commands = <String>[];

      Future<ProcessResult> runProcess(
        String executable,
        List<String> arguments,
      ) async {
        commands.add([executable, ...arguments].join(" "));
        if (executable == "/usr/bin/codesign") {
          // Run the production signing arguments with a local ad hoc identity.
          // Notarization, Gatekeeper, and Developer ID trust are outside this test.
          final local = arguments.where((arg) => arg != "--timestamp").toList();
          final sign = local.indexOf("--sign");
          if (sign >= 0) local[sign + 1] = "-";
          return Process.run(executable, local);
        }
        if (executable == "/usr/bin/xcrun" && arguments.first == "notarytool") {
          return ProcessResult(
            0,
            0,
            '{"id":"fixture-submission","status":"Accepted"}',
            "",
          );
        }
        return ProcessResult(0, 0, "", "");
      }

      await ReleasePublisher(
        skipBuild: true,
        packager: _RecordingPackager(commands),
        runProcess: runProcess,
      ).publish(
        projectRoot: root,
        platform: "macos",
        overrides: const ReleasePublishOverrides(),
        output: StringBuffer(),
      );

      expect(await _nativeEntitlements(app, root), outerBefore);
      expect(await _nativeEntitlements(nested, root), nestedBefore);
      expect(await _nativeEntitlements(framework, root), isEmpty);
      expect((await resource.stat()).mode, resourceMode);
      expect(await resource.readAsBytes(), resourceBytes);
      expect(
        commands.where(
          (command) => command.startsWith("/usr/bin/codesign --force"),
        ),
        hasLength(3),
      );

      final trust = AppleTrustCommands(runProcess: runProcess);
      await trust.codesignApp(app: app, identity: "-");
      await trust.verifyApp(app);
      expect(await _nativeEntitlements(app, root), outerBefore);
      expect(await _nativeEntitlements(nested, root), nestedBefore);

      final unsigned = Directory(path.join(root.path, "Unsigned.app"));
      await _createNativeBundle(unsigned, "Unsigned", framework: false);
      await _runNative("/usr/bin/codesign", [
        "--remove-signature",
        path.join(unsigned.path, "Contents", "MacOS", "Unsigned"),
      ]);
      await trust.codesignApp(app: unsigned, identity: "-");
      await trust.verifyApp(unsigned);
      expect(await _nativeEntitlements(unsigned, root), isEmpty);
    },
    skip: !Platform.isMacOS ? "Requires macOS codesign and clang" : false,
  );
}

String _nativePlist(String entries) =>
    '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>$entries</dict></plist>';

Future<void> _createNativeBundle(
  Directory bundle,
  String executable, {
  required bool framework,
}) async {
  final info = File(
    path.join(
      bundle.path,
      framework ? "Resources" : "Contents",
      "Info.plist",
    ),
  );
  final binary = File(
    framework
        ? path.join(bundle.path, executable)
        : path.join(bundle.path, "Contents", "MacOS", executable),
  );
  await info.parent.create(recursive: true);
  await binary.parent.create(recursive: true);
  await info.writeAsString(
    _nativePlist(
      "<key>CFBundleIdentifier</key><string>com.example.$executable</string>"
      "<key>CFBundleExecutable</key><string>$executable</string>"
      "<key>CFBundlePackageType</key><string>${framework ? "FMWK" : "APPL"}</string>"
      "<key>CFBundleVersion</key><string>1</string>",
    ),
  );
  final source = File(path.join(bundle.parent.path, "$executable.c"));
  try {
    await source.writeAsString(
      framework
          ? "int fixtureValue(void) { return 82; }"
          : "int main(void) { return 0; }",
    );
    await _runNative(
      "/usr/bin/clang",
      [if (framework) "-dynamiclib", source.path, "-o", binary.path],
    );
  } finally {
    if (await source.exists()) await source.delete();
  }
}

Future<ProcessResult> _runNative(
  String executable,
  List<String> arguments,
) async {
  final result = await Process.run(executable, arguments);
  expect(
    result.exitCode,
    0,
    reason: "$executable $arguments\n${result.stderr}",
  );
  return result;
}

Future<Object?> _nativeEntitlements(Directory bundle, Directory root) async {
  final result = await _runNative(
    "/usr/bin/codesign",
    ["-d", "--entitlements", ":-", bundle.path],
  );
  final output = "${result.stdout}\n${result.stderr}";
  final start = output.indexOf("<?xml");
  if (start < 0) return <String, Object?>{};
  final end = output.indexOf("</plist>", start);
  expect(end, greaterThan(start));
  final plist = File(path.join(root.path, "observed.plist"));
  await plist.writeAsString(output.substring(start, end + "</plist>".length));
  final converted = await _runNative(
    "/usr/bin/plutil",
    ["-convert", "json", "-o", "-", plist.path],
  );
  return jsonDecode(converted.stdout.toString());
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
  await File(path.join(app.path, "app.txt")).writeAsString("hello");
  for (final frameworkName in [
    "App.framework",
    "FlutterMacOS.framework",
  ]) {
    final framework = Directory(
      path.join(app.path, "Contents", "Frameworks", frameworkName),
    );
    await framework.create(recursive: true);
    await File(path.join(framework.path, "framework.txt")).writeAsString(
      frameworkName,
    );
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
    await artifact.writeAsString("zip");
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
