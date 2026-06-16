# 2.2.0 Compatibility Lock Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans or superpowers:subagent-driven-development to implement this plan task-by-task. This plan must be completed before `2026-06-16-multi-stage-desktop-updater-extraction-plan.md`. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Freeze the current `desktop_updater` 2.2.0 behavior with tests, fixtures, snapshots, and release gates before any protocol or native extraction begins.

**Architecture:** Add a compatibility harness that exercises the existing package from public API, CLI, metadata, diagnostics, and native-helper boundaries. This plan intentionally avoids product-code refactors; tests should pass against the current implementation once their fixtures/snapshots are added. Later extraction stages must run this harness unchanged.

**Tech Stack:** Dart 3.6, Flutter plugin APIs, `flutter_test`, existing release CLI entrypoints, current Swift/C++/Linux native plugin sources, `dart pub publish --dry-run`, and existing platform smoke/config tests.

---

## Hard Rule

No protocol extraction, package moving, SwiftPM extraction, .NET wrapper, Linux helper extraction, or Flutter adapter cleanup may start until this plan is complete.

Allowed changes in this plan:

- Add tests.
- Add static fixtures and golden snapshots.
- Add documentation describing compatibility gates.
- Update `docs/plans/index.md`.

Disallowed changes in this plan:

- Move production code.
- Rename public APIs.
- Change CLI commands or output intentionally.
- Change hosted metadata shape.
- Change native helper behavior.
- Simplify diagnostics/recovery behavior.

If a compatibility test cannot pass against current 2.2.0 behavior, stop and classify one of these before editing product code:

- the test is wrong and must be corrected,
- the fixture is wrong and must be corrected,
- the current behavior has an existing bug that needs a separate bugfix plan,
- the requested extraction would require a breaking change and must be rejected or deferred.

## Baseline Reference

Current branch: `protocol-extraction-milestone`

Baseline already observed before this plan:

```text
flutter test --no-pub
Result: PASS, 232 passed, 3 provider E2E skipped behind DESKTOP_UPDATER_RUN_RELEASE_PUBLISH_E2E=1
```

That baseline is not enough by itself. This plan adds targeted guards so future refactors fail quickly when they drift from 2.2.0 behavior.

## Locked Surfaces

This plan must lock these surfaces before extraction starts:

- Flutter public exports and constructor behavior.
- MethodChannel method names and argument shapes.
- `DesktopUpdaterController` startup/manual/strict behavior.
- `app-archive.json` schema-v3 parsing and serialization.
- `release.json` schema-v3 parsing, canonical signing bytes, and serialization.
- Release selection by platform, channel, version/build, and rollout.
- Version/build comparison semantics.
- Artifact URL policy, hash mismatch, and length mismatch behavior.
- Ed25519 descriptor signature success/failure behavior.
- Safe zip path policy and current macOS `ditto` boundary.
- Diagnostics redaction, report formatting, bounded entries, sink behavior, and recovery marker behavior.
- Native helper JSONL event names.
- CLI help text, exit code classes, publish layout, hook order, and validation behavior.
- Existing release gates and skipped-gate reporting.

## Task 1: Add Compatibility Test Directory And Public API Lock

**Files:**
- Create: `test/compat/flutter_220_public_api_test.dart`
- Test existing: `test/desktop_updater_test.dart`
- Test existing: `test/desktop_updater_method_channel_test.dart`
- Test existing: `test/updater_controller_test.dart`

- [ ] **Step 1: Write the public API characterization test**

Create `test/compat/flutter_220_public_api_test.dart`:

```dart
import "package:desktop_updater/desktop_updater.dart";
import "package:desktop_updater/updater_controller.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  test("Flutter package keeps 2.2.0 public runtime surface", () {
    final updater = DesktopUpdater();
    final controller = DesktopUpdaterController(
      appArchiveUrl: null,
      skipInitialVersionCheck: true,
    );

    expect(updater, isA<DesktopUpdater>());
    expect(controller.skipInitialVersionCheck, isTrue);
    expect(const UpdateIdle(), isA<UpdateState>());
    expect(UpdateFailed(StateError("x")), isA<UpdateState>());
    expect(UpdateProblemReport, isNotNull);
    expect(UpdateDiagnosticsRecorder, isNotNull);
    expect(UpdateInstallRecoveryMarker, isNotNull);
    expect(UpdateCleanupReport, isNotNull);
  });
}
```

- [ ] **Step 2: Run and classify**

Run:

```sh
flutter test --no-pub test/compat/flutter_220_public_api_test.dart
```

