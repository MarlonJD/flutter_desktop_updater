import "dart:convert";
import "dart:io";

import "package:desktop_updater/src/core/release_index.dart";
import "package:desktop_updater/src/core/release_index_signature_verifier.dart";
import "package:flutter_test/flutter_test.dart";

import "../tool/native_runtime_smoke_server.dart" as smoke_server;

void main() {
  test("external samples drive the complete packaged runtime flow", () {
    final swiftClient = readFile(
      "macos/desktop_updater/Sources/DesktopUpdaterKit/Runtime/UpdateClient.swift",
    );
    final swiftSample = readDirectory("example/native/macos-runtime");
    final linuxHeader = readFile(
      "linux/native/include/desktop_updater_runtime.h",
    );
    final linuxSample = readDirectory("example/native/linux-cmake-runtime");
    final windowsHeader = readFile(
      "windows/native/include/desktop_updater_runtime_c.h",
    );
    final dotnetClient = readFile(
      "windows/native/dotnet/DesktopUpdater.Native/DesktopUpdaterClient.cs",
    );
    final windowsSample = readDirectory(
      "example/native/windows-dotnet-runtime",
    );

    for (final source in [swiftClient, swiftSample]) {
      expect(source, contains("checkForUpdate"));
      expect(source, contains("downloadVerifyAndStage"));
      expect(source, contains("installAndRelaunch"));
    }
    for (final source in [linuxHeader, linuxSample]) {
      expect(source, contains("CheckForUpdate"));
      expect(source, contains("DownloadVerifyAndStage"));
      expect(source, contains("InstallAndRelaunch"));
    }
    for (final source in [windowsHeader, dotnetClient, windowsSample]) {
      expect(source.toLowerCase(), contains("check_for_update"));
      expect(source.toLowerCase(), contains("download_verify_and_stage"));
      expect(source.toLowerCase(), contains("install_and_relaunch"));
    }
  });

  test("runtime smoke harness is local, bounded, signed, and disposable", () {
    final server = readFile("tool/native_runtime_smoke_server.dart");
    final workflow = readFile(".github/workflows/desktop-updater-ci.yml");
    final linuxSample = readDirectory("example/native/linux-cmake-runtime");

    expect(server, contains("Ed25519"));
    expect(server, contains("native-runtime-smoke-stable"));
    expect(server, contains("127.0.0.1"));
    expect(server, contains("HttpHeaders.rangeHeader"));
    expect(server, contains("maximumArtifactBytes"));
    expect(server, contains("delete(recursive: true)"));

    for (final lane in [
      "macOS native runtime ZIP smoke",
      "macOS native runtime DMG smoke",
      "macOS native runtime PKG smoke",
      "Windows native runtime ZIP smoke",
      "Windows native runtime Inno smoke",
      "Linux native runtime ZIP smoke",
    ]) {
      expect(workflow, contains(lane), reason: lane);
    }
    expect(workflow, contains("DESKTOP_UPDATER_RUN_SIGNED_NATIVE_RUNTIME_E2E"));
    expect(linuxSample, contains("/usr/bin"));
    expect(linuxSample, contains("must remain unchanged"));
  });

  test("runtime smoke server signs app archive discovery metadata", () async {
    final json = await smoke_server.signedIndex(
      appName: "NativeRuntimeSmoke",
      version: "2.7.1",
      buildNumber: 271,
      platform: "macos",
      releaseURL: Uri.parse("http://127.0.0.1:43892/release.json"),
    );
    final publicKey = await smoke_server
        .smokeKeyPair()
        .then((keyPair) => keyPair.extractPublicKey());
    final index = ReleaseIndex.fromJson(json);

    expect(index.signature?.publicKeyId, smoke_server.publicKeyId);
    expect(
      await Ed25519ReleaseIndexSignatureVerifier({
        smoke_server.publicKeyId: base64Encode(publicKey.bytes),
      }).verify(index),
      isTrue,
    );
  });

  test("runtime smoke consumers use installed package boundaries", () {
    final swiftPackage = readFile(
      "example/native/macos-runtime/Package.swift",
    );
    final dotnetProject = readFile(
      "example/native/windows-dotnet-runtime/DesktopUpdater.RuntimeCompile.csproj",
    );
    final linuxProject = readFile(
      "example/native/linux-cmake-runtime/CMakeLists.txt",
    );
    final workflow = readFile(".github/workflows/desktop-updater-ci.yml");

    expect(swiftPackage, contains("DESKTOP_UPDATER_PACKAGE_PATH"));
    expect(dotnetProject, contains("PackageReference"));
    expect(dotnetProject, isNot(contains("ProjectReference")));
    expect(linuxProject, contains("find_package(desktop_updater_native"));
    expect(workflow, contains(r"DesktopUpdater.Native.$"));
    expect(workflow, contains("CMAKE_PREFIX_PATH"));
  });

  test("ZIP smokes preserve caller-owned staging roots", () {
    final workflow = readFile(".github/workflows/desktop-updater-ci.yml");

    expect(workflow, contains(r"$cleanupComplete = $false"));
    expect(workflow, contains(r"$stagingRoot = Join-Path $smokeRoot"));
    expect(workflow, contains(r"$stagingClean = (Test-Path -LiteralPath"));
    expect(
      workflow,
      contains(r"Get-ChildItem -LiteralPath $stagingRoot -Force"),
    );
    expect(
      workflow,
      contains(
        r"$versionReady -and $stagingClean -and $cleanupComplete",
      ),
    );
    expect(workflow, isNot(contains(r"$stagingRemoved")));
    expect(
      RegExp(
        RegExp.escape(r'test -d "$smoke_root/runtime/staging"'),
      ).allMatches(workflow),
      hasLength(2),
    );
    expect(
      RegExp(
        RegExp.escape(
          r'test -z "$(find "$smoke_root/runtime/staging" '
          r'-mindepth 1 -maxdepth 1 -print -quit)"',
        ),
      ).allMatches(workflow),
      hasLength(2),
    );
    expect(
      workflow,
      isNot(contains(r'test ! -e "$smoke_root/runtime/staging"')),
    );
  });
}

String readFile(String path) {
  final file = File(path);
  expect(file.existsSync(), isTrue, reason: "$path must exist");
  return file.existsSync() ? file.readAsStringSync() : "";
}

String readDirectory(String path) {
  final directory = Directory(path);
  expect(directory.existsSync(), isTrue, reason: "$path must exist");
  if (!directory.existsSync()) return "";
  return directory
      .listSync(recursive: true)
      .whereType<File>()
      .where((file) => !file.path.contains("${Platform.pathSeparator}.build"))
      .where((file) => !file.path.contains("${Platform.pathSeparator}obj"))
      .where((file) => !file.path.contains("${Platform.pathSeparator}bin"))
      .map((file) => file.readAsStringSync())
      .join("\n");
}
