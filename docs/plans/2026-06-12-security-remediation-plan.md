# Security Remediation And Follow-Up Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the confirmed `FDU-RTSEL-001` update-selection risk and turn the scan's review-only findings into targeted hardening or evidence tasks.

**Architecture:** First bind selected `app-archive.json` metadata to the verified `release.json` descriptor before any controller state or staging path can be produced. Then add release-validation defense-in-depth so publish CI catches the same identity mismatch. Finally investigate the platform-specific "Needs follow-up" rows with small native/file-system tests before changing install semantics.

**Tech Stack:** Dart 3.6+, Flutter tests via `flutter test --no-pub`, existing `UpdateClient`, `ReleaseIndex`, `ReleaseDescriptor`, `ReleaseValidator`, macOS `ditto`, Swift native plugin code, Windows PowerShell helper generation, Linux bash helper generation.

---

## Security Scan Inputs

- Primary report: `/tmp/codex-security-scans/flutter_desktop_updater/09305b61_20260612T101828Z/report.md`
- HTML report: `/tmp/codex-security-scans/flutter_desktop_updater/09305b61_20260612T101828Z/report.html`
- Confirmed finding: `FDU-RTSEL-001`, medium, high confidence.
- Follow-up rows: `FDU-MAC-001`, `FDU-WIN-001`, `FDU-LIN-001`.
- Rejected but easy hardening: `FDU-PUB-001` release validation descriptor identity comparison.

## Non-Negotiable Constraints

- Do not create, switch, rename, delete, or otherwise operate on branches unless the user explicitly asks for that branch action in the same execution turn.
- Do not post GitHub comments or review feedback through any Codex/GitHub connector identity.
- Do not commit, push, publish to pub.dev, or run real remote uploads unless the user explicitly asks in the execution turn.
- Keep canonical docs, source comments, test names, public API names, and JSON fields in English.
- Use `flutter test --no-pub` for targeted verification to avoid lockfile churn.
- Treat the scan artifacts under `/tmp/codex-security-scans/...` as evidence inputs, not as files to ship in the package.

## File Structure

- Modify: `lib/src/core/update_client.dart`
  - Add a descriptor/index binding check inside `checkForUpdate`.
  - Keep `UpdateCheckResult` unchanged unless tests prove a typed validation helper is clearer.
- Create: `test/update_client_security_test.dart`
  - Lock the regression where a high-version index item points to an older descriptor.
  - Lock the matching descriptor path to prevent over-rejection.
- Modify: `lib/src/release_cli/validate_command.dart`
  - Extend `_verifyDescriptorMatchesManifest` to compare descriptor identity fields against `PublishManifestRelease`.
- Modify: `test/release_cli/release_validate_test.dart`
  - Add a negative hosted validation fixture for descriptor version/platform/channel/build mismatch.
- Create: `lib/src/core/macos_staged_app_validator.dart`
  - Add a top-level macOS staged app symlink rejection helper before native install handoff.
- Modify: `lib/src/core/update_client.dart`
  - Call the macOS staged app validator after computing `stagedPath`.
- Modify: `macos/desktop_updater/Sources/desktop_updater/DesktopUpdaterPlugin.swift`
  - Add native-side symlink rejection as defense-in-depth if Dart-side rejection is added.
- Modify: `test/macos_updater_manifest_test.dart` or create `test/macos_staged_app_symlink_test.dart`
  - Prove top-level `.app` symlink rejection without breaking legitimate framework symlinks inside `.app`.
- Modify: `windows/desktop_updater_plugin.cpp`
  - After Windows evidence, change `wholeDirectoryReplace` semantics so stale target files cannot survive the default zip-first path.
- Modify: `linux/desktop_updater_plugin.cc`
  - After Linux evidence, change `wholeDirectoryReplace` semantics so stale target files cannot survive the default zip-first path.
- Modify: `test/native_helper_script_test.dart` or create focused platform tests
  - Lock Windows and Linux generated helper scripts around prune/replace behavior.

---

### Task 1: Bind Selected Index Item To Verified Descriptor

**Files:**
- Modify: `lib/src/core/update_client.dart`
- Create: `test/update_client_security_test.dart`

- [x] **Step 1: Add the failing rollback regression test**

Create `test/update_client_security_test.dart`:

