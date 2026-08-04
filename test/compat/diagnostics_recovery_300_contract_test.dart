import "dart:io";

import "package:desktop_updater/desktop_updater.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  test("problem report redaction golden remains stable", () {
    final report = UpdateProblemReport(
      generatedAt: DateTime.utc(2026, 6, 16, 12),
      packageVersion: "3.0.0",
      platform: "macos",
      channel: "stable",
      appVersion: "1.0.0+100",
      updateVersion: "3.0.0",
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
          .replaceAll("\r\n", "\n")
          .trimRight(),
    );
  });

  test("v3 recovery marker binds identity, stage, and transaction", () {
    final marker = UpdateInstallRecoveryMarker.pendingV3(
      createdAt: DateTime.utc(2026, 6, 16, 12, 2),
      packageVersion: "3.0.0",
      platform: "macos",
      channel: "stable",
      appVersion: "1.0.0+100",
      updateVersion: "3.0.0",
      updateBuildNumber: 300,
      expectedPackageId: "com.example.app",
      stagingPath: "/tmp/staged",
      stageProvenanceSha256:
          "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      diagnosticsText: "redacted diagnostics",
      transactionId: "00000000-0000-4000-8000-000000000001",
    );

    expect(marker.packageVersion, "3.0.0");
    expect(marker.expectedPackageId, "com.example.app");
    expect(marker.stageProvenanceSha256, hasLength(64));
    expect(marker.transactionId, "00000000-0000-4000-8000-000000000001");
    expect(marker.diagnosticsText, "redacted diagnostics");
  });
}
