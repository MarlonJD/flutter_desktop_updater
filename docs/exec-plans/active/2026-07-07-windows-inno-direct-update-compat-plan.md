# Windows Inno Direct Update Compatibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Windows direct zip updates safe for apps that were originally installed with Inno Setup, without claiming full `.exe` installer update support.

**Architecture:** Keep the existing zip-first release contract and Windows `wholeDirectoryReplace` strategy. The Windows native helper preserves known Inno uninstall artifacts while pruning the app payload, retries successful-install staging cleanup, and Dart performs conservative stale staging cleanup before future staging attempts. Docs define the boundary between Inno-compatible direct updates and full Inno installer execution.

**Tech Stack:** Dart/Flutter tests, Windows C++ Flutter plugin helper, generated PowerShell install script, existing `app-archive.json`/`release.json` schema version 3, repository validation ladder.

## Global Constraints

- Do not add full Inno `.exe` installer execution in this plan.
- Do not change `app-archive.json` or `release.json` schema.
- Do not change the public Dart API unless a task explicitly adds a backward-compatible optional parameter.
- Do not create, switch, rename, or delete branches.
- Keep docs and user-facing compatibility statements in English.
- Keep Windows behavior focused on direct zip updates produced by `dart run desktop_updater:release publish --platform windows`.
- Preserve existing `wholeDirectoryReplace` semantics for ordinary app payload files.
- Treat native helper cleanup as best-effort after a successful copy; cleanup failure must not roll back an otherwise successful update.
- Use the narrowest useful validation command first, then widen before handoff.

---

## Support Boundary

This plan supports:

- Apps first installed with Inno Setup and later updated through
  `desktop_updater` direct zip updates.
- Preserving Inno uninstall artifacts that live in the app root:
  `unins000.exe`, `unins000.dat`, `unins000.msg`, and the same three-digit
  family with different numbers such as `unins001.exe`.
- Keeping the existing Windows uninstall registry entry usable when direct zip
  updates replace the Flutter Release payload.
- Removing successful-install staging directories more reliably.
- Opportunistically removing old failed or abandoned
  `desktop_updater_stage_*` directories.

This plan does not support:

- Downloading an Inno Setup installer `.exe` as the update artifact.
- Running Inno silent installer flags such as `/VERYSILENT`.
- Regenerating or editing Inno's `unins*.dat` uninstall log.
- Guaranteeing a perfectly clean uninstall for files that were added by a zip
  update after the original Inno install. The preserved Inno uninstaller can
  run, but Inno may not know about files it did not install.
- Supporting arbitrary third-party installer metadata beyond the explicit Inno
  artifact names above.

## File Structure

### Windows Native Helper

- Modify `windows/desktop_updater_plugin.h`.
  - Expose a test-visible matcher:
    `bool IsInstallerOwnedWindowsFileForTesting(const std::wstring& file_name);`
- Modify `windows/desktop_updater_plugin.cpp`.
  - Add C++ filename matcher for Inno uninstall artifacts.
  - Add matching PowerShell predicate inside the generated install helper.
  - Skip deleting preserved Inno uninstall artifacts during target pruning.
  - Add retrying staging cleanup after a successful copy.
- Modify `windows/test/desktop_updater_plugin_test.cpp`.
  - Add native matcher tests for Inno artifact names and false positives.

### Dart Staging Cleanup

- Create `lib/src/core/staging_directory_cleanup.dart`.
  - Own the staging prefix constant and stale staging cleanup helper.
- Modify `lib/src/core/update_client.dart`.
  - Use the shared staging prefix.
  - Run conservative stale staging cleanup before creating a new staging root.
- Create `test/staging_directory_cleanup_test.dart`.
  - Test deletion of old staging directories and preservation of recent,
    unrelated, file, and explicitly preserved paths.
- Modify `test/e2e/zip_first_update_flow_test.dart`.
  - Add one integration-style check that stale staging cleanup runs before a
    new Windows staging directory is created.

### Source-Shape And Docs Tests

- Modify `test/native_helper_script_test.dart`.
  - Keep source-shape coverage for generated PowerShell behavior.
  - Assert Inno preserve logic appears before the copy step.
  - Assert cleanup retry logic appears after the move step.
- Modify `docs/publishing.md`.
  - Document Windows Inno-compatible direct zip updates and their limits.
- Modify `docs/windows-linux-production-release.md`.
  - Add a Windows subsection for Inno Setup compatibility.
