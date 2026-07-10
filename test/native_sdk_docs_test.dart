import "dart:io";

import "package:flutter_test/flutter_test.dart";

void main() {
  test("checked native SDK versions match the canonical pubspec version",
      () async {
    final result = await Process.run(
      "dart",
      const ["run", "tool/version_check.dart"],
    );

    expect(result.exitCode, 0, reason: "${result.stdout}\n${result.stderr}");
    expect(result.stdout, contains("Native SDK versions match"));
  });

  test("version sync cannot rewrite release authority files", () {
    final source = _read("tool/sync_versions.dart");

    expect(source, contains("pubspec.yaml"));
    expect(source, contains("desktopUpdaterPackageVersion"));
    expect(source, contains("DesktopUpdaterVersion"));
    expect(source, contains("DESKTOP_UPDATER_NATIVE_VERSION_STRING"));
    expect(source, contains("NuGet"));
    expect(source, isNot(contains("CHANGELOG.md")));
    expect(source, isNot(contains("git tag")));
    expect(source, isNot(contains("writeAsString(pubspec")));
  });

  test("native SDK guide publishes helper and preview runtime boundaries", () {
    final guide = _read("docs/native-sdk.md");
    final runtimeApi = _read("docs/native-runtime-api.md");
    final harness = _read("docs/harness-engineering.md");
    final readme = _read("README.md");
    final publishing = _read("docs/publishing.md");
    final ciGuide = _read("docs/github-actions-ci-cd.md");

    for (final surface in [
      "DesktopUpdaterKit",
      "desktop_updater::native",
      "DesktopUpdater.Native",
      "desktop-updater-macos-arm64",
      "desktop-updater-macos-x64",
      "desktop-updater-windows-x64.exe",
      "desktop-updater-linux-x64",
    ]) {
      expect(guide, contains(surface));
    }
    expect(guide, contains("helper SDK"));
    expect(guide, contains("Native Runtime Preview"));
    expect(guide, contains("signed standalone release assets"));
    for (final operation in [
      "checkForUpdate",
      "downloadVerifyAndStage",
      "installAndRelaunch",
    ]) {
      expect("$guide\n$runtimeApi\n$readme", contains(operation));
    }
    for (final label in [
      "preview",
      "verified locally",
      "verified in CI",
      "not run",
      "blocked",
      "candidate-only",
      "production-ready",
    ]) {
      expect("$guide\n$runtimeApi\n$harness", contains(label));
    }
    for (final boundary in [
      "discovery metadata",
      "canonical JSON",
      "pinned key ID",
      "expectedPackageId",
      "publisher checks",
      "Delta artifacts",
      "Linux prebuilt binary distribution",
    ]) {
      expect(runtimeApi, contains(boundary));
    }
    expect(runtimeApi, isNot(contains("`not implemented`")));
    expect(runtimeApi, contains("not production-ready"));
    expect(harness, contains("macOS native runtime ZIP smoke"));
    expect(harness, contains("Windows native runtime ZIP smoke"));
    expect(harness, contains("Linux native runtime ZIP smoke"));
    expect(harness, contains("workflow_dispatch"));
    expect(readme, contains("docs/native-sdk.md"));
    expect(readme, contains("docs/native-runtime-api.md"));
    expect(publishing, contains("--project-type"));
    expect(publishing, contains("--artifact-root"));
    expect(ciGuide, contains("Standalone CLI candidate matrix"));
    expect(ciGuide, contains("target-host"));
  });

  test("CI validates versions and every native integration boundary", () {
    final workflow = _read(".github/workflows/desktop-updater-ci.yml");
    final harness = _read("tool/harness_check.dart");

    expect(workflow, contains("dart run tool/version_check.dart"));
    expect(workflow, contains("swift test --package-path ."));
    expect(workflow, contains("--enable-swift-package-manager"));
    expect(workflow, contains("--no-enable-swift-package-manager"));
    expect(workflow, contains("flutter test integration_test -d macos"));
    expect(workflow, contains("cmake --install windows/native/build"));
    expect(
      workflow,
      contains("dotnet run --project example/native/windows-dotnet"),
    );
    expect(workflow, contains("cmake --install linux/native/build"));
    expect(workflow, contains("Windows Inno update smoke"));
    expect(workflow, contains("Run update smoke release"));
    expect(harness, contains("Version check"));
    expect(harness, contains("tool/version_check.dart"));
  });
}

String _read(String path) {
  final file = File(path);
  expect(file.existsSync(), isTrue, reason: "$path must exist");
  return file.existsSync() ? file.readAsStringSync() : "";
}
