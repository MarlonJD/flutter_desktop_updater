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
}
