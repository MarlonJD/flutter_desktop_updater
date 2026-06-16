import "dart:io";

import "package:flutter_test/flutter_test.dart";

void main() {
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
}
