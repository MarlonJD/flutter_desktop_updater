import "dart:io";

import "package:desktop_updater/src/release_cli/publish_layout.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;

void main() {
  test("creates stable local and remote release paths", () {
    final layout = PublishLayout.create(
      outputDirectory: Directory("/tmp/app/dist/desktop_updater"),
      baseUrl: Uri.parse("https://updates.example.com"),
      version: "2.0.1",
      buildNumber: 201,
      platform: "macos",
      channel: "stable",
      appName: "Example.app",
    );

    expect(layout.appArchiveRelativePath, "app-archive.json");
    expect(
      layout.appArchiveUrl.toString(),
      "https://updates.example.com/app-archive.json",
    );
    expect(layout.releaseRelativePath,
        "releases/stable/2.0.1/build-201/macos/release.json");
    expect(
      layout.artifactRelativePath,
      "releases/stable/2.0.1/build-201/macos/Example-2.0.1-macos.zip",
    );
    expect(
      layout.releaseUrl.toString(),
      "https://updates.example.com/releases/stable/2.0.1/build-201/macos/release.json",
    );
    expect(
      layout.releaseFile.path,
      path.join(
        layout.outputDirectory.path,
        "releases",
        "stable",
        "2.0.1",
        "build-201",
        "macos",
        "release.json",
      ),
    );
  });

  test("creates exe artifact layout for Windows Inno installers", () {
    final layout = PublishLayout.create(
      outputDirectory: Directory("/tmp/out"),
      baseUrl: Uri.parse("https://updates.example.com/app"),
      version: "2.5.0",
      buildNumber: 250,
      platform: "windows",
      channel: "stable",
      appName: "Example",
      artifactExtension: ".exe",
      artifactSuffix: "-setup",
    );

    expect(
      layout.artifactRelativePath,
      "releases/stable/2.5.0/build-250/windows/Example-2.5.0-windows-setup.exe",
    );
    expect(
      layout.artifactUrl.toString(),
      "https://updates.example.com/app/releases/stable/2.5.0/build-250/windows/Example-2.5.0-windows-setup.exe",
    );
  });

  test("uses explicit artifact file name for custom installer artifacts", () {
    final layout = PublishLayout.create(
      outputDirectory: Directory("/tmp/out"),
      baseUrl: Uri.parse("https://updates.example.com/app"),
      version: "2.4.6",
      buildNumber: 246,
      platform: "windows",
      channel: "beta",
      appName: "Example",
      artifactFileName: "ExampleSetup.exe",
    );

    expect(
      layout.artifactRelativePath,
      "releases/beta/2.4.6/build-246/windows/ExampleSetup.exe",
    );
    expect(
      layout.artifactUrl.toString(),
      "https://updates.example.com/app/releases/beta/2.4.6/build-246/windows/ExampleSetup.exe",
    );
  });

  test("creates dmg artifact layout for macOS DMG updates", () {
    final layout = PublishLayout.create(
      outputDirectory: Directory("/tmp/out"),
      baseUrl: Uri.parse("https://updates.example.com"),
      version: "2.6.0",
      buildNumber: 260,
      platform: "macos",
      channel: "stable",
      appName: "Example.app",
      artifactExtension: ".dmg",
    );

    expect(
      layout.artifactRelativePath,
      "releases/stable/2.6.0/build-260/macos/Example-2.6.0-macos.dmg",
    );
  });

  test("distinguishes missing build numbers from build zero", () {
    PublishLayout layout(int? buildNumber) => PublishLayout.create(
          outputDirectory: Directory("/tmp/out"),
          baseUrl: Uri.parse("https://updates.example.com"),
          version: "2.6.0",
          buildNumber: buildNumber,
          platform: "macos",
          channel: "stable",
          appName: "Example.app",
        );

    expect(
      layout(null).releaseRelativePath,
      "releases/stable/2.6.0/no-build/macos/release.json",
    );
    expect(
      layout(0).releaseRelativePath,
      "releases/stable/2.6.0/build-0/macos/release.json",
    );
  });

  test("encodes semantic version build metadata as one URL segment", () {
    final layout = PublishLayout.create(
      outputDirectory: Directory("/tmp/out"),
      baseUrl: Uri.parse("https://updates.example.com"),
      version: "2.1.0+meta",
      buildNumber: null,
      platform: "macos",
      channel: "stable",
      appName: "Example.app",
    );

    expect(
      layout.releaseRelativePath,
      "releases/stable/2.1.0+meta/no-build/macos/release.json",
    );
    expect(
      layout.releaseUrl.toString(),
      "https://updates.example.com/releases/stable/2.1.0%2Bmeta/no-build/macos/release.json",
    );
  });

  test("rejects unsafe identity and artifact path segments", () {
    PublishLayout create({
      String version = "2.0.1",
      String platform = "macos",
      String channel = "stable",
      String appName = "Example.app",
      String? artifactFileName,
    }) =>
        PublishLayout.create(
          outputDirectory: Directory("/tmp/out"),
          baseUrl: Uri.parse("https://updates.example.com"),
          version: version,
          buildNumber: null,
          platform: platform,
          channel: channel,
          appName: appName,
          artifactFileName: artifactFileName,
        );

    expect(() => create(channel: "stable/../beta"), throwsFormatException);
    expect(() => create(channel: "%2e%2e"), throwsFormatException);
    expect(() => create(version: ".."), throwsFormatException);
    expect(() => create(platform: "windows/.."), throwsFormatException);
    expect(() => create(appName: "../Example.app"), throwsFormatException);
    expect(
      () => create(artifactFileName: "../ExampleSetup.exe"),
      throwsFormatException,
    );
  });

  test("creates pkg artifact layout for macOS PKG installers", () {
    final layout = PublishLayout.create(
      outputDirectory: Directory("/tmp/out"),
      baseUrl: Uri.parse("https://updates.example.com"),
      version: "2.6.0",
      buildNumber: null,
      platform: "macos",
      channel: "stable",
      appName: "Example.app",
      artifactExtension: ".pkg",
    );

    expect(
      layout.artifactRelativePath,
      "releases/stable/2.6.0/no-build/macos/Example-2.6.0-macos.pkg",
    );
  });
}
