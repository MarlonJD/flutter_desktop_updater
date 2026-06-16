# Native Helper Diagnostics, Recovery Marker, And Post-Relaunch Reports

**Goal:** Add an opt-in, product-grade diagnostics and recovery path that can
explain update failures even when the Flutter app exits before the native helper
finishes install, copy, move, or rollback work.

**Non-goals:**

- Do not write logs by default.
- Do not upload logs, add telemetry backends, or add a storage package.
- Do not choose an app's retention, privacy, or support policy.
- Do not make platform helper logging implicit; the app must opt in with an
  explicit log path or app-owned store.

**Design split:**

1. Dart lifecycle diagnostics for check, descriptor, download, verify, stage,
   and native handoff.
2. App-owned recovery marker for "install was scheduled" state that can be read
   on the next launch.
3. Native helper diagnostics for work that happens after the Flutter process
   exits: validation, backup, move/copy, rollback, cleanup, and relaunch.

The Dart layer should land first because it is cross-platform and keeps the
default package contract clean. Native helper diagnostics should land only after
the Dart recovery contract is stable.

## Product Behavior

When the app opts in:

1. The controller writes normal lifecycle diagnostics to an app-owned sink.
2. Before `installUpdate` hands off to native code, the controller writes a
   pending install marker to an app-owned recovery store.
3. The native helper receives an explicit `diagnosticsLogPath` and appends
   bounded, redacted helper events.
4. On next launch, the controller reads the marker:
   - if the current app version/build matches the expected update, the marker is
     cleared;
   - if the old version is still running, the controller exposes
     `UpdateFailed(error, report: report)` with a post-relaunch install failure
     report;
   - if current version cannot be read, the report says the package could not
     prove the update completed.
5. Stock UI can show the recovered report, and app-owned support flows can ask
   the user for the log file when the UI report is unavailable.

## Task 8A: Dart Opt-In Diagnostics Sink

**Files:**

- Modify: `lib/src/core/update_diagnostics.dart`
- Modify: `lib/src/core/update_diagnostics_recorder.dart`
- Modify: `lib/updater_controller.dart`
- Modify: `lib/desktop_updater.dart`
- Modify: `docs/ui-widgets.md`
- Modify: `docs/publishing.md`
- Test: `test/update_diagnostics_test.dart`
- Test: `test/updater_controller_test.dart`

**Contract:**

```dart
abstract class UpdateDiagnosticsSink {
  void record(UpdateDiagnosticEntry entry);
}
```

`UpdateDiagnosticsRecorder` accepts an optional sink and forwards every retained
entry in order. Sink failures must never prevent in-memory report generation or
update state transitions.

For file logging, document an app-owned sink such as:

```dart
class AppUpdateLogSink implements UpdateDiagnosticsSink {
  AppUpdateLogSink(this.file);
  final File file;

  @override
  void record(UpdateDiagnosticEntry entry) {
    file.writeAsStringSync(
      "${entry.timestamp.toUtc().toIso8601String()} "
      "${entry.level.name} ${entry.stage.name}: "
      "${entry.redactedMessage}\n",
      mode: FileMode.append,
      flush: true,
    );
  }
}
```

The package should expose a redacted formatter so app-owned file sinks do not
need to duplicate secret-redaction logic.

**Fail-first tests:**

- Recorder forwards ordered entries to the optional sink.
- Throwing sink still leaves `UpdateProblemReport` available.
- Redacted log formatting removes tokens, authorization, passwords, signatures,
  secrets, keys, and credentials before file-oriented export.

Status on 2026-06-16: complete. `UpdateDiagnosticsSink`,
`UpdateDiagnosticEntry.toRedactedLogLine()`, and
`UpdateDiagnosticsRecorder(sink: ...)` are implemented. Verification:
`flutter test --no-pub test/update_diagnostics_test.dart` passed with 8 tests,
including ordered sink forwarding, throwing sink isolation, and redacted log line
formatting.

## Task 8B: App-Owned Recovery Marker

**Files:**

