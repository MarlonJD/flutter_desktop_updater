import "dart:io";

import "package:flutter_test/flutter_test.dart";

void main() {
  test("root SwiftPM package exports the Flutter-free helper kit", () {
    final rootManifest = File("Package.swift").readAsStringSync();
    final pluginManifest =
        File("macos/desktop_updater/Package.swift").readAsStringSync();

    expect(rootManifest, contains('name: "DesktopUpdaterKit"'));
    expect(rootManifest, contains('.library(name: "DesktopUpdaterKit"'));
    expect(rootManifest, contains('.macOS("10.15")'));
    expect(
      rootManifest,
      contains('path: "macos/desktop_updater/Sources/DesktopUpdaterKit"'),
    );
    expect(rootManifest, isNot(contains("FlutterFramework")));
    expect(rootManifest, isNot(contains('name: "desktop_updater"')));

    expect(pluginManifest, contains('name: "desktop_updater"'));
    expect(pluginManifest, contains('.library(name: "DesktopUpdaterKit"'));
    expect(pluginManifest, contains('.library(name: "desktop-updater"'));
    expect(pluginManifest, contains('.macOS("10.15")'));
    expect(
      pluginManifest,
      contains(
        '.package(name: "FlutterFramework", path: "../FlutterFramework")',
      ),
    );
    expect(
      pluginManifest,
      contains(
        '.product(name: "FlutterFramework", package: "FlutterFramework")',
      ),
    );
    expect(pluginManifest, contains('"DesktopUpdaterKit"'));
  });

  test("macOS helper kit exposes constructible public request API", () {
    final requestSource = File(
      "macos/desktop_updater/Sources/DesktopUpdaterKit/MacInstallRequest.swift",
    ).readAsStringSync();
    final helperSource = File(
      "macos/desktop_updater/Sources/DesktopUpdaterKit/MacInstallHelper.swift",
    ).readAsStringSync();
    final diagnosticsSource = File(
      "macos/desktop_updater/Sources/DesktopUpdaterKit/Diagnostics.swift",
    ).readAsStringSync();

    expect(
      requestSource,
      contains("public struct MacInstallRequest: Sendable"),
    );
    expect(requestSource, contains("public init("));
    expect(helperSource, contains("public struct MacInstallHelper"));
    expect(helperSource, contains("public init()"));
    expect(
      helperSource,
      contains(
        "scheduleInstallAndRelaunch(_ request: MacInstallRequest) throws",
      ),
    );
    expect(diagnosticsSource, contains("public struct MacDiagnosticEvent"));
    expect(diagnosticsSource, contains("public init("));
  });

  test("macOS production updater gates stay enabled by default", () {
    final pluginSource = File(
      "macos/desktop_updater/Sources/desktop_updater/DesktopUpdaterPlugin.swift",
    ).readAsStringSync();
    final helperSource = File(
      "macos/desktop_updater/Sources/DesktopUpdaterKit/MacInstallHelper.swift",
    ).readAsStringSync();
    final project = File(
      "example/macos/Runner.xcodeproj/project.pbxproj",
    ).readAsStringSync();
    final releaseEntitlements = File(
      "example/macos/Runner/Release.entitlements",
    ).readAsStringSync();

    expect(pluginSource, contains("#if canImport(DesktopUpdaterKit)"));
    expect(pluginSource, contains("import DesktopUpdaterKit"));
    expect(pluginSource, contains("MacInstallHelper"));
    expect(pluginSource, contains("MacInstallRequest"));
    expect(helperSource, contains("#if DEBUG"));
    expect(pluginSource, contains("allowUnsignedMacOSUpdates"));
    expect(
      helperSource,
      contains(
        'let allowUnsignedValue = request.allowUnsignedUpdates ? "1" : ""',
      ),
    );
    expect(
      helperSource,
      contains(
        r'ALLOW_UNSIGNED_MACOS=\"${DESKTOP_UPDATER_SMOKE_ALLOW_UNSIGNED_MACOS:-\(allowUnsignedValue)}\"',
      ),
    );
    expect(helperSource, contains("#else"));
    expect(
      helperSource,
      contains(r'ALLOW_UNSIGNED_MACOS=\"\(allowUnsignedValue)\"'),
    );
    expect(helperSource, contains("/usr/bin/codesign --verify"));
    expect(helperSource, contains("/usr/sbin/spctl --assess"));
    expect(helperSource, contains("/usr/bin/xcrun stapler validate"));
    expect(helperSource, contains("TeamIdentifier mismatch"));
    expect(helperSource, contains("CFBundleIdentifier mismatch"));
    expect(helperSource, contains("pkg manifest loaded"));
    expect(helperSource, contains('log_event "rollback success"'));

    expect(
      project,
      contains("CODE_SIGN_ENTITLEMENTS = Runner/Release.entitlements;"),
    );
    expect(project, contains("ENABLE_HARDENED_RUNTIME = YES;"));
    expect(
      releaseEntitlements,
      contains("<key>com.apple.security.app-sandbox</key>"),
    );
    expect(releaseEntitlements, contains("<false/>"));
    expect(releaseEntitlements, isNot(contains("get-task-allow")));
  });
}
