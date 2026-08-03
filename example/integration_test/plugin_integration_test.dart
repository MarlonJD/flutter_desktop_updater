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
    final stagingRoot =
        await Directory.systemTemp.createTemp("desktop_updater_forged_stage_");
    addTearDown(() async {
      if (await stagingRoot.exists()) {
        await stagingRoot.delete(recursive: true);
      }
    });
    final arguments = <String, Object?>{
      "stagingPath": stagingRoot.path,
      "packageId": "com.example.forged",
      "stageProvenanceSha256": "f" * 64,
      "expectedArtifactSha256": "a" * 64,
      "transactionId": "123e4567-e89b-42d3-a456-426614174000",
      if (Platform.isWindows) ...{
        "installRoot": r"C:\Windows",
        "executableRelativePath": r"System32\notepad.exe",
        "innoRequiresElevation": "never",
      } else if (Platform.isLinux) ...{
        "installRoot": "/usr/bin",
        "executableRelativePath": "my-app",
      },
    };

    await expectLater(
      const MethodChannel("desktop_updater").invokeMethod<void>(
        "installUpdate",
        arguments,
      ),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          "code",
          "InstallError",
        ),
      ),
    );
  });
}