```dart
import "dart:convert";
import "dart:io";

import "package:desktop_updater/src/core/update_client.dart";
import "package:desktop_updater/src/version_info.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;

import "fixtures/update_server.dart";

void main() {
  test("rejects index item that points to an older descriptor", () async {
    final fixture = await _UpdateFixture.create(
      indexVersion: "99.0.0",
      indexBuildNumber: 9900,
      descriptorVersion: "1.0.0",
      descriptorBuildNumber: 100,
    );
    try {
      final client = UpdateClient(
        appArchiveUrl: fixture.archiveUrl,
        currentVersion: DesktopVersionInfo.fromParts(
          versionName: "2.0.0",
          buildNumber: "200",
        ),
        platform: "macos",
      );

      await expectLater(
        client.checkForUpdate(),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            "message",
            contains("release.json version does not match app-archive.json"),
          ),
        ),
      );
    } finally {
      await fixture.delete();
    }
  });

  test("accepts index item when descriptor identity matches", () async {
    final fixture = await _UpdateFixture.create(
      indexVersion: "2.1.0",
      indexBuildNumber: 210,
      descriptorVersion: "2.1.0",
      descriptorBuildNumber: 210,
    );
    try {
      final client = UpdateClient(
        appArchiveUrl: fixture.archiveUrl,
        currentVersion: DesktopVersionInfo.fromParts(
          versionName: "2.0.0",
          buildNumber: "200",
        ),
        platform: "macos",
      );

      final result = await client.checkForUpdate();

      expect(result, isNotNull);
      expect(result!.item.version, "2.1.0");
      expect(result.descriptor.version, "2.1.0");
      expect(result.descriptor.buildNumber, 210);
    } finally {
      await fixture.delete();
    }
  });
}

class _UpdateFixture {
  const _UpdateFixture({
    required this.root,
    required this.server,
    required this.archiveUrl,
  });

  final Directory root;
  final UpdateServer server;
  final Uri archiveUrl;

  static Future<_UpdateFixture> create({
    required String indexVersion,
    required int indexBuildNumber,
    required String descriptorVersion,
    required int descriptorBuildNumber,
  }) async {
    final root = await Directory.systemTemp.createTemp("update_client_security_");
    final server = await UpdateServer.bind(root);
    final releaseUrl = server.uri.resolve("release.json");
    final artifactUrl = server.uri.resolve("artifact.zip");
    final artifactFile = File(path.join(root.path, "artifact.zip"));
    await artifactFile.writeAsString("artifact bytes");
    final artifactLength = await artifactFile.length();
    const artifactSha256 =
        "7d52c30d0d2362251274e409f06b29005d8d9eea1986cf94d645a4cc1f26921b";

    await File(path.join(root.path, "app-archive.json")).writeAsString(
      "${const JsonEncoder.withIndent("  ").convert({
            "schemaVersion": 3,
            "appName": "Example",
            "items": [
              {
                "version": indexVersion,
                "buildNumber": indexBuildNumber,
                "platform": "macos",
                "channel": "stable",
                "mandatory": true,
                "release": releaseUrl.toString(),
              },
            ],
          })}\n",
    );
    await File(path.join(root.path, "release.json")).writeAsString(
      "${const JsonEncoder.withIndent("  ").convert({
            "schemaVersion": 3,
            "packageId": "com.example.app",
            "appName": "Example",
            "version": descriptorVersion,
            "buildNumber": descriptorBuildNumber,
            "platform": "macos",
            "channel": "stable",
            "artifact": {
              "kind": "zip",
              "url": artifactUrl.toString(),
              "sha256": artifactSha256,
              "length": artifactLength,
            },
            "install": {"strategy": "wholeBundleReplace"},
            "minimumUpdaterVersion": "2.0.0",
            "generatedAt": DateTime.utc(2026, 6, 12).toIso8601String(),
          })}\n",
    );

    return _UpdateFixture(
      root: root,
      server: server,
      archiveUrl: server.uri.resolve("app-archive.json"),
    );
  }

  Future<void> delete() async {
    await server.close();
    await root.delete(recursive: true);
  }
}
```

- [x] **Step 2: Run the failing test**

Run:

```bash
flutter test --no-pub test/update_client_security_test.dart
```

