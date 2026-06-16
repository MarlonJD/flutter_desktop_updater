# Multi-Stage Desktop Updater Extraction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans or superpowers:subagent-driven-development to implement this plan task-by-task. Every code-changing task starts with a failing test or an explicit characterization test, records red/green evidence, and preserves the current Flutter package behavior.

> **Prerequisite:** Complete `docs/plans/2026-06-16-220-compatibility-lock-plan.md` before starting any stage in this plan. The compatibility lock must prove current 2.2.0 public API, CLI, metadata, diagnostics/recovery, and native helper contracts are guarded.

**Goal:** Turn `desktop_updater` from a Flutter-only implementation into a staged desktop updater platform while keeping the Flutter package working exactly as it does in 2.2.0.

**Architecture:** Keep this as one monorepo while the contract and platform packages are being split. First lock current 2.2.0 behavior with compatibility tests and fixtures, then add shared spec/conformance assets, then extract reusable platform layers in this order: macOS SwiftPM, Windows C++/Win32 helper plus .NET wrapper, Linux helper/CLI, and finally thin Flutter adapters over those shared layers. The existing Flutter package, release CLI, diagnostics/recovery model, native helper behavior, and hosted metadata format remain compatible throughout.

**Tech Stack:** Dart 3.6, Flutter plugin APIs, SwiftPM, Swift, C++/Win32, .NET/NuGet, Linux shell/POSIX helper code, `flutter_test`, `swift test`, `dotnet test`, current `args`, `archive`, `crypto`, `cryptography_plus`, `pub_semver`, and current native plugin code.

---

## Current Branch And Baseline

- Branch: `protocol-extraction-milestone`
- Baseline command: `flutter test --no-pub`
- Baseline result before planning: passed with `232` tests and `3` provider E2E tests skipped behind `DESKTOP_UPDATER_RUN_RELEASE_PUBLISH_E2E=1`.
- First sandbox attempt failed because Flutter SDK cache files live outside the workspace; the successful baseline used approved escalation for the same command.

## Stage Gate Policy

Every stage must prove that the existing 2.2.0 behavior is still intact before the next stage begins.

For every code-changing step:

- Run the focused test for the area that changed.
- Run `flutter test --no-pub test/compat`.
- If the step touches a native/platform surface, run that platform's local focused gate too, such as `swift test --package-path macos/desktop_updater` for macOS plugin work.
- If a 2.2.0 compatibility test fails, first assume the test, fixture, or moved wrapper is wrong. Do not intentionally change 2.2.0 behavior without a separate bugfix plan.

For every stage close:

- Run `flutter test --no-pub test/compat`.
- Run `flutter test --no-pub`.
- Run `dart pub publish --dry-run` when the stage touches public package layout, exports, metadata, CLI, fixtures included in the package, or publishable files.
- Run the stage's native gates when that stage touches macOS, Windows, or Linux behavior.
- Record an exact passed/skipped/blocked split before committing, opening a PR, or starting the next stage.

Provider E2E policy:

- The FTP, S3, and SFTP release-publish E2E tests remain behind `DESKTOP_UPDATER_RUN_RELEASE_PUBLISH_E2E=1`.
- If a stage does not touch provider upload behavior, hosted metadata layout, descriptor signing, artifact paths, or release-publish orchestration, record those provider E2Es as skipped unless the credentialed environment is already available.
- If a stage does touch those release-sensitive surfaces, run:

```sh
DESKTOP_UPDATER_RUN_RELEASE_PUBLISH_E2E=1 flutter test --no-pub test/e2e
```

- If the provider E2E environment is unavailable for a release-sensitive stage, record that gate as blocked and require CI or credentialed local evidence before declaring the stage complete.
- Final pre-merge or pre-release verification must either run the provider E2Es or explicitly record why they are skipped/blocked.

## Product Shape At The End

```text
flutter_desktop_updater/
  spec/
  fixtures/
  conformance/

  packages/
    desktop_updater_macos/
      Package.swift
      Sources/DesktopUpdaterMacOS/
      Tests/DesktopUpdaterMacOSTests/

    desktop_updater_windows/
      native/
        # C++/Win32 helper used by Flutter Windows and .NET
      dotnet/
        # DesktopUpdater.DotNet NuGet package wrapping the native helper

    desktop_updater_linux/
      native/
        # Linux helper shared by Flutter Linux and CLI users
      cli/
        # Machine-facing helper CLI

  lib/
    # Existing Flutter package public API remains compatible.

  macos/
  windows/
  linux/
    # Flutter plugin adapters remain, but native update logic becomes thin calls
    # into the shared platform packages/helpers above.
```