Expected: PASS. If it fails, fix the test to match actual 2.2.0 exports; do not change product code.

- [ ] **Step 3: Run existing Flutter adapter tests**

Run:

```sh
flutter test --no-pub test/desktop_updater_test.dart test/desktop_updater_method_channel_test.dart test/updater_controller_test.dart
```

Expected: PASS.

## Task 2: Lock MethodChannel And Controller Behavior

**Files:**
- Create: `test/compat/flutter_220_channel_controller_contract_test.dart`
- Test existing: `test/desktop_updater_method_channel_test.dart`
- Test existing: `test/updater_controller_test.dart`

- [ ] **Step 1: Write MethodChannel contract test**

Create `test/compat/flutter_220_channel_controller_contract_test.dart`:

```dart
import "package:desktop_updater/desktop_updater_method_channel.dart";
import "package:desktop_updater/updater_controller.dart";
import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";

const _channel = MethodChannel("desktop_updater");

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  test("installUpdate keeps 2.2.0 MethodChannel argument shape", () async {
    late MethodCall capturedCall;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (methodCall) async {
      capturedCall = methodCall;
      return null;
    });

    await MethodChannelDesktopUpdater().installUpdate(
      stagingPath: "/tmp/staged",
      removedFiles: const ["old.dll"],
      allowUnsignedMacOSUpdates: true,
      diagnosticsLogPath: "/tmp/helper.jsonl",
    );

    expect(capturedCall.method, "installUpdate");
    expect(capturedCall.arguments, {
      "stagingPath": "/tmp/staged",
      "removedFiles": <String>["old.dll"],
      "allowUnsignedMacOSUpdates": true,
      "diagnosticsLogPath": "/tmp/helper.jsonl",
    });
  });

  test("skipInitialVersionCheck remains a passive initialization mode", () {
    final controller = DesktopUpdaterController(
      appArchiveUrl: null,
      skipInitialVersionCheck: true,
    );

    expect(controller.skipInitialVersionCheck, isTrue);
    expect(controller.state, isA<UpdateIdle>());
  });
}
```

- [ ] **Step 2: Run and classify**

Run:

```sh
flutter test --no-pub test/compat/flutter_220_channel_controller_contract_test.dart
```

Expected: PASS. If it fails because existing behavior differs, correct the test to current behavior before proceeding.

- [ ] **Step 3: Run controller regression set**

Run:

```sh
flutter test --no-pub test/updater_controller_test.dart test/desktop_updater_method_channel_test.dart
```

Expected: PASS.

## Task 3: Lock Metadata Fixtures And Selection Behavior

**Files:**
- Create: `fixtures/compat/app-archive.schema-v3.json`
- Create: `fixtures/compat/release.schema-v3.json`
- Create: `fixtures/compat/version-ordering.json`
- Create: `fixtures/compat/rollout-selection.json`
- Create: `test/compat/metadata_selection_220_contract_test.dart`
- Test existing: `test/release_index_test.dart`
- Test existing: `test/release_descriptor_test.dart`
- Test existing: `test/version_info_test.dart`
- Test existing: `test/update_client_security_test.dart`

- [ ] **Step 1: Write failing fixture-backed metadata test**

Create `test/compat/metadata_selection_220_contract_test.dart`:

```dart
import "dart:convert";
import "dart:io";

import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:desktop_updater/src/core/release_index.dart";
import "package:desktop_updater/src/version_info.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  test("2.2.0 app archive and release fixtures parse unchanged", () {
    final index = ReleaseIndex.fromJson(
      jsonDecode(File("fixtures/compat/app-archive.schema-v3.json").readAsStringSync())
          as Map<String, dynamic>,
    );
    final descriptor = ReleaseDescriptor.fromJson(
      jsonDecode(File("fixtures/compat/release.schema-v3.json").readAsStringSync())
          as Map<String, dynamic>,
    );

    expect(index.schemaVersion, 3);
    expect(index.items.single.version, descriptor.version);
    expect(index.items.single.buildNumber, descriptor.buildNumber);
    expect(index.items.single.platform, descriptor.platform);
    expect(index.items.single.channel, descriptor.channel);
  });

  test("2.2.0 version ordering fixture remains stable", () {
    final cases = jsonDecode(
      File("fixtures/compat/version-ordering.json").readAsStringSync(),
    ) as List<dynamic>;

    for (final entry in cases.cast<Map<String, dynamic>>()) {
      final candidate = DesktopVersionInfo.parse(entry["candidate"] as String);
      final current = DesktopVersionInfo.parse(entry["current"] as String);
      expect(compareDesktopVersions(candidate, current).sign, entry["result"]);
    }
  });

  test("2.2.0 rollout selection fixture remains stable", () {
    final fixture = jsonDecode(
      File("fixtures/compat/rollout-selection.json").readAsStringSync(),
    ) as Map<String, dynamic>;
    final index = ReleaseIndex.fromJson(fixture["index"] as Map<String, dynamic>);
    final current = DesktopVersionInfo.parse(fixture["currentVersion"] as String);

    for (final entry in (fixture["cases"] as List<dynamic>).cast<Map<String, dynamic>>()) {
      final selected = selectReleaseIndexItem(
        index: index,
        platform: entry["platform"] as String,
        channel: entry["channel"] as String,
        currentVersion: current,
        installationIdentity: entry["identity"] as String?,
      );
      expect(selected?.version, entry["selectedVersion"]);
    }
  });
}
```

