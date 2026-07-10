import "dart:io";

import "package:flutter_test/flutter_test.dart";

void main() {
  test("CocoaPods fallback compiles helper and Flutter adapter sources", () {
    final podspec = File("macos/desktop_updater.podspec").readAsStringSync();

    expect(podspec, contains("s.source_files = ["));
    expect(
      podspec,
      contains(
        "File.join('desktop_updater', 'Sources', "
        "'DesktopUpdaterKit', '**', '*.swift')",
      ),
    );
    expect(
      podspec,
      contains(
        "File.join('desktop_updater', 'Sources', "
        "'desktop_updater', '**', '*.swift')",
      ),
    );
    expect(podspec, contains("s.platform = :osx, '10.14'"));
    expect(podspec, contains("s.swift_version = '5.0'"));
  });

  test("CocoaPods fallback excludes SwiftPM runtime sources", () {
    final podspec = File("macos/desktop_updater.podspec").readAsStringSync();

    expect(
      podspec,
      contains(
        "s.exclude_files = File.join('desktop_updater', 'Sources', "
        "'DesktopUpdaterKit', 'Runtime', '**', '*.swift')",
      ),
    );
  });

  test("shared helper sources remain Flutter-free", () {
    final helperSources = Directory(
      "macos/desktop_updater/Sources/DesktopUpdaterKit",
    )
        .listSync()
        .whereType<File>()
        .map((file) => file.readAsStringSync())
        .join("\n");
    final pluginSource = File(
      "macos/desktop_updater/Sources/desktop_updater/DesktopUpdaterPlugin.swift",
    ).readAsStringSync();

    expect(helperSources, isNot(contains("FlutterMacOS")));
    expect(helperSources, isNot(contains("FlutterMethodChannel")));
    expect(pluginSource, contains("#if canImport(DesktopUpdaterKit)"));
    expect(pluginSource, contains("import DesktopUpdaterKit"));
  });
}