## Compatibility Invariants

- Existing Flutter public imports continue to compile:
  - `package:desktop_updater/desktop_updater.dart`
  - `package:desktop_updater/updater_controller.dart`
  - `package:desktop_updater/desktop_updater_platform_interface.dart`
  - `package:desktop_updater/desktop_updater_method_channel.dart`
- Existing controller behavior remains unchanged:
  - `skipInitialVersionCheck` avoids automatic startup checks.
  - automatic `init()` failures settle into `UpdateFailed` without unhandled errors.
  - awaited `checkVersion()` stays strict and rethrows after updating state.
  - manual `checkForUpdates()` keeps typed manual results.
- Existing release contract remains unchanged:
  - `app-archive.json -> release.json -> app.zip`
  - schema version `3`
  - versioned `release.json` stays under `releases/<version>/<platform>/release.json`
  - mutable top-level `app-archive.json` stays the archive index
- Existing trust split remains unchanged:
  - Ed25519 descriptor signing authenticates publisher-owned metadata.
  - SHA-256 and length verification still prove downloaded artifact bytes.
- Existing diagnostics/recovery behavior remains unchanged:
  - no package-owned log files by default
  - app-owned `UpdateDiagnosticsSink`
  - app-owned `UpdateRecoveryStore`
  - optional `diagnosticsLogPath`
  - redacted `UpdateProblemReport`
  - native helper JSONL event names remain backward-compatible
- Existing CLI-first release flow remains unchanged:
  - `dart run desktop_updater:release doctor`
  - `dart run desktop_updater:release publish`
  - `dart run desktop_updater:release sign`
  - `dart run desktop_updater:release validate`
  - `dart run desktop_updater:package`
  - `dart run desktop_updater:app_archive`
  - `dart run desktop_updater:verify`

## Non-Goals

- Do not add Kotlin.
- Do not introduce Rust or a C++ shared cross-platform core.
- Do not rename the Flutter package unless a later release plan explicitly approves it.
- Do not change hosted metadata format.
- Do not make release publishing UI-first. CLI remains the primary control plane.
- Do not remove existing native helpers until adapters are proven against the new shared layer on that platform.

## Stage 0: Preserve 2.2.0 With Compatibility Tests

**Purpose:** Make the current Flutter package behavior hard to accidentally break before any extraction begins.

**Files:**
- Create: `test/compat/flutter_220_public_api_test.dart`
- Create: `test/compat/release_cli_compatibility_test.dart`
- Create: `test/compat/native_helper_diagnostics_contract_test.dart`
- Modify only if a test exposes a gap: current tests under `test/`

- [ ] **Step 0.1: Write the public API characterization test**

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
    expect(UpdateInstallRecoveryMarker, isNotNull);
    expect(UpdateDiagnosticsRecorder, isNotNull);
  });
}
```

- [ ] **Step 0.2: Run and classify the public API test**

Run:

```sh
flutter test --no-pub test/compat/flutter_220_public_api_test.dart
```

Expected: PASS. Record it as a characterization test; if it fails, fix the test to match actual 2.2.0 public exports before changing product code.

- [ ] **Step 0.3: Write release CLI compatibility tests**

Create `test/compat/release_cli_compatibility_test.dart`:

```dart
import "package:desktop_updater/src/release_cli/release_command.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  test("release CLI keeps existing 2.2.0 subcommands", () async {
    final output = StringBuffer();
    final exitCode = await runReleaseCommand(["--help"], output: output);

    expect(exitCode, 0);
    expect(output.toString(), contains("release doctor"));
    expect(output.toString(), contains("release publish"));
    expect(output.toString(), contains("release sign"));
    expect(output.toString(), contains("release validate"));
  });
}
```

- [ ] **Step 0.4: Run release CLI compatibility test**

Run:

```sh
flutter test --no-pub test/compat/release_cli_compatibility_test.dart
```

Expected: PASS.

- [ ] **Step 0.5: Write native helper diagnostics contract tests**

Create `test/compat/native_helper_diagnostics_contract_test.dart` that reads existing Swift/C++/Linux plugin sources and asserts these JSONL event names are still present:

```dart
import "dart:io";

import "package:flutter_test/flutter_test.dart";