- [ ] **Step 2: Run and verify RED**

Run:

```sh
flutter test --no-pub test/compat/metadata_selection_220_contract_test.dart
```

Expected: FAIL because `fixtures/compat/*` does not exist.

- [ ] **Step 3: Add fixtures from current behavior**

Add fixture files with current schema-v3 fields only. Include rollout cases for:

- no rollout metadata,
- partial rollout without identity,
- identity inside rollout,
- identity outside rollout,
- channel-specific bucket behavior.

- [ ] **Step 4: Verify GREEN**

Run:

```sh
flutter test --no-pub test/compat/metadata_selection_220_contract_test.dart
```

Expected: PASS.

- [ ] **Step 5: Run metadata regression set**

Run:

```sh
flutter test --no-pub test/release_index_test.dart test/release_descriptor_test.dart test/version_info_test.dart test/update_client_security_test.dart test/compat/metadata_selection_220_contract_test.dart
```

Expected: PASS.

## Task 4: Lock Artifact Trust, Signing, And Zip Safety

**Files:**
- Create: `fixtures/compat/signing-ed25519.json`
- Create: `fixtures/compat/artifact-valid.txt`
- Create: `fixtures/compat/artifact-hash-mismatch.txt`
- Create: `fixtures/compat/artifact-length-mismatch.txt`
- Create: `fixtures/compat/zip-safety.md`
- Create: `test/compat/trust_zip_220_contract_test.dart`
- Test existing: `test/artifact_verifier_test.dart`
- Test existing: `test/release_signature_verifier_test.dart`
- Test existing: `test/safe_zip_extractor_test.dart`

- [ ] **Step 1: Write failing trust and zip contract test**

Create `test/compat/trust_zip_220_contract_test.dart`:

```dart
import "dart:convert";
import "dart:io";

import "package:crypto/crypto.dart" as crypto;
import "package:desktop_updater/src/core/artifact_verifier.dart";
import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  test("artifact hash and length checks remain fail-closed", () async {
    final tempDir = await Directory.systemTemp.createTemp("compat_trust_");
    try {
      final artifact = File("${tempDir.path}/artifact.txt")
        ..writeAsStringSync("hello");
      final valid = ReleaseArtifact(
        kind: "zip",
        url: Uri.parse("https://updates.example.com/artifact.zip"),
        sha256: crypto.sha256.convert(utf8.encode("hello")).toString(),
        length: 5,
      );

      await const ArtifactVerifier().verifyArtifactFile(
        artifact: valid,
        file: artifact,
      );

      await expectLater(
        const ArtifactVerifier().verifyArtifactFile(
          artifact: ReleaseArtifact(
            kind: "zip",
            url: valid.url,
            sha256: "a" * 64,
            length: 5,
          ),
          file: artifact,
        ),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(
        const ArtifactVerifier().verifyArtifactFile(
          artifact: ReleaseArtifact(
            kind: "zip",
            url: valid.url,
            sha256: valid.sha256,
            length: 6,
          ),
          file: artifact,
        ),
        throwsA(isA<FileSystemException>()),
      );
    } finally {
      await tempDir.delete(recursive: true);
    }
  });
}
```

- [ ] **Step 2: Run and classify**

Run:

```sh
flutter test --no-pub test/compat/trust_zip_220_contract_test.dart
```

Expected: PASS as characterization. If it fails, inspect current artifact verifier behavior before changing product code.

- [ ] **Step 3: Add signing fixture after current tests**

Use existing `test/release_signature_verifier_test.dart` behavior as the source of truth. Add `fixtures/compat/signing-ed25519.json` with public key id, public key, valid descriptor, and invalid descriptor values for future cross-language conformance.

