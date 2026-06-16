# Trust, UX, And Product Roadmap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the current 2.x release mechanics into a more trusted, quieter, easier-to-adopt updater while preserving the platform-neutral zip-first contract.

**Architecture:** Keep the existing `app-archive.json -> release.json -> app.zip` contract and add trust, UX, and adoption improvements as independent slices. Platform-specific signing stays advisory and hook-based; the package-owned trust layer is a platform-independent signed `release.json` verifier with pinned public keys.

**Tech Stack:** Dart 3.6+, Flutter desktop plugins, existing `ReleaseDescriptor`, `ArtifactVerifier`, `UpdateClient`, `DesktopUpdaterController`, `release publish/validate` CLI, `cryptography_plus`, Flutter tests via `flutter test --no-pub`, and GitHub Actions release smoke gates.

---

## Non-Negotiable Constraints

- Do not create, switch, rename, delete, or otherwise operate on branches unless the user explicitly asks for that branch action in the same execution turn.
- Do not post GitHub comments or review feedback through any Codex/GitHub connector identity.
- Do not commit, push, publish to pub.dev, run real uploads, or mutate production signing resources unless the user explicitly asks in the execution turn.
- Keep canonical docs, file names, type names, method names, JSON field names, and source comments in English.
- Use `flutter test --no-pub` for normal validation to avoid `example/pubspec.lock` churn.
- Treat Windows Authenticode and Linux package-channel signing as optional app-owned release gates. Do not make US/EU/CA-backed code-signing availability a core package requirement.
- Keep the default updater usable for unsigned internal, local, and user-controlled distribution, while making production-trust gaps explicit through warnings and doctor output.

## Scope Split

This roadmap intentionally covers several independent product lanes. Execute each task group as its own implementation slice with fail-first tests and its own verification. Do not try to land every section in one change unless the user explicitly asks for a large combined pass.

Recommended order:

1. Platform-independent signed `release.json`.
2. Quiet startup check failures.
3. Release doctor and adoption friction reduction.
4. Analyzer info cleanup.
5. Persistent skip, retry/backoff, telemetry, and policy features.
6. Update diagnostics and problem report UI.
7. Resumable download, rollout percentages, rollback reports, and delta updates.

## File Structure

- Create: `lib/src/core/release_signature_verifier.dart`
  - Ed25519 verification for `ReleaseDescriptor.signature` against pinned public keys.
- Create: `lib/src/release_cli/sign_command.dart`
  - Signs a local `release.json` after packaging using a private key supplied outside the repository.
- Modify: `lib/src/core/artifact_verifier.dart`
  - Keep policy-based verification, but wire a first-class Ed25519 verifier path.
- Modify: `lib/src/release_cli/validate_command.dart`
  - Add optional signature verification for hosted validation.
- Modify: `lib/src/release_cli/release_command.dart`
  - Add `release sign` to the existing `publish` and `validate` CLI family.
- Modify: `lib/src/release_cli/publish_command.dart`
  - Add pre-package and post-package hook configuration only after `release doctor` defines the checks clearly.
- Modify: `lib/updater_controller.dart`
  - Make automatic startup checks quiet on failure while preserving explicit manual-check results.
- Modify: `lib/src/core/update_state.dart`
  - Add state details only when required for retry, policy, telemetry, or user-facing failure classification.
- Modify: `lib/src/io/http_update_transport.dart`
  - Add retry/backoff first; add resumable range download later as a separate slice.
- Modify: `lib/src/core/update_client.dart`
  - Add metadata policy checks, telemetry callbacks, staged cleanup reporting, and descriptor signature enforcement.
- Create: `lib/src/core/update_diagnostics.dart`
  - Structured update log entries and user-copyable problem reports with safe redaction.
- Create: `lib/src/core/update_diagnostics_recorder.dart`
  - In-memory diagnostics recorder with optional app-owned export callback and no storage backend dependency.
- Modify: `lib/src/core/release_descriptor.dart`
  - Extend schema only when adding signed metadata, minimum OS, rollout, or delta artifacts. Preserve schema v3 compatibility.
- Create: `lib/widget/update_problem_report_dialog.dart`
  - Ready-made Material dialog for failed updates with summary, details, copy report, retry, and optional report action.
- Modify: `lib/src/package/zip_release_packager.dart`
  - Add optional descriptor fields that publish-time policy owns.
- Modify: `docs/publishing.md`
  - Document signed descriptor, quiet startup behavior, doctor workflow, hooks, and advanced update policies.
