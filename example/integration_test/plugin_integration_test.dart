// This is a basic Flutter integration test.
//
// Since integration tests run in a full Flutter application, they can interact
// with the host side of a plugin implementation, unlike Dart unit tests.
//
// For more information about Flutter integration tests, please see
// https://flutter.dev/to/integration-testing

import "dart:convert";
import "dart:io";

import "package:desktop_updater/desktop_updater.dart";
import "package:desktop_updater/src/core/staged_update_provenance.dart";
import "package:desktop_updater/src/release_cli/sign_command.dart";
import "package:desktop_updater/src/release_manifest.dart";
import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";
import "package:integration_test/integration_test.dart";

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets("getPlatformVersion test", (WidgetTester tester) async {
    final plugin = DesktopUpdater();
    final version = await plugin.getPlatformVersion();
    // The version string depends on the host platform running the test, so
    // just assert that some non-empty string is returned.
    expect(version?.isNotEmpty, true);
  });

  testWidgets("migration fixture uses release descriptor URL", (tester) async {
    final fixture = File("migration/app_archive_v3.json");
    final json = jsonDecode(fixture.readAsStringSync()) as Map<String, dynamic>;
    final items = json["items"] as List<dynamic>;
    final first = items.single as Map<String, dynamic>;

    expect(json["schemaVersion"], 3);
    expect(first["release"], contains("release.json"));
  });

  testWidgets("forged raw MethodChannel payload fails native validation",
      (tester) async {
    final fixture = await _createVerifiedStageFixture();
    addTearDown(() async {
      if (await fixture.root.exists()) {
        await fixture.root.delete(recursive: true);
      }
      if (await fixture.installRoot.exists()) {
        await fixture.installRoot.delete(recursive: true);
      }
    });
    final arguments = <String, Object?>{
      "stagingPath":
          Platform.isMacOS ? fixture.stagedAppPath : fixture.stageRoot.path,
      "packageId": Platform.isLinux ? "com.example.forged" : fixture.packageId,
      "stageProvenanceSha256": fixture.provenanceSha256,
      "expectedArtifactSha256": fixture.artifactSha256,
      "transactionId": "123e4567-e89b-42d3-a456-426614174000",
      if (Platform.isWindows) ...{
        "installRoot": fixture.installRoot.path,
        "executableRelativePath": "forged-target.exe",
        "innoRequiresElevation": "never",
      } else if (Platform.isLinux) ...{
        "installRoot": fixture.installRoot.path,
        "executableRelativePath": fixture.executableRelativePath,
      },
    };

    await expectLater(
      const MethodChannel("desktop_updater").invokeMethod<void>(
        "installUpdate",
        arguments,
      ),
      throwsA(
        isA<PlatformException>()
            .having((error) => error.code, "code", "InstallError")
            .having(
              _platformExceptionText,
              "message/details",
              contains(_expectedForgedBindingMessage()),
            ),
      ),
    );
  });
}

class _VerifiedStageFixture {
  const _VerifiedStageFixture({
    required this.root,
    required this.stageRoot,
    required this.installRoot,
    required this.stagedAppPath,
    required this.packageId,
    required this.executableRelativePath,
    required this.artifactSha256,
    required this.provenanceSha256,
  });

  final Directory root;
  final Directory stageRoot;
  final Directory installRoot;
  final String stagedAppPath;
  final String packageId;
  final String executableRelativePath;
  final String artifactSha256;
  final String provenanceSha256;
}