- [ ] **Step 4: Run trust regression set**

Run:

```sh
flutter test --no-pub test/artifact_verifier_test.dart test/release_signature_verifier_test.dart test/safe_zip_extractor_test.dart test/compat/trust_zip_220_contract_test.dart
```

Expected: PASS.

## Task 5: Lock Diagnostics, Recovery, And Helper Event Names

**Files:**
- Create: `fixtures/compat/problem-report-redacted.txt`
- Create: `fixtures/compat/native-helper-events.json`
- Create: `test/compat/diagnostics_recovery_220_contract_test.dart`
- Create: `test/compat/native_helper_events_220_contract_test.dart`
- Test existing: `test/update_diagnostics_test.dart`
- Test existing: `test/update_recovery_test.dart`
- Test existing: `test/native_helper_diagnostics_docs_test.dart`

- [ ] **Step 1: Write diagnostics golden test**

Create `test/compat/diagnostics_recovery_220_contract_test.dart`:

```dart
import "dart:io";

import "package:desktop_updater/desktop_updater.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  test("problem report redaction golden remains stable", () {
    final report = UpdateProblemReport(
      generatedAt: DateTime.utc(2026, 6, 16, 12),
      packageVersion: "2.2.0",
      platform: "macos",
      channel: "stable",
      appVersion: "1.0.0+100",
      updateVersion: "2.0.0",
      stagingPath: "/tmp/staged",
      failure: StateError("Authorization: Bearer abc password=hunter2"),
      entries: [
        UpdateDiagnosticEntry(
          timestamp: DateTime.utc(2026, 6, 16, 12, 1),
          stage: UpdateDiagnosticStage.download,
          level: UpdateDiagnosticLevel.error,
          message: "GET https://updates.example.com/release.json?token=abc&safe=value",
        ),
      ],
    );

    expect(
      report.toPlainText(),
      File("fixtures/compat/problem-report-redacted.txt").readAsStringSync(),
    );
  });
}
```

- [ ] **Step 2: Run and verify RED**

Run:

```sh
flutter test --no-pub test/compat/diagnostics_recovery_220_contract_test.dart
```

Expected: FAIL because `fixtures/compat/problem-report-redacted.txt` does not exist.

- [ ] **Step 3: Generate and review golden text**

Create the golden text from current behavior. Review it manually for:

- no `abc`,
- no `hunter2`,
- `safe=value` preserved,
- bounded report format readable.

- [ ] **Step 4: Write native helper event source contract test**

Create `test/compat/native_helper_events_220_contract_test.dart`:

```dart
import "dart:io";

import "package:flutter_test/flutter_test.dart";

void main() {
  test("native helper event names are stable across platform sources", () {
    final sources = [
      File("macos/desktop_updater/Sources/desktop_updater/DesktopUpdaterPlugin.swift"),
      File("windows/desktop_updater_plugin.cpp"),
      File("linux/desktop_updater_plugin.cc"),
    ].map((file) => file.readAsStringSync()).join("\n");

    for (final event in [
      "helper scheduled",
      "waiting for parent process",
      "parent process exited",
      "staging path validation",
      "backup start",
      "backup success",
      "backup failure",
      "move start",
      "move success",
      "move failure",
      "rollback start",
      "rollback success",
      "rollback failure",
      "cleanup start",
      "cleanup success",
      "cleanup failure",
      "relaunch attempt",
    ]) {
      expect(sources, contains(event), reason: event);
    }
  });
}
```

- [ ] **Step 5: Run diagnostics gate**

Run:

```sh
flutter test --no-pub test/update_diagnostics_test.dart test/update_recovery_test.dart test/native_helper_diagnostics_docs_test.dart test/compat/diagnostics_recovery_220_contract_test.dart test/compat/native_helper_events_220_contract_test.dart
```

Expected: PASS.

## Task 6: Lock CLI Help, Exit Codes, Publish Layout, And Hook Order

**Files:**
- Create: `test/compat/cli_220_contract_test.dart`
- Test existing: `test/release_cli/release_doctor_test.dart`
- Test existing: `test/release_cli/release_validate_test.dart`
- Test existing: `test/release_cli/release_sign_command_test.dart`
- Test existing: `test/release_cli/release_publisher_build_test.dart`
- Test existing: `test/release_cli/publish_layout_test.dart`
- Test existing: `test/app_archive_command_test.dart`
- Test existing: `test/app_archive_writer_test.dart`
- Test existing: `test/zip_release_packager_test.dart`