- Modify: `docs/windows-linux-production-release.md`
  - Reframe platform code signing as optional app-owned trust, not the main package trust model.
- Modify: `README.md`
  - Keep quick start small; link advanced trust and doctor sections instead of front-loading release engineering.
- Test: `test/release_signature_verifier_test.dart`
- Test: `test/release_cli/release_sign_command_test.dart`
- Test: `test/release_cli/release_validate_test.dart`
- Test: `test/updater_controller_test.dart`
- Test: `test/update_transport_test.dart`
- Test: `test/update_client_security_test.dart`
- Test: `test/release_descriptor_test.dart`
- Test: `test/release_cli/release_doctor_test.dart`
- Test: `test/update_diagnostics_test.dart`
- Test: `test/update_problem_report_dialog_test.dart`

## Task 1: Platform-Independent Signed `release.json`

**Files:**
- Create: `lib/src/core/release_signature_verifier.dart`
- Create: `lib/src/release_cli/sign_command.dart`
- Modify: `lib/src/core/artifact_verifier.dart`
- Modify: `lib/src/release_cli/validate_command.dart`
- Modify: `lib/src/release_cli/release_command.dart`
- Modify: `docs/publishing.md`
- Test: `test/release_signature_verifier_test.dart`
- Test: `test/release_cli/release_sign_command_test.dart`
- Test: `test/release_cli/release_validate_test.dart`

- [ ] **Step 1.1: Add fail-first signature verifier tests**

Create `test/release_signature_verifier_test.dart` with tests for valid signature, tampered descriptor, missing public key, malformed base64 signature, and unsupported algorithm.

Run:

```sh
flutter test --no-pub test/release_signature_verifier_test.dart
```

Expected: fail because `release_signature_verifier.dart` does not exist.

- [ ] **Step 1.2: Implement Ed25519 descriptor verification**

Create `lib/src/core/release_signature_verifier.dart` with an `Ed25519ReleaseSignatureVerifier` that accepts a `Map<String, String>` of `publicKeyId -> base64 raw public key`, decodes `ReleaseDescriptor.signature.value`, and verifies `descriptor.canonicalSignatureBytes()`.

Acceptance behavior:

```text
valid descriptor + matching key -> true
tampered descriptor -> false
unknown publicKeyId -> false
invalid base64 -> false
non-ed25519 algorithm -> false
```

- [ ] **Step 1.3: Wire verifier into `ArtifactVerifier` policy**

Keep `ArtifactVerificationPolicy(requireSignature: true)` fail-closed. Add a constructor helper or factory so CLI callers can build a verifier from pinned public keys without hand-writing the callback every time.

Acceptance behavior:

```text
requireSignature false -> existing behavior
requireSignature true + no signature -> throws
requireSignature true + no verifier -> throws
requireSignature true + invalid signature -> throws
requireSignature true + valid signature -> passes
```

- [ ] **Step 1.4: Add `release sign` CLI**

Add a command shape under the existing release command:

```sh
dart run desktop_updater:release sign \
  --release dist/desktop_updater/releases/2.2.0/linux/release.json \
  --public-key-id stable-2026 \
  --private-key-env DESKTOP_UPDATER_RELEASE_PRIVATE_KEY
```

The private key must come from an environment variable or external file path, not from `desktop_updater.yaml`.

Expected output:

```text
Signed release descriptor:
dist/desktop_updater/releases/2.2.0/linux/release.json

Public key id:
stable-2026
```

- [ ] **Step 1.5: Add signed validation**

Extend `release validate` with:

```sh
dart run desktop_updater:release validate \
  --manifest dist/desktop_updater/.desktop_updater_publish.json \
  --require-signature \
  --public-keys-env DESKTOP_UPDATER_RELEASE_PUBLIC_KEYS
```

Expected `DESKTOP_UPDATER_RELEASE_PUBLIC_KEYS` shape:

```json
{"stable-2026":"base64-raw-ed25519-public-key"}
```

- [ ] **Step 1.6: Document platform trust split**

In `docs/publishing.md`, document that signed `release.json` proves update metadata authenticity across macOS, Windows, and Linux, while Authenticode/notarization/native package signatures remain app-owned platform trust.

Verification:

```sh
flutter test --no-pub test/release_signature_verifier_test.dart test/release_cli/release_sign_command_test.dart test/release_cli/release_validate_test.dart test/artifact_verifier_test.dart
```

Expected: all tests pass.

