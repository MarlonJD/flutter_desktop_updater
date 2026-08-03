# Task 2 Report — Dart Trust, Durable Handoff, and Signed Publishing

Date: 2026-08-03

## Summary

Implemented the Task 2 Dart/core/platform/publishing candidate from the clean Task 2 base. The change makes signed trust and package identity mandatory for update checks and staging, keeps check/stage authority owner-bound and single-use, writes and reads back exact v3 recovery receipts before native dispatch, replaces raw platform install handoff with a library-issued `VerifiedNativeInstallRequest`, adds sealed typed native recovery capabilities, and preserves the internal MethodChannel method name `installUpdate` with the exact five-entry payload.

The signed publishing path now requires the active signing key to match the trusted public-key map, signs descriptor and app archive metadata from publisher-owned final bytes after hooks, signs the final index, and routes custom-command uploads through ordered isolated phases with strict receipts and revision evidence. Automatic S3/SFTP/FTP signed index publication is fail-closed unless a backend supplies a tested conditional write/lease; that production backend work remains explicitly outstanding.

## Implemented

- Required `expectedPackageId` and non-empty normalized trusted release public keys for `UpdateClient`, `DesktopUpdater`, and `DesktopUpdaterController`.
- Verified signed `app-archive.json`, signed `release.json`, and descriptor package identity before artifact requests.
- Made low-level update checks/stages owner-bound and single-use through retained internal state.
- Added v3 recovery markers with package identity, staging path, stage provenance SHA-256, diagnostics text, app version, and transaction ID.
- Added `PersistedInstallTransaction` and exact write/readback receipt creation.
- Added sealed `VerifiedNativeInstallRequest`, sealed `NativeInstallRecovery`, `QueryAndRecoverNativeInstallRecovery`, `AtomicAfterExitNativeInstallRecovery`, and `dispatchVerifiedInstall`.
- Changed platform handoff to `installVerifiedUpdate(VerifiedNativeInstallRequest)` while preserving MethodChannel method name `installUpdate` and exact payload keys: `stagingPath`, `expectedPackageId`, `expectedArtifactSha256`, `stageProvenanceSha256`, `transactionId`.
- Updated controller recovery to use typed recovery capabilities instead of runtime-type or method fallback paths.
- Updated focused fixtures, example smoke hooks, compiler-contract tests, CLI tests, publishing E2Es, and fixture builders.
- Added ordered custom-command upload phase isolation, strict receipt parsing, expected revision evidence, and fail-closed unordered backend behavior.

## Verification

- `flutter test --no-pub test/update_client_security_test.dart test/updater_controller_test.dart test/update_recovery_test.dart test/desktop_updater_test.dart test/desktop_updater_method_channel_test.dart test/release_signature_verifier_test.dart test/release_index_signature_verifier_test.dart` — passed, 41 tests.
- `flutter test --no-pub test/release_cli/upload/custom_command_upload_provider_test.dart test/release_cli/release_publisher_build_test.dart test/release_cli/release_publish_config_test.dart test/release_cli/release_command_test.dart test/release_cli/release_sign_command_test.dart test/release_cli/release_validate_test.dart test/release_cli/release_doctor_test.dart test/desktop_updater_cli_test.dart test/app_archive_command_test.dart test/app_archive_writer_test.dart test/release_cli/upload` — passed, 97 tests.
- `flutter test --no-pub test/e2e/zip_first_update_flow_test.dart test/native_runtime_resource_limits_test.dart test/staged_update_provenance_test.dart test/release_publish_smoke_tool_test.dart test/e2e/release_publish_manual_e2e_test.dart test/e2e/release_publish_custom_command_e2e_test.dart test/zip_release_packager_test.dart test/release_cli/upload/custom_command_upload_provider_test.dart test/v3_removed_api_contract_test.dart` — passed, 62 tests.
- `flutter test --no-pub test/artifact_verifier_test.dart test/compat/flutter_300_channel_controller_contract_test.dart test/compat/flutter_300_public_api_test.dart test/linux_native_sdk_layout_test.dart` — passed, 32 tests.
- `flutter test --no-pub test/example_hosted_smoke_config_test.dart test/linux_release_smoke_config_test.dart test/native_package_retail_contract_test.dart test/native_runtime_smoke_contract_test.dart` — passed, 30 tests with 1 local tool skip because `pkg-config` is unavailable on this host.
- `dart format --output=none --set-exit-if-changed .` — passed.
- `flutter analyze --no-fatal-infos` — passed with 539 pre-existing info diagnostics and no warnings/errors.
- `flutter test --no-pub` — passed, 759 tests with 4 skips. The skips are the gated provider E2Es plus the local `pkg-config` compile proof when the host tool is unavailable.

## Decisions and notes

- Kept the internal MethodChannel method name `installUpdate`; only the Dart API and payload authority changed.
- Added typed recovery classes instead of keeping per-method platform fallback surfaces, matching the ExecPlan model and compiler contract fixtures.
- Kept direct example smoke from constructing raw native installs; it now records the raw handoff removal and smoke diagnostics while the controller owns verified install dispatch.
- Made S3/SFTP/FTP automatic signed publishing reject without a conditional write/lease rather than silently publishing an unordered index.
- Did not change native production ABI/API contracts for macOS Swift, Windows ABI 2/NuGet, or Linux installed targets/recovery implementation.
- Did not change lockfiles, package version, changelog, branch, tags, releases, or GitHub PR state.

## Remaining risks / explicitly incomplete brief items

- Hosted prior-index acquisition, explicit `--initialize-feed`, `--existing-app-archive`, final remote revision recheck, and hosted selection validation are not fully implemented for all backends in this candidate. The local publisher carries a revision object through the ordered boundary, and custom-command receipts are strict, but the production remote history/conditional index-write protocol still needs backend-specific implementation.
- S3/SFTP/FTP signed app-archive publication is fail-closed until a tested exclusive lease or conditional write is added. This prevents unsafe unordered publish, but it is not the complete production publishing experience described by the brief.
- Provider E2E tests that require external credentials remain skipped unless `DESKTOP_UPDATER_RUN_RELEASE_PUBLISH_E2E=1` is set.
- Native target-host proof for future Tasks 3–5 remains out of scope for this Task 2 Dart/public/core/platform/publishing candidate.
