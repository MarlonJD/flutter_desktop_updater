# Task 2 Report — Dart Trust, Durable Handoff, and Signed Publishing

Date: 2026-08-03

## Summary

Implemented the Task 2 Dart/core/platform/publishing candidate from the clean Task 2 base. The change makes signed trust and package identity mandatory for update checks and staging, keeps check/stage authority owner-bound and single-use, writes and reads back exact v3 recovery receipts before native dispatch, replaces raw platform install handoff with a library-issued `VerifiedNativeInstallRequest`, adds sealed typed native recovery capabilities, and preserves the internal MethodChannel method name `installUpdate` with the exact five-entry payload.

The signed publishing path now requires the active signing key to match the trusted public-key map, acquires and strictly verifies hosted signed prior history, supports explicit first-feed initialization and byte-exact existing-history input, freezes the prior remote revision, rechecks it before automatic publication, signs descriptor and app archive metadata from publisher-owned final bytes after hooks, signs the final index, and routes automatic uploads through ordered isolated phases with strict conditional-write or exclusive-lease receipts. Custom-command, S3, SFTP, and FTP providers now expose deterministic ordered index-publication boundaries; S3 accepts a conditional object-storage client and SFTP/FTP accept tested exclusive-lease clients.

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
- Added ordered custom-command upload phase isolation, strict receipt parsing, expected revision evidence, and provider-side receipt verification.
- Added signed hosted prior-index acquisition, `--initialize-feed`, `--existing-app-archive`, final remote revision recheck, and hosted selection validation for automatic signed publishing.
- Added typed S3 conditional-write and SFTP/FTP exclusive-lease provider boundaries with deterministic local fixture coverage.

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

## Fix round 1 — reviewer findings addressed

Implementation changes:

- Completed canonical signed publishing for the in-scope Dart publisher path:
  - signed publish now fetches hosted `app-archive.json`, verifies its Ed25519 signature with the trusted key map, and freezes its raw SHA-256 plus ETag revision;
  - absent hosted history now requires explicit `--initialize-feed`;
  - `--existing-app-archive` is parsed and must itself be signed; when hosted history exists, its bytes must match the hosted bytes exactly;
  - automatic publish rechecks the hosted revision immediately before upload and validates hosted update selection after ordered publication;
  - final local index is seeded from the frozen prior index before the new release is upserted and signed.
- Replaced S3/SFTP/FTP "only fail-closed" behavior with explicit production-safe provider boundaries:
  - `ConditionalObjectStorageClient.putIndexFileConditionally` for S3;
  - `ExclusiveLeaseSftpRemoteFileClient.writeIndexFileWithLease` for SFTP;
  - `ExclusiveLeaseFtpRemoteFileClient.writeIndexFileWithLease` for FTP;
  - all return `IndexPublishReceipt` and share digest/prior-revision/evidence validation.
- Restored focused `UpdateClient` trust/authority coverage for unknown key ID, invalid index signature, concurrent/stale results, owner-bound result rejection, post-success replay, and artifact URL non-request on trust failures.
- Restored focused controller coverage for throwing write, null readback, every authoritative serialized marker-field mismatch, exact cross-stage receipt pairing, and two-dispatch race with exactly one platform call.
- Added target-host proof hooks for forged raw MethodChannel payload validation without changing production native ABI:
  - Windows and Linux plugin GTests named `ForgedRawMethodChannelPayloadFailsStageDescriptorAndTargetValidation`;
  - macOS SwiftPM test named `testForgedRawMethodChannelPayloadFailsStageDescriptorAndTargetValidation`;
  - GitHub Actions target-host steps filter and run those tests explicitly.

Exact verification commands:

- `flutter test --no-pub test/release_cli/upload/s3_upload_provider_test.dart test/release_cli/upload/sftp_upload_provider_test.dart test/release_cli/upload/ftp_upload_provider_test.dart` — passed.
- `flutter test --no-pub test/release_cli/release_publisher_build_test.dart` — passed.
- `flutter test --no-pub test/update_client_security_test.dart test/updater_controller_test.dart` — passed.
- `flutter test --no-pub test/release_cli/release_publisher_build_test.dart test/release_cli/release_command_test.dart test/release_cli/upload/s3_upload_provider_test.dart test/release_cli/upload/sftp_upload_provider_test.dart test/release_cli/upload/ftp_upload_provider_test.dart test/update_client_security_test.dart test/updater_controller_test.dart test/desktop_updater_method_channel_test.dart` — passed, 66 tests.
- `dart format --output=none --set-exit-if-changed lib/src/release_cli/release_publish_config.dart lib/src/release_cli/publish_command.dart lib/src/release_cli/release_publisher.dart lib/src/release_cli/upload/upload_provider.dart lib/src/release_cli/upload/s3_upload_provider.dart lib/src/release_cli/upload/sftp_upload_provider.dart lib/src/release_cli/upload/ftp_upload_provider.dart test/release_cli/release_publisher_build_test.dart test/release_cli/release_command_test.dart test/release_cli/upload/s3_upload_provider_test.dart test/release_cli/upload/sftp_upload_provider_test.dart test/release_cli/upload/ftp_upload_provider_test.dart test/update_client_security_test.dart test/updater_controller_test.dart` — passed.
- `flutter analyze --no-fatal-infos` — passed with 545 info diagnostics and no warnings/errors.
- `ruby -e 'require "yaml"; YAML.load_file(".github/workflows/desktop-updater-ci.yml"); puts ".github/workflows/desktop-updater-ci.yml: OK"'` — passed.
- `flutter test --no-pub` — passed, 773 tests with 4 skips.
- `flutter test --no-pub test/v3_removed_api_contract_test.dart` — passed.