## Task 2: Quiet Startup Check Failures

**Files:**
- Modify: `lib/updater_controller.dart`
- Modify: `lib/src/core/update_state.dart` only if failure classification needs public state
- Modify: `docs/ui-widgets.md`
- Test: `test/updater_controller_test.dart`
- Test: `test/update_dialog_listener_test.dart`

- [ ] **Step 2.1: Add fail-first startup behavior tests**

Add tests proving:

```text
DesktopUpdaterController(appArchiveUrl: url) does not surface an unhandled async exception when automatic check fails.
controller.state becomes UpdateFailed(error).
checkForUpdates() still returns ManualUpdateCheckFailed for explicit user checks.
checkVersion() still throws when awaited directly.
```

Run:

```sh
flutter test --no-pub test/updater_controller_test.dart
```

Expected: fail until automatic startup checks use a quiet wrapper.

- [ ] **Step 2.2: Split automatic and explicit checks**

Keep `checkVersion()` as the strict low-level method. Add a private `_checkVersionQuietly()` used only by `init()`:

```dart
Future<void> _checkVersionQuietly() async {
  try {
    await checkVersion();
  } on Object {
    // checkVersion already moved state to UpdateFailed.
  }
}
```

Change `init()` to call `unawaited(_checkVersionQuietly())`.

- [ ] **Step 2.3: Document behavior**

Update `docs/ui-widgets.md` to state that automatic startup checks update controller state and built-in UI, but do not throw into app startup; explicit `checkVersion()` remains strict and `checkForUpdates()` returns a typed result.

Verification:

```sh
flutter test --no-pub test/updater_controller_test.dart test/update_dialog_listener_test.dart
```

Expected: all tests pass.

## Task 3: Adoption Friction Reduction

**Files:**
- Create: `lib/src/release_cli/doctor_command.dart`
- Modify: `lib/src/release_cli/release_command.dart`
- Modify: `lib/src/release_cli/release_publish_config.dart`
- Modify: `docs/publishing.md`
- Modify: `README.md`
- Test: `test/release_cli/release_doctor_test.dart`
- Test: `test/release_cli/release_command_test.dart`

- [ ] **Step 3.1: Add `release doctor` tests**

Test these diagnostics:

```text
missing desktop_updater.yaml -> warning with minimum config example
missing updates.baseUrl -> blocking error
http baseUrl -> warning for production
no upload provider -> info that manual upload is expected
windows platform + no configured pre-package signing hook -> warning only
linux direct zip + no descriptor signature config -> warning only
macos + allowUnsignedMacOSUpdates guidance -> warning only
```

- [ ] **Step 3.2: Implement `release doctor`**

Add:

```sh
dart run desktop_updater:release doctor --platform windows
dart run desktop_updater:release doctor --platform linux
dart run desktop_updater:release doctor --platform macos
```

Exit behavior:

```text
0 -> ready or warnings only
64 -> invalid config or missing required fields
1 -> unexpected filesystem or parser failure
```

- [ ] **Step 3.3: Add hook config after doctor messages are stable**

Add optional app-owned hooks to config:

```yaml
hooks:
  prePackage:
    - command: ./tool/sign_windows_release.ps1
      platforms: [windows]
  postPackage:
    - command: ./tool/sign_release_json.sh
      platforms: [linux, windows, macos]
```

Hooks must receive a manifest/environment contract and must never receive secrets from YAML.

- [ ] **Step 3.4: Keep README quick**

Update README with one small line:

```text
Run `dart run desktop_updater:release doctor --platform <platform>` before your first production release.
```

Verification:

```sh
flutter test --no-pub test/release_cli/release_doctor_test.dart test/release_cli/release_command_test.dart test/release_cli/release_publish_config_test.dart
```

Expected: all tests pass.

## Task 4: Analyzer Info Debt Reduction

**Files:**
- Modify: public Dart files under `lib/`
- Modify: selected tests only when formatter/lint fixes are mechanical
- Modify: `analysis_options.yaml` only if a lint rule is intentionally relaxed with a comment

- [x] **Step 4.1: Capture baseline**

Run:

```sh
flutter analyze --no-fatal-infos
```

Expected: command exits 0. Record the issue count before cleanup.

Baseline captured on 2026-06-16: `flutter analyze --no-fatal-infos` exited 0
with 324 analyzer info issues.

- [x] **Step 4.2: Fix public API documentation in focused batches**

Start with exported or user-facing files:

