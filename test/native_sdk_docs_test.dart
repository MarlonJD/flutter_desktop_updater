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

  test("native SDK guide exposes helper packages without claiming runtime", () {
    final guide = _read("docs/native-sdk.md");
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
    expect(guide, contains("Full native runtime"));
    expect(guide, contains("unavailable"));
    expect(guide, contains("candidate-only"));
    expect(guide, contains("signed standalone release assets"));
    expect(readme, contains("docs/native-sdk.md"));
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