- Modify `docs/diagnostics-and-recovery.md`.
  - Document cleanup retry events and what stale staging cleanup means.

## Phase 1: Inno-Compatible Direct Zip Updates

### Task 1: Add A Native Inno Artifact Matcher

**Files:**

- Modify: `windows/desktop_updater_plugin.h`
- Modify: `windows/desktop_updater_plugin.cpp`
- Test: `windows/test/desktop_updater_plugin_test.cpp`

**Interfaces:**

- Produces: `bool IsInstallerOwnedWindowsFileForTesting(const std::wstring& file_name);`
- Consumes: Windows native tests use the matcher directly. The generated
  PowerShell script uses its own equivalent predicate because it runs after the
  app process exits.

- [x] **Step 1.1: Write the failing native matcher test**

Add this test to `windows/test/desktop_updater_plugin_test.cpp` after
`RemovedFileMustBeStrictChildPath`:

```cpp
TEST(DesktopUpdaterPlugin, InnoUninstallArtifactsAreInstallerOwnedFiles) {
  EXPECT_TRUE(IsInstallerOwnedWindowsFileForTesting(L"unins000.exe"));
  EXPECT_TRUE(IsInstallerOwnedWindowsFileForTesting(L"unins000.dat"));
  EXPECT_TRUE(IsInstallerOwnedWindowsFileForTesting(L"unins000.msg"));
  EXPECT_TRUE(IsInstallerOwnedWindowsFileForTesting(L"UNINS001.EXE"));
  EXPECT_TRUE(IsInstallerOwnedWindowsFileForTesting(
      L"C:\\Program Files\\Example\\unins002.dat"));

  EXPECT_FALSE(IsInstallerOwnedWindowsFileForTesting(L"unins.exe"));
  EXPECT_FALSE(IsInstallerOwnedWindowsFileForTesting(L"unins00.exe"));
  EXPECT_FALSE(IsInstallerOwnedWindowsFileForTesting(L"unins000.tmp"));
  EXPECT_FALSE(IsInstallerOwnedWindowsFileForTesting(L"uninstall.exe"));
  EXPECT_FALSE(IsInstallerOwnedWindowsFileForTesting(L"example.exe"));
  EXPECT_FALSE(IsInstallerOwnedWindowsFileForTesting(L""));
}
```

- [ ] **Step 1.2: Run the Windows native test and verify it fails**

Run on Windows or in the Windows CI lane:

```sh
flutter build windows --debug
cmake --build example/build/windows/x64 --config Debug --target desktop_updater_test
ctest --test-dir example/build/windows/x64 -C Debug --output-on-failure
```

Expected before implementation: compile failure because
`IsInstallerOwnedWindowsFileForTesting` is not declared.

- [x] **Step 1.3: Expose the test-visible matcher in the Windows header**

Add this declaration to `windows/desktop_updater_plugin.h` after
`IsKnownProtectedInstallDirectoryForTesting`:

```cpp
bool IsInstallerOwnedWindowsFileForTesting(const std::wstring& file_name);
```

- [x] **Step 1.4: Implement the matcher in the Windows plugin**

Add this implementation to `windows/desktop_updater_plugin.cpp` near the other
test-visible functions after `IsKnownProtectedInstallDirectoryForTesting`:

```cpp
bool IsInstallerOwnedWindowsFileForTesting(const std::wstring& file_name) {
  const std::wstring name = fs::path(file_name).filename().wstring();
  if (name.empty()) {
    return false;
  }

  const size_t dot_position = name.rfind(L'.');
  if (dot_position == std::wstring::npos) {
    return false;
  }

  const std::wstring stem = name.substr(0, dot_position);
  const std::wstring extension = name.substr(dot_position);
  if (stem.size() != 8) {
    return false;
  }

  if (_wcsnicmp(stem.c_str(), L"unins", 5) != 0) {
    return false;
  }

  for (size_t index = 5; index < stem.size(); index += 1) {
    if (stem[index] < L'0' || stem[index] > L'9') {
      return false;
    }
  }

  return _wcsicmp(extension.c_str(), L".exe") == 0 ||
         _wcsicmp(extension.c_str(), L".dat") == 0 ||
         _wcsicmp(extension.c_str(), L".msg") == 0;
}
```

The matcher intentionally accepts only Inno's default numbered uninstall family
instead of every `unins*` string. This avoids preserving unrelated app payload
files such as `uninstall.exe`.

- [ ] **Step 1.5: Run the native matcher test**

