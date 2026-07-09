import "dart:io";

import "package:desktop_updater/src/release_cli/publish_layout.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  test("creates stable local and remote release paths", () {
    final layout = PublishLayout.create(
      outputDirectory: Directory("/tmp/app/dist/desktop_updater"),
      baseUrl: Uri.parse("https://updates.example.com"),
      version: "2.0.1",
      platform: "macos",
      appName: "Example.app",
    );

    expect(layout.appArchiveRelativePath, "app-archive.json");
    expect(layout.releaseRelativePath, "releases/2.0.1/macos/release.json");
    expect(
      layout.artifactRelativePath,
      "releases/2.0.1/macos/Example-2.0.1-macos.zip",
    );
    expect(
      layout.releaseUrl.toString(),
      "https://updates.example.com/releases/2.0.1/macos/release.json",
    );
  });

  test("creates exe artifact layout for Windows Inno installers", () {
    final layout = PublishLayout.create(
      outputDirectory: Directory("/tmp/out"),
      baseUrl: Uri.parse("https://updates.example.com/app"),
      version: "2.5.0",
      platform: "windows",
      appName: "Example",
      artifactExtension: ".exe",
      artifactSuffix: "-setup",
    );

    expect(
      layout.artifactRelativePath,
      "releases/2.5.0/windows/Example-2.5.0-windows-setup.exe",
    );
    expect(
      layout.artifactUrl.toString(),
      "https://updates.example.com/app/releases/2.5.0/windows/Example-2.5.0-windows-setup.exe",
    );
  });

  test("uses explicit artifact file name for custom installer artifacts", () {
    final layout = PublishLayout.create(
      outputDirectory: Directory("/tmp/out"),
      baseUrl: Uri.parse("https://updates.example.com/app"),
      version: "2.4.6",
      platform: "windows",
      appName: "Example",
      artifactFileName: "ExampleSetup.exe",
    );

    expect(
      layout.artifactRelativePath,
      "releases/2.4.6/windows/ExampleSetup.exe",
    );
    expect(
      layout.artifactUrl.toString(),
      "https://updates.example.com/app/releases/2.4.6/windows/ExampleSetup.exe",
    );
  });

  test("creates dmg artifact layout for macOS DMG updates", () {
    final layout = PublishLayout.create(
      outputDirectory: Directory("/tmp/out"),
      baseUrl: Uri.parse("https://updates.example.com"),
      version: "2.6.0",
      platform: "macos",
      appName: "Example.app",
      artifactExtension: ".dmg",
    );

    expect(
      layout.artifactRelativePath,
      "releases/2.6.0/macos/Example-2.6.0-macos.dmg",
    );
  });

  test("creates pkg artifact layout for macOS PKG installers", () {
    final layout = PublishLayout.create(
      outputDirectory: Directory("/tmp/out"),
      baseUrl: Uri.parse("https://updates.example.com"),
      version: "2.6.0",
      platform: "macos",
      appName: "Example.app",
      artifactExtension: ".pkg",
    );

    expect(
      layout.artifactRelativePath,
      "releases/2.6.0/macos/Example-2.6.0-macos.pkg",
    );
  });
}
