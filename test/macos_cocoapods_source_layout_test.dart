import "dart:io";

import "package:flutter_test/flutter_test.dart";

void main() {
  test("CocoaPods fallback compiles only the exact helper and adapter sources",
      () {
    final podspec = File("macos/desktop_updater.podspec").readAsStringSync();
    final sourceFilesBlock = RegExp(
      r"s\.source_files\s*=\s*\[(.*?)\]",
      dotAll: true,
    ).firstMatch(podspec)!.group(1)!;
    final sourceEntries = RegExp(
      r"File\.join\(([^\n]+)\)",
    ).allMatches(sourceFilesBlock).map((match) => match.group(1)!).toList();

    expect(
      sourceEntries,
      equals(<String>[
        "'desktop_updater', 'Sources', 'DesktopUpdaterKit', 'DesktopUpdaterVersion.swift'",
        "'desktop_updater', 'Sources', 'DesktopUpdaterKit', 'Diagnostics.swift'",
        "'desktop_updater', 'Sources', 'DesktopUpdaterKit', 'MacInstallHelper.swift'",
        "'desktop_updater', 'Sources', 'DesktopUpdaterKit', 'MacInstallRequest.swift'",
        "'desktop_updater', 'Sources', 'desktop_updater', 'DesktopUpdaterPlugin.swift'",
      ]),
    );
    expect(sourceFilesBlock, isNot(contains("Runtime")));
    expect(sourceFilesBlock, isNot(matches(RegExp(r"[?*]"))));
    expect(podspec, contains("s.platform = :osx, '10.14'"));
    expect(podspec, contains("s.swift_version = '5.0'"));
  });

  test("CI typechecks the exact CocoaPods source set for macOS 10.14", () {
    final workflow = File(
      ".github/workflows/desktop-updater-ci.yml",
    ).readAsStringSync();
    const command =
        r'xcrun swiftc -typecheck -target x86_64-apple-macosx10.14 -swift-version 5 -module-cache-path "$RUNNER_TEMP/desktop-updater-swift-module-cache" -F "$FLUTTER_ROOT/bin/cache/artifacts/engine/darwin-x64/FlutterMacOS.xcframework/macos-arm64_x86_64" macos/desktop_updater/Sources/DesktopUpdaterKit/DesktopUpdaterVersion.swift macos/desktop_updater/Sources/DesktopUpdaterKit/Diagnostics.swift macos/desktop_updater/Sources/DesktopUpdaterKit/MacInstallHelper.swift macos/desktop_updater/Sources/DesktopUpdaterKit/MacInstallRequest.swift macos/desktop_updater/Sources/desktop_updater/DesktopUpdaterPlugin.swift';

    expect(workflow, contains(command));
  });

  test("macOS 10.14 launch uses the legacy API with LaunchFailed parity", () {
    final pluginSource = File(
      "macos/desktop_updater/Sources/desktop_updater/DesktopUpdaterPlugin.swift",
    ).readAsStringSync();

    expect(pluginSource, contains("if #available(macOS 10.15, *)"));
    expect(pluginSource, contains("NSWorkspace.OpenConfiguration()"));
    expect(
      pluginSource,
      contains("NSWorkspace.shared.launchApplication(\n"
          "                    destinationURL.path\n"
          "                )"),
    );
    expect(
      RegExp(r'code: "LaunchFailed"').allMatches(pluginSource),
      hasLength(2),
    );
    expect(
      RegExp(r'message: "Unable to launch the copied app\."')
          .allMatches(pluginSource),
      hasLength(2),
    );
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
