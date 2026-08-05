import "dart:convert";
import "dart:io";

import "package:crypto/crypto.dart";
import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:desktop_updater/src/core/staged_update_provenance.dart";
import "package:desktop_updater/src/core/update_client.dart";
import "package:desktop_updater/src/release_manifest.dart";
import "package:desktop_updater/src/version_info.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;

import "../fixtures/release_fixture_builder.dart";
import "../fixtures/update_server.dart";

void main() {
  test("checks, downloads, verifies, and stages a zip-first update", () async {
    final tempDir = await Directory.systemTemp.createTemp("zip_first_e2e_");
    UpdateServer? server;
    try {
      server = await UpdateServer.bind(tempDir);
      final fixture =
          await buildReleaseFixture(root: tempDir, baseUri: server.uri);

      final client = UpdateClient(
        appArchiveUrl: server.uri.resolve("app-archive.json"),
        currentVersion: DesktopVersionInfo.fromParts(
          versionName: "1.0.0",
          buildNumber: "100",
        ),
        platform: "linux",
        expectedPackageId: "com.example.app",
        trustedReleasePublicKeys: fixture.publicKeys,
      );

      final check = await client.checkForUpdate();
      expect(check, isNotNull);

      final progress = <int>[];
      final staged = await client.downloadVerifyAndStage(
        checkResult: check!,
        onProgress: (receivedBytes, _) => progress.add(receivedBytes),
      );

      expect(progress, isNotEmpty);
      expect(
        File(path.join(staged.stagingPath, "app.txt")).readAsStringSync(),
        "version=2.0.0",
      );
      expect(
        File(
          path.join(staged.stagingPath, ".desktop_updater_artifact.zip"),
        ).existsSync(),
        isTrue,
      );
      final sidecar = File(
        path.join(staged.stagingPath, stagedReleaseManifestFileName),
      );
      expect(sidecar.existsSync(), isTrue);
      final sidecarJson = await sidecar.readAsString();
      final sidecarMap = jsonDecode(sidecarJson) as Map<String, dynamic>;
      expect(
        sidecarJson,
        jsonEncode(sortJsonValue(sidecarMap)),
      );
      expect(sidecarMap["version"], "2.0.0");
      expect(
        staged.stageProvenance.descriptorSha256,
        sha256.convert(utf8.encode(sidecarJson)).toString(),
      );
    } finally {
      await server?.close();
      await tempDir.delete(recursive: true);
    }
  });

  test("macOS zip-first staging writes native helper sidecar", () async {
    final tempDir = await Directory.systemTemp.createTemp("zip_first_e2e_");
    UpdateServer? server;
    try {
      server = await UpdateServer.bind(tempDir);
      final fixture = await buildReleaseFixture(
        root: tempDir,
        baseUri: server.uri,
        platform: "macos",
      );

      final client = UpdateClient(
        appArchiveUrl: server.uri.resolve("app-archive.json"),
        currentVersion: DesktopVersionInfo.fromParts(
          versionName: "1.0.0",
          buildNumber: "100",
        ),
        platform: "macos",
        expectedPackageId: "com.example.app",
        trustedReleasePublicKeys: fixture.publicKeys,
        stagingParent: tempDir,
        runProcess: (_, arguments) async {
          if (arguments.contains("CFBundleIdentifier")) {
            return ProcessResult(0, 0, "com.example.app\n", "");
          }
          if (arguments.contains("-dv")) {
            return ProcessResult(0, 0, "", "TeamIdentifier=ABCDE12345\n");
          }
          final destination = arguments.last;
          await Directory(path.join(destination, "Example")).create();
          return ProcessResult(0, 0, "", "");
        },
      );
      final check = await client.checkForUpdate();

      final staged = await client.downloadVerifyAndStage(checkResult: check!);
      final sidecar = File(
        path.join(
          Directory(staged.stagingPath).parent.path,
          stagedReleaseManifestFileName,
        ),
      );

      expect(sidecar.existsSync(), isTrue);
      final sidecarMap =
          jsonDecode(await sidecar.readAsString()) as Map<String, dynamic>;
      expect(sidecarMap["schemaVersion"], 3);
    } finally {
      await server?.close();
      await tempDir.delete(recursive: true);
    }
  });

  test("Windows zip-first staging writes native helper sidecar", () async {
    final tempDir = await Directory.systemTemp.createTemp("zip_first_e2e_");
    UpdateServer? server;
    try {
      server = await UpdateServer.bind(tempDir);
      final fixture = await buildReleaseFixture(
        root: tempDir,
        baseUri: server.uri,
        platform: "windows",
      );

      final client = UpdateClient(
        appArchiveUrl: server.uri.resolve("app-archive.json"),
        currentVersion: DesktopVersionInfo.fromParts(
          versionName: "1.0.0",
          buildNumber: "100",
        ),
        platform: "windows",
        expectedPackageId: "com.example.app",
        trustedReleasePublicKeys: fixture.publicKeys,
        stagingParent: tempDir,
      );
      final check = await client.checkForUpdate();

      final staged = await client.downloadVerifyAndStage(checkResult: check!);
      final sidecar = File(
        path.join(staged.stagingPath, stagedReleaseManifestFileName),
      );

      expect(sidecar.existsSync(), isTrue);
      final sidecarMap =
          jsonDecode(await sidecar.readAsString()) as Map<String, dynamic>;
      expect(sidecarMap["version"], "2.0.0");
    } finally {
      await server?.close();
      await tempDir.delete(recursive: true);
    }
  });

  test("preserves an unmarked stale staging-prefix directory", () async {
    final tempDir = await Directory.systemTemp.createTemp("zip_first_e2e_");
    UpdateServer? server;
    try {
      final staleStage =
          await Directory(path.join(tempDir.path, "desktop_updater_stage_old"))
              .create();
      await _setDirectoryLastModified(
        staleStage,
        DateTime.now().subtract(const Duration(days: 8)),
      );

      server = await UpdateServer.bind(tempDir);
      final fixture = await buildReleaseFixture(
        root: tempDir,
        baseUri: server.uri,
        platform: "windows",
      );

      final client = UpdateClient(
        appArchiveUrl: server.uri.resolve("app-archive.json"),
        currentVersion: DesktopVersionInfo.fromParts(
          versionName: "1.0.0",
          buildNumber: "100",
        ),
        platform: "windows",
        expectedPackageId: "com.example.app",
        trustedReleasePublicKeys: fixture.publicKeys,
        stagingParent: tempDir,
      );
      final check = await client.checkForUpdate();

      final staged = await client.downloadVerifyAndStage(checkResult: check!);

      expect(staleStage.existsSync(), isTrue);
      expect(Directory(staged.stagingPath).existsSync(), isTrue);
    } finally {
      await server?.close();
      await tempDir.delete(recursive: true);
    }
  });

  test("removes a stale marker-bound stage before creating a Windows stage",
      () async {
    final tempDir = await Directory.systemTemp.createTemp("zip_first_e2e_");
    UpdateServer? server;
    try {
      const nonce = "123e4567-e89b-42d3-a456-426614174000";
      final staleStage = await createOwnedStagingDirectory(
        parent: tempDir,
        nonce: nonce,
      );
      await File(path.join(staleStage.path, "old.exe")).writeAsString("old");
      await writeStagedUpdateProvenance(
        stageRoot: staleStage,
        nonce: nonce,
        packageId: "com.example.app",
        descriptorSha256: "a".padRight(64, "a"),
        artifactSha256: "b".padRight(64, "b"),
      );
      await _setDirectoryLastModified(
        staleStage,
        DateTime.now().subtract(const Duration(days: 8)),
      );

      server = await UpdateServer.bind(tempDir);
      final fixture = await buildReleaseFixture(
        root: tempDir,
        baseUri: server.uri,
        platform: "windows",
      );
      final client = UpdateClient(
        appArchiveUrl: server.uri.resolve("app-archive.json"),
        currentVersion: DesktopVersionInfo.fromParts(
          versionName: "1.0.0",
          buildNumber: "100",
        ),
        platform: "windows",
        expectedPackageId: "com.example.app",
        trustedReleasePublicKeys: fixture.publicKeys,
        stagingParent: tempDir,
      );
      final check = await client.checkForUpdate();

      final staged = await client.downloadVerifyAndStage(checkResult: check!);

      expect(staleStage.existsSync(), isFalse);
      expect(Directory(staged.stagingPath).existsSync(), isTrue);
    } finally {
      await server?.close();
      await tempDir.delete(recursive: true);
    }
  });

  test("checksum mismatch fails before extraction", () async {
    final tempDir = await Directory.systemTemp.createTemp("zip_first_e2e_");
    UpdateServer? server;
    try {
      server = await UpdateServer.bind(tempDir);
      final fixture = await buildReleaseFixture(
        root: tempDir,
        baseUri: server.uri,
        badChecksum: true,
      );

      final client = UpdateClient(
        appArchiveUrl: server.uri.resolve("app-archive.json"),
        currentVersion: DesktopVersionInfo.fromParts(
          versionName: "1.0.0",
          buildNumber: "100",
        ),
        platform: "linux",
        expectedPackageId: "com.example.app",
        trustedReleasePublicKeys: fixture.publicKeys,
      );
      final check = await client.checkForUpdate();

      await expectLater(
        client.downloadVerifyAndStage(checkResult: check!),
        throwsA(isA<FileSystemException>()),
      );
    } finally {
      await server?.close();
      await tempDir.delete(recursive: true);
    }
  });

  test("path traversal inside zip is rejected", () async {
    final tempDir = await Directory.systemTemp.createTemp("zip_first_e2e_");
    UpdateServer? server;
    try {
      server = await UpdateServer.bind(tempDir);
      final fixture = await buildReleaseFixture(
        root: tempDir,
        baseUri: server.uri,
        traversalZip: true,
      );

      final client = UpdateClient(
        appArchiveUrl: server.uri.resolve("app-archive.json"),
        currentVersion: DesktopVersionInfo.fromParts(
          versionName: "1.0.0",
          buildNumber: "100",
        ),
        platform: "linux",
        expectedPackageId: "com.example.app",
        trustedReleasePublicKeys: fixture.publicKeys,
      );
      final check = await client.checkForUpdate();

      await expectLater(
        client.downloadVerifyAndStage(checkResult: check!),
        throwsFormatException,
      );
    } finally {
      await server?.close();
      await tempDir.delete(recursive: true);
    }
  });
}