Expected: the first test fails because `checkForUpdate` currently accepts the mismatched descriptor.

- [x] **Step 3: Add the descriptor binding helper**

In `lib/src/core/update_client.dart`, after the platform/channel descriptor check in `checkForUpdate`, call a new helper:

```dart
      if (descriptor.platform != platform || descriptor.channel != channel) {
        return null;
      }
      _verifyDescriptorMatchesIndexItem(item: item, descriptor: descriptor);

      return UpdateCheckResult(
```

Add this helper below `UpdateClient` and before `UpdateCheckResult`:

```dart
void _verifyDescriptorMatchesIndexItem({
  required ReleaseIndexItem item,
  required ReleaseDescriptor descriptor,
}) {
  if (descriptor.version != item.version) {
    throw FormatException(
      "release.json version does not match app-archive.json: "
      "expected ${item.version}, got ${descriptor.version}.",
    );
  }
  if (descriptor.buildNumber != item.buildNumber) {
    throw FormatException(
      "release.json buildNumber does not match app-archive.json: "
      "expected ${item.buildNumber}, got ${descriptor.buildNumber}.",
    );
  }
  if (descriptor.platform != item.platform) {
    throw FormatException(
      "release.json platform does not match app-archive.json: "
      "expected ${item.platform}, got ${descriptor.platform}.",
    );
  }
  if (descriptor.channel != item.channel) {
    throw FormatException(
      "release.json channel does not match app-archive.json: "
      "expected ${item.channel}, got ${descriptor.channel}.",
    );
  }
}
```

Keep `mandatory` on the index for this task because `release.json` does not currently define that field. A later schema change can move mandatory state into signed metadata if the package wants stronger release-intent authentication.

- [x] **Step 4: Verify targeted tests pass**

Run:

```bash
flutter test --no-pub test/update_client_security_test.dart test/release_index_test.dart
```

Expected: all tests pass.

- [x] **Step 5: Run controller smoke tests**

Run:

```bash
flutter test --no-pub test/updater_controller_test.dart test/update_dialog_listener_test.dart test/update_ready_ui_test.dart
```

Expected: all tests pass, proving the existing typed state and mandatory UI paths still compile and behave.

---

### Task 2: Harden `release validate` Descriptor Identity Checks

**Files:**
- Modify: `lib/src/release_cli/validate_command.dart`
- Modify: `test/release_cli/release_validate_test.dart`

- [x] **Step 1: Add the failing hosted validation mismatch test**

Append this test to `test/release_cli/release_validate_test.dart`:

```dart
  test("validate rejects hosted descriptor identity mismatch", () async {
    final fixture = await createHostedPublishFixture(
      targetVersion: "2.0.1",
      targetBuildNumber: 201,
    );
    try {
      final releaseFile = File(
        path.join(
          fixture.projectRoot.path,
          "web",
          "releases",
          "2.0.1",
          "macos",
          "release.json",
        ),
      );
      final json = jsonDecode(await releaseFile.readAsString())
          as Map<String, dynamic>;
      await releaseFile.writeAsString(
        "${const JsonEncoder.withIndent("  ").convert({
              ...json,
              "version": "1.0.0",
              "buildNumber": 100,
            })}\n",
      );

      final output = StringBuffer();
      final exitCode = await runReleaseCommand(
        [
          "validate",
          "--manifest",
          fixture.manifestFile.path,
          "--from-version",
          "2.0.0+200",
        ],
        projectRoot: fixture.projectRoot,
        output: output,
      );

      expect(exitCode, 1);
      expect(
        output.toString(),
        contains("release.json version mismatch"),
      );
    } finally {
      await fixture.delete();
    }
  });
```

Also add `dart:convert` to the imports if it is not already present.

- [x] **Step 2: Run the failing validation test**

Run:

```bash
flutter test --no-pub test/release_cli/release_validate_test.dart
```

Expected: the new mismatch test fails because `_verifyDescriptorMatchesManifest` currently checks only artifact URL, SHA-256, and length.

- [x] **Step 3: Compare descriptor identity fields against the manifest**

In `lib/src/release_cli/validate_command.dart`, extend `_verifyDescriptorMatchesManifest` before artifact checks:

