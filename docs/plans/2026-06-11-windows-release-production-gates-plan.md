# Windows Release Production Gates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move Windows from debug update confidence to release production confidence by adding Release CI smoke coverage and an Authenticode-based production signing gate.

**Architecture:** First make the current Windows update smoke work against Flutter Release output. Then add a production gate that verifies staged `.exe` and `.dll` Authenticode signatures before replacement, with an optional pinned publisher thumbprint. CI should always run unsigned Release smoke, and run signing verification only when signing secrets or a pre-signed artifact are provided.

**Tech Stack:** Flutter Windows, CMake, PowerShell, Windows Authenticode, `signtool.exe`, optional Azure Artifact Signing or OV/EV code signing certificate, GitHub Actions.

---

## File Structure

- Modify: `.github/workflows/desktop-updater-ci.yml`
  - Add Windows Release build, Release native tests, Release integration tests, and Release update smoke.
  - Add optional signed Release gate guarded by secrets.
- Modify: `example/tool/updater_smoke.dart`
  - Add `--config Debug|Release` so Windows/Linux smoke can target Release output.
- Modify: `windows/desktop_updater_plugin.cpp`
  - Add optional production Authenticode checks before staged files are copied.
  - Read `DESKTOP_UPDATER_REQUIRED_WINDOWS_PUBLISHER_SHA256` or `DESKTOP_UPDATER_REQUIRE_SIGNED_WINDOWS=1`.
- Modify or create: `windows/desktop_updater_test.cpp`
  - Add script generation tests for signature checks and rollback behavior.
- Create: `test/windows_release_smoke_config_test.dart`
  - Lock CI and smoke tool Release behavior.
- No branch operation is allowed. Commit only after explicit user approval.

---

### Task 1: Add Release-Aware Smoke Tool Paths

**Files:**
- Modify: `example/tool/updater_smoke.dart`
- Test: `test/windows_release_smoke_config_test.dart`

- [ ] **Step 1: Add the failing test**

Create `test/windows_release_smoke_config_test.dart`:

```dart
import "dart:io";

import "package:test/test.dart";

void main() {
  test("updater smoke supports Windows Release output", () {
    final source = File("example/tool/updater_smoke.dart").readAsStringSync();

    expect(source, contains("--config"));
    expect(source, contains("Release"));
    expect(
      source,
      contains(
        '"build", "windows", "x64", "runner", config, "desktop_updater_example.exe"',
      ),
    );
  });
}
```

- [ ] **Step 2: Run the failing test**

Run:

```bash
flutter test --no-pub test/windows_release_smoke_config_test.dart
```

Expected: fail because `--config` is not supported.

- [ ] **Step 3: Add config parsing**

In `example/tool/updater_smoke.dart`, add:

```dart
  final config = _argValue(args, "--config") ?? "Debug";
```

Pass it into `_defaultAppPath(config)`, then change the function signature and Windows/Linux defaults:

```dart
String? _defaultAppPath(String config) {
  if (Platform.isMacOS) {
    return _joinAll([
      "build",
      "macos",
      "Build",
      "Products",
      config,
      "desktop_updater_example.app",
    ]);
  }

  if (Platform.isWindows) {
    return _joinAll([
      "build",
      "windows",
      "x64",
      "runner",
      config,
      "desktop_updater_example.exe",
    ]);
  }

  if (Platform.isLinux) {
    return _joinAll([
      "build",
      "linux",
      "x64",
      config.toLowerCase(),
      "bundle",
      "desktop_updater_example",
    ]);
  }

  return null;
}
```

Update usage text:

```dart
"Usage: dart run tool/updater_smoke.dart [--app <path>] [--config Debug|Release] [--relaunch]\n"
```

- [ ] **Step 4: Verify the test passes**

Run:

```bash
flutter test --no-pub test/windows_release_smoke_config_test.dart
```

Expected: pass.

---

### Task 2: Add Windows Release CI Gates

**Files:**
- Modify: `.github/workflows/desktop-updater-ci.yml`
- Test: `test/windows_release_smoke_config_test.dart`

