# 2.2.0 Compatibility Lock Report

## Passed Checks

- `flutter test --no-pub test/compat`
  - Result: PASS
  - Evidence: 13 compatibility tests passed.
- `flutter test --no-pub`
  - Result: PASS
  - Evidence: 245 tests passed.
- `swift test --package-path macos/desktop_updater`
  - Result: PASS
  - Evidence: SwiftPM built `desktop_updater`, copied `FlutterMacOS.framework`, and executed 1 XCTest with 0 failures. SwiftPM also emitted the existing `PrivacyInfo.xcprivacy` unhandled-file warning.
- `dart pub publish --dry-run`
  - Result: PASS
  - Evidence: package validation completed with 0 warnings after the scoped compatibility-lock changes were committed.

## Skipped Checks

- `flutter test --no-pub`
  - Skipped: 3 release publish provider E2E tests.
  - Reason: provider E2E tests remain gated behind `DESKTOP_UPDATER_RUN_RELEASE_PUBLISH_E2E=1`.
  - Skipped tests observed:
    - `test/e2e/release_publish_ftp_e2e_test.dart`
    - `test/e2e/release_publish_s3_e2e_test.dart`
    - `test/e2e/release_publish_sftp_e2e_test.dart`

## Blocked Checks

- None.

## Generated Local Gate Inputs

- `macos/FlutterFramework` is an ignored local symlink to Flutter's generated `FlutterFramework` Swift package.
- `Frameworks` is an ignored local symlink to Flutter's generated `FlutterMacOS.xcframework` output.
- These are generated dependency inputs for the local SwiftPM gate and are excluded from git and pub packages.

## Fixtures Added

- `fixtures/compat/app-archive.schema-v3.json`
- `fixtures/compat/release.schema-v3.json`
- `fixtures/compat/version-ordering.json`
- `fixtures/compat/rollout-selection.json`
- `fixtures/compat/signing-ed25519.json`
- `fixtures/compat/artifact-valid.txt`
- `fixtures/compat/artifact-hash-mismatch.txt`
- `fixtures/compat/artifact-length-mismatch.txt`
- `fixtures/compat/zip-safety.md`
- `fixtures/compat/problem-report-redacted.txt`
- `fixtures/compat/native-helper-events.json`

## Public API Locked

- `package:desktop_updater/desktop_updater.dart`
- `package:desktop_updater/updater_controller.dart`
- `DesktopUpdater`
- `DesktopUpdaterController(skipInitialVersionCheck: true)`
- `UpdateState` and `UpdateIdle`
- `UpdateFailed`
- `UpdateProblemReport`
- `UpdateDiagnosticsRecorder`
- `UpdateInstallRecoveryMarker`
- `UpdateCleanupReport`

## CLI Behavior Locked

- `release --help` keeps the 2.2.0 subcommand surface:
  - `release doctor`
  - `release publish`
  - `release sign`
  - `release validate`
- Unknown top-level release token keeps current help-style exit `0` behavior.
- Invalid known-command option keeps usage/error exit `64` behavior.

## Diagnostics/Recovery Locked

- Redacted plain-text problem report format.
- Secret redaction for authorization, token, and password values.
- Preservation of non-secret query values such as `safe=value`.
- App-owned pending install marker fields and values.

## Native Helper Events Locked

- `helper scheduled`
- `waiting for parent process`
- `parent process exited`
- `staging path validation`
- `backup start`
- `backup success`
- `backup failure`
- `move start`
- `move success`
- `move failure`
- `rollback start`
- `rollback success`
- `rollback failure`
- `cleanup start`
- `cleanup success`
- `cleanup failure`
- `relaunch attempt`

## Approval To Start Extraction

The 2.2.0 compatibility lock gates are complete except for the intentionally gated provider E2E tests. Multi-stage extraction may begin as a separate follow-up task; this report does not start extraction work.
