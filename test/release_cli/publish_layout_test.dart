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
}
