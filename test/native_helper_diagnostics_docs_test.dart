import "dart:io";

import "package:flutter_test/flutter_test.dart";

void main() {
  test("README surfaces native helper diagnostics and current setup", () {
    final source = File("README.md").readAsStringSync();
    final version = _currentPackageVersion();

    expect(source, contains("desktop_updater: ^$version"));
    expect(source, contains("## Diagnostics And Recovery"));
    expect(source, contains("diagnosticsLogPath"));
    expect(source, contains("UpdateRecoveryStore"));
    expect(source, contains("docs/diagnostics-and-recovery.md"));
    expect(source, contains("docs/ui-widgets.md#diagnostics-and-support"));
    expect(source, contains("docs/publishing.md#runtime-policies"));
    expect(source, isNot(contains("native helper diagnostics plan")));
    expect(source, isNot(contains("docs/plans")));
  });

  test("support docs describe app-owned diagnostics levels", () {
    final uiDocs = File("docs/ui-widgets.md").readAsStringSync();
    final publishingDocs = File("docs/publishing.md").readAsStringSync();
    final diagnosticsDocs =
        File("docs/diagnostics-and-recovery.md").readAsStringSync();

    for (final source in <String>[uiDocs, publishingDocs, diagnosticsDocs]) {
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

  test("diagnostics docs explain log locations and helper behavior", () {
    final source = File("docs/diagnostics-and-recovery.md").readAsStringSync();

    expect(source, contains("The package writes no log files by default"));
    expect(source, contains("Where Logs Go"));
    expect(source, contains("UpdateDiagnosticsSink"));
    expect(source, contains("diagnosticsLogPath"));
    expect(source, contains("UpdateRecoveryStore"));
    expect(source, contains("Create the parent directory"));
    expect(source, contains("one JSON object per line"));
    expect(source, contains("helper scheduled"));
    expect(source, contains("relaunch attempt"));
    expect(source, contains("does not include a logging backend"));
    expect(source, isNot(contains("docs/plans")));
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

  test("package metadata and changelog agree on current version", () {
    final pubspec = File("pubspec.yaml").readAsStringSync();
    final changelog = File("CHANGELOG.md").readAsStringSync();
    final version = _currentPackageVersion();

    expect(pubspec, contains("version: $version"));
    expect(changelog, startsWith("## $version"));
    expect(changelog, contains("MandatoryReadyToInstallBehavior"));
    expect(changelog, contains("supportPolicy"));
    expect(changelog, contains("freshInstall"));
    expect(changelog, contains("## 2.3.3"));
    expect(changelog, contains("Linux zip staging"));
    expect(changelog, contains("## 2.3.1"));
    expect(changelog, contains("release publish --dart-define"));
    expect(changelog, contains("release notes support"));
    expect(changelog, contains("## 2.2.0"));
    expect(changelog, contains("native helper diagnostics"));
    expect(changelog, contains("install recovery markers"));
  });

  test("release notes docs show built-in and custom UI patterns", () {
    final readme = File("README.md").readAsStringSync();
    final requestHeadersDoc =
        File("doc/runtime-request-headers.md").readAsStringSync();
    final uiDocs = File("docs/ui-widgets.md").readAsStringSync();

    expect(readme, contains("releaseNotesLoader"));
    expect(readme, contains("releaseNotesUrl"));
    expect(readme, contains("Runtime request headers"));
    expect(readme, contains("hosted release notes"));
    expect(requestHeadersDoc, contains("releaseNotesUrl"));
    expect(requestHeadersDoc, contains("source.path.endsWith"));
    expect(requestHeadersDoc, contains("x-notes-auth"));
    expect(uiDocs, contains("Release Notes Patterns"));
    expect(uiDocs, contains("Built-in card and bottom sheet"));
    expect(uiDocs, contains("Inline panel"));
    expect(uiDocs, contains("Side sheet"));
    expect(uiDocs, contains("Changelog page"));
  });
}

String _currentPackageVersion() {
  final pubspec = File("pubspec.yaml").readAsStringSync();
  final match =
      RegExp(r"^version:\s*(\S+)", multiLine: true).firstMatch(pubspec);
  if (match == null) {
    throw StateError("pubspec.yaml is missing a package version.");
  }
  return match.group(1)!;
}