Run on Windows or in the Windows CI lane:

```sh
ctest --test-dir example/build/windows/x64 -C Debug --output-on-failure
```

Expected after implementation: PASS for
`DesktopUpdaterPlugin.InnoUninstallArtifactsAreInstallerOwnedFiles`.

- [ ] **Step 1.6: Commit Phase 1 matcher**

Commit message:

```sh
git commit -m "test: cover inno uninstall artifact matching"
```

### Task 2: Preserve Inno Artifacts During Windows Target Prune

**Files:**

- Modify: `windows/desktop_updater_plugin.cpp`
- Test: `test/native_helper_script_test.dart`

**Interfaces:**

- Consumes: The generated PowerShell helper's `$target` directory and existing
  `Write-DiagnosticsEvent` function.
- Produces: PowerShell function
  `Test-InstallerOwnedWindowsFile([string]$Name)` used before
  `Remove-Item` during the target prune loop.

- [x] **Step 2.1: Write the failing source-shape test**

Add this test to `test/native_helper_script_test.dart` after
`Windows helper prunes target before whole directory overlay`:

```dart
test("Windows helper preserves Inno uninstall artifacts during prune", () {
  final source =
      File("windows/desktop_updater_plugin.cpp").readAsStringSync();
  const predicateSnippet = "function Test-InstallerOwnedWindowsFile";
  const preserveCondition =
      r"$_.PSIsContainer -or -not (Test-InstallerOwnedWindowsFile $_.Name)";
  const preserveEvent = "preserve installer file";
  const pruneSnippet = r"Get-ChildItem -LiteralPath $target -Force";
  const copySnippet =
      r"Copy-Item -LiteralPath $_.FullName -Destination $target -Recurse -Force";

  final predicateIndex = source.indexOf(predicateSnippet);
  final pruneIndex = source.indexOf(pruneSnippet);
  final conditionIndex = source.indexOf(preserveCondition);
  final eventIndex = source.indexOf(preserveEvent);
  final copyIndex = source.indexOf(copySnippet);

  expect(predicateIndex, isNonNegative);
  expect(pruneIndex, isNonNegative);
  expect(conditionIndex, isNonNegative);
  expect(eventIndex, isNonNegative);
  expect(copyIndex, isNonNegative);
  expect(predicateIndex, lessThan(pruneIndex));
  expect(pruneIndex, lessThan(copyIndex));
  expect(conditionIndex, lessThan(copyIndex));
});
```

- [x] **Step 2.2: Run the focused Dart source-shape test and verify it fails**

Run:

```sh
flutter test --no-pub test/native_helper_script_test.dart
```

Expected before implementation: FAIL because
`Test-InstallerOwnedWindowsFile` is not present in the generated PowerShell.

- [x] **Step 2.3: Add the PowerShell predicate before backup/prune logic**

In `windows/desktop_updater_plugin.cpp`, add this generated script block after
`Update-UninstallDisplayVersion` and before `$backup = Join-Path ...`:

```cpp
      << "function Test-InstallerOwnedWindowsFile([string]$Name) {\n"
      << "  if ([string]::IsNullOrWhiteSpace($Name)) { return $false }\n"
      << "  return $Name -imatch '^unins[0-9][0-9][0-9]\\.(exe|dat|msg)$'\n"
      << "}\n"
```

- [x] **Step 2.4: Skip preserved files during the target prune loop**

Replace the current target prune body:

```cpp
      << "      Get-ChildItem -LiteralPath $target -Force | ForEach-Object {\n"
      << "        Remove-Item -LiteralPath $_.FullName -Recurse -Force\n"
      << "      }\n"
```

with:

```cpp
      << "      Get-ChildItem -LiteralPath $target -Force | ForEach-Object {\n"
      << "        if ($_.PSIsContainer -or -not (Test-InstallerOwnedWindowsFile $_.Name)) {\n"
      << "          Remove-Item -LiteralPath $_.FullName -Recurse -Force\n"
      << "        } else {\n"
      << "          Write-DiagnosticsEvent ('preserve installer file ' + $_.Name)\n"
      << "        }\n"
      << "      }\n"
```

This preserves only files, not directories, because a directory named
`unins000.exe` should not be treated as installer metadata.

- [x] **Step 2.5: Update the existing prune source-shape test if needed**

If `Windows helper prunes target before whole directory overlay` depends on the
old exact remove placement, keep the same test intent but allow the new guarded
remove. The test should still assert:

```dart
expect(source, contains(r"Remove-Item -LiteralPath $_.FullName -Recurse -Force"));
expect(pruneIndex, lessThan(copyIndex));
```

Do not weaken the test so much that a future change could copy over the app
payload without pruning stale files.

- [ ] **Step 2.6: Run focused tests**

Run:

```sh
flutter test --no-pub test/native_helper_script_test.dart
```

Expected: PASS.

On Windows or in CI, also run:

```sh
ctest --test-dir example/build/windows/x64 -C Debug --output-on-failure
```

Expected: PASS.

- [ ] **Step 2.7: Commit Phase 1 behavior**

Commit message:

```sh
git commit -m "fix: preserve inno uninstall files during windows updates"
```

### Task 3: Document The Inno Compatibility Boundary

**Files:**

- Modify: `docs/publishing.md`
- Modify: `docs/windows-linux-production-release.md`

**Interfaces:**

- Consumes: The Phase 1 behavior that preserves `unins###.exe`,
  `unins###.dat`, and `unins###.msg`.
- Produces: Reader-facing docs that avoid overstating support as full Inno
  installer execution.

- [x] **Step 3.1: Add Windows publishing guidance**

In `docs/publishing.md`, under the Windows section after the production trust
bullets, add:

```markdown
For apps that were originally installed with Inno Setup, Windows direct zip
updates preserve Inno uninstall artifacts named `unins###.exe`,
`unins###.dat`, and `unins###.msg` in the app root. This keeps the existing
Windows uninstall entry usable when the updater replaces the Flutter Release
payload.

This is Inno-compatible direct zip updating, not full Inno installer updating.
The updater does not download or execute an Inno `.exe` installer, and it does
not regenerate Inno's uninstall log. If a zip update adds new files that were
not part of the original installer, Inno may leave those files behind during
uninstall.
```

- [x] **Step 3.2: Add production release boundary notes**

In `docs/windows-linux-production-release.md`, add a Windows subsection after
`Direct Zip Plus Authenticode`:

```markdown
### Inno Setup Installed Apps

`desktop_updater` can update an app that was originally installed with Inno
Setup when the update artifact is still the normal Windows Release directory
zip. During Windows `wholeDirectoryReplace`, the helper preserves Inno uninstall
artifacts named `unins###.exe`, `unins###.dat`, and `unins###.msg` in the app
root so the existing uninstall entry remains usable.

