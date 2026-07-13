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

  test("macOS ZIP smoke waits for complete helper evidence", () {
    final workflow = readFile(".github/workflows/desktop-updater-ci.yml");
    final start = workflow.indexOf("- name: macOS native runtime ZIP smoke");
    final end = workflow.indexOf("\n  macos-flutter:", start);

    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final lane = workflow.substring(start, end);
    expect(
      lane,
      contains(
        r'''for attempt in $(seq 1 60); do
            if [ "$(tr -d '\r\n' < "$smoke_root/install/$app_name/Contents/Resources/version.txt" 2>/dev/null || true)" = "2.7.1" ] &&
               [ -d "$smoke_root/runtime/staging" ] &&
               [ -z "$(find "$smoke_root/runtime/staging" -mindepth 1 -maxdepth 1 -print -quit)" ] &&
               grep -q '"event":"move success"' "$smoke_root/helper-diagnostics.jsonl" 2>/dev/null &&
               grep -q '"event":"cleanup success"' "$smoke_root/helper-diagnostics.jsonl" 2>/dev/null &&
               [ -s "$smoke_root/runtime/runtime-diagnostics.log" ]; then
              break
            fi''',
      ),
    );
  });

  test("Linux ZIP smoke binds install root to the executable parent", () {
    final workflow = readFile(".github/workflows/desktop-updater-ci.yml");
    final start = workflow.indexOf("- name: Linux native runtime ZIP smoke");
    final end = workflow.indexOf("- name: Enable Linux desktop", start);

    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final lane = workflow.substring(start, end);
    expect(
      lane,
      contains(r'mkdir -p "$smoke_root/install" "$smoke_root/payload"'),
    );
    expect(
      lane,
      contains(r'"$smoke_root/install/runtime_compile"'),
    );
    expect(
      RegExp(
        RegExp.escape(
          ".desktop_updater_install_identity.json",
        ),
      ).allMatches(lane),
      hasLength(2),
    );
    expect(lane, contains('"packageId":"com.example.native-runtime-smoke"'));
    expect(lane, contains("--executable-relative-path runtime_compile"));
    expect(lane, isNot(contains(r'"$smoke_root/install/bin/runtime_compile"')));
  });

  test("Windows ZIP smoke seeds matching installed identity", () {
    final workflow = readFile(".github/workflows/desktop-updater-ci.yml");
    final start = workflow.indexOf("- name: Windows native runtime ZIP smoke");
    final end = workflow.indexOf(
      "- name: Windows native runtime Inno smoke",
      start,
    );

    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final lane = workflow.substring(start, end);
    expect(
      RegExp(
        RegExp.escape(".desktop_updater_install_identity.json"),
      ).allMatches(lane),
      hasLength(2),
    );
    expect(lane, contains(r'"packageId":"com.example.native-runtime-smoke"'));
    expect(
      lane.indexOf(".desktop_updater_install_identity.json"),
      lessThan(lane.indexOf("Compress-Archive")),
    );
  });

  test("Windows ZIP smoke outlives helper retries and preserves diagnostics",
      () {
    final workflow = readFile(".github/workflows/desktop-updater-ci.yml");
    final start = workflow.indexOf("- name: Windows native runtime ZIP smoke");
    final end = workflow.indexOf(
      "- name: Windows native runtime Inno smoke",
      start,
    );

    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final lane = workflow.substring(start, end);
    expect(
      lane,
      contains(r"for ($attempt = 0; $attempt -lt 600; $attempt++)"),
    );
    final diagnosticsDump = lane.indexOf(
      r"Get-Content -LiteralPath $diagnosticsPath "
      "-ErrorAction SilentlyContinue",
    );
    final versionFailure = lane.indexOf(
      "Windows ZIP runtime smoke did not install version 2.7.1.",
    );
    final smokeCleanup = lane.indexOf(
      r"Remove-Item -LiteralPath $smokeRoot -Recurse -Force",
    );
    expect(diagnosticsDump, greaterThanOrEqualTo(0));
    expect(versionFailure, greaterThan(diagnosticsDump));
    expect(smokeCleanup, greaterThan(versionFailure));
  });

  test("direct Flutter smokes hand off owned verified provenance", () {
    final tool = readFile("example/tool/updater_smoke.dart");
    final app = readFile("example/lib/app.dart");

    expect(tool, contains("createOwnedStagingDirectory("));
    expect(tool, contains("_copyInstallTree("));
    expect(tool, contains("robocopy"));
    expect(tool, contains("executable = \"/bin/cp\""));
    expect(tool, contains("Process.run(executable, arguments)"));
    expect(tool, contains(".desktop_updater_install_identity.json"));
    expect(tool, contains("Platform.isWindows || Platform.isLinux"));
    expect(tool, contains("writeStagedUpdateProvenance("));
    expect(tool, contains("DESKTOP_UPDATER_SMOKE_PROVENANCE_SHA256"));
    expect(app, contains("DESKTOP_UPDATER_SMOKE_PROVENANCE_SHA256"));
    expect(app, contains("verifyStagedUpdateProvenance("));
    expect(
      app,
      contains("DesktopUpdaterPlatform.instance.installUpdateWithContext("),
    );
    expect(app, contains("stageProvenanceSha256:"));
    expect(app, contains("stageProvenanceNonce:"));
    expect(app, contains("stageProvenanceEntries:"));
    expect(app, contains("expectedArtifactSha256:"));
  });

  test("Windows ZIP handoff does not read Inno signer metadata", () {
    final source = readFile(
      "windows/native/src/runtime/artifact_stager_windows.cpp",
    );
    final handoffStart = source.indexOf(
      "WindowsInstallHandoffResult HandoffWindowsInstall(",
    );
    final handoffEnd = source.indexOf(
      "desktop_updater_result_v1 result",
      handoffStart,
    );

    expect(handoffStart, greaterThanOrEqualTo(0));
    expect(handoffEnd, greaterThan(handoffStart));
    final handoff = source.substring(handoffStart, handoffEnd);
    expect(
      handoff,
      matches(
        RegExp(
          r'if\s*\(descriptor\.artifact\.kind == "innoInstaller"\)\s*\{'
          r'\s*for\s*\(const std::string& thumbprint\s*:'
          r'\s*AuthenticodeThumbprints\(descriptor\)\)',
        ),
      ),
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
