import "dart:io";

import "package:flutter_test/flutter_test.dart";

void main() {
  test("CocoaPods fallback compiles helper and Flutter adapter sources", () {
    final podspec = File("macos/desktop_updater.podspec").readAsStringSync();

    expect(podspec, contains("s.source_files = ["));
    for (final file in <String>[
      "DesktopUpdaterVersion.swift",
      "Diagnostics.swift",
      "MacInstallHelper.swift",
      "MacInstallRequest.swift",
    ]) {
      expect(
        podspec,
        contains(
          "File.join('desktop_updater', 'Sources', "
          "'DesktopUpdaterKit', '$file')",
        ),
      );
    }
    expect(
      podspec,
      contains(
        "File.join('desktop_updater', 'Sources', "
        "'desktop_updater', 'DesktopUpdaterPlugin.swift')",
      ),
    );
    expect(podspec, isNot(contains("'**', '*.swift'")));
    expect(podspec, contains("s.platform = :osx, '10.14'"));
    expect(podspec, contains("s.swift_version = '5.0'"));
  });

  test("CocoaPods helper source set owns its provenance dependencies", () {
    final podspec = File("macos/desktop_updater.podspec").readAsStringSync();
    final requestSource = File(
      "macos/desktop_updater/Sources/DesktopUpdaterKit/MacInstallRequest.swift",
    ).readAsStringSync();

    expect(podspec, isNot(contains("'Runtime'")));
    expect(requestSource, contains("public struct StageProvenanceEntry"));
    expect(requestSource, contains("public struct StageProvenanceState"));
    expect(requestSource, contains("public enum StageProvenance"));
    expect(requestSource, contains("import CommonCrypto"));
    expect(requestSource, isNot(contains("import CryptoKit")));
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