This compatibility path does not run an Inno installer. Use it when you want
Inno for first install and `desktop_updater` for direct zip updates. If your
update policy requires installer-owned repair, modify, uninstall-log, or
enterprise deployment behavior, track that as installer-based update support
instead of relying on direct zip updates.
```

- [x] **Step 3.3: Add a docs drift test if the repo already checks this area**

If `test/native_helper_diagnostics_docs_test.dart` or another docs drift test
already asserts Windows production guidance, add contains checks:

```dart
expect(source, contains("Inno Setup"));
expect(source, contains("unins###.exe"));
expect(source, contains("not full Inno installer updating"));
```

If no suitable docs drift test exists, do not create a broad new docs test just
for wording. Keep the code behavior tests as the source of truth.

- [x] **Step 3.4: Run focused docs and helper tests**

Run:

```sh
flutter test --no-pub test/native_helper_script_test.dart test/native_helper_diagnostics_docs_test.dart
```

Expected: PASS. If the docs drift test was not modified because it was not
relevant, run only `test/native_helper_script_test.dart`.

- [ ] **Step 3.5: Commit Phase 1 docs**

Commit message:

```sh
git commit -m "docs: explain inno-compatible windows updates"
```

## Phase 2: Reliable Temp Cleanup

### Task 4: Retry Native Helper Cleanup After Successful Windows Install

**Files:**

- Modify: `windows/desktop_updater_plugin.cpp`
- Test: `test/native_helper_script_test.dart`

**Interfaces:**

- Consumes: Existing generated PowerShell function `Write-DiagnosticsEvent`.
- Produces: Generated PowerShell function
  `Remove-StagingDirectoryWithRetry([string]$Path)`.
- Emits diagnostics events:
  - `cleanup start`
  - `cleanup retry`
  - `cleanup success`
  - `cleanup failure`

- [x] **Step 4.1: Write the failing source-shape test**

Add this test to `test/native_helper_script_test.dart` after the Windows Inno
preserve test:

```dart
test("Windows helper retries staging cleanup after successful copy", () {
  final source =
      File("windows/desktop_updater_plugin.cpp").readAsStringSync();
  const cleanupFunction = "function Remove-StagingDirectoryWithRetry";
  const retryEvent = "Write-DiagnosticsEvent 'cleanup retry'";
  const cleanupCall = "Remove-StagingDirectoryWithRetry -Path $staging";
  const moveSuccess = "Write-DiagnosticsEvent 'move success'";
  const relaunchSnippet = r"Start-Process -FilePath $exe";

  final functionIndex = source.indexOf(cleanupFunction);
  final retryIndex = source.indexOf(retryEvent);
  final moveSuccessIndex = source.indexOf(moveSuccess);
  final cleanupCallIndex = source.indexOf(cleanupCall);
  final relaunchIndex = source.indexOf(relaunchSnippet);

  expect(functionIndex, isNonNegative);
  expect(retryIndex, isNonNegative);
  expect(moveSuccessIndex, isNonNegative);
  expect(cleanupCallIndex, isNonNegative);
  expect(relaunchIndex, isNonNegative);
  expect(functionIndex, lessThan(moveSuccessIndex));
  expect(moveSuccessIndex, lessThan(cleanupCallIndex));
  expect(cleanupCallIndex, lessThan(relaunchIndex));
});
```

- [x] **Step 4.2: Run the focused test and verify it fails**

Run:

```sh
flutter test --no-pub test/native_helper_script_test.dart
```

Expected before implementation: FAIL because the cleanup retry function is not
present.

- [x] **Step 4.3: Add the retrying cleanup function to the generated script**

In `windows/desktop_updater_plugin.cpp`, add this generated script block after
`Test-InstallerOwnedWindowsFile`:

```cpp
      << "function Remove-StagingDirectoryWithRetry([string]$Path) {\n"
      << "  if ([string]::IsNullOrWhiteSpace($Path)) { return }\n"
      << "  Write-DiagnosticsEvent 'cleanup start'\n"
      << "  if (-not (Test-Path -LiteralPath $Path)) {\n"
      << "    Write-DiagnosticsEvent 'cleanup success'\n"
      << "    return\n"
      << "  }\n"
      << "  $cleanupDeadline = (Get-Date).AddSeconds(30)\n"
      << "  while ($true) {\n"
      << "    try {\n"
      << "      Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop\n"
      << "      Write-DiagnosticsEvent 'cleanup success'\n"
      << "      return\n"
      << "    } catch {\n"
      << "      if ((Get-Date) -gt $cleanupDeadline) {\n"
      << "        Write-DiagnosticsEvent 'cleanup failure'\n"
      << "        return\n"
      << "      }\n"
      << "      Write-DiagnosticsEvent 'cleanup retry'\n"
      << "      Start-Sleep -Milliseconds 500\n"
      << "    }\n"
      << "  }\n"
      << "}\n"
```

- [x] **Step 4.4: Replace the one-shot staging cleanup block**

Replace:

```cpp
      << "  Write-DiagnosticsEvent 'cleanup start'\n"
      << "  try {\n"
      << "    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction Stop\n"
      << "    Write-DiagnosticsEvent 'cleanup success'\n"
      << "  } catch {\n"
      << "    Write-DiagnosticsEvent 'cleanup failure'\n"
      << "  }\n"
```

with:

```cpp
      << "  Remove-StagingDirectoryWithRetry -Path $staging\n"
```

Do not throw from cleanup failure. The copy already succeeded at this point, so
cleanup failure should remain diagnostic-only.

- [x] **Step 4.5: Update diagnostics docs**

In `docs/diagnostics-and-recovery.md`, after the Windows UAC paragraph, add:

```markdown
After a successful Windows copy, the helper retries staging cleanup for a short
bounded window. The diagnostics log may include `cleanup retry` before
`cleanup success` when antivirus, indexing, or another process temporarily
holds a file. If cleanup still fails, the helper writes `cleanup failure` and
continues to relaunch because the update has already been copied into place.
```

- [x] **Step 4.6: Run focused tests**

Run:

```sh
flutter test --no-pub test/native_helper_script_test.dart test/native_helper_diagnostics_docs_test.dart
```

Expected: PASS.

- [ ] **Step 4.7: Commit native cleanup retry**

Commit message:

```sh
git commit -m "fix: retry windows staging cleanup"
```

### Task 5: Add Conservative Dart Stale Staging Cleanup

**Files:**

- Create: `lib/src/core/staging_directory_cleanup.dart`
- Modify: `lib/src/core/update_client.dart`
- Test: `test/staging_directory_cleanup_test.dart`
- Test: `test/e2e/zip_first_update_flow_test.dart`

**Interfaces:**

- Produces: `const String desktopUpdaterStagingPrefix`
- Produces: `const Duration defaultStaleStagingAge`
- Produces:
  `Future<StagingDirectoryCleanupReport> cleanupStaleDesktopUpdaterStagingDirectories(...)`
- Consumes: `UpdateClient.downloadVerifyAndStage` calls the cleanup helper
  before creating a fresh staging root.

- [x] **Step 5.1: Write failing unit tests for stale cleanup**

Create `test/staging_directory_cleanup_test.dart`:

```dart
import "dart:io";