```text
lib/desktop_updater.dart
lib/updater_controller.dart
lib/src/core/update_state.dart
lib/src/manual_update_check_result.dart
lib/src/core/release_descriptor.dart
lib/src/core/release_index.dart
lib/src/core/artifact_verifier.dart
```

- [x] **Step 4.3: Fix mechanical style infos**

Apply `dart format .`, then fix `require_trailing_commas`, `use_raw_strings`, `prefer_const_constructors`, and `directives_ordering` in small batches.

- [x] **Step 4.4: Decide example-app doc lint policy**

Either document public example classes or suppress `public_member_api_docs` for `example/**` through `analysis_options.yaml` with a comment explaining that example app widgets are not package API.

Verification:

```sh
dart format --set-exit-if-changed .
flutter analyze --no-fatal-infos
flutter test --no-pub
```

Expected: analyzer exits 0 with materially fewer infos than the baseline, and tests pass.

Verification on 2026-06-16: `dart format --set-exit-if-changed .` exited 0,
`flutter analyze --no-fatal-infos` exited 0 with 229 analyzer info issues, and
`flutter test --no-pub` passed with 207 tests and 3 opt-in provider E2E tests
skipped.

## Task 5: Persistent Skip, Retry/Backoff, Telemetry, And Policy

**Files:**
- Create: `lib/src/core/update_preferences.dart`
- Create: `lib/src/core/update_retry_policy.dart`
- Create: `lib/src/core/update_telemetry.dart`
- Modify: `lib/updater_controller.dart`
- Modify: `lib/src/io/http_update_transport.dart`
- Modify: `lib/src/core/release_descriptor.dart`
- Modify: `lib/src/core/release_index.dart`
- Modify: `docs/ui-widgets.md`
- Modify: `docs/publishing.md`
- Test: `test/updater_controller_test.dart`
- Test: `test/update_transport_test.dart`
- Test: `test/release_descriptor_test.dart`
- Test: `test/release_index_test.dart`

- [ ] **Step 5.1: Persistent skip-this-version**

Add an optional preference adapter:

```dart
abstract interface class UpdatePreferences {
  Future<String?> skippedVersion({required String channel});
  Future<void> skipVersion({required String version, required String channel});
  Future<void> clearSkippedVersion({required String channel});
}
```

The controller should keep current in-memory skip behavior when no adapter is supplied.

- [ ] **Step 5.2: Retry/backoff**

Add `UpdateRetryPolicy` with explicit defaults:

```text
maxAttempts: 3
initialDelay: 500 milliseconds
maxDelay: 5 seconds
retry statuses: 408, 429, 500, 502, 503, 504
do not retry: descriptor parse failures, signature failures, SHA-256 mismatch
```

- [ ] **Step 5.3: Telemetry callbacks**

Add optional callbacks without adding a telemetry backend:

```dart
typedef DesktopUpdaterTelemetry = void Function(UpdateTelemetryEvent event);
```

Events should include `checkStarted`, `checkFailed`, `updateSelected`, `downloadStarted`, `downloadFailed`, `artifactVerified`, `installScheduled`, and `installFailed`.

- [ ] **Step 5.4: Minimum OS and minimum updater version policy**

Keep existing `minimumUpdaterVersion` and enforce it in `UpdateClient` before download. Add optional descriptor fields:

```json
"minimumOS": {
  "macos": "13.0",
  "windows": "10.0.19045",
  "linux": "glibc-2.35"
}
```

Start with parse and skip behavior; only add platform-specific OS detection when tests can run deterministically.

Verification:

```sh
flutter test --no-pub test/updater_controller_test.dart test/update_transport_test.dart test/release_descriptor_test.dart test/update_client_security_test.dart
```

Expected: all tests pass.

## Task 6: Update Diagnostics And Problem Report UI

**Files:**
- Create: `lib/src/core/update_diagnostics.dart`
- Create: `lib/src/core/update_diagnostics_recorder.dart`
- Modify: `lib/src/core/update_state.dart`
- Modify: `lib/updater_controller.dart`
- Create: `lib/widget/update_problem_report_dialog.dart`
- Modify: `lib/widget/update_card.dart`
- Modify: `lib/widget/update_dialog.dart`
- Modify: `lib/desktop_updater.dart`
- Modify: `docs/ui-widgets.md`
- Modify: `docs/publishing.md`
- Test: `test/update_diagnostics_test.dart`
- Test: `test/updater_controller_test.dart`
- Test: `test/update_problem_report_dialog_test.dart`
- Test: `test/update_ready_ui_test.dart`
- Test: `test/update_dialog_listener_test.dart`

