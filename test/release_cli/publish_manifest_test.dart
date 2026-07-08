import "dart:io";

import "package:desktop_updater/src/release_cli/publish_manifest.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;

void main() {
  test("writes publish manifest used by validate", () async {
    final tempDir = await Directory.systemTemp.createTemp("publish_manifest_");
    try {
      final manifest = PublishManifest(
        schemaVersion: 1,
        baseUrl: Uri.parse("https://updates.example.com/"),
        localRoot: tempDir.path,
        appArchive: PublishManifestFile(
          path: "app-archive.json",
          url: Uri.parse("https://updates.example.com/app-archive.json"),
        ),
        release: PublishManifestRelease(
          version: "2.0.1",
          buildNumber: 201,
          platform: "macos",
          channel: "stable",
          path: "releases/2.0.1/macos/release.json",
          url: Uri.parse(
            "https://updates.example.com/releases/2.0.1/macos/release.json",
          ),
        ),
        artifact: PublishManifestArtifact(
          path: "releases/2.0.1/macos/Example-2.0.1-macos.zip",
          url: Uri.parse(
            "https://updates.example.com/releases/2.0.1/macos/Example-2.0.1-macos.zip",
          ),
          sha256:
              "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          length: 12,
        ),
      );

      final file =
          File(path.join(tempDir.path, ".desktop_updater_publish.json"));
      await manifest.writeTo(file);
      final parsed = await PublishManifest.readFrom(file);

      expect(parsed.release.version, "2.0.1");
      expect(parsed.artifact.kind, "zip");
      expect(parsed.artifact.length, 12);
      expect(await file.readAsString(), endsWith("\n"));
    } finally {
      await tempDir.delete(recursive: true);
    }
  });

  test("round-trips Inno installer artifact kind", () async {
    final manifest = PublishManifest.fromJson({
      "schemaVersion": 1,
      "baseUrl": "https://updates.example.com/",
      "localRoot": "/tmp/dist",
      "appArchive": {
        "path": "app-archive.json",
        "url": "https://updates.example.com/app-archive.json",
      },
      "release": {
        "version": "2.5.0",
        "buildNumber": 250,
        "platform": "windows",
        "channel": "stable",
        "path": "releases/2.5.0/windows/release.json",
        "url":
            "https://updates.example.com/releases/2.5.0/windows/release.json",
      },
      "artifact": {
        "kind": "innoInstaller",
        "path": "releases/2.5.0/windows/Example-2.5.0-windows-setup.exe",
        "url":
            "https://updates.example.com/releases/2.5.0/windows/Example-2.5.0-windows-setup.exe",
        "sha256": "b" * 64,
        "length": 42,
      },
    });

    expect(manifest.artifact.kind, "innoInstaller");
    expect(manifest.toJson()["artifact"]["kind"], "innoInstaller");
  });

  test("round-trips macOS DMG artifact kind", () async {
    final manifest = PublishManifest.fromJson({
      "schemaVersion": 1,
      "baseUrl": "https://updates.example.com/",
      "localRoot": "/tmp/dist",
      "appArchive": {
        "path": "app-archive.json",
        "url": "https://updates.example.com/app-archive.json",
      },
      "release": {
        "version": "2.6.0",
        "buildNumber": 260,
        "platform": "macos",
        "channel": "stable",
        "path": "releases/2.6.0/macos/release.json",
        "url": "https://updates.example.com/releases/2.6.0/macos/release.json",
      },
      "artifact": {
        "kind": "dmg",
        "path": "releases/2.6.0/macos/Example-2.6.0-macos.dmg",
        "url":
            "https://updates.example.com/releases/2.6.0/macos/Example-2.6.0-macos.dmg",
        "sha256": "c" * 64,
        "length": 43,
      },
    });

    expect(manifest.artifact.kind, "dmg");
    expect(manifest.toJson()["artifact"]["kind"], "dmg");
  });

  test("round-trips macOS PKG installer artifact kind", () async {
    final manifest = PublishManifest.fromJson({
      "schemaVersion": 1,
      "baseUrl": "https://updates.example.com/",
      "localRoot": "/tmp/dist",
      "appArchive": {
        "path": "app-archive.json",
        "url": "https://updates.example.com/app-archive.json",
      },
      "release": {
        "version": "2.6.0",
        "buildNumber": 260,
        "platform": "macos",
        "channel": "stable",
        "path": "releases/2.6.0/macos/release.json",
        "url": "https://updates.example.com/releases/2.6.0/macos/release.json",
      },
      "artifact": {
        "kind": "pkgInstaller",
        "path": "releases/2.6.0/macos/Example-2.6.0-macos.pkg",
        "url":
            "https://updates.example.com/releases/2.6.0/macos/Example-2.6.0-macos.pkg",
        "sha256": "d" * 64,
        "length": 44,
      },
    });

    expect(manifest.artifact.kind, "pkgInstaller");
    expect(manifest.toJson()["artifact"]["kind"], "pkgInstaller");
  });
}