import "package:desktop_updater/src/core/staging_directory_cleanup.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;

void main() {
  test("deletes only stale desktop updater staging directories", () async {
    final root = await Directory.systemTemp.createTemp("staging_cleanup_");
    try {
      final oldStage =
          await Directory(path.join(root.path, "desktop_updater_stage_old"))
              .create();
      final recentStage =
          await Directory(path.join(root.path, "desktop_updater_stage_recent"))
              .create();
      final unrelated =
          await Directory(path.join(root.path, "other_stage_old")).create();
      final stageFile = File(path.join(root.path, "desktop_updater_stage_file"));
      await stageFile.writeAsString("not a directory");

      final now = DateTime.utc(2026, 7, 7, 12);
      await oldStage.setLastModified(now.subtract(const Duration(days: 8)));
      await recentStage.setLastModified(now.subtract(const Duration(hours: 2)));
      await unrelated.setLastModified(now.subtract(const Duration(days: 8)));
      await stageFile.setLastModified(now.subtract(const Duration(days: 8)));

      final report = await cleanupStaleDesktopUpdaterStagingDirectories(
        parent: root,
        now: now,
      );

      expect(oldStage.existsSync(), isFalse);
      expect(recentStage.existsSync(), isTrue);
      expect(unrelated.existsSync(), isTrue);
      expect(stageFile.existsSync(), isTrue);
      expect(report.scanned, 4);
      expect(report.deleted, 1);
      expect(report.failedPaths, isEmpty);
    } finally {
      await root.delete(recursive: true);
    }
  });

  test("preserves explicitly protected staging paths", () async {
    final root = await Directory.systemTemp.createTemp("staging_cleanup_");
    try {
      final protectedStage =
          await Directory(path.join(root.path, "desktop_updater_stage_keep"))
              .create();
      final now = DateTime.utc(2026, 7, 7, 12);
      await protectedStage.setLastModified(now.subtract(const Duration(days: 8)));

      final report = await cleanupStaleDesktopUpdaterStagingDirectories(
        parent: root,
        now: now,
        preservedPaths: {protectedStage.path},
      );

      expect(protectedStage.existsSync(), isTrue);
      expect(report.scanned, 1);
      expect(report.deleted, 0);
      expect(report.failedPaths, isEmpty);
    } finally {
      await root.delete(recursive: true);
    }
  });
}
```

- [x] **Step 5.2: Run the unit tests and verify they fail**

Run:

```sh
flutter test --no-pub test/staging_directory_cleanup_test.dart
```

Expected before implementation: FAIL because
`staging_directory_cleanup.dart` does not exist.

- [x] **Step 5.3: Implement the cleanup helper**

Create `lib/src/core/staging_directory_cleanup.dart`:

```dart
import "dart:io";

import "package:path/path.dart" as path;

const String desktopUpdaterStagingPrefix = "desktop_updater_stage_";
const Duration defaultStaleStagingAge = Duration(days: 7);

class StagingDirectoryCleanupReport {
  const StagingDirectoryCleanupReport({
    required this.scanned,
    required this.deleted,
    required this.failedPaths,
  });

  final int scanned;
  final int deleted;
  final List<String> failedPaths;
}