void main() {
  test("native helper diagnostics event names stay backward-compatible", () {
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

- [ ] **Step 0.6: Run Stage 0 focused gate**

Run:

```sh
flutter test --no-pub test/compat test/desktop_updater_test.dart test/desktop_updater_method_channel_test.dart test/updater_controller_test.dart test/update_diagnostics_test.dart test/update_recovery_test.dart
```

Expected: PASS.

## Stage 1: Add Spec, Fixtures, And Conformance Skeleton

**Purpose:** Create the language-neutral contract that SwiftPM, .NET, Linux helper, and Flutter must all follow.

**Files:**
- Create: `spec/protocol.md`
- Create: `spec/app-archive.schema.json`
- Create: `spec/release.schema.json`
- Create: `spec/signing.md`
- Create: `spec/selection.md`
- Create: `spec/rollout.md`
- Create: `spec/diagnostics.md`
- Create: `spec/helper-cli.md`
- Create: `spec/security-threat-model.md`
- Create: `fixtures/app-archive/valid.schema-v3.json`
- Create: `fixtures/app-archive/invalid.missing-release.json`
- Create: `fixtures/release/valid.schema-v3.json`
- Create: `fixtures/release/invalid.missing-artifact.json`
- Create: `fixtures/versions/ordering.json`
- Create: `fixtures/rollout/buckets.json`
- Create: `fixtures/signing/ed25519-valid.json`
- Create: `fixtures/signing/ed25519-invalid-signature.json`
- Create: `fixtures/artifacts/README.md`
- Create: `fixtures/zip-safety/README.md`
- Create: `conformance/README.md`
- Create: `conformance/fixtures.md`
- Create: `test/spec/protocol_specs_test.dart`
- Create: `test/spec/protocol_fixtures_test.dart`

- [ ] **Step 1.1: Write failing spec existence test**

Create `test/spec/protocol_specs_test.dart`:

```dart
import "dart:io";

import "package:flutter_test/flutter_test.dart";

void main() {
  test("all staged protocol specs exist and preserve current contract wording", () {
    for (final path in [
      "spec/protocol.md",
      "spec/app-archive.schema.json",
      "spec/release.schema.json",
      "spec/signing.md",
      "spec/selection.md",
      "spec/rollout.md",
      "spec/diagnostics.md",
      "spec/helper-cli.md",
      "spec/security-threat-model.md",
    ]) {
      expect(File(path).existsSync(), isTrue, reason: path);
    }

    expect(File("spec/protocol.md").readAsStringSync(), contains("schemaVersion 3"));
    expect(File("spec/protocol.md").readAsStringSync(), contains("app-archive.json -> release.json -> app.zip"));
    expect(File("spec/signing.md").readAsStringSync(), contains("Ed25519"));
    expect(File("spec/diagnostics.md").readAsStringSync(), contains("app-owned"));
    expect(File("spec/helper-cli.md").readAsStringSync(), contains("machine-facing"));
  });
}
```

- [ ] **Step 1.2: Run and verify RED**

Run:

```sh
flutter test --no-pub test/spec/protocol_specs_test.dart
```

Expected: FAIL because `spec/` files do not exist.

- [ ] **Step 1.3: Add draft spec files**

Document only current behavior. The JSON schemas should describe schema version `3` and stay compatible with current parser permissiveness for optional fields.

- [ ] **Step 1.4: Add fixture contract test**

Create `test/spec/protocol_fixtures_test.dart` that parses the fixture JSON through current package code:

```dart
import "dart:convert";
import "dart:io";

import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:desktop_updater/src/core/release_index.dart";
import "package:desktop_updater/src/version_info.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  test("fixtures parse through the current 2.2.0 implementation", () {
    final index = ReleaseIndex.fromJson(
      jsonDecode(File("fixtures/app-archive/valid.schema-v3.json").readAsStringSync()) as Map<String, dynamic>,
    );
    final descriptor = ReleaseDescriptor.fromJson(
      jsonDecode(File("fixtures/release/valid.schema-v3.json").readAsStringSync()) as Map<String, dynamic>,
    );

    expect(index.schemaVersion, 3);
    expect(descriptor.schemaVersion, 3);
  });

  test("version ordering fixtures match current compareDesktopVersions", () {
    final cases = jsonDecode(File("fixtures/versions/ordering.json").readAsStringSync()) as List<dynamic>;
    for (final entry in cases.cast<Map<String, dynamic>>()) {
      expect(
        compareDesktopVersions(
          DesktopVersionInfo.parse(entry["candidate"] as String),
          DesktopVersionInfo.parse(entry["current"] as String),
        ).sign,
        entry["result"] as int,
      );
    }
  });
}
```

- [ ] **Step 1.5: Run and verify RED, then add fixture files**

Run:

```sh
flutter test --no-pub test/spec/protocol_fixtures_test.dart
```

Expected first run: FAIL because fixtures do not exist. Add fixtures, then rerun until PASS.

- [ ] **Step 1.6: Add conformance skeleton**

`conformance/README.md` must define:

- Dart implementation is the first reference runner.
- SwiftPM and .NET runners are future stages in this plan.
- Kotlin is out of scope.
- Fixtures are the shared behavior contract.
- All runners must report pass/fail without network access.

- [ ] **Step 1.7: Run Stage 1 gate**

Run:

```sh
flutter test --no-pub test/spec
```

Expected: PASS.

## Stage 2: Internal Dart Protocol Boundary And Protocol CLI

**Purpose:** Separate Flutter-independent Dart behavior without publishing a second Dart package yet.

**Files:**
- Create: `lib/src/protocol/protocol.dart`
- Create: `lib/src/protocol/release_descriptor.dart`
- Create: `lib/src/protocol/release_index.dart`
- Create: `lib/src/protocol/release_signature_verifier.dart`
- Create: `lib/src/protocol/artifact_verifier.dart`
- Create: `lib/src/protocol/safe_zip_extractor.dart`
- Create: `lib/src/protocol/version_info.dart`
- Create: `lib/src/protocol/diagnostics.dart`
- Create: `lib/src/protocol/recovery.dart`
- Keep shims under: `lib/src/core/`
- Keep shim: `lib/src/version_info.dart`
- Create: `bin/protocol.dart`
- Create: `lib/src/protocol_cli/protocol_command.dart`
- Create: `test/protocol/protocol_namespace_test.dart`
- Create: `test/protocol/protocol_import_boundary_test.dart`
- Create: `test/protocol_cli/protocol_command_test.dart`
- Modify: `pubspec.yaml`

- [ ] **Step 2.1: Write failing namespace test**

Create `test/protocol/protocol_namespace_test.dart`:

```dart
import "package:desktop_updater/src/protocol/protocol.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  test("protocol namespace exposes Flutter-independent contract types", () {
    expect(ReleaseDescriptor, isNotNull);
    expect(ReleaseIndex, isNotNull);
    expect(ArtifactVerifier, isNotNull);
    expect(SafeZipExtractor, isNotNull);
    expect(UpdateProblemReport, isNotNull);
    expect(UpdateInstallRecoveryMarker, isNotNull);
    expect(DesktopVersionInfo.parse("1.2.3+4").buildNumber, 4);
  });
}
```

Run:

```sh
flutter test --no-pub test/protocol/protocol_namespace_test.dart
```

Expected: FAIL because `lib/src/protocol/protocol.dart` does not exist.

- [ ] **Step 2.2: Add wrapper protocol namespace**

First implementation should only re-export current files. Do not move code yet.

- [ ] **Step 2.3: Add import boundary test**

Create `test/protocol/protocol_import_boundary_test.dart` that asserts no `lib/src/protocol/*.dart` file imports Flutter packages or the MethodChannel implementation.

- [ ] **Step 2.4: Move implementation files one at a time**

Move in this order, leaving one-line export shims at the old paths:

1. `release_descriptor`
2. `release_index`
3. `version_info`
4. `release_signature_verifier`
5. `artifact_verifier`
6. `safe_zip_extractor`
7. `diagnostics`
8. `recovery`

After each move, run the focused test for that area plus:

```sh
flutter test --no-pub test/protocol/protocol_namespace_test.dart test/protocol/protocol_import_boundary_test.dart
```

- [ ] **Step 2.5: Add failing protocol CLI help test**

Create `test/protocol_cli/protocol_command_test.dart`:

```dart
import "package:desktop_updater/src/protocol_cli/protocol_command.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  test("protocol CLI help exposes validate select and verify", () async {
    final output = StringBuffer();
    final exitCode = await runProtocolCommand(["--help"], output: output);

    expect(exitCode, 0);
    expect(output.toString(), contains("validate"));
    expect(output.toString(), contains("select"));
    expect(output.toString(), contains("verify"));
  });
}
```

Run:

```sh
flutter test --no-pub test/protocol_cli/protocol_command_test.dart
```

Expected: FAIL because protocol CLI code does not exist.

- [ ] **Step 2.6: Implement protocol CLI**

Add local-file commands:

```sh
dart run desktop_updater:protocol validate --app-archive fixtures/app-archive/valid.schema-v3.json
dart run desktop_updater:protocol validate --release fixtures/release/valid.schema-v3.json
dart run desktop_updater:protocol select --app-archive fixtures/app-archive/valid.schema-v3.json --platform macos --current-version 1.0.0+100 --channel stable --identity pilot-a
dart run desktop_updater:protocol verify --release fixtures/release/valid.schema-v3.json --artifact fixtures/artifacts/valid.zip
```

Return code contract:

- `0`: valid input
- `64`: usage or semantic validation error
- `1`: unexpected runtime failure

- [ ] **Step 2.7: Run Stage 2 gate**

Run:

```sh
flutter test --no-pub test/protocol test/protocol_cli test/release_index_test.dart test/release_descriptor_test.dart test/version_info_test.dart test/artifact_verifier_test.dart test/release_signature_verifier_test.dart test/safe_zip_extractor_test.dart test/update_diagnostics_test.dart test/update_recovery_test.dart
```

Expected: PASS.

## Stage 3: CLI Control Plane Design And Compatibility

**Purpose:** Keep CLI as the primary release/publishing surface while adding protocol and helper CLI contracts.

**Files:**
- Modify: `spec/helper-cli.md`
- Modify: `docs/publishing.md`
- Modify: `README.md`
- Create: `test/cli/cli_control_plane_docs_test.dart`
- Extend: `test/compat/release_cli_compatibility_test.dart`

- [ ] **Step 3.1: Write failing CLI docs test**

Create `test/cli/cli_control_plane_docs_test.dart`:

```dart
import "dart:io";

import "package:flutter_test/flutter_test.dart";

void main() {
  test("docs keep release CLI primary and helper CLI machine-facing", () {
    final publishing = File("docs/publishing.md").readAsStringSync();
    final helperSpec = File("spec/helper-cli.md").readAsStringSync();

    expect(publishing, contains("dart run desktop_updater:release publish"));
    expect(publishing, contains("CLI-first"));
    expect(helperSpec, contains("machine-facing"));
    expect(helperSpec, contains("request.json"));
    expect(helperSpec, contains("diagnosticsLogPath"));
  });
}
```

Run:

```sh
flutter test --no-pub test/cli/cli_control_plane_docs_test.dart
```

Expected: FAIL until docs are updated.

- [ ] **Step 3.2: Document CLI layers**

Document the three CLI layers:

- user-facing release CLI
- protocol/conformance CLI
- machine-facing native helper CLI

State that helper CLI request payloads are JSON files, not a growing set of ad hoc flags.

- [ ] **Step 3.3: Run Stage 3 gate**

Run:

```sh
flutter test --no-pub test/cli test/compat/release_cli_compatibility_test.dart test/release_cli
```

Expected: PASS.

## Stage 4: macOS SwiftPM Extraction

**Purpose:** Make `desktop_updater_macos` the shared macOS native package used by native macOS apps and the Flutter macOS plugin.

**Files:**
- Create: `packages/desktop_updater_macos/Package.swift`
- Create: `packages/desktop_updater_macos/Sources/DesktopUpdaterMacOS/DesktopUpdaterMacOS.swift`
- Create: `packages/desktop_updater_macos/Sources/DesktopUpdaterMacOS/MacOSUpdateRequest.swift`
- Create: `packages/desktop_updater_macos/Sources/DesktopUpdaterMacOS/MacOSInstallScheduler.swift`
- Create: `packages/desktop_updater_macos/Sources/DesktopUpdaterMacOS/MacOSHelperScriptWriter.swift`
- Create: `packages/desktop_updater_macos/Sources/DesktopUpdaterMacOS/MacOSDiagnostics.swift`
- Create: `packages/desktop_updater_macos/Tests/DesktopUpdaterMacOSTests/DesktopUpdaterMacOSTests.swift`
- Modify later: `macos/desktop_updater/Sources/desktop_updater/DesktopUpdaterPlugin.swift`
- Create: `test/macos_swiftpm_adapter_docs_test.dart`

- [ ] **Step 4.1: Add failing SwiftPM package test**

Create `packages/desktop_updater_macos/Tests/DesktopUpdaterMacOSTests/DesktopUpdaterMacOSTests.swift` with tests for request validation and helper script diagnostics event names. Run:

```sh
swift test --package-path packages/desktop_updater_macos
```

Expected: FAIL because package code does not exist.

- [ ] **Step 4.2: Extract pure Swift request and diagnostics models**

Move no Flutter code yet. Implement `MacOSUpdateRequest`, diagnostics events, and validation for empty staging path, symlink rejection policy, bundle ID expectation, and `allowUnsignedMacOSUpdates`.

- [ ] **Step 4.3: Extract helper script writer from current Flutter Swift plugin**

Move script generation logic into `MacOSHelperScriptWriter` while preserving existing event names and command behavior.

- [ ] **Step 4.4: Update Flutter macOS plugin to call SwiftPM package**

Keep MethodChannel parsing in `DesktopUpdaterPlugin.swift`. The plugin should translate arguments into `MacOSUpdateRequest` and call `MacOSInstallScheduler`.

- [ ] **Step 4.5: Run macOS gates**

Run:

```sh
swift test --package-path packages/desktop_updater_macos
swift test --package-path macos/desktop_updater
flutter test --no-pub test/macos_swift_package_test.dart test/macos_updater_manifest_test.dart test/native_helper_script_test.dart test/compat/native_helper_diagnostics_contract_test.dart
```

Expected: PASS.

## Stage 5: Windows C++ Helper And .NET Wrapper

**Purpose:** Make one C++/Win32 helper the shared Windows install layer for Flutter Windows and .NET apps.

**Files:**
- Create: `packages/desktop_updater_windows/native/`
- Create: `packages/desktop_updater_windows/native/include/desktop_updater_windows.h`
- Create: `packages/desktop_updater_windows/native/src/desktop_updater_windows.cpp`
- Create: `packages/desktop_updater_windows/native/tests/`
- Create: `packages/desktop_updater_windows/dotnet/DesktopUpdater.DotNet.sln`
- Create: `packages/desktop_updater_windows/dotnet/src/DesktopUpdater.DotNet/DesktopUpdater.DotNet.csproj`
- Create: `packages/desktop_updater_windows/dotnet/src/DesktopUpdater.DotNet/WindowsUpdateRequest.cs`
- Create: `packages/desktop_updater_windows/dotnet/src/DesktopUpdater.DotNet/DesktopUpdaterWindows.cs`
- Create: `packages/desktop_updater_windows/dotnet/test/DesktopUpdater.DotNet.Tests/DesktopUpdater.DotNet.Tests.csproj`
- Modify later: `windows/desktop_updater_plugin.cpp`
- Create: `test/windows_shared_helper_docs_test.dart`

- [ ] **Step 5.1: Add failing C++ helper characterization tests**

Add tests that protect:

- process wait script/request shape
- backup event names
- move event names
- rollback event names
- locked-file retry policy
- diagnostics JSONL event names

Run the repository's Windows-native test command on Windows CI or a Windows host. If running locally on macOS, compile-free source tests may be used first, but do not claim native Windows parity from macOS-only evidence.

- [ ] **Step 5.2: Extract C++ helper from Flutter plugin**

Move reusable Win32 logic into `packages/desktop_updater_windows/native`. Keep Flutter MethodChannel argument parsing in `windows/desktop_updater_plugin.cpp`.

- [ ] **Step 5.3: Add .NET wrapper tests first**

Create `.NET` tests for:

- request serialization
- diagnostics path forwarding
- helper invocation command
- failure exit code mapping

Run:

```sh
dotnet test packages/desktop_updater_windows/dotnet/DesktopUpdater.DotNet.sln
```

Expected first run: FAIL until wrapper code exists.

- [ ] **Step 5.4: Implement minimal .NET wrapper**

Expose a C# API over the C++ helper. Do not duplicate Win32 install logic in C#.

- [ ] **Step 5.5: Update Flutter Windows plugin to call shared helper**

Keep C++ MethodChannel adapter thin. Ensure `diagnosticsLogPath`, `removedFiles`, install, restart, rollback, registry version update, and relaunch behavior are still covered.

- [ ] **Step 5.6: Run Windows gates**

Run on Windows:

```sh
flutter test --no-pub test/windows_release_smoke_config_test.dart test/desktop_updater_method_channel_test.dart test/compat/native_helper_diagnostics_contract_test.dart
dotnet test packages/desktop_updater_windows/dotnet/DesktopUpdater.DotNet.sln
```

Expected: PASS. If the current machine is not Windows, record Windows gates as skipped and require GitHub Actions Windows evidence before completion.

## Stage 6: Linux Helper And CLI Extraction

**Purpose:** Make Linux install/relaunch behavior a reusable helper/CLI instead of logic embedded only in the Flutter Linux plugin.

**Files:**
- Create: `packages/desktop_updater_linux/native/`
- Create: `packages/desktop_updater_linux/cli/`
- Create: `packages/desktop_updater_linux/README.md`
- Modify later: `linux/desktop_updater_plugin.cc`
- Create: `test/linux_helper_contract_test.dart`

- [ ] **Step 6.1: Add failing Linux helper contract tests**

Create source-level tests that assert:

- request JSON includes staging path, target path, diagnostics path, and relaunch mode
- helper events include existing JSONL event names
- path checks reject traversal
- backup, move, rollback, cleanup, and relaunch events are preserved

Run:

```sh
flutter test --no-pub test/linux_helper_contract_test.dart test/linux_release_smoke_config_test.dart
```

Expected first run: FAIL until helper docs/source structure exists.

- [ ] **Step 6.2: Extract Linux helper**

Move reusable Linux helper behavior under `packages/desktop_updater_linux/native` or `packages/desktop_updater_linux/cli` while keeping Flutter plugin method parsing in `linux/desktop_updater_plugin.cc`.

- [ ] **Step 6.3: Update Flutter Linux plugin adapter**

Flutter Linux plugin should call the shared helper/CLI with a request file or stable argument contract.

- [ ] **Step 6.4: Run Linux gates**

Run on Linux CI:

```sh
flutter test --no-pub test/linux_release_smoke_config_test.dart test/compat/native_helper_diagnostics_contract_test.dart
```

Expected: PASS. If current machine is not Linux, record Linux native gates as skipped and require CI evidence before completion.

## Stage 7: Flutter Adapter Cleanup

**Purpose:** Keep Flutter package as the user-facing Flutter surface while platform-specific native logic lives in shared platform packages/helpers.

**Files:**
- Modify: `macos/desktop_updater/Sources/desktop_updater/DesktopUpdaterPlugin.swift`
- Modify: `windows/desktop_updater_plugin.cpp`
- Modify: `linux/desktop_updater_plugin.cc`
- Modify only as needed: `lib/desktop_updater_method_channel.dart`
- Modify only as needed: `lib/desktop_updater_platform_interface.dart`
- Modify only as needed: `lib/desktop_updater.dart`
- Modify only as needed: `lib/updater_controller.dart`
- Extend: `test/compat/flutter_220_public_api_test.dart`
- Extend: `test/desktop_updater_method_channel_test.dart`
- Extend: `test/updater_controller_test.dart`

- [ ] **Step 7.1: Add adapter thinness tests**

Tests should assert that Flutter MethodChannel argument shapes remain unchanged and that native helper diagnostics paths still forward unchanged.

- [ ] **Step 7.2: Remove duplicate native logic only after shared helper tests pass**

Do not remove old native logic until the platform package/helper has passing focused tests and the Flutter adapter tests pass.

- [ ] **Step 7.3: Run Flutter adapter gates**

Run:

```sh
flutter test --no-pub test/compat test/desktop_updater_test.dart test/desktop_updater_method_channel_test.dart test/updater_controller_test.dart test/update_ready_ui_test.dart test/update_dialog_listener_test.dart test/update_problem_report_dialog_test.dart
```

Expected: PASS.

## Stage 8: CI, Docs, Migration, And Release Readiness

**Purpose:** Make the new multi-package repo understandable, testable, and releasable without breaking existing users.

**Files:**
- Modify: `README.md`
- Modify: `docs/publishing.md`
- Modify: `docs/diagnostics-and-recovery.md`
- Modify: `docs/github-actions-ci-cd.md`
- Modify: `docs/2.0-roadmap.md`
- Modify: `docs/plans/index.md`
- Create: `docs/migration/native-sdk-roadmap.md`
- Create: `test/docs/multi_stage_extraction_docs_test.dart`

- [ ] **Step 8.1: Add failing docs test**

Create a docs test that requires:

- README still starts with Flutter quick start.
- README links to protocol/spec docs.
- publishing docs remain CLI-first.
- diagnostics docs still state no package-owned log files by default.
- native SDK roadmap states SwiftPM and .NET are staged packages.
- Kotlin is explicitly out of scope.

- [ ] **Step 8.2: Update docs minimally**

Keep Flutter users oriented first. Add protocol/native SDK sections as roadmap and architecture, not as a replacement for current quick start.

- [ ] **Step 8.3: Add CI plan**

Document gates:

- Dart/Flutter unit and widget tests
- Dart pub dry run
- SwiftPM package tests
- Windows native helper tests
- .NET tests
- Linux helper tests
- provider E2Es behind `DESKTOP_UPDATER_RUN_RELEASE_PUBLISH_E2E=1`

- [ ] **Step 8.4: Run docs gate**

Run:

```sh
flutter test --no-pub test/docs test/native_helper_diagnostics_docs_test.dart
```

Expected: PASS.

## Stage 9: Final Verification And PR Summary

**Purpose:** Prove the Flutter package still behaves like 2.2.0 while the new staged architecture is in place.

- [ ] **Step 9.1: Run full Flutter gate**

Run:

```sh
flutter test --no-pub
```

Expected: PASS with provider E2Es skipped unless `DESKTOP_UPDATER_RUN_RELEASE_PUBLISH_E2E=1` is set.

- [ ] **Step 9.1a: Run or classify provider E2E gate**

If release-publish provider behavior, hosted metadata layout, descriptor signing, artifact paths, or release-publish orchestration changed in this branch, run:

```sh
DESKTOP_UPDATER_RUN_RELEASE_PUBLISH_E2E=1 flutter test --no-pub test/e2e
```

Expected: PASS in a credentialed/provider-ready environment. If the branch did not touch those release-sensitive surfaces, record the provider E2Es as skipped. If the branch did touch those surfaces but the credentialed environment is unavailable, record the provider E2Es as blocked and require CI or credentialed local evidence before declaring the stage complete.

- [ ] **Step 9.2: Run publish dry run**

Run:

```sh
dart pub publish --dry-run
```

Expected: PASS. Separate analyzer/pub warnings from hard failures.

- [ ] **Step 9.3: Run macOS Swift gates**

Run:

```sh
swift test --package-path macos/desktop_updater
swift test --package-path packages/desktop_updater_macos
```

Expected: PASS on macOS.

- [ ] **Step 9.4: Run Windows gates**

Run on Windows:

```sh
dotnet test packages/desktop_updater_windows/dotnet/DesktopUpdater.DotNet.sln
```

Expected: PASS. Record if skipped locally and require CI evidence.

- [ ] **Step 9.5: Run Linux gates**

Run on Linux:

```sh
flutter test --no-pub test/linux_release_smoke_config_test.dart test/linux_helper_contract_test.dart
```

Expected: PASS. Record if skipped locally and require CI evidence.

- [ ] **Step 9.6: Prepare PR-style summary**

Include:

- changes made
- files added/modified
- tests run
- passed checks
- skipped checks
- blocked checks
- provider E2E classification
- compatibility notes
- migration notes
- open questions
- next milestone recommendation

## Stage Boundaries

These stages can be separate commits or separate PRs. Do not start a later native extraction stage until the earlier stage has its focused gate passing:

1. Stage 0 compatibility tests
2. Stage 1 spec/fixtures/conformance
3. Stage 2 internal Dart protocol boundary and protocol CLI
4. Stage 3 CLI control-plane docs
5. Stage 4 macOS SwiftPM extraction
6. Stage 5 Windows C++ helper and .NET wrapper
7. Stage 6 Linux helper and CLI extraction
8. Stage 7 Flutter adapter cleanup
9. Stage 8 docs/CI/migration
10. Stage 9 final verification

## Open Questions

- Should this branch implement only Stages 0-3 and leave native extraction to follow-up branches, or should it carry the first macOS extraction too?
- Should `desktop_updater_macos` be published from this monorepo directly as SwiftPM, or mirrored later to a Swift-focused repo after API stabilization?
- Should Windows `.NET` ship the C++ helper as an embedded executable, a DLL, or both?
- Should Linux helper be a standalone executable only, or also expose a small C ABI for non-CLI integrations?
- Should the protocol CLI live only at `dart run desktop_updater:protocol`, or should `dart run desktop_updater:release protocol ...` also exist for discoverability?

## Recommended Execution Order

For this branch, execute Stages 0-3 first and stop for review. Those stages establish the compatibility harness, shared contract, internal Dart boundary, and CLI design without touching platform native helpers. After review, continue with Stage 4 macOS SwiftPM extraction because it is the highest-value native package for immediate reuse and the lowest-risk extraction from the current Swift plugin code.
