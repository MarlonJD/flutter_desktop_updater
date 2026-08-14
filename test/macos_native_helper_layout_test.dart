import "dart:io";

import "package:flutter_test/flutter_test.dart";

void main() {
  const helperRoot = "macos/install_helper";
  const kitRoot = "macos/desktop_updater";

  test("macOS install helper package and embed contract exist", () {
    for (final requiredPath in <String>[
      "$helperRoot/Package.swift",
      "$helperRoot/Sources/DesktopUpdaterInstallHelper/main.swift",
      "$helperRoot/Sources/DesktopUpdaterInstallHelper/HelperVersion.swift",
      "$helperRoot/Sources/DesktopUpdaterInstallHelper/NativeInstallRequest.swift",
      "$helperRoot/Tests/DesktopUpdaterInstallHelperTests/HelperVersionTests.swift",
      "$helperRoot/Tests/DesktopUpdaterInstallHelperTests/NativeInstallRequestTests.swift",
      "$kitRoot/Sources/DesktopUpdaterKit/InstallHelper/EmbeddedHelperLocator.swift",
      "$kitRoot/Tests/DesktopUpdaterKitTests/EmbeddedHelperLayoutTests.swift",
    ]) {
      expect(
        File(requiredPath).existsSync(),
        isTrue,
        reason: "$requiredPath must exist",
      );
    }
  });

  test("helper is a distinct macOS 10.14 executable product", () {
    final manifest = _source("$helperRoot/Package.swift");
    expect(manifest, contains(".macOS(.v10_14)"));
    expect(
      manifest,
      contains(
        '.executable(name: "DesktopUpdaterInstallHelper", '
        'targets: ["DesktopUpdaterInstallHelper"])',
      ),
    );
    expect(manifest, contains(".executableTarget("));
    expect(manifest, contains('name: "DesktopUpdaterInstallHelper"'));
    expect(manifest, isNot(contains("DesktopUpdaterKit")));
    expect(manifest, isNot(contains("Flutter")));
  });

  test("helper diagnostic mode uses the strict protocol parser", () {
    final sources = <String>[
      _source(
        "$helperRoot/Sources/DesktopUpdaterInstallHelper/main.swift",
      ),
      _source(
        "$helperRoot/Sources/DesktopUpdaterInstallHelper/HelperVersion.swift",
      ),
      _source(
        "$helperRoot/Sources/DesktopUpdaterInstallHelper/NativeInstallRequest.swift",
      ),
    ].join("\n");
    expect(sources, contains('"--version"'));
    expect(sources, contains('"--test-parse-protocol"'));
    expect(sources, contains("JSONSerialization"));
    for (final forbidden in <String>[
      "FileManager",
      "Process(",
      "copyItem",
      "removeItem",
      "moveItem",
      "replaceItem",
      "AuthorizationExecuteWithPrivileges",
      "SMJobBless",
      "NSWorkspace",
      "/usr/bin/",
      "/usr/sbin/",
    ]) {
      expect(sources, isNot(contains(forbidden)), reason: forbidden);
    }
  });

  test("helper executable version follows the 3.1.6 package version", () {
    final helperVersion = _source(
      "$helperRoot/Sources/DesktopUpdaterInstallHelper/HelperVersion.swift",
    );
    final plist = _source("$helperRoot/Configuration/Helper-Info.plist");

    expect(helperVersion, contains('semanticVersion = "3.1.6"'));
    expect(
        plist,
        contains(
            "<key>CFBundleShortVersionString</key>\n  <string>3.1.6</string>"));
    expect(plist,
        contains("<key>CFBundleVersion</key>\n  <string>3.1.6</string>"));
  });

  test("embedded helper discovery uses only fixed bundle-relative locations",
      () {
    final source = _source(
      "$kitRoot/Sources/DesktopUpdaterKit/InstallHelper/EmbeddedHelperLocator.swift",
    );
    expect(
      source,
      contains(
        '"Contents/Helpers/DesktopUpdaterInstallHelper"',
      ),
    );
    expect(source, contains('"Contents/Library/LaunchDaemons"'));
    expect(source, contains("oneShotHelperURL"));
    expect(source, contains("privilegedHelperURL"));
    expect(source, contains("launchDaemonPlistURL"));
    expect(source, contains("invalidServiceIdentifier"));
    for (final forbidden in <String>[
      "PATH",
      "NSTemporaryDirectory",
      "temporaryDirectory",
      "currentDirectoryPath",
      "fileExists",
      "enumerator",
      "contentsOfDirectory",
    ]) {
      expect(source, isNot(contains(forbidden)), reason: forbidden);
    }
  });

  test("root and plugin SwiftPM products keep the macOS 10.15 floor", () {
    for (final manifestPath in <String>[
      "Package.swift",
      "$kitRoot/Package.swift",
    ]) {
      final manifest = _source(manifestPath);
      expect(manifest, contains('.macOS("10.15")'));
      expect(
        manifest,
        contains(
          '.library(name: "DesktopUpdaterKit", '
          'targets: ["DesktopUpdaterKit"])',
        ),
      );
      expect(manifest, isNot(contains("DesktopUpdaterInstallHelper")));
    }
  });

  test("macOS approval requirement is a stable Flutter error and action", () {
    final plugin = _source(
      "$kitRoot/Sources/desktop_updater/DesktopUpdaterPlugin.swift",
    );
    expect(plugin, contains('case "openMacOSBackgroundItemsSettings"'));
    expect(plugin, contains("SMAppService.openSystemSettingsLoginItems()"));
    expect(plugin, contains('code: "PrivilegedHelperApprovalRequired"'));
  });
}

String _source(String filePath) => File(filePath).readAsStringSync();
