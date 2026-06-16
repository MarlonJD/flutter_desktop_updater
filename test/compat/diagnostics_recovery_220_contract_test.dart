import "dart:io";

import "package:desktop_updater/desktop_updater.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  test("problem report redaction golden remains stable", () {
    final report = UpdateProblemReport(
      generatedAt: DateTime.utc(2026, 6, 16, 12),
      packageVersion: "2.2.0",
      platform: "macos",
      channel: "stable",
      appVersion: "1.0.0+100",
      updateVersion: "2.0.0",
      stagingPath: "/tmp/staged",
      failure: StateError("Authorization: Bearer abc password=hunter2"),
      entries: [
        UpdateDiagnosticEntry(
          timestamp: DateTime.utc(2026, 6, 16, 12, 1),
          stage: UpdateDiagnosticStage.download,
          level: UpdateDiagnosticLevel.error,
          message:
              "GET https://updates.example.com/release.json?token=abc&safe=value",
        ),
      ],
    );

    expect(
      report.toPlainText(),
      File("fixtures/compat/problem-report-redacted.txt")
          .readAsStringSync()
          .trimRight(),
    );
  });

  test("recovery marker keeps 2.2.0 app-owned pending install fields", () {
    final marker = UpdateInstallRecoveryMarker(
      createdAt: DateTime.utc(2026, 6, 16, 12, 2),
      packageVersion: "2.2.0",
      platform: "macos",
      channel: "stable",
      appVersion: "1.0.0+100",
      updateVersion: "2.0.0",
      updateBuildNumber: 200,
      stagingPath: "/tmp/staged",
      diagnosticsText: "redacted diagnostics",
    );

    expect(marker.createdAt, DateTime.utc(2026, 6, 16, 12, 2));
    expect(marker.packageVersion, "2.2.0");
    expect(marker.platform, "macos");
    expect(marker.channel, "stable");
    expect(marker.appVersion, "1.0.0+100");
    expect(marker.updateVersion, "2.0.0");
    expect(marker.updateBuildNumber, 200);
    expect(marker.stagingPath, "/tmp/staged");
    expect(marker.diagnosticsText, "redacted diagnostics");
  });
}
