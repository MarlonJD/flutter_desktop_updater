import "package:desktop_updater/src/core/update_diagnostics.dart";
import "package:desktop_updater/src/core/update_diagnostics_recorder.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  test("diagnostic entry records lifecycle details", () {
    final timestamp = DateTime.utc(2026, 6, 13, 8, 30);
    final error = StateError("download failed");

    final entry = UpdateDiagnosticEntry(
      timestamp: timestamp,
      stage: UpdateDiagnosticStage.download,
      level: UpdateDiagnosticLevel.error,
      message: "Download failed",
      error: error,
    );

    expect(entry.timestamp, timestamp);
    expect(entry.stage, UpdateDiagnosticStage.download);
    expect(entry.level, UpdateDiagnosticLevel.error);
    expect(entry.message, "Download failed");
    expect(entry.error, same(error));
  });

  test("problem report includes metadata and ordered entries", () {
    final generatedAt = DateTime.utc(2026, 6, 13, 9);
    final first = UpdateDiagnosticEntry(
      timestamp: DateTime.utc(2026, 6, 13, 8),
      stage: UpdateDiagnosticStage.check,
      level: UpdateDiagnosticLevel.info,
      message: "Checking app archive",
    );
    final second = UpdateDiagnosticEntry(
      timestamp: DateTime.utc(2026, 6, 13, 8, 1),
      stage: UpdateDiagnosticStage.download,
      level: UpdateDiagnosticLevel.error,
      message: "Download failed",
      error: StateError("network down"),
    );

    final report = UpdateProblemReport(
      generatedAt: generatedAt,
      packageVersion: "2.1.4",
      platform: "macos",
      channel: "stable",
      appVersion: "1.0.0+100",
      updateVersion: "2.0.1",
      stagingPath: "/tmp/staged-app",
      failure: StateError("network down"),
      entries: [first, second],
    );

    expect(report.generatedAt, generatedAt);
    expect(report.packageVersion, "2.1.4");
    expect(report.platform, "macos");
    expect(report.channel, "stable");
    expect(report.appVersion, "1.0.0+100");
    expect(report.updateVersion, "2.0.1");
    expect(report.stagingPath, "/tmp/staged-app");
    expect(report.entries, [first, second]);

    final plainText = report.toPlainText();
    expect(plainText, contains("Generated: 2026-06-13T09:00:00.000Z"));
    expect(plainText, contains("Package version: 2.1.4"));
    expect(plainText, contains("Platform: macos"));
    expect(plainText, contains("Channel: stable"));
    expect(plainText, contains("App version: 1.0.0+100"));
    expect(plainText, contains("Update version: 2.0.1"));
    expect(
      plainText.indexOf("Checking app archive"),
      lessThan(plainText.indexOf("Download failed")),
    );
  });

  test("plain text redacts secrets from URLs, headers, and messages", () {
    final report = UpdateProblemReport(
      generatedAt: DateTime.utc(2026, 6, 13, 9),
      packageVersion: "2.1.4",
      platform: "windows",
      channel: "stable",
      failure: StateError(
        "Authorization: Bearer abc123 password=hunter2 signature=deadbeef",
      ),
      entries: [
        UpdateDiagnosticEntry(
          timestamp: DateTime.utc(2026, 6, 13, 8),
          stage: UpdateDiagnosticStage.check,
          level: UpdateDiagnosticLevel.info,
          message:
              "GET https://updates.example.com/app-archive.json?token=abc&key=def&safe=value",
        ),
        UpdateDiagnosticEntry(
          timestamp: DateTime.utc(2026, 6, 13, 8, 1),
          stage: UpdateDiagnosticStage.descriptor,
          level: UpdateDiagnosticLevel.error,
          message:
              "credential=my-credential secret=my-secret Authorization: Basic Zm9v",
          error: const FormatException("publicKey=abc password=def"),
        ),
      ],
    );

    final plainText = report.toPlainText();

    expect(plainText, contains("token=<redacted>"));
    expect(plainText, contains("key=<redacted>"));
    expect(plainText, contains("safe=value"));
    expect(plainText, contains("Authorization: <redacted>"));
    expect(plainText, contains("password=<redacted>"));
    expect(plainText, contains("signature=<redacted>"));
    expect(plainText, contains("credential=<redacted>"));
    expect(plainText, contains("secret=<redacted>"));
    expect(plainText, contains("publicKey=<redacted>"));
    expect(plainText, isNot(contains("abc123")));
    expect(plainText, isNot(contains("hunter2")));
    expect(plainText, isNot(contains("deadbeef")));
    expect(plainText, isNot(contains("my-credential")));
    expect(plainText, isNot(contains("my-secret")));
    expect(plainText, isNot(contains("Basic Zm9v")));
  });

  test("problem reports bound entries so copied text stays compact", () {
    final entries = [
      for (var index = 0;
          index < UpdateProblemReport.maxEntries + 12;
          index += 1)
        UpdateDiagnosticEntry(
          timestamp: DateTime.utc(2026, 6, 13, 8, 0, index),
          stage: UpdateDiagnosticStage.download,
          level: UpdateDiagnosticLevel.info,
          message: "entry $index",
        ),
    ];

    final report = UpdateProblemReport(
      generatedAt: DateTime.utc(2026, 6, 13, 9),
      packageVersion: "2.1.4",
      platform: "linux",
      channel: "beta",
      entries: entries,
    );

    expect(report.entries, hasLength(UpdateProblemReport.maxEntries));
    expect(report.entries.first.message, "entry 12");
    expect(report.entries.last.message, "entry ${entries.length - 1}");
    expect(
      report.toPlainText(),
      contains("Entries omitted: 12 older entries"),
    );
  });

  test("diagnostics recorder builds bounded reports without exporting", () {
    final timestamps = [
      DateTime.utc(2026, 6, 13, 8),
      DateTime.utc(2026, 6, 13, 8, 1),
      DateTime.utc(2026, 6, 13, 8, 2),
      DateTime.utc(2026, 6, 13, 9),
    ];
    final recorder = UpdateDiagnosticsRecorder(
      clock: () => timestamps.removeAt(0),
      packageVersion: "2.1.4",
      platform: "linux",
      channel: "stable",
      maxEntries: 2,
    );

    final records = [
      (
        stage: UpdateDiagnosticStage.check,
        level: UpdateDiagnosticLevel.info,
        message: "Checking app archive",
        error: null,
      ),
      (
        stage: UpdateDiagnosticStage.download,
        level: UpdateDiagnosticLevel.info,
        message: "Downloading artifact",
        error: null,
      ),
      (
        stage: UpdateDiagnosticStage.download,
        level: UpdateDiagnosticLevel.error,
        message: "Download failed token=abc",
        error: StateError("password=hunter2"),
      ),
    ];
    for (final record in records) {
      recorder.record(
        stage: record.stage,
        level: record.level,
        message: record.message,
        error: record.error,
      );
    }

    final report = recorder.buildReport(
      appVersion: "1.0.0+100",
      updateVersion: "2.0.1",
      failure: StateError("Authorization: Bearer abc"),
    );

    expect(report.packageVersion, "2.1.4");
    expect(report.platform, "linux");
    expect(report.channel, "stable");
    expect(report.entries.map((entry) => entry.message), [
      "Downloading artifact",
      "Download failed token=abc",
    ]);
    expect(report.omittedEntryCount, 1);

    final plainText = report.toPlainText();
    expect(plainText, contains("Entries omitted: 1 older entries"));
    expect(plainText, contains("token=<redacted>"));
    expect(plainText, contains("password=<redacted>"));
    expect(plainText, contains("Authorization: <redacted>"));
  });
}