- [ ] **Step 1: Extend the failing test for CI Release steps**

Add to `test/windows_release_smoke_config_test.dart`:

```dart
  test("Windows CI runs Release build, native tests, integration, and smoke", () {
    final workflow =
        File(".github/workflows/desktop-updater-ci.yml").readAsStringSync();

    expect(workflow, contains("Build example release"));
    expect(workflow, contains("flutter build windows --release"));
    expect(workflow, contains("cmake --build build/windows/x64 --config Release"));
    expect(workflow, contains("ctest --test-dir build/windows/x64 -C Release"));
    expect(workflow, contains("dart run tool/updater_smoke.dart --config Release"));
  });
```

- [ ] **Step 2: Run the failing test**

Run:

```bash
flutter test --no-pub test/windows_release_smoke_config_test.dart
```

Expected: fail because the workflow only runs Debug.

- [ ] **Step 3: Add Release steps to the Windows job**

In `.github/workflows/desktop-updater-ci.yml`, after the existing Windows debug smoke, add:

```yaml
      - name: Build example release
        working-directory: example
        run: flutter build windows --release
      - name: Build native tests release
        working-directory: example
        run: cmake --build build/windows/x64 --config Release --target desktop_updater_test
      - name: Run native tests release
        working-directory: example
        run: ctest --test-dir build/windows/x64 -C Release --output-on-failure
      - name: Run integration tests release
        working-directory: example
        run: flutter test integration_test -d windows
      - name: Rebuild example release for smoke
        working-directory: example
        run: flutter build windows --release
      - name: Run update smoke release
        working-directory: example
        run: dart run tool/updater_smoke.dart --config Release
```

- [ ] **Step 4: Verify the test passes**

Run:

```bash
flutter test --no-pub test/windows_release_smoke_config_test.dart
```

Expected: pass.

---

### Task 3: Add Optional Windows Authenticode Production Gate

**Files:**
- Modify: `windows/desktop_updater_plugin.cpp`
- Modify or create: `windows/desktop_updater_test.cpp`

- [ ] **Step 1: Add native test coverage**

Add tests that assert the generated PowerShell helper contains these behaviors:

```text
$requireSigned = $env:DESKTOP_UPDATER_REQUIRE_SIGNED_WINDOWS
$requiredPublisherSha256 = $env:DESKTOP_UPDATER_REQUIRED_WINDOWS_PUBLISHER_SHA256
Get-AuthenticodeSignature
if ($signature.Status -ne 'Valid') { throw
if ($requiredPublisherSha256
```

Expected native test command:

```bash
cmake --build build/windows/x64 --config Debug --target desktop_updater_test
ctest --test-dir build/windows/x64 -C Debug --output-on-failure
```

- [ ] **Step 2: Implement PowerShell signature checks**

In `windows/desktop_updater_plugin.cpp`, inject this script before copying staged files:

```powershell
$requireSigned = $env:DESKTOP_UPDATER_REQUIRE_SIGNED_WINDOWS
$requiredPublisherSha256 = $env:DESKTOP_UPDATER_REQUIRED_WINDOWS_PUBLISHER_SHA256
if ($requireSigned -eq '1' -or -not [string]::IsNullOrWhiteSpace($requiredPublisherSha256)) {
  Get-ChildItem -LiteralPath $staging -Recurse -File -Include *.exe,*.dll | ForEach-Object {
    $signature = Get-AuthenticodeSignature -LiteralPath $_.FullName
    if ($signature.Status -ne 'Valid') {
      throw "Staged file is not Authenticode valid: $($_.FullName) status=$($signature.Status)"
    }
    if (-not [string]::IsNullOrWhiteSpace($requiredPublisherSha256)) {
      $certHash = $signature.SignerCertificate.GetCertHashString('SHA256')
      if ($certHash -ne $requiredPublisherSha256) {
        throw "Publisher certificate mismatch for $($_.FullName): expected $requiredPublisherSha256 got $certHash"
      }
    }
  }
}
```

Keep this gate opt-in so unsigned Release smoke remains possible.