- Create: `lib/src/core/update_recovery.dart`
- Modify: `lib/updater_controller.dart`
- Modify: `lib/desktop_updater.dart`
- Modify: `lib/widget/update_card.dart`
- Modify: `lib/widget/update_dialog.dart`
- Modify: `docs/ui-widgets.md`
- Test: `test/update_recovery_test.dart`
- Test: `test/updater_controller_test.dart`
- Test: `test/update_ready_ui_test.dart`
- Test: `test/update_dialog_listener_test.dart`

**Contract:**

```dart
class UpdateInstallRecoveryMarker {
  const UpdateInstallRecoveryMarker({
    required this.createdAt,
    required this.packageVersion,
    required this.platform,
    required this.channel,
    this.appVersion,
    this.updateVersion,
    this.updateBuildNumber,
    this.stagingPath,
    this.diagnosticsText,
  });
}

abstract class UpdateRecoveryStore {
  Future<UpdateInstallRecoveryMarker?> readPendingInstall({
    required String channel,
  });

  Future<void> writePendingInstall(UpdateInstallRecoveryMarker marker);

  Future<void> clearPendingInstall({required String channel});
}
```

The store is app-owned. The package never picks a default path and never writes
recovery markers unless the app supplies a store.

**Controller behavior:**

- Before native handoff, write a pending marker with app version, target update
  version/build, staging path, and redacted diagnostics text.
- If the platform method throws before the app exits, clear the marker and
  surface the current-session `UpdateFailed(report)`.
- On startup or explicit `recoverPendingInstall()`, read the marker:
  - target version/build installed -> clear marker and stay idle;
  - old version still installed -> state becomes `UpdateFailed(report)`;
  - version unavailable -> state becomes `UpdateFailed(report)` with a clear
    "could not verify completed install" entry.

**Fail-first tests:**

- `restartApp()` writes a marker before native handoff.
- Pre-handoff native failure clears the marker and still exposes a report.
- Relaunch on old version creates a recovered `UpdateFailed(report)`.
- Relaunch on target version clears the marker without showing failure.
- Recovery store read/write failures do not crash app startup; they create
  diagnostic warnings when possible.

## Task 8C: Native Helper Diagnostics Log Path

**Files:**

- Modify: `lib/desktop_updater_platform_interface.dart`
- Modify: `lib/desktop_updater_method_channel.dart`
- Modify: `lib/desktop_updater.dart`
- Modify: `lib/updater_controller.dart`
- Modify: `macos/desktop_updater/Sources/desktop_updater/DesktopUpdaterPlugin.swift`
- Modify: `windows/desktop_updater_plugin.cpp`
- Modify: `linux/desktop_updater_plugin.cc`
- Test: `test/desktop_updater_method_channel_test.dart`
- Test: `test/native_helper_script_test.dart`
- Test: `windows/test/desktop_updater_plugin_test.cpp`
- Test: `linux/test/desktop_updater_plugin_test.cc`

**Contract:**

```dart
Future<void> installUpdate({
  required String stagingPath,
  List<String> removedFiles = const [],
  bool allowUnsignedMacOSUpdates = false,
  String? diagnosticsLogPath,
});
```

The path is explicit and app-owned. If absent, native helpers do not write logs.

**Native helper events:**

- helper scheduled;
- waiting for parent process;
- staging path validation;
- bundle/package identity checks;
- backup start/success/failure;
- move/copy start/success/failure;
- rollback start/success/failure;
- cleanup start/success/failure;
- relaunch attempt.

Use line-oriented text or JSONL with a stable schema. Prefer JSONL for machine
parsing, but keep the user-facing copied report plain text.

**Safety rules:**

- Never log authorization headers, tokens, credentials, passwords, signatures,
  private keys, certificate passwords, or upload secrets.
- Do not log environment variables wholesale.
- Bound line length.
- If the helper cannot write the log, continue install work; support logging
  must not brick updates.
- Include enough context to understand rollback without exposing secret paths
  beyond the app-owned staging/install paths.

## Task 8D: Platform Verification Gates

