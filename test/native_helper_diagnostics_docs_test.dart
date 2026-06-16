import "dart:io";

import "package:flutter_test/flutter_test.dart";

void main() {
  test("README surfaces native helper diagnostics and 2.2.0 setup", () {
    final source = File("README.md").readAsStringSync();

    expect(source, contains("desktop_updater: ^2.2.0"));
    expect(source, contains("## Diagnostics And Recovery"));
    expect(source, contains("diagnosticsLogPath"));
    expect(source, contains("UpdateRecoveryStore"));
    expect(source, contains("docs/ui-widgets.md#diagnostics-and-support"));
    expect(source, contains("docs/publishing.md#runtime-policies"));
    expect(
      source,
      contains(
        "docs/windows-linux-production-release.md#diagnostics-and-support-logs",
      ),
    );
    expect(source, isNot(contains("native helper diagnostics plan")));
    expect(source, isNot(contains("docs/plans")));
  });

  test("support docs describe app-owned diagnostics levels", () {
    final uiDocs = File("docs/ui-widgets.md").readAsStringSync();
    final publishingDocs = File("docs/publishing.md").readAsStringSync();

    for (final source in <String>[uiDocs, publishingDocs]) {
      expect(source, contains("In-memory problem report only"));
      expect(source, contains("App-owned Dart lifecycle log"));
      expect(
        source,
        contains("App-owned native helper log plus recovery store"),
      );
      expect(source, contains("Open Settings > Updates > Copy update report"));
      expect(source, contains("app-owned"));
    }
  });

  test("CI docs keep helper diagnostics artifacts opt-in", () {
    final source = File("docs/github-actions-ci-cd.md").readAsStringSync();

    expect(source, contains("DESKTOP_UPDATER_UPLOAD_SMOKE_DIAGNOSTICS"));
    expect(source, contains("failed"));
    expect(source, contains("does not upload helper logs by default"));
  });

  test("Windows and Linux docs keep diagnostics separate from trust", () {
    final source =
        File("docs/windows-linux-production-release.md").readAsStringSync();

    expect(source, contains("support evidence, not a trust layer"));
    expect(source, contains("they do not"));
    expect(source, contains("replace Authenticode"));
    expect(source, contains("descriptor signing"));
    expect(source, contains("repository signing"));
    expect(source, contains("Default package behavior writes no files"));
  });

  test("package metadata and changelog agree on 2.2.0", () {
    final pubspec = File("pubspec.yaml").readAsStringSync();
    final changelog = File("CHANGELOG.md").readAsStringSync();

    expect(pubspec, contains("version: 2.2.0"));
    expect(changelog, startsWith("## 2.2.0"));
    expect(changelog, contains("native helper diagnostics"));
    expect(changelog, contains("install recovery markers"));
  });
}