Future<StagingDirectoryCleanupReport> cleanupStaleDesktopUpdaterStagingDirectories({
  required Directory parent,
  DateTime? now,
  Duration staleAge = defaultStaleStagingAge,
  Set<String> preservedPaths = const {},
}) async {
  if (!await parent.exists()) {
    return const StagingDirectoryCleanupReport(
      scanned: 0,
      deleted: 0,
      failedPaths: [],
    );
  }

  final cutoff = (now ?? DateTime.now()).subtract(staleAge);
  final normalizedPreservedPaths = preservedPaths
      .map((value) => path.normalize(path.absolute(value)))
      .toSet();
  var scanned = 0;
  var deleted = 0;
  final failedPaths = <String>[];

  await for (final entity in parent.list(followLinks: false)) {
    scanned += 1;
    if (entity is! Directory) {
      continue;
    }
    if (!path.basename(entity.path).startsWith(desktopUpdaterStagingPrefix)) {
      continue;
    }

    final normalizedPath = path.normalize(path.absolute(entity.path));
    if (normalizedPreservedPaths.contains(normalizedPath)) {
      continue;
    }

    try {
      final modified = await entity.lastModified();
      if (!modified.isBefore(cutoff)) {
        continue;
      }
      await entity.delete(recursive: true);
      deleted += 1;
    } on FileSystemException {
      failedPaths.add(entity.path);
    }
  }

  return StagingDirectoryCleanupReport(
    scanned: scanned,
    deleted: deleted,
    failedPaths: List.unmodifiable(failedPaths),
  );
}
```

- [x] **Step 5.4: Use the shared staging prefix in UpdateClient**

In `lib/src/core/update_client.dart`, add:

```dart
import "package:desktop_updater/src/core/staging_directory_cleanup.dart";
```

Replace:

```dart
    final stagingRoot = await (_stagingParent ?? Directory.systemTemp)
        .createTemp("desktop_updater_stage_");
```

with:

```dart
    final stagingParent = _stagingParent ?? Directory.systemTemp;
    await cleanupStaleDesktopUpdaterStagingDirectories(parent: stagingParent);
    final stagingRoot = await stagingParent.createTemp(
      desktopUpdaterStagingPrefix,
    );
```

This cleanup runs before creating the new staging root, so it cannot delete the
current attempt's staging directory.

- [x] **Step 5.5: Add an UpdateClient integration test for stale cleanup**

Append this test to `test/e2e/zip_first_update_flow_test.dart`:

```dart
  test("removes stale staging directories before creating a new Windows stage",
      () async {
    final tempDir = await Directory.systemTemp.createTemp("zip_first_e2e_");
    UpdateServer? server;
    try {
      final staleStage =
          await Directory(path.join(tempDir.path, "desktop_updater_stage_old"))
              .create();
      await staleStage.setLastModified(
        DateTime.now().subtract(const Duration(days: 8)),
      );

      server = await UpdateServer.bind(tempDir);
      await buildReleaseFixture(
        root: tempDir,
        baseUri: server.uri,
        platform: "windows",
      );

      final client = UpdateClient(
        appArchiveUrl: server.uri.resolve("app-archive.json"),
        currentVersion: DesktopVersionInfo.fromParts(
          versionName: "1.0.0",
          buildNumber: "100",
        ),
        platform: "windows",
        stagingParent: tempDir,
      );
      final check = await client.checkForUpdate();

      final staged = await client.downloadVerifyAndStage(
        descriptor: check!.descriptor,
      );

      expect(staleStage.existsSync(), isFalse);
      expect(Directory(staged.stagingPath).existsSync(), isTrue);
    } finally {
      await server?.close();
      await tempDir.delete(recursive: true);
    }
  });