macOS can be verified locally. Windows and Linux should use the existing GitHub
Actions platform jobs as the source of evidence.

**macOS local gates:**

```sh
dart format --set-exit-if-changed lib test
flutter analyze --no-fatal-infos
flutter test --no-pub \
  test/update_diagnostics_test.dart \
  test/update_recovery_test.dart \
  test/updater_controller_test.dart \
  test/desktop_updater_method_channel_test.dart \
  test/native_helper_script_test.dart \
  test/update_ready_ui_test.dart \
  test/update_dialog_listener_test.dart
flutter build macos --release
```

Add a local helper-failure smoke that:

- builds an installed old app and staged update app;
- passes a temp `diagnosticsLogPath`;
- forces one helper failure path, such as invalid staging or identity mismatch;
- confirms the log contains helper events and the old app remains runnable.

**Windows GitHub Actions gates:**

Use `.github/workflows/desktop-updater-ci.yml` Windows jobs:

- `flutter build windows --debug`;
- Windows native plugin tests;
- `flutter test integration_test -d windows`;
- `flutter build windows --release`;
- release native plugin tests;
- `dart run tool/release_publish_smoke.dart --platform windows`.

Extend the smoke or native tests to assert:

- method channel forwards `diagnosticsLogPath`;
- helper writes expected log events when a copy/rollback path fails;
- rollback still restores the backup;
- log file is uploaded as a workflow artifact only for failed or explicit
  diagnostics runs.

**Linux GitHub Actions gates:**

Use `.github/workflows/desktop-updater-ci.yml` Linux jobs:

- `flutter build linux --debug`;
- Linux native plugin tests;
- `xvfb-run -a flutter test integration_test -d linux`;
- `flutter build linux --release`;
- release native plugin tests;
- `dart run tool/release_publish_smoke.dart --platform linux`.

Extend the smoke or native tests to assert:

- method channel forwards `diagnosticsLogPath`;
- helper writes expected log events when prune/copy/rollback fails;
- rollback still restores the previous bundle;
- log file is uploaded as a workflow artifact only for failed or explicit
  diagnostics runs.

## Task 8E: Documentation And Support Flow

**Files:**

- Modify: `docs/ui-widgets.md`
- Modify: `docs/publishing.md`
- Modify: `docs/github-actions-ci-cd.md`
- Modify: `docs/windows-linux-production-release.md`

Document three app-owned integration levels:

1. In-memory problem report only: default, no file writes.
2. App-owned Dart log sink: writes redacted lifecycle entries to a path chosen
   by the app.
3. App-owned native helper log path plus recovery store: captures post-exit
   helper failures and supports post-relaunch reports.

Include sample user support wording:

```text
Open Settings > Updates > Copy update report. If the app cannot open that
screen, attach the update log from <app-owned path>.
```

Avoid hardcoding platform-specific support paths in the package docs except as
examples owned by the app.

## Acceptance

- No storage, file logging, upload, or telemetry happens by default.
- Apps can opt into redacted Dart lifecycle logs without platform code.
- Apps can opt into recovery markers and post-relaunch reports.
- Native helpers can append post-exit install/rollback events only when an
  explicit `diagnosticsLogPath` is provided.
- `UpdateFailed(error, report: report)` works for recovered install failures.
- Redaction applies before copied/exported reports and documented file-log
  examples.
- Logging failures do not prevent diagnostics generation or update install
  attempts.
- macOS evidence can be produced locally.
- Windows and Linux evidence is produced by existing GitHub Actions jobs, with
  log artifacts attached for diagnostics runs.

## Open Questions

- Should the package provide a ready `FileUpdateDiagnosticsSink`, or should docs
  keep file writes fully app-owned?
- Should recovered install markers be consumed after first report, or retained
  until the app explicitly clears them?
- Should native helper logs be plain text for support teams or JSONL for
  structured parsing?
- Should `diagnosticsLogPath` be passed only through `DesktopUpdaterController`,
  or also exposed on the lower-level `DesktopUpdater.installUpdate()` facade?