Future<void> _setDirectoryLastModified(
  Directory directory,
  DateTime value,
) async {
  final result = Platform.isWindows
      ? await _setDirectoryLastModifiedWithPowerShell(directory, value)
      : await _setDirectoryLastModifiedWithTouch(directory, value);
  if (result.exitCode != 0) {
    fail(
      "Unable to set last modified for ${directory.path}: "
      "${result.stderr}${result.stdout}",
    );
  }
}

Future<ProcessResult> _setDirectoryLastModifiedWithPowerShell(
  Directory directory,
  DateTime value,
) {
  final escapedPath = directory.path.replaceAll("'", "''");
  final timestamp = value.toUtc().toIso8601String();
  return Process.run("powershell.exe", [
    "-NoProfile",
    "-Command",
    "\$item = Get-Item -LiteralPath '$escapedPath'; "
        "\$item.LastWriteTimeUtc = [DateTime]::Parse('$timestamp')",
  ]);
}

Future<ProcessResult> _setDirectoryLastModifiedWithTouch(
  Directory directory,
  DateTime value,
) {
  final local = value.toLocal();
  final timestamp = "${local.year.toString().padLeft(4, "0")}"
      "${local.month.toString().padLeft(2, "0")}"
      "${local.day.toString().padLeft(2, "0")}"
      "${local.hour.toString().padLeft(2, "0")}"
      "${local.minute.toString().padLeft(2, "0")}"
      ".${local.second.toString().padLeft(2, "0")}";
  return Process.run("touch", ["-t", timestamp, directory.path]);
}