```

- [x] **Step 5.6: Run focused Dart tests**

Run:

```sh
flutter test --no-pub test/staging_directory_cleanup_test.dart test/e2e/zip_first_update_flow_test.dart
```

Expected: PASS.

- [ ] **Step 5.7: Commit Dart stale cleanup**

Commit message:

```sh
git commit -m "fix: prune stale updater staging directories"
```

### Task 6: Document Temp Cleanup Semantics

**Files:**

- Modify: `docs/diagnostics-and-recovery.md`
- Modify: `docs/publishing.md`
- Test: `test/native_helper_diagnostics_docs_test.dart`

**Interfaces:**

- Consumes: Task 4 cleanup retry diagnostics and Task 5 stale staging cleanup.
- Produces: Docs that tell users when remaining temp directories are expected
  and when they indicate a bug.

- [x] **Step 6.1: Update diagnostics docs for stale staging cleanup**

In `docs/diagnostics-and-recovery.md`, add:

```markdown
Before staging a new update, the Dart update client removes old
`desktop_updater_stage_*` directories from the staging parent when they are
older than the bounded stale-staging window. Recent staging directories are left
alone so a user who downloaded an update but has not installed it yet does not
lose the staged update.
```

- [x] **Step 6.2: Update publishing docs for temp directory expectations**

In `docs/publishing.md`, near the Windows update behavior section, add:

```markdown
A successful Windows install should remove its `desktop_updater_stage_*`
directory after the payload copy succeeds. If the app downloads an update but
the install is cancelled, never handed to the native helper, or fails before the
successful copy point, a staging directory can remain temporarily. Future update
checks prune stale staging directories conservatively after they age past the
cleanup window.
```

- [x] **Step 6.3: Add docs drift assertions**

In `test/native_helper_diagnostics_docs_test.dart`, add checks to the relevant
docs test:

```dart
expect(source, contains("cleanup retry"));
expect(source, contains("desktop_updater_stage_*"));
expect(source, contains("stale-staging window"));
```

- [x] **Step 6.4: Run docs tests**

Run:

```sh
flutter test --no-pub test/native_helper_diagnostics_docs_test.dart
```

Expected: PASS.

- [ ] **Step 6.5: Commit cleanup docs**

Commit message:

```sh
git commit -m "docs: clarify updater staging cleanup"
```

## Final Verification

- [x] **Step 7.1: Run focused Dart tests**

Run:

```sh
flutter test --no-pub \
  test/native_helper_script_test.dart \
  test/native_helper_diagnostics_docs_test.dart \
  test/staging_directory_cleanup_test.dart \
  test/e2e/zip_first_update_flow_test.dart
```

Expected: PASS.

- [x] **Step 7.2: Run formatting**

Run:

```sh
dart format --set-exit-if-changed .
```

Expected: exits 0 with no formatting changes after the command.

- [x] **Step 7.3: Run analyzer**

Run:

```sh
flutter analyze --no-fatal-infos
```

Expected: PASS with no new warnings caused by this plan.

- [x] **Step 7.4: Run full Flutter tests**

Run:

```sh
flutter test --no-pub
```

Expected: PASS.

- [ ] **Step 7.5: Run Windows native validation in CI or on Windows**

Run:

```sh
flutter build windows --debug
cmake --build example/build/windows/x64 --config Debug --target desktop_updater_test
ctest --test-dir example/build/windows/x64 -C Debug --output-on-failure
```

Expected: PASS.

- [ ] **Step 7.6: Run Windows update smoke in CI or on Windows**

Run the existing Windows update smoke lane from
`.github/workflows/desktop-updater-ci.yml`.

Expected:

- Windows direct zip update succeeds.
- Native helper diagnostics include `cleanup success` after successful install.
- No `desktop_updater_stage_*` directory from the successful install remains in
  the staging parent after helper completion.
- An Inno-like target root fixture containing `unins000.exe`,
  `unins000.dat`, and `unins000.msg` still contains those files after the
  update.

## GitHub Issue Follow-Up Draft

Post this after Phase 1 and Phase 2 are implemented and verified:

```markdown
Implemented the short-term Windows compatibility path for Inno-installed apps.

What changed:
- Windows direct zip updates now preserve Inno uninstall artifacts named `unins###.exe`, `unins###.dat`, and `unins###.msg` during `wholeDirectoryReplace`.
- Windows helper cleanup retries staging directory deletion after a successful payload copy.
- The Dart update client prunes stale `desktop_updater_stage_*` directories conservatively before future staging attempts.
- Docs now clarify that this is Inno-compatible direct zip updating, not full Inno `.exe` installer update support.

This should keep the existing Inno uninstall entry usable after a `desktop_updater` zip update. Full installer-based update support, where the updater downloads and executes an Inno installer, remains a separate enhancement.
```

## Self-Review Checklist

- [x] Spec coverage: Phase 1 covers Inno uninstall artifact preservation. Phase
  2 covers successful-install cleanup reliability and stale staging cleanup.
- [x] Boundary coverage: Docs explicitly say this is not full Inno installer
  execution.
- [x] Placeholder scan: This plan contains no unresolved marker text or
  undefined follow-up placeholders.
- [x] Type consistency: `desktopUpdaterStagingPrefix`,
  `defaultStaleStagingAge`, `StagingDirectoryCleanupReport`, and
  `cleanupStaleDesktopUpdaterStagingDirectories` are named consistently across
  tasks.
- [x] Compatibility: No public Dart API shape changes are required.
- [x] Safety: Stale cleanup deletes only old directories with the exact
  `desktop_updater_stage_` prefix and skips recent or explicitly preserved
  paths.