- [ ] **Step 1: Write CLI compatibility test**

Create `test/compat/cli_220_contract_test.dart`:

```dart
import "package:desktop_updater/src/release_cli/release_command.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  test("release CLI keeps help, subcommands, and usage exit code", () async {
    final output = StringBuffer();
    final helpCode = await runReleaseCommand(["--help"], output: output);

    expect(helpCode, 0);
    expect(output.toString(), contains("release doctor"));
    expect(output.toString(), contains("release publish"));
    expect(output.toString(), contains("release sign"));
    expect(output.toString(), contains("release validate"));

    final badOutput = StringBuffer();
    final badCode = await runReleaseCommand(["unknown"], output: badOutput);
    expect(badCode, 64);
  });
}
```

- [ ] **Step 2: Run and classify**

Run:

```sh
flutter test --no-pub test/compat/cli_220_contract_test.dart
```

Expected: PASS. If it fails, adjust the test to current `args` behavior and record the actual exit code.

- [ ] **Step 3: Run CLI regression set**

Run:

```sh
flutter test --no-pub test/release_cli test/app_archive_command_test.dart test/app_archive_writer_test.dart test/zip_release_packager_test.dart test/compat/cli_220_contract_test.dart
```

Expected: PASS.

## Task 7: Add Compatibility Gate Documentation

**Files:**
- Create: `docs/plans/2026-06-16-220-compatibility-lock-report-template.md`
- Modify: `docs/plans/2026-06-16-multi-stage-desktop-updater-extraction-plan.md`
- Modify: `docs/plans/index.md`

- [ ] **Step 1: Add report template**

Create `docs/plans/2026-06-16-220-compatibility-lock-report-template.md` with this structure:

```markdown
# 2.2.0 Compatibility Lock Report

## Passed Checks

## Skipped Checks

## Blocked Checks

## Fixtures Added

## Public API Locked

## CLI Behavior Locked

## Diagnostics/Recovery Locked

## Native Helper Events Locked

## Approval To Start Extraction

Extraction may start only after passed/skipped/blocked checks are reviewed.
```

- [ ] **Step 2: Add prerequisite note to the multi-stage plan**

At the top of `docs/plans/2026-06-16-multi-stage-desktop-updater-extraction-plan.md`, add a prerequisite note that this compatibility lock plan must complete first.

- [ ] **Step 3: Update plan index**

Keep compatibility lock under Active and move the multi-stage extraction plan under Next until this plan is complete.

## Task 8: Final Compatibility Lock Gate

**Files:**
- No production files.
- Test: full repository gates.

- [ ] **Step 1: Run focused compatibility gate**

Run:

```sh
flutter test --no-pub test/compat
```

Expected: PASS.

- [ ] **Step 2: Run full Flutter gate**

Run:

```sh
flutter test --no-pub
```

Expected: PASS with provider E2E tests skipped unless `DESKTOP_UPDATER_RUN_RELEASE_PUBLISH_E2E=1` is set.

- [ ] **Step 3: Run publish dry-run gate**

Run:

```sh
dart pub publish --dry-run
```

Expected: PASS or documented non-product blocker. Separate warnings from failures.

- [ ] **Step 4: Run current macOS SwiftPM gate**

Run:

```sh
swift test --package-path macos/desktop_updater
```

Expected: PASS on macOS or documented blocker.

- [ ] **Step 5: Write compatibility lock report**

Fill out `docs/plans/2026-06-16-220-compatibility-lock-report-template.md` or copy it into a dated report file. Include:

- exact passed checks,
- exact skipped checks,
- exact blocked checks,
- fixture list,
- public API locked,
- CLI behavior locked,
- diagnostics/recovery locked,
- native helper events locked,
- explicit statement whether Stage 1 of the multi-stage extraction may begin.

## Completion Criteria

This plan is complete only when:

- `test/compat` exists and passes.
- Full `flutter test --no-pub` passes.
- Existing CLI and publish tests pass.
- Golden fixtures exist for metadata, diagnostics, signing, artifact checks, and rollout behavior.
- Native helper event names are locked.
- The compatibility lock report has passed/skipped/blocked checks.
- `docs/plans/index.md` marks this plan Completed and moves multi-stage extraction back to Active or Next with user approval.

## Next Step After Completion

After this plan is complete, begin `2026-06-16-multi-stage-desktop-updater-extraction-plan.md` at Stage 1. Do not skip directly to macOS SwiftPM, Windows .NET, Linux helper, or Flutter adapter cleanup.