- [x] **Step 6.1: Add fail-first diagnostics model tests**

Create `test/update_diagnostics_test.dart` with tests proving:

```text
UpdateDiagnosticEntry records timestamp, stage, level, message, optional error.
UpdateProblemReport includes package/app/update metadata and ordered entries.
toPlainText() redacts secrets from URLs and text values.
copy text does not include Authorization headers, tokens, passwords, or signatures.
report is bounded to a sane max entry count so UI cannot explode.
```

Use deterministic timestamps in tests.

Run:

```sh
flutter test --no-pub test/update_diagnostics_test.dart
```

Expected: fail because diagnostics types do not exist.

- [x] **Step 6.2: Implement diagnostics data types**

Create `lib/src/core/update_diagnostics.dart` with:

```dart
enum UpdateDiagnosticLevel { info, warning, error }

enum UpdateDiagnosticStage {
  check,
  descriptor,
  policy,
  download,
  verify,
  stage,
  install,
  cleanup,
}

class UpdateDiagnosticEntry {
  const UpdateDiagnosticEntry({
    required this.timestamp,
    required this.stage,
    required this.level,
    required this.message,
    this.error,
  });

  final DateTime timestamp;
  final UpdateDiagnosticStage stage;
  final UpdateDiagnosticLevel level;
  final String message;
  final Object? error;
}

class UpdateProblemReport {
  const UpdateProblemReport({
    required this.generatedAt,
    required this.packageVersion,
    required this.platform,
    required this.channel,
    required this.entries,
    this.appVersion,
    this.updateVersion,
    this.stagingPath,
    this.failure,
  });

  String toPlainText();
}
```

Add redaction helpers that replace query values for keys such as `token`,
`signature`, `password`, `secret`, `key`, `authorization`, and `credential`
with `<redacted>`.

- [x] **Step 6.3: Add fail-first recorder/controller tests**

Extend `test/updater_controller_test.dart` with tests proving:

```text
failed check moves state to UpdateFailed(error, report: report)
failed download records check/download/failed entries
failed install records installFailed and exposes the report
telemetry callback failures do not prevent report generation
onProblemReport callback is optional and invoked only by explicit UI action
```

Run:

```sh
flutter test --no-pub test/updater_controller_test.dart
```

Expected: fail because `UpdateFailed.report`, recorder, and callback wiring do not exist.

- [x] **Step 6.4: Implement in-memory recorder and controller wiring**

Create `lib/src/core/update_diagnostics_recorder.dart` with an in-memory
`UpdateDiagnosticsRecorder` that:

```text
stores bounded entries
records lifecycle stages from check/download/verify/stage/install/cleanup
builds UpdateProblemReport on failure
does not write files
does not upload reports
does not require telemetry
```

Modify `DesktopUpdaterController`:

```dart
DesktopUpdaterController({
  ...,
  UpdateDiagnosticsRecorder? diagnosticsRecorder,
  Future<void> Function(UpdateProblemReport report)? onProblemReport,
})
```

Keep the default recorder in memory. When failures occur, move state to
`UpdateFailed(error, report: recorder.buildReport(...))`. Keep existing
telemetry events; diagnostics must still work when telemetry is null or throws.

- [x] **Step 6.5: Add fail-first problem report UI tests**

Create `test/update_problem_report_dialog_test.dart` and extend ready UI tests
for:

```text
UpdateFailed with report shows "View report" / "Ayrıntıları göster" action in stock UI.
dialog shows human summary first and collapsible technical details second.
"Copy report" writes redacted plain text to Clipboard.
"Report issue" is hidden when no onProblemReport callback exists.
"Report issue" invokes onProblemReport with the current report when supplied.
"Try again" calls controller.checkVersion().
```

Run:

```sh
flutter test --no-pub test/update_problem_report_dialog_test.dart test/update_ready_ui_test.dart test/update_dialog_listener_test.dart
```

Expected: fail until the dialog and UI actions exist.

- [x] **Step 6.6: Implement ready-made report dialog**

Create `lib/widget/update_problem_report_dialog.dart` exporting:

```dart
Future<void> showUpdateProblemReportDialog(
  BuildContext context, {
  required DesktopUpdaterController controller,
  required UpdateProblemReport report,
});

class UpdateProblemReportDialog extends StatelessWidget { ... }
```

The dialog should feel like a desktop problem report surface:

