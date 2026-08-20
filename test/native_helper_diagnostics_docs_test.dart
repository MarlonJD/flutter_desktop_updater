import "dart:io";

import "package:flutter_test/flutter_test.dart";

void main() {
  test("README surfaces native helper diagnostics and current setup", () {
    final source = File("README.md").readAsStringSync();
    final version = _currentPackageVersion();
    final keygenOffset =
        source.indexOf("dart run desktop_updater:release keygen");
    final controllerOffset = source.indexOf("DesktopUpdaterController(");

    expect(source, contains("desktop_updater: ^$version"));
    expect(keygenOffset, greaterThanOrEqualTo(0));
    expect(controllerOffset, greaterThan(keygenOffset));
    expect(source, contains("Public key map:"));
    expect(source, contains("desktop_updater.keys.json"));
    expect(source, contains("release-key.dukey"));
    expect(source, contains("expectedPackageIdForCurrentPlatform"));
    expect(source, contains("PRODUCT_BUNDLE_IDENTIFIER"));
    expect(source, contains("APPLICATION_ID"));
    expect(source, contains("JsonFileUpdateRecoveryStore"));
    expect(source, contains("getApplicationSupportDirectory"));
    expect(source, contains("`recoveryStore` is required in 3.1"));
    expect(
      source,
      isNot(
        contains(
          '"stable-2026": "base64-raw-ed25519-public-key"',
        ),
      ),
    );
    expect(source, contains("## Diagnostics And Recovery"));
    expect(source, isNot(contains("diagnosticsLogPath")));
    expect(
        source, contains("do not accept a caller-selected diagnostics path"));
    expect(source, contains("UpdateRecoveryStore"));
    expect(source, contains("docs/diagnostics-and-recovery.md"));
    expect(source, contains("docs/ui-widgets.md#diagnostics-and-support"));
    expect(source, contains("docs/publishing.md#runtime-policies"));
    expect(source, contains("docs/windows-inno-installer-updates.md"));
    expect(source, isNot(contains("native helper diagnostics plan")));
    expect(source, isNot(contains("docs/plans")));
  });

  test("release key docs bridge keygen output to runtime trust and backup", () {
    final source = File("docs/release-key-management.md").readAsStringSync();

    expect(source, contains("complete `Public key map`"));
    expect(source, contains("`trustedReleasePublicKeys`"));
    expect(source, contains("does not load `desktop_updater.keys.json`"));
    expect(source, contains("release-key.dukey"));
    expect(source, contains("outside the repository"));
  });

  test("support docs describe app-owned diagnostics levels", () {
    final uiDocs = File("docs/ui-widgets.md").readAsStringSync();
    final publishingDocs = File("docs/publishing.md").readAsStringSync();
    final diagnosticsDocs =
        File("docs/diagnostics-and-recovery.md").readAsStringSync();

    for (final source in <String>[uiDocs, publishingDocs, diagnosticsDocs]) {
      expect(source, contains("In-memory problem report only"));
      expect(source, contains("App-owned Dart lifecycle log"));
      expect(source, contains("Platform helper log plus recovery store"));
      expect(source, contains("Open Settings > Updates > Copy update report"));
      expect(source, contains("app-owned"));
    }

    expect(uiDocs, contains("UpdateDiagnosticsRecorder("));
    expect(
      uiDocs,
      isNot(contains("diagnosticsLogPath: appOwnedHelperLogFile.path")),
    );
  });

  test("diagnostics docs explain log locations and helper behavior", () {
    final source = File("docs/diagnostics-and-recovery.md").readAsStringSync();
    final normalizedSource = source.replaceAll(RegExp(r"\s+"), " ");

    expect(
      source,
      contains("The package writes no caller-selected log files by default"),
    );
    expect(source, contains("Where Logs Go"));
    expect(source, contains("UpdateDiagnosticsSink"));
    expect(source, isNot(contains("diagnosticsLogPath")));
    expect(source, contains("platformLog"));
    expect(source, contains("UpdateRecoveryStore"));
    expect(
      normalizedSource,
      contains(
        "Every 3.1 `DesktopUpdaterController` therefore requires an "
        "`UpdateRecoveryStore`",
      ),
    );
    expect(
      normalizedSource,
      contains(
        "A failed write or mismatched readback blocks native install "
        "dispatch.",
      ),
    );
    expect(source, contains("one JSON object per line"));
    expect(source, contains("helper scheduled"));
    expect(source, contains("relaunch attempt"));
    expect(source, contains("transaction completed"));
    expect(source, contains("package manager state verified"));
    expect(source, contains("desktop_updater_stage_*"));
    expect(source, contains("stale-staging window"));
    expect(source, contains("does not include a logging backend"));
    expect(
      source,
      isNot(contains("A normal, non-elevated Windows helper may append")),
    );
    expect(source, isNot(contains("docs/plans")));
  });

  test("diagnostics docs describe standalone platform-owned helper sinks", () {
    final source = File("docs/diagnostics-and-recovery.md")
        .readAsStringSync()
        .replaceAll(RegExp(r"\s+"), " ");

    expect(
      source,
      contains("The 3.1 native request has no diagnostics path."),
    );
    expect(
      source,
      contains(
        "The standalone protocol-v1 Windows and Linux helpers do not receive, "
        "open, create, append to, or otherwise use a caller-provided path.",
      ),
    );
    expect(
      source,
      contains(
        "App-owned Dart diagnostics and the package's in-memory problem "
        "report remain available before helper handoff.",
      ),
    );
    expect(source, contains("Windows Application Event Log"));
    expect(
      source,
      contains("DesktopUpdater.InstallHelper.ProtocolV1"),
    );
    expect(source, contains("fixed protocol-v1 event names and IDs"));
    expect(source, contains("`desktop-updater-helper` syslog identity"));
    expect(source, contains("helper-owned `events.jsonl`"));
    expect(
      source,
      contains("Windows UAC and real helper execution: `not run`."),
    );
  });

  test("native SDK docs do not advertise a caller-selected helper log", () {
    for (final path in <String>[
      "docs/native-sdk.md",
      "docs/native-runtime-api.md",
    ]) {
      final source = File(
        path,
      ).readAsStringSync().replaceAll(RegExp(r"\s+"), " ");
      expect(
        source,
        contains("do not accept a caller-selected diagnostics path"),
      );
      expect(source, contains("fixed platform-owned log"));
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
    expect(source, contains("Inno Setup"));
    expect(source, contains("unins###.exe"));
    expect(source, contains("not full Inno installer updating"));
    expect(source, contains("SignPath Foundation"));
    expect(source, contains("qualifying open-source"));
    expect(source, contains("does not currently implement MSIX packaging"));
    expect(source, contains("Store-installed package should be updated"));
  });

  test("publishing docs describe full Inno installer update mode", () {
    final source = [
      File("docs/windows-inno-installer-updates.md").readAsStringSync(),
      File("docs/publishing.md").readAsStringSync(),
      File("docs/windows-linux-production-release.md").readAsStringSync(),
      File("docs/diagnostics-and-recovery.md").readAsStringSync(),
    ].join("\n");

    expect(source, contains("Inno installer update mode"));
    expect(source, contains("Inno owns the uninstall log"));
    expect(source, contains("artifact.kind"));
    expect(source, contains("innoInstaller"));
    expect(source, contains("mode: generated"));
    expect(source, contains("mode: script"));
    expect(source, contains("authenticodeThumbprints"));
    expect(source, contains("protectedHelperInstallDir"));
    expect(
      source,
      contains("DESKTOP_UPDATER_PROTECTED_HELPER_INSTALL_DIR"),
    );
    expect(source, contains("--register-endpoint"));
    expect(source, contains("uninsneveruninstall"));
    expect(source, contains("registration fails"));
    expect(source, contains("target-host"));
    expect(source, contains("Windows Inno Installer Updates"));
  });

  test("package metadata and changelog agree on current version", () {
    final pubspec = File("pubspec.yaml").readAsStringSync();
    final changelog = File("CHANGELOG.md").readAsStringSync();
    final packageVersion =
        File("lib/src/package_version.dart").readAsStringSync();
    final version = _currentPackageVersion();

    expect(pubspec, contains("version: $version"));
    expect(changelog, startsWith("## $version"));
    expect(
      packageVersion,
      contains('desktopUpdaterPackageVersion = "$version"'),
    );
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