Local limitations:

- `swift test --package-path macos/desktop_updater --filter DesktopUpdaterSwiftPMTests/testForgedRawMethodChannelPayloadFailsStageDescriptorAndTargetValidation` was attempted locally and failed before test execution because `macos/FlutterFramework` is absent in this worktree. The CI target-host step was added to run this after the workflow prepares the Flutter macOS framework.
- Windows and Linux forged raw MethodChannel native GTest filters are target-host workflow evidence; local macOS does not have the Windows/Linux example CTest build trees.

Remaining risks:

- External credentialed provider E2E tests remain skipped unless `DESKTOP_UPDATER_RUN_RELEASE_PUBLISH_E2E=1` is set.
- The new S3/SFTP/FTP production-safe ordered index publication requires the app/deployer to provide a concrete conditional-write or exclusive-lease client/transport; unsafe unordered index publication remains rejected.

## Fix round 2 — scoped re-review 019fc79a addressed

Implementation changes:

- Publishing:
  - manual signed publication now performs the same final hosted remote-revision recheck before returning;
  - final signed `app-archive.json` is rebuilt after `postPackage` hooks from the frozen pre-hook signed prior snapshot plus the publisher-owned current release item, so hooks cannot author index history/items;
  - shared ordered-upload receipt validation now rejects `conditionalWrite` receipts with non-null lease evidence and requires lowercase 64-hex `leaseEvidenceSha256` for `exclusiveLease`;
  - strict custom-command receipt parser coverage now includes mechanism/evidence contradictions.
- Authority tests:
  - added a distinct differently configured foreign-client check-result rejection test;
  - added signed descriptor/index binding mutation coverage that fails before artifact download;
  - retained unknown-key, invalid-signature, concurrent/stale/replay, and artifact-not-requested trust failure coverage in `test/update_client_security_test.dart`.
- Controller tests:
  - added cross-stage receipt pairing coverage: a stage A receipt presented with stage B blocks dispatch and makes zero platform calls;
  - added marker-retention coverage for native status transport loss and unauthenticated status;
  - added marker-clear coverage only after authenticated terminal success plus current-version evidence.
- Forged raw MethodChannel proof:
  - reverted the temporary Linux production plugin/private-header seam after scope review; no production native ABI/API files are changed in this fix round;
  - added an example integration test that invokes `MethodChannel("desktop_updater").invokeMethod("installUpdate", forgedRawMap)` so the payload crosses the real plugin MethodChannel boundary;
  - added explicit Windows, macOS, and Linux target-host workflow steps for that integration test;
  - converted the Windows native test from direct `ScheduleInstallAndRelaunch` to the existing public plugin `HandleMethodCall("installUpdate", raw map)` boundary.

Exact verification commands and output:

```text
$ flutter test --no-pub --reporter compact --name "signed manual publish rechecks frozen hosted revision before returning" test/release_cli/release_publisher_build_test.dart
00:01 +0: signed manual publish rechecks frozen hosted revision before returning
00:01 +1: signed manual publish rechecks frozen hosted revision before returning
00:01 +1: All tests passed!
```

```text
$ flutter test --no-pub --reporter compact --name "signed publisher ignores post-package hook-authored index history" test/release_cli/release_publisher_build_test.dart
00:00 +0: signed publisher ignores post-package hook-authored index history
00:01 +1: signed publisher ignores post-package hook-authored index history
00:01 +1: All tests passed!
```

```text
$ flutter test --no-pub --reporter compact --name "rejects mechanism and lease evidence contradictions" test/release_cli/upload/custom_command_upload_provider_test.dart
00:00 +0: strict index publish receipt parser rejects mechanism and lease evidence contradictions
00:00 +1: strict index publish receipt parser rejects mechanism and lease evidence contradictions
00:00 +1: All tests passed!
```