```dart
  if (descriptor.version != manifest.release.version) {
    throw StateError(
      "release.json version mismatch: expected ${manifest.release.version}, got ${descriptor.version}.",
    );
  }
  if (descriptor.buildNumber != manifest.release.buildNumber) {
    throw StateError(
      "release.json buildNumber mismatch: expected ${manifest.release.buildNumber}, got ${descriptor.buildNumber}.",
    );
  }
  if (descriptor.platform != manifest.release.platform) {
    throw StateError(
      "release.json platform mismatch: expected ${manifest.release.platform}, got ${descriptor.platform}.",
    );
  }
  if (descriptor.channel != manifest.release.channel) {
    throw StateError(
      "release.json channel mismatch: expected ${manifest.release.channel}, got ${descriptor.channel}.",
    );
  }
```

Keep the existing artifact URL, SHA-256, and length checks after these identity checks.

- [x] **Step 4: Verify release validation tests pass**

Run:

```bash
flutter test --no-pub test/release_cli/release_validate_test.dart test/release_cli/publish_manifest_test.dart
```

Expected: all tests pass.

---

### Task 3: Review And Close macOS Top-Level `.app` Symlink Follow-Up

**Files:**
- Modify: `lib/src/core/update_client.dart` or `lib/src/macos_update.dart`
- Modify: `macos/desktop_updater/Sources/desktop_updater/DesktopUpdaterPlugin.swift`
- Create: `test/macos_staged_app_symlink_test.dart`
- Keep: `test/macos_updater_manifest_test.dart`

- [x] **Step 1: Add a Dart-side failing symlink rejection test**

Create `test/macos_staged_app_symlink_test.dart`:

```dart
import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;

void main() {
  test("top-level staged macOS app symlink is rejected before install", () async {
    final tempDir = await Directory.systemTemp.createTemp("macos_symlink_");
    try {
      final realApp = Directory(path.join(tempDir.path, "Real.app"));
      await Directory(path.join(realApp.path, "Contents")).create(recursive: true);
      final stagedLink = Link(path.join(tempDir.path, "Staged.app"));
      await stagedLink.create(realApp.path);

      expect(
        FileSystemEntity.typeSync(stagedLink.path, followLinks: false),
        FileSystemEntityType.link,
      );
      await expectLater(
        rejectTopLevelMacOSAppSymlink(stagedLink.path),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            "message",
            contains("Staged macOS app must be a real directory"),
          ),
        ),
      );
    } finally {
      await tempDir.delete(recursive: true);
    }
  }, skip: !Platform.isMacOS);
}
```

Add this import at the top of the test:

```dart
import "package:desktop_updater/src/core/macos_staged_app_validator.dart";
```

- [x] **Step 2: Run the failing macOS test**

Run:

```bash
flutter test --no-pub test/macos_staged_app_symlink_test.dart
```

Expected on macOS: fail until a top-level staged app symlink rejection helper exists. Expected on non-macOS: skipped.

- [x] **Step 3: Add Dart-side rejection before native handoff**

Create `lib/src/core/macos_staged_app_validator.dart`:

```dart
import "dart:io";

Future<void> rejectTopLevelMacOSAppSymlink(String stagedPath) async {
  final type = await FileSystemEntity.type(stagedPath, followLinks: false);
  if (type == FileSystemEntityType.link) {
    throw FormatException(
      "Staged macOS app must be a real directory, not a symlink: $stagedPath",
    );
  }
  if (type != FileSystemEntityType.directory) {
    throw FormatException(
      "Staged macOS app must be a directory: $stagedPath",
    );
  }
}
```

Call it in `UpdateClient.downloadVerifyAndStage` inside the macOS branch after `stagedPath` is computed and before writing the staged release manifest.

- [x] **Step 4: Add native defense-in-depth**

In `macos/desktop_updater/Sources/desktop_updater/DesktopUpdaterPlugin.swift`, add a symlink check before the helper script is written:

```swift
if let stagingPath {
    let values = try URL(fileURLWithPath: stagingPath)
        .resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
    if values.isSymbolicLink == true {
        result(
            FlutterError(
                code: "InstallError",
                message: "Staged macOS update must be a real .app directory, not a symlink.",
                details: stagingPath
            )
        )
        return
    }
    if values.isDirectory != true {
        result(
            FlutterError(
                code: "InstallError",
                message: "Staged macOS update directory does not exist.",
                details: stagingPath
            )
        )
        return
    }
}
```