- [ ] **Step 3: Verify native tests**

Run on Windows:

```powershell
cd example
flutter build windows --debug
cmake --build build/windows/x64 --config Debug --target desktop_updater_test
ctest --test-dir build/windows/x64 -C Debug --output-on-failure
```

Expected: native tests pass.

---

### Task 4: Add Signed Windows Release Workflow Path

**Files:**
- Modify: `.github/workflows/desktop-updater-ci.yml`
- Test: `test/windows_release_smoke_config_test.dart`

- [ ] **Step 1: Add workflow test for optional signed gate**

Add to `test/windows_release_smoke_config_test.dart`:

```dart
  test("Windows CI documents optional signed production gate", () {
    final workflow =
        File(".github/workflows/desktop-updater-ci.yml").readAsStringSync();

    expect(workflow, contains("WINDOWS_SIGNING_ENABLED"));
    expect(workflow, contains("DESKTOP_UPDATER_REQUIRE_SIGNED_WINDOWS"));
    expect(workflow, contains("DESKTOP_UPDATER_REQUIRED_WINDOWS_PUBLISHER_SHA256"));
    expect(workflow, contains("signtool verify"));
  });
```

- [ ] **Step 2: Add optional CI steps**

Add this after Release build and before signed smoke:

```yaml
      - name: Verify signed release artifacts
        if: ${{ env.WINDOWS_SIGNING_ENABLED == 'true' }}
        working-directory: example
        shell: pwsh
        env:
          WINDOWS_SIGNING_ENABLED: ${{ secrets.WINDOWS_SIGNING_ENABLED }}
        run: |
          $ErrorActionPreference = 'Stop'
          Get-ChildItem build/windows/x64/runner/Release -Recurse -File -Include *.exe,*.dll | ForEach-Object {
            signtool verify /pa /v $_.FullName
          }
      - name: Run signed update smoke release
        if: ${{ env.WINDOWS_SIGNING_ENABLED == 'true' }}
        working-directory: example
        shell: pwsh
        env:
          WINDOWS_SIGNING_ENABLED: ${{ secrets.WINDOWS_SIGNING_ENABLED }}
          DESKTOP_UPDATER_REQUIRE_SIGNED_WINDOWS: "1"
          DESKTOP_UPDATER_REQUIRED_WINDOWS_PUBLISHER_SHA256: ${{ secrets.WINDOWS_PUBLISHER_SHA256 }}
        run: dart run tool/updater_smoke.dart --config Release
```

If Azure Artifact Signing is chosen, insert the official signing action before `Verify signed release artifacts`. If PFX signing is chosen, import the certificate into the runner certificate store and sign with `signtool sign /fd SHA256 /td SHA256 /tr <timestamp-url>`.

- [ ] **Step 3: Verify workflow syntax locally where possible**

Run:

```bash
flutter test --no-pub test/windows_release_smoke_config_test.dart
```

Expected: pass.

---

### Task 5: Production Acceptance

- [ ] **Step 1: Run local Dart verification**

Run:

```bash
dart format --set-exit-if-changed .
flutter test --no-pub
flutter analyze --no-fatal-infos
dart pub publish --dry-run
```

Expected: format clean, tests pass, analyzer exits 0, dry-run exits 0.

- [ ] **Step 2: Push only after approval and wait for CI**

After explicit user approval:

```bash
git add .github/workflows/desktop-updater-ci.yml example/tool/updater_smoke.dart windows/desktop_updater_plugin.cpp windows/desktop_updater_test.cpp test/windows_release_smoke_config_test.dart
git commit -m "ci: add windows release update gates"
git push origin main
gh run watch --exit-status
```

Expected: Windows Debug and Release jobs pass. Signed gate is skipped until signing secrets are configured.

- [ ] **Step 3: Mark production readiness**

Windows can be marked:

```text
Windows release mechanics: ready after unsigned Release smoke passes.
Windows production signed update: ready only after Authenticode signing, signtool verify, and signed update smoke pass.
```

Do not call Windows production signed update ready while the signed gate is skipped.