```text
title: "Update failed"
summary: short user-facing failure message
actions: Try again, Copy report, optional Report issue, Close
details: collapsed technical report with monospace selectable text
```

Use Material widgets already used in the package. Do not add a dependency.

- [x] **Step 6.7: Document diagnostics and app-owned reporting**

Update `docs/ui-widgets.md` and `docs/publishing.md`:

```text
automatic checks stay quiet but failures can expose a report through stock UI
reports are generated locally and redacted before copy/export
the package does not upload logs or include a backend
apps can wire onProblemReport to Sentry, email, issue form, or their own API
```

Verification:

```sh
dart format --set-exit-if-changed lib test
flutter analyze --no-fatal-infos
flutter test --no-pub test/update_diagnostics_test.dart test/updater_controller_test.dart test/update_problem_report_dialog_test.dart test/update_ready_ui_test.dart test/update_dialog_listener_test.dart
```

Expected: format clean, analyzer exits 0, and targeted tests pass.

## Task 7: Resumable Download, Staged Rollout, Rollback Reports, And Delta Updates

**Files:**
- Modify: `lib/src/io/http_update_transport.dart`
- Modify: `lib/src/io/update_transport.dart`
- Modify: `lib/src/core/release_index.dart`
- Modify: `lib/src/core/release_descriptor.dart`
- Modify: `lib/src/core/update_client.dart`
- Modify: `lib/src/release_manifest.dart`
- Modify: `docs/publishing.md`
- Test: `test/update_transport_test.dart`
- Test: `test/release_index_test.dart`
- Test: `test/release_descriptor_test.dart`
- Test: `test/update_client_security_test.dart`

- [ ] **Step 7.1: Resumable downloads**

Add HTTP Range support only after retry/backoff lands. Resume only when the server returns `206 Partial Content` and the existing `.part` file length is less than the expected artifact length.

Failure rules:

```text
server ignores Range and returns 200 -> restart from byte 0
server returns wrong Content-Range -> delete partial and fail
final SHA-256 mismatch -> delete partial and fail
```

- [x] **Step 7.2: Staged rollout percentage**

Add optional index metadata:

```json
"rollout": {
  "percentage": 25,
  "salt": "stable-2026-06"
}
```

Selection must be deterministic per installation identity and channel. If the app does not provide an installation identity, rollout filtering is disabled and the item is treated as not eligible unless the rollout is 100 percent.

- [ ] **Step 7.3: Rollback and cleanup report**

Add a small report object emitted after install scheduling or next startup cleanup:

```text
stagingPath
descriptor version
cleanup attempted
cleanup succeeded
backup restored by native helper when known
error text when known
```

Do not block install success on telemetry/report persistence.

- [ ] **Step 7.4: Delta update design gate**

Do not implement binary deltas until the signed descriptor, retry, and resumable download paths are stable. First add descriptor shape support behind an explicit unsupported error:

```json
"artifact": {
  "kind": "zip",
  "url": "https://updates.example.com/full.zip",
  "sha256": "...",
  "length": 123
},
"deltaArtifacts": [
  {
    "fromVersion": "2.1.4",
    "kind": "bsdiff",
    "url": "https://updates.example.com/2.1.4-to-2.2.0.patch",
    "sha256": "...",
    "length": 456
  }
]
```

Runtime must continue choosing the full zip until delta verification and patch application are implemented with fail-first tests.

Verification:

```sh
flutter test --no-pub test/update_transport_test.dart test/release_index_test.dart test/release_descriptor_test.dart test/update_client_security_test.dart
```

Expected: all tests pass.

## Final Verification Gate

Run after each completed implementation slice:

```sh
dart format --set-exit-if-changed .
flutter analyze --no-fatal-infos
flutter test --no-pub
dart pub publish --dry-run
```

Expected:

```text
format clean
analyze exits 0
tests pass
publish dry-run exits 0
```

For platform release mechanics, wait for GitHub Actions Windows and Linux jobs. For notarized macOS publish, use the existing opt-in workflow only when credentials are configured and the user explicitly asks for that gate.

## Self-Review Notes

- Signed `release.json` is the package-owned trust layer and is platform-independent.
- Windows Authenticode and Linux package/repository signing remain app-owned release gates.
- Startup check failure softening is scoped to automatic `init()` checks; strict `checkVersion()` remains available.
- Analyzer cleanup is intentionally separate from behavior changes to keep review risk low.
- Advanced product features are staged after trust and adoption basics so they do not destabilize the release path.