```text
$ flutter test --no-pub --reporter compact --name "shared receipt validation rejects provider mechanism contradictions" test/release_cli/upload/custom_command_upload_provider_test.dart
00:01 +0: shared receipt validation rejects provider mechanism contradictions
00:01 +1: shared receipt validation rejects provider mechanism contradictions
00:01 +1: All tests passed!
```

```text
$ flutter test --no-pub --reporter compact --name "download rejects check result from differently configured foreign client before artifact request" test/update_client_security_test.dart
00:01 +0: download rejects check result from differently configured foreign client before artifact request
00:01 +1: download rejects check result from differently configured foreign client before artifact request
00:01 +1: All tests passed!
```

```text
$ flutter test --no-pub --reporter compact --name "mutated descriptor/index binding fails before artifact request" test/update_client_security_test.dart
00:01 +0: mutated descriptor/index binding fails before artifact request
00:01 +1: mutated descriptor/index binding fails before artifact request
00:01 +1: All tests passed!
```

```text
$ flutter test --no-pub --reporter compact --name "stage A receipt cannot authorize stage B platform dispatch" test/updater_controller_test.dart
00:01 +0: stage A receipt cannot authorize stage B platform dispatch
00:01 +1: stage A receipt cannot authorize stage B platform dispatch
00:01 +1: All tests passed!
```

```text
$ flutter test --no-pub --reporter compact --name "recovery marker survives transport loss and unauthenticated status" test/updater_controller_test.dart
00:01 +0: recovery marker survives transport loss and unauthenticated status
00:01 +1: recovery marker survives transport loss and unauthenticated status
00:01 +1: All tests passed!
```

```text
$ flutter test --no-pub --reporter compact --name "recovery marker clears only after authenticated terminal evidence" test/updater_controller_test.dart
00:00 +0: recovery marker clears only after authenticated terminal evidence
00:01 +1: recovery marker clears only after authenticated terminal evidence
00:01 +1: All tests passed!
```

```text
$ flutter test --no-pub --reporter compact test/release_cli/release_publisher_build_test.dart test/release_cli/upload/custom_command_upload_provider_test.dart test/update_client_security_test.dart test/updater_controller_test.dart test/desktop_updater_method_channel_test.dart
00:03 +58: recovery marker clears only after authenticated terminal evidence
00:03 +58: All tests passed!
```

```text
$ dart format --output=none --set-exit-if-changed example/integration_test/plugin_integration_test.dart lib/src/release_cli/release_publisher.dart lib/src/release_cli/upload/upload_provider.dart test/release_cli/release_publisher_build_test.dart test/release_cli/upload/custom_command_upload_provider_test.dart test/update_client_security_test.dart test/updater_controller_test.dart test/desktop_updater_method_channel_test.dart
Formatted 8 files (0 changed) in 0.03 seconds.
```

```text
$ dart format --output=none --set-exit-if-changed test/release_cli/upload/custom_command_upload_provider_test.dart
Formatted 1 file (0 changed) in 0.01 seconds.
```

```text
$ flutter test --no-pub --reporter compact test/release_cli/upload/custom_command_upload_provider_test.dart
00:01 +5: shared receipt validation rejects provider mechanism contradictions
00:01 +6: shared receipt validation rejects provider mechanism contradictions
00:01 +6: All tests passed!
```

```text
$ flutter analyze --no-fatal-infos
Analyzing flutter_desktop_updater...
542 issues found. (ran in 2.3s)
Exit code: 0. All diagnostics were info-level pre-existing style/API-doc diagnostics; no warnings or errors.
```

```text
$ ruby -e 'require "yaml"; YAML.load_file(".github/workflows/desktop-updater-ci.yml"); puts ".github/workflows/desktop-updater-ci.yml: OK"'
.github/workflows/desktop-updater-ci.yml: OK
```

Local target-host limitations:

```text
$ flutter test integration_test/plugin_integration_test.dart -d macos --name "forged raw MethodChannel payload fails native validation"
/Users/marlonjd/.codex/worktrees/f828/flutter_desktop_updater/example/macos/Runner.xcodeproj: error: No signing certificate "Mac Development" found: No "Mac Development" signing certificate matching team ID "UPK4SC93AN" with a private key was found. (in target 'Runner' from project 'Runner')
** BUILD FAILED **
00:00 +0 -1: Some tests failed.
```

The macOS integration test is blocked locally by host signing credentials, not by Dart or plugin compilation. The workflow now runs the same forged raw MethodChannel integration test on Windows, macOS, and Linux target hosts:

```text
flutter test integration_test/plugin_integration_test.dart -d windows --name "forged raw MethodChannel payload fails native validation"
flutter test integration_test/plugin_integration_test.dart -d macos --name "forged raw MethodChannel payload fails native validation"
xvfb-run -a flutter test integration_test/plugin_integration_test.dart -d linux --name "forged raw MethodChannel payload fails native validation"
```

## Fix round 3 — forged raw MethodChannel target-host boundary proof tightened

Implementation changes:

- Replaced the empty/invalid-stage forged payload fixture with a real integration-test fixture that creates an updater-owned staging directory, staged executable tree, platform release manifest, stage provenance marker, and install identity marker before dispatching a raw `MethodChannel("desktop_updater").invokeMethod("installUpdate", forgedRawMap)`.
- The fixture signs `.desktop_updater_release_manifest.json` with `ReleaseDescriptorSigner` and records the stage provenance descriptor SHA-256 from the final signed canonical descriptor bytes.
- The forged map now keeps valid stage/provenance/descriptor/artifact evidence and forges the binding that native code must reject:
  - Windows: valid staged evidence plus a forged `executableRelativePath` under the install root, expecting `Windows install target does not match the running app.`
  - macOS: valid staged app/provenance evidence with a staged package identity that differs from the running bundle, expecting `Stage provenance is not bound to the install request.`
  - Linux: valid staged evidence with a forged expected package identity, expecting `Linux stage provenance package identity changed.`
- Removed only the prior inadequate forged-proof native tests: the Windows invalid-stage `HandleMethodCall` assertion, the Linux direct `ValidateInstallRequest` forged proof, and the macOS SwiftPM empty-stage proof. Their coverage is replaced by the single real example integration MethodChannel boundary test wired into all applicable target-host lanes.
- CI target-host commands:
  - Windows: `flutter test integration_test/plugin_integration_test.dart -d windows --name "forged raw MethodChannel payload fails native validation"`
  - macOS: `flutter test integration_test/plugin_integration_test.dart -d macos --name "forged raw MethodChannel payload fails native validation"`
  - Linux: `xvfb-run -a flutter test integration_test/plugin_integration_test.dart -d linux --name "forged raw MethodChannel payload fails native validation"`
- Scope guard: no production native ABI/API files are changed in this fix round; the diff is limited to integration tests, native test cleanup, CI workflow wiring, and this report.

Exact local verification commands and output:

```text
$ dart format --output=none --set-exit-if-changed example/integration_test/plugin_integration_test.dart
Formatted 1 file (0 changed) in 0.00 seconds.
```

```text
$ flutter test --no-pub --reporter compact test/update_client_security_test.dart test/updater_controller_test.dart test/update_recovery_test.dart test/desktop_updater_test.dart test/desktop_updater_method_channel_test.dart test/release_cli/upload/custom_command_upload_provider_test.dart test/release_cli/release_publisher_build_test.dart
00:03 +68: recovery marker survives transport loss and unauthenticated status
00:03 +68: recovery marker clears only after authenticated terminal evidence
00:03 +69: recovery marker clears only after authenticated terminal evidence
00:03 +69: All tests passed!
```

```text
$ flutter analyze --no-fatal-infos
Analyzing flutter_desktop_updater...
542 issues found. (ran in 2.4s)
Exit code: 0. All diagnostics were info-level pre-existing style/API-doc diagnostics; no warnings or errors.
```

```text
$ ruby -e 'require "yaml"; YAML.load_file(".github/workflows/desktop-updater-ci.yml"); puts ".github/workflows/desktop-updater-ci.yml: OK"'
.github/workflows/desktop-updater-ci.yml: OK
```

```text
$ git diff --check
Exit code: 0. No whitespace errors.
```

Local target-host attempt:

```text
$ flutter test --no-pub integration_test/plugin_integration_test.dart -d macos --name "forged raw MethodChannel payload fails native validation"
00:00 +0: loading /Users/marlonjd/.codex/worktrees/f828/flutter_desktop_updater/example/integration_test/plugin_integration_test.dart
Adding Swift Package Manager integration...                        755ms
Building macOS application...
/Users/marlonjd/.codex/worktrees/f828/flutter_desktop_updater/example/macos/Runner.xcodeproj: error: No signing certificate "Mac Development" found: No "Mac Development" signing certificate matching team ID "UPK4SC93AN" with a private key was found. (in target 'Runner' from project 'Runner')
** BUILD FAILED **
00:00 +0 -1: Some tests failed.
```

The local macOS integration run is blocked before test execution by this host's missing Mac Development signing certificate. The exact target-host command is wired into CI for macOS, and corresponding Windows/Linux target-host commands are wired into their lanes. Their pass/fail output must be taken from the next pushed workflow run; no direct helper calls or source scans are used as the Task 2 forged-payload proof.