Keep internal framework symlinks valid; only reject the top-level staged `.app` object.

- [x] **Step 5: Verify macOS tests**

Run:

```bash
flutter test --no-pub test/macos_staged_app_symlink_test.dart test/macos_updater_manifest_test.dart
```

Expected: staged top-level symlink rejection passes, and existing framework symlink preservation tests still pass or remain skipped by their current platform guards.

---

### Task 4: Review Windows/Linux `wholeDirectoryReplace` Stale-File Semantics

**Files:**
- Modify: `windows/desktop_updater_plugin.cpp`
- Modify: `linux/desktop_updater_plugin.cc`
- Modify: `test/native_helper_script_test.dart`

- [x] **Step 1: Add generated-script ordering assertions**

Extend `test/native_helper_script_test.dart`:

```dart
  test("Linux helper prunes target before whole directory overlay", () {
    final source = File("linux/desktop_updater_plugin.cc").readAsStringSync();
    const pruneSnippet =
        r'find \"$target\" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +';
    const copySnippet = r'cp -a \"$staging/.\" \"$target/\"';

    final pruneIndex = source.indexOf(pruneSnippet);
    final copyIndex = source.indexOf(copySnippet);

    expect(pruneIndex, isNonNegative);
    expect(copyIndex, isNonNegative);
    expect(pruneIndex, lessThan(copyIndex));
  });

  test("Windows helper prunes target before whole directory overlay", () {
    final source = File("windows/desktop_updater_plugin.cpp").readAsStringSync();
    const pruneSnippet = r"Get-ChildItem -LiteralPath $target -Force";
    const copySnippet =
        r"Copy-Item -LiteralPath $_.FullName -Destination $target -Recurse -Force";

    final pruneIndex = source.indexOf(pruneSnippet);
    final removeIndex =
        source.indexOf(r"Remove-Item -LiteralPath $_.FullName -Recurse -Force");
    final copyIndex = source.indexOf(copySnippet);

    expect(pruneIndex, isNonNegative);
    expect(removeIndex, isNonNegative);
    expect(copyIndex, isNonNegative);
    expect(pruneIndex, lessThan(copyIndex));
  });
```

These tests intentionally check generated script text because the repository already tests native helper script generation through Dart source assertions. They assert ordering, not just presence.

- [x] **Step 2: Run the helper-script tests**

Run:

```bash
flutter test --no-pub test/native_helper_script_test.dart
```

Expected: pass after Windows and Linux helper scripts explicitly prune target children before copying staged contents.

- [x] **Step 3: Change Linux helper to true directory replacement semantics**

In `linux/desktop_updater_plugin.cc`, after backup succeeds and before `cp -a "$staging/." "$target/"`, add a prune step that deletes only children inside the already-resolved target directory:

```bash
find "$target" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
cp -a "$staging/." "$target/"
```

Keep the existing backup/rollback trap unchanged so any prune/copy failure restores the previous target from backup.

- [x] **Step 4: Change Windows helper to true directory replacement semantics**

In `windows/desktop_updater_plugin.cpp`, after backup succeeds and before staged children are copied, add:

```powershell
Get-ChildItem -LiteralPath $target -Force | ForEach-Object {
  Remove-Item -LiteralPath $_.FullName -Recurse -Force
}
Get-ChildItem -LiteralPath $staging -Force | ForEach-Object {
  Copy-Item -LiteralPath $_.FullName -Destination $target -Recurse -Force
}
```

Keep the current catch block so failure removes the partial target and restores backup.

- [x] **Step 5: Verify helper-script tests**

Run:

```bash
flutter test --no-pub test/native_helper_script_test.dart
```

Expected: all tests pass.

- [x] **Step 6: Platform runtime evidence**

Run the platform-specific native/runtime checks on matching hosts:

```bash
flutter test --no-pub test/native_helper_script_test.dart
```

Expected on all hosts: Dart script-generation checks pass.

On Windows CI or a Windows machine, also run the existing Windows native helper test target documented in `.github/workflows/desktop-updater-ci.yml` and confirm the generated PowerShell rollback path still restores the backup on copy failure.

