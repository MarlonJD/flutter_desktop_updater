import "dart:io";

import "package:flutter_test/flutter_test.dart";

void main() {
  test("macOS SwiftPM package depends on FlutterFramework", () {
    final manifest =
        File("macos/desktop_updater/Package.swift").readAsStringSync();

    expect(manifest, contains('name: "desktop_updater"'));
    expect(manifest, contains('.library(name: "desktop-updater"'));
    expect(manifest, contains('.macOS("10.15")'));
    expect(
      manifest,
      contains(
        '.package(name: "FlutterFramework", path: "../FlutterFramework")',
      ),
    );
    expect(
      manifest,
      contains(
        '.product(name: "FlutterFramework", package: "FlutterFramework")',
      ),
    );
  });

  test("macOS production updater gates stay enabled by default", () {
    final pluginSource = File(
      "macos/desktop_updater/Sources/desktop_updater/DesktopUpdaterPlugin.swift",
    ).readAsStringSync();
    final project = File(
      "example/macos/Runner.xcodeproj/project.pbxproj",
    ).readAsStringSync();
    final releaseEntitlements = File(
      "example/macos/Runner/Release.entitlements",
    ).readAsStringSync();

    expect(pluginSource, contains("#if DEBUG"));
    expect(pluginSource, contains("allowUnsignedMacOSUpdates"));
    expect(
      pluginSource,
      contains('let allowUnsignedValue = allowUnsignedMacOSUpdates ? "1" : ""'),
    );
    expect(
      pluginSource,
      contains(
        r'ALLOW_UNSIGNED_MACOS=\"${DESKTOP_UPDATER_SMOKE_ALLOW_UNSIGNED_MACOS:-\(allowUnsignedValue)}\"',
      ),
    );
    expect(pluginSource, contains("#else"));
    expect(
      pluginSource,
      contains(r'ALLOW_UNSIGNED_MACOS=\"\(allowUnsignedValue)\"'),
    );
    expect(pluginSource, contains("/usr/bin/codesign --verify"));
    expect(pluginSource, contains("/usr/sbin/spctl --assess"));
    expect(pluginSource, contains("/usr/bin/xcrun stapler validate"));
    expect(pluginSource, contains("TeamIdentifier mismatch"));
    expect(pluginSource, contains("CFBundleIdentifier mismatch"));

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