Future<_VerifiedStageFixture> _createVerifiedStageFixture() async {
  final root = await Directory.systemTemp.createTemp(
    "desktop_updater_forged_boundary_",
  );
  final stageParent = Directory(_joinPath(root.path, "staging"));
  await stageParent.create();
  const nonce = "123e4567-e89b-42d3-a456-426614174000";
  final stageRoot = await createOwnedStagingDirectory(
    parent: stageParent,
    nonce: nonce,
  );
  final installRoot = Directory(
    _joinPath(
      Directory.current.path,
      "build",
      "desktop_updater_forged_target",
    ),
  );
  if (await installRoot.exists()) {
    await installRoot.delete(recursive: true);
  }
  await installRoot.create(recursive: true);

  final packageId = Platform.isMacOS
      ? "com.example.forged.stage"
      : "com.example.desktop-updater-boundary";
  const artifactSha256 =
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
  final executableRelativePath = Platform.isWindows
      ? "bin/example.exe"
      : Platform.isMacOS
          ? "Example.app/Contents/MacOS/Example"
          : "bin/my-app";
  final stagedExecutable = File(
    _joinPathAll([
      stageRoot.path,
      ...executableRelativePath.split("/"),
    ]),
  );
  await stagedExecutable.parent.create(recursive: true);
  await stagedExecutable.writeAsString("staged executable");

  if (Platform.isMacOS) {
    final infoPlist = File(
      _joinPath(stageRoot.path, "Example.app", "Contents", "Info.plist"),
    );
    await infoPlist.writeAsString("""
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>Example</string>
  <key>CFBundleIdentifier</key>
  <string>$packageId</string>
  <key>CFBundleShortVersionString</key>
  <string>2.0.0</string>
  <key>CFBundleVersion</key>
  <string>200</string>
</dict>
</plist>
""");
  }

  final manifest = _releaseManifestJson(
    packageId: packageId,
    artifactSha256: artifactSha256,
  );
  final releaseManifest =
      File(_joinPath(stageRoot.path, stagedReleaseManifestFileName));
  await releaseManifest.writeAsString(jsonEncode(sortJsonValue(manifest)));
  await ReleaseDescriptorSigner().sign(
    releaseFile: releaseManifest,
    publicKeyId: "stable-2026",
    privateKeyBase64: base64Encode(List<int>.generate(32, (index) => index)),
  );
  final signedManifest =
      jsonDecode(await releaseManifest.readAsString()) as Map<String, dynamic>;
  final provenance = await writeStagedUpdateProvenance(
    stageRoot: stageRoot,
    nonce: nonce,
    packageId: packageId,
    descriptorSha256: canonicalJsonSha256(signedManifest),
    artifactSha256: artifactSha256,
  );
  await File(
    _joinPath(installRoot.path, ".desktop_updater_install_identity.json"),
  ).writeAsString(
    jsonEncode(
      sortJsonValue({
        "schemaVersion": 1,
        "packageId": packageId,
      }),
    ),
  );
  if (Platform.isWindows) {
    await File(_joinPath(installRoot.path, "forged-target.exe"))
        .writeAsString("not the running app");
  }

  return _VerifiedStageFixture(
    root: root,
    stageRoot: stageRoot,
    installRoot: installRoot,
    stagedAppPath: _joinPath(stageRoot.path, "Example.app"),
    packageId: packageId,
    executableRelativePath: executableRelativePath,
    artifactSha256: artifactSha256,
    provenanceSha256: provenance.markerSha256,
  );
}

Map<String, Object?> _releaseManifestJson({
  required String packageId,
  required String artifactSha256,
}) {
  return {
    "schemaVersion": 3,
    "packageId": packageId,
    "appName": Platform.isMacOS ? "Example.app" : "Example",
    "version": "2.0.0",
    "buildNumber": 200,
    "platform": Platform.operatingSystem,
    "channel": "stable",
    "artifact": {
      "kind": "zip",
      "url": "https://updates.example.com/releases/2.0.0/artifact.zip",
      "sha256": artifactSha256,
      "length": 17,
    },
    "install": {
      "strategy":
          Platform.isMacOS ? "wholeBundleReplace" : "wholeDirectoryReplace",
    },
    "minimumUpdaterVersion": "3.0.0",
    "generatedAt": "2026-08-03T00:00:00.000Z",
  };
}

String _expectedForgedBindingMessage() {
  if (Platform.isLinux) {
    return "Linux stage provenance package identity changed.";
  }
  if (Platform.isWindows) {
    return "Windows install target does not match the running app.";
  }
  if (Platform.isMacOS) {
    return "Stage provenance is not bound to the install request.";
  }
  return "InstallError";
}

String _platformExceptionText(PlatformException error) {
  return [
    error.message,
    if (error.details != null) error.details.toString(),
  ].whereType<String>().join("\n");
}

String _joinPath(
  String first,
  String second, [
  String? third,
  String? fourth,
]) {
  return _joinPathAll([
    first,
    second,
    if (third != null) third,
    if (fourth != null) fourth,
  ]);
}

String _joinPathAll(List<String> parts) {
  return parts.reduce((value, element) {
    if (value.endsWith(Platform.pathSeparator)) {
      return "$value$element";
    }
    return "$value${Platform.pathSeparator}$element";
  });
}