On Linux CI or a Linux machine, run the existing Linux native helper test target documented in `.github/workflows/desktop-updater-ci.yml` and confirm the generated bash rollback path still restores the backup on prune/copy failure.

Local evidence captured on macOS: Dart script-generation checks passed and both subagent reviews passed. Windows/Linux native CMake/ctest targets were not run locally because this host is macOS; run them on matching CI/hosts before release.

---

### Task 5: Final Verification And Report Closure

**Files:**
- Modify: `docs/publishing.md` only if behavior or guidance changed.
- Do not modify scan artifacts under `/tmp` during product implementation.

- [x] **Step 1: Run targeted security regression gates**

Run:

```bash
flutter test --no-pub \
  test/update_client_security_test.dart \
  test/release_cli/release_validate_test.dart \
  test/native_helper_script_test.dart
```

Expected: all tests pass.

- [x] **Step 2: Run broader package tests around changed surfaces**

Run:

```bash
flutter test --no-pub \
  test/release_index_test.dart \
  test/release_descriptor_test.dart \
  test/safe_zip_extractor_test.dart \
  test/macos_updater_manifest_test.dart \
  test/desktop_updater_method_channel_test.dart \
  test/updater_controller_test.dart
```

Expected: all tests pass or retain their existing platform skips.

Additional local E2E evidence captured after closure:

```bash
flutter test --no-pub test/e2e/zip_first_update_flow_test.dart
```

Result: all 4 zip-first E2E tests passed, covering check, download, verify, stage, macOS sidecar staging, checksum failure, and path traversal rejection.

Additional Docker-backed provider E2E evidence captured:

```bash
DESKTOP_UPDATER_RUN_RELEASE_PUBLISH_E2E=1 \
AWS_ACCESS_KEY_ID=minioadmin \
AWS_SECRET_ACCESS_KEY=minioadmin \
AWS_DEFAULT_REGION=us-east-1 \
DESKTOP_UPDATER_FTP_PASSWORD=desktop-updater-test \
DESKTOP_UPDATER_SFTP_PASSWORD=desktop-updater-test \
flutter test --no-pub --concurrency=1 \
  test/e2e/release_publish_s3_e2e_test.dart \
  test/e2e/release_publish_ftp_e2e_test.dart \
  test/e2e/release_publish_sftp_e2e_test.dart
```

Result: S3/MinIO and SFTP passed in the combined Docker run. FTP upload succeeded but hosted validation hit a static HTTP readiness race (`Connection closed before full header was received`); rerunning the FTP E2E after the static service was ready passed:

```bash
DESKTOP_UPDATER_RUN_RELEASE_PUBLISH_E2E=1 \
DESKTOP_UPDATER_FTP_PASSWORD=desktop-updater-test \
flutter test --no-pub --concurrency=1 \
  test/e2e/release_publish_ftp_e2e_test.dart
```

Additional local macOS release-mechanics evidence captured:

```bash
flutter clean
flutter pub get
flutter build macos --release
dart run tool/updater_smoke.dart --config Release
```

Result: Release build passed and the updater smoke installed the staged `.app` successfully with the explicit unsigned macOS smoke bypass. A small example-app fix was added so direct smoke honors `DESKTOP_UPDATER_SMOKE_ALLOW_UNSIGNED_MACOS` by passing `allowUnsignedMacOSUpdates` into `installUpdate`.

- [x] **Step 3: Check formatting and whitespace**

Run:

```bash
dart format lib/src/core/update_client.dart lib/src/core/macos_staged_app_validator.dart lib/src/release_cli/validate_command.dart test/update_client_security_test.dart test/release_cli/release_validate_test.dart test/macos_staged_app_symlink_test.dart test/native_helper_script_test.dart
git diff --check
```

Expected: formatter completes and `git diff --check` prints no whitespace errors.

- [x] **Step 4: Summarize residual follow-up**

In the final implementation response, include:

```text
Closed:
- FDU-RTSEL-001 with descriptor/index identity binding.
- Release validate identity hardening.

Reviewed:
- macOS top-level .app symlink behavior.
- Windows/Linux wholeDirectoryReplace stale-file behavior.

Verification:
- flutter test --no-pub ...
- git diff --check
```

If any platform runtime evidence could not be run locally, name the exact platform and command that must run in CI or on a matching host.
