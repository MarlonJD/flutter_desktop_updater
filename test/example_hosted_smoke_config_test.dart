import "dart:io";

import "package:flutter_test/flutter_test.dart";

void main() {
  test("example app exposes hosted update smoke environment hooks", () {
    final source = File("example/lib/app.dart").readAsStringSync();

    expect(source, contains("DESKTOP_UPDATER_APP_ARCHIVE_URL"));
    expect(source, contains("DESKTOP_UPDATER_HOSTED_SMOKE"));
    expect(source, contains("DESKTOP_UPDATER_HOSTED_SMOKE_MARKER"));
    expect(source, contains("DESKTOP_UPDATER_HOSTED_SMOKE_DIAGNOSTICS_LOG"));
    expect(
      source,
      contains("_writeSmokeDiagnostics(diagnosticsLogPath"),
    );
    expect(
        source, isNot(contains("DESKTOP_UPDATER_HOSTED_ALLOW_UNSIGNED_MACOS")));
    expect(source, contains("_runHostedSmokeTestCommand"));
    expect(source, contains("checkVersion()"));
    expect(source, contains("downloadUpdate()"));
    expect(source, contains("restartApp()"));
  });

  test("example app displays native app version instead of fixture text", () {
    final source = File("example/lib/app.dart").readAsStringSync();

    expect(source, contains("getCurrentVersionInfo()"));
    expect(source, contains("App version:"));
    expect(source, isNot(contains("Running on: 1.0.0+1")));
  });

  test("direct smoke does not expose the rejected macOS unsigned bypass", () {
    final source = File("example/lib/app.dart").readAsStringSync();

    expect(
        source, isNot(contains("DESKTOP_UPDATER_SMOKE_ALLOW_UNSIGNED_MACOS")));
    expect(source, contains("DESKTOP_UPDATER_SMOKE_DIAGNOSTICS_LOG"));
    expect(source, isNot(contains("allowUnsignedMacOSUpdates:")));
    expect(source, isNot(contains("diagnosticsLogPath: diagnosticsLogPath")));
    expect(source, contains("raw-smoke-handoff-removed"));
  });
}
