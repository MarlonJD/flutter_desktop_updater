# Desktop Updater Zip-First Rewrite V2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a safe `1.4.1` maintenance warning release and then implement a secure, zip-first `2.0.0` updater contract without mixing release baselines or duplicating platform logic.

**Architecture:** Split the work into two independent release lanes: a minimal 1.x maintenance lane from the latest stable baseline, and a 2.x rewrite lane on the current development baseline. The 2.x lane uses one shared Dart update core for parsing, transport, verification, staging, and state, with thin native platform installers for macOS, Windows, and Linux. Update metadata uses exact URLs only: `app-archive.json` points to `release.json`, and `release.json` points to one verified zip artifact.

**Tech Stack:** Dart 3.6+, Flutter desktop plugins, MethodChannel platform adapters, `archive` for non-macOS zip handling, `/usr/bin/ditto` for macOS zips, `crypto` for SHA-256, optional `cryptography_plus` signatures, Flutter test, native C++/Swift tests, and desktop integration smoke tests.

---

## Non-Negotiable Constraints

- Do not create, switch, rename, or delete branches unless the user explicitly approves that branch action during execution.
- Do not publish to pub.dev until `dart pub publish --dry-run` passes and the user explicitly confirms publish in the execution turn.
- Do not post GitHub comments through the Codex/GitHub connector identity.
- Keep canonical docs, file names, type names, method names, JSON field names, and source comments in English.
- Do not mix `1.4.1` maintenance changes with `2.0.0` rewrite changes in one publishable package.
- Do not commit, push, or publish unrelated files.
- Treat update metadata, artifacts, zip entries, staging paths, and installer arguments as attacker-controlled unless verified.

## Live State To Re-Verify At Execution Time

- Run `curl -s https://pub.dev/api/packages/desktop_updater`.
- Expected at plan creation: `latest.version` is `1.4.0`, and newest dev is `2.0.0-dev.5`.
- If `latest.version` is still `1.4.0`, prepare `1.4.1`.
- If another stable version exists, prepare the next patch above that stable version.
- Local evidence at plan creation:
  - `2b6de3b` contains `pubspec.yaml` with `version: 1.4.0`.
  - `26d474f` starts the `2.0.0-dev.1` rewrite line.
  - Current working tree is `2.0.0-dev.5`.

## KILLCRITIC Gates

The executor must stop before implementation if any of these cannot be satisfied:

- The `1.x` maintenance lane cannot be isolated from the current `2.x` working tree.
- The 2.x release descriptor or artifact integrity model has no authenticity story for production.
- Any platform installer can replace files outside the intended app root.
- A zip extractor can write absolute paths, `..` traversal paths, Windows drive paths, or unsafe links.
- Windows replacement can leave a partially copied app without rollback or old-app preservation.
- Linux replacement depends on current working directory, relative `update/` folders, or unverified shell snippets.
- macOS replacement loses the existing native gates: `ditto`, codesign, Gatekeeper, stapler, bundle identifier, Team ID, and rollback.
- `dart pub publish --dry-run` package contents include unrelated plan/worktree files.

## File Structure

### 1.x Maintenance Lane

- Modify in isolated 1.x baseline only: `pubspec.yaml`
- Modify in isolated 1.x baseline only: `CHANGELOG.md`
- Modify in isolated 1.x baseline only: `README.md`
- Modify in isolated 1.x baseline only: `bin/archive.dart`
- Modify in isolated 1.x baseline only: `bin/release.dart`

### 2.x Rewrite Lane

- Create: `docs/2.0-roadmap.md`
- Create: `docs/migration/1.x-to-2.0.md`
- Create: `docs/migration/agent-prompt.md`
- Create: `lib/src/core/update_client.dart`
- Create: `lib/src/core/update_state.dart`
- Create: `lib/src/core/release_index.dart`
- Create: `lib/src/core/release_descriptor.dart`
- Create: `lib/src/core/artifact_verifier.dart`
- Create: `lib/src/core/safe_zip_extractor.dart`
- Create: `lib/src/io/update_transport.dart`
- Create: `lib/src/io/http_update_transport.dart`
- Create: `lib/src/io/file_update_transport.dart`
- Create: `lib/src/package/release_packager.dart`
- Create: `lib/src/package/zip_release_packager.dart`
- Create: `lib/src/platform/platform_installer.dart`
- Create: `lib/src/platform/macos_installer.dart`
- Create: `lib/src/platform/windows_installer.dart`
- Create: `lib/src/platform/linux_installer.dart`
- Create: `bin/package.dart`
- Create: `bin/verify.dart`
- Create: `bin/smoke_update.dart`
- Modify: `lib/desktop_updater.dart`
- Modify: `lib/updater_controller.dart`
- Modify: `macos/desktop_updater/Sources/desktop_updater/DesktopUpdaterPlugin.swift`
- Modify: `windows/desktop_updater_plugin.cpp`
- Modify: `linux/desktop_updater_plugin.cc`
- Create or modify tests under `test/`, `test/e2e/`, `test/fixtures/`, `windows/test/`, `linux/test/`, and `example/integration_test/`.

## Release Contract

### `app-archive.json`

```json
{
  "schemaVersion": 3,
  "appName": "Example App",
  "items": [
    {
      "version": "2.0.0",
      "buildNumber": 200,
      "platform": "macos",
      "channel": "stable",
      "mandatory": false,
      "release": "https://updates.example.com/releases/example/2.0.0/macos/release.json"
    }
  ]
}
```

### `release.json`

```json
{
  "schemaVersion": 3,
  "packageId": "com.example.app",
  "appName": "Example.app",
  "version": "2.0.0",
  "buildNumber": 200,
  "platform": "macos",
  "channel": "stable",
  "artifact": {
    "kind": "zip",
    "url": "https://cdn.example.com/releases/example/2.0.0/macos/Example-2.0.0-macos.zip",
    "sha256": "64-lowercase-hex-characters",
    "length": 12345678
  },
  "install": {
    "strategy": "wholeBundleReplace"
  },
  "signature": {
    "algorithm": "ed25519",
    "publicKeyId": "stable-2026-06",
    "value": "base64-signature-over-canonical-release-json-with-empty-signature-value"
  },
  "minimumUpdaterVersion": "2.0.0",
  "generatedAt": "2026-06-11T00:00:00Z"
}
```

Production releases must support descriptor or artifact signatures. Local fixtures may disable signature verification explicitly through test-only configuration.

## Task 0: Prepare Execution Context

**Files:**
- Read: `docs/plans/2026-06-11-zip-first-2-0-rewrite-v2-plan.md`
- Read: `pubspec.yaml`
- Read: `CHANGELOG.md`
- Read: `README.md`

- [ ] **Step 0.1: Verify git state**

Run:

```sh
git status --short --branch
```

Expected: Note the current branch and every modified or untracked file. Do not discard user changes.

- [ ] **Step 0.2: Verify pub.dev live state**

Run:

```sh
curl -s https://pub.dev/api/packages/desktop_updater
```

Expected: Read `latest.version`. If it is `1.4.0`, the stable maintenance version is `1.4.1`.

- [ ] **Step 0.3: Ask for maintenance baseline approval**

Ask the user to approve exactly one of these execution paths:

```text
I need to isolate the 1.x maintenance release from the 2.x rewrite. Please approve one path:
1. Create a detached maintenance worktree from commit 2b6de3b for 1.4.1.
2. Download the pub.dev 1.4.0 archive into /private/tmp and prepare the dry-run there.
```

Expected: Do not create a branch or switch branches unless the user explicitly approves that branch action.

## Task 1: Prepare `1.4.1` Maintenance Warning Release

**Files:**
- Modify in isolated 1.x baseline: `pubspec.yaml`
- Modify in isolated 1.x baseline: `CHANGELOG.md`
- Modify in isolated 1.x baseline: `README.md`
- Modify in isolated 1.x baseline: `bin/archive.dart`
- Modify in isolated 1.x baseline: `bin/release.dart`

- [ ] **Step 1.1: Set package version**

Change only the isolated 1.x baseline:

```yaml
version: 1.4.1
```

- [ ] **Step 1.2: Add the warning helper**

Add this exact helper to each 1.x CLI entrypoint, or to a shared 1.x helper imported by both commands:

```dart
void printMaintenanceWarning() {
  stderr.writeln(
    "WARNING: desktop_updater 2.x is in active development and will move to a zip-first release format. "
    "The current 1.x folder-based release flow remains supported for 1.x, but new projects should review "
    "docs/2.0-roadmap.md and docs/migration/1.x-to-2.0.md before adopting 2.x.",
  );
}
```

Call `printMaintenanceWarning();` at the start of `main` in `bin/archive.dart` and `bin/release.dart`.

- [ ] **Step 1.3: Add README links**

Add this maintenance notice near the top of `README.md`:

```markdown
## Maintenance Notice

desktop_updater 2.x is in active development and will move to a zip-first release format.
The 1.x folder-based release flow remains supported for 1.x users.

- [2.0 roadmap](docs/2.0-roadmap.md)
- [1.x to 2.0 migration guide](docs/migration/1.x-to-2.0.md)
```

- [ ] **Step 1.4: Add CHANGELOG entry**

Add this entry above the previous latest stable entry:

```markdown
## 1.4.1

* Added CLI warnings and documentation links for the upcoming 2.0 zip-first updater rewrite.
* No runtime update behavior changed for 1.x users.
```

- [ ] **Step 1.5: Verify the maintenance package**

Run in the isolated 1.x baseline:

```sh
dart format --set-exit-if-changed .
flutter analyze --no-fatal-infos
flutter test --no-pub
dart pub publish --dry-run
```

Expected: All commands pass. If `dart pub publish --dry-run` includes unrelated files, fix package ignores or use a clean package source before proceeding.

- [ ] **Step 1.6: Stop for publish confirmation**

Ask:

```text
The 1.4.1 maintenance dry-run passed. Do you explicitly approve running `dart pub publish` for desktop_updater 1.4.1 now?
```

Expected: Do not publish without a clear yes.

## Task 2: Write 2.0 Roadmap And Migration Docs

**Files:**
- Create: `docs/2.0-roadmap.md`
- Create: `docs/migration/1.x-to-2.0.md`
- Create: `docs/migration/agent-prompt.md`
- Modify: `README.md`

- [ ] **Step 2.1: Create roadmap**

Create `docs/2.0-roadmap.md` with these sections:

```markdown
# desktop_updater 2.0 Roadmap

## Current State

desktop_updater 1.x is the stable folder-based updater line. desktop_updater 2.x is the active development line for a zip-first release format.

## Why Zip-First

Zip-first releases avoid public folder listing, work with signed URLs and private buckets, and make each update artifact easy to verify before extraction.

## Release Contract

The app checks `app-archive.json`, the selected item points to `release.json`, and `release.json` points to one zip artifact with length, SHA-256, and production authenticity metadata.

## Platform Behavior

- macOS replaces a complete `.app` bundle created and extracted with `/usr/bin/ditto`.
- Windows replaces a complete app directory after the running process exits.
- Linux uses one documented strategy for 2.0 final: directory bundle zip unless AppImage support is explicitly selected before release.

## Private Bucket Guidance

Do not rely on bucket listing. Publish exact descriptor and artifact URLs. Signed URLs, private proxies, and CDN URLs are supported as long as clients can fetch the exact URL before expiry.

## Release Gates

2.0 final requires unit, widget, native, and e2e tests for check, download, verify, stage, install scheduling, rollback, and migration examples.

## Compatibility

1.x installed apps should remain on the 1.x release contract until their publishers migrate their release pipeline and app code.
```

- [ ] **Step 2.2: Create migration guide**

Create `docs/migration/1.x-to-2.0.md` with before/after JSON examples, CLI commands, typed state migration, S3/CDN troubleshooting, macOS signing troubleshooting, Windows locked-file troubleshooting, and Linux permissions troubleshooting.

- [ ] **Step 2.3: Create agent prompt doc**

Create `docs/migration/agent-prompt.md` containing the execution prompt from the bottom of this plan.

- [ ] **Step 2.4: Link docs from README**

Add links to `README.md`:

```markdown
- [2.0 roadmap](docs/2.0-roadmap.md)
- [1.x to 2.0 migration guide](docs/migration/1.x-to-2.0.md)
- [Agent migration prompt](docs/migration/agent-prompt.md)
```

## Task 3: Implement Shared Zip-First Core

**Files:**
- Create: `lib/src/core/release_index.dart`
- Create: `lib/src/core/release_descriptor.dart`
- Create: `lib/src/core/artifact_verifier.dart`
- Create: `lib/src/core/safe_zip_extractor.dart`
- Create: `lib/src/core/update_state.dart`
- Create: `lib/src/core/update_client.dart`
- Test: `test/release_index_test.dart`
- Test: `test/release_descriptor_test.dart`
- Test: `test/artifact_verifier_test.dart`
- Test: `test/safe_zip_extractor_test.dart`
- Test: `test/update_state_test.dart`

- [ ] **Step 3.1: Write parser tests first**

Cover:

- schema v3 valid index.
- v1/v2 legacy index remains readable where feasible.
- missing `release` is invalid for schema v3.
- unsupported platform is ignored, not fatal.
- downgrade item is ignored by `UpdateClient`.

- [ ] **Step 3.2: Implement release models**

Implement immutable model classes:

```dart
class ReleaseIndex {
  const ReleaseIndex({required this.schemaVersion, required this.appName, required this.items});
  final int schemaVersion;
  final String appName;
  final List<ReleaseIndexItem> items;
}

class ReleaseIndexItem {
  const ReleaseIndexItem({
    required this.version,
    required this.buildNumber,
    required this.platform,
    required this.channel,
    required this.mandatory,
    required this.release,
  });
  final String version;
  final int buildNumber;
  final String platform;
  final String channel;
  final bool mandatory;
  final Uri release;
}
```

```dart
class ReleaseDescriptor {
  const ReleaseDescriptor({
    required this.schemaVersion,
    required this.packageId,
    required this.appName,
    required this.version,
    required this.buildNumber,
    required this.platform,
    required this.channel,
    required this.artifact,
    required this.install,
    required this.minimumUpdaterVersion,
    required this.generatedAt,
    this.signature,
  });
}
```

- [ ] **Step 3.3: Write verifier tests first**

Cover:

- length mismatch fails before extraction.
- SHA-256 mismatch fails before extraction.
- unsupported URL scheme fails.
- missing artifact fails.
- signed descriptor verification fails closed in production mode.

- [ ] **Step 3.4: Implement artifact verifier**

Use SHA-256 hex for zip artifacts. Keep existing Blake2b folder hashing only for legacy 1.x compatibility paths.

- [ ] **Step 3.5: Write safe zip tests first**

Cover:

- `../evil` rejected.
- `/tmp/evil` rejected.
- `C:\evil` rejected.
- nested valid paths accepted.
- symlink entries rejected on Windows and Linux by default.
- macOS app zips are extracted only by `ditto`, not by Dart `archive`.

- [ ] **Step 3.6: Implement safe zip extraction**

The extractor must normalize every entry path and verify the resolved destination remains inside the staging root before writing.

- [ ] **Step 3.7: Implement typed update state**

Use a sealed-style state hierarchy:

```dart
sealed class UpdateState {
  const UpdateState();
}

final class UpdateIdle extends UpdateState {
  const UpdateIdle();
}

final class UpdateChecking extends UpdateState {
  const UpdateChecking();
}

final class UpdateAvailable extends UpdateState {
  const UpdateAvailable({required this.descriptor, required this.mandatory});
  final ReleaseDescriptor descriptor;
  final bool mandatory;
}

final class UpdateDownloading extends UpdateState {
  const UpdateDownloading({required this.receivedBytes, required this.totalBytes});
  final int receivedBytes;
  final int totalBytes;
}

final class UpdateReadyToInstall extends UpdateState {
  const UpdateReadyToInstall({required this.stagingPath});
  final String stagingPath;
}

final class UpdateInstalling extends UpdateState {
  const UpdateInstalling();
}

final class UpdateFailed extends UpdateState {
  const UpdateFailed(this.error);
  final Object error;
}
```

## Task 4: Implement Transport And Packaging CLI

**Files:**
- Create: `lib/src/io/update_transport.dart`
- Create: `lib/src/io/http_update_transport.dart`
- Create: `lib/src/io/file_update_transport.dart`
- Create: `lib/src/package/release_packager.dart`
- Create: `lib/src/package/zip_release_packager.dart`
- Create: `bin/package.dart`
- Create: `bin/verify.dart`
- Test: `test/update_transport_test.dart`
- Test: `test/zip_release_packager_test.dart`
- Test: `test/verify_command_test.dart`

- [ ] **Step 4.1: Define transport interface**

Use one interface for HTTP and local fixtures:

```dart
abstract interface class UpdateTransport {
  Future<void> download(
    Uri source,
    File destination, {
    void Function(int receivedBytes, int? totalBytes)? onProgress,
    Duration? timeout,
  });
}
```

- [ ] **Step 4.2: Implement HTTP transport**

Support exact URLs, progress, timeout, cancellation through client close, and useful HTTP error messages.

- [ ] **Step 4.3: Implement file transport**

Support local fixture paths and `file://` URLs for tests.

- [ ] **Step 4.4: Implement package command**

`dart run desktop_updater:package` must generate:

- zip artifact.
- `release.json`.
- optional signature.
- updated example `app-archive.json` snippet.

- [ ] **Step 4.5: Implement verify command**

`dart run desktop_updater:verify --release path/to/release.json` must verify descriptor shape, exact artifact fetch, length, SHA-256, optional signature, and zip safety.

## Task 5: Implement Native Installers

**Files:**
- Create: `lib/src/platform/platform_installer.dart`
- Create: `lib/src/platform/macos_installer.dart`
- Create: `lib/src/platform/windows_installer.dart`
- Create: `lib/src/platform/linux_installer.dart`
- Modify: `macos/desktop_updater/Sources/desktop_updater/DesktopUpdaterPlugin.swift`
- Modify: `windows/desktop_updater_plugin.cpp`
- Modify: `linux/desktop_updater_plugin.cc`
- Test: `windows/test/desktop_updater_plugin_test.cpp`
- Test: `linux/test/desktop_updater_plugin_test.cc`
- Test: `test/macos_updater_manifest_test.dart`

- [ ] **Step 5.1: Preserve macOS native gates**

macOS must keep:

- `/usr/bin/ditto` zip create/extract.
- codesign verification.
- Gatekeeper assessment.
- stapler validation.
- bundle identifier match.
- Team ID match.
- whole `.app` replacement.
- backup rollback.

- [ ] **Step 5.2: Replace Windows copy with directory swap**

Windows helper must:

- wait for the current process to exit.
- verify staging path exists.
- create backup of target app directory contents or preserve old app until replacement succeeds.
- copy or move staged directory into place atomically where possible.
- restore backup or leave old app intact on failure.
- reject removed file paths outside app root.
- honor `DESKTOP_UPDATER_SMOKE_SKIP_RELAUNCH=1`.

- [ ] **Step 5.3: Replace Linux script**

Linux helper must:

- implement `installUpdate(stagingPath, removedFiles)`.
- resolve current executable and app root without relying on current working directory.
- write helper script to a temp path.
- wait for the current process to exit.
- verify staging path exists.
- reject removed file paths outside app root.
- replace the documented directory-bundle app root.
- restore backup or leave old app intact on failure.
- honor `DESKTOP_UPDATER_SMOKE_SKIP_RELAUNCH=1`.

## Task 6: Convert Controller And Public API

**Files:**
- Modify: `lib/updater_controller.dart`
- Modify: `lib/desktop_updater.dart`
- Modify: `lib/widget/update_card.dart`
- Modify: `lib/widget/update_dialog.dart`
- Modify: `lib/widget/update_direct_card.dart`
- Modify: `lib/widget/update_sliver.dart`
- Test: `test/updater_controller_test.dart`
- Test: `test/update_dialog_listener_test.dart`
- Test: `test/desktop_updater_test.dart`

- [ ] **Step 6.1: Add `state` to controller**

Expose:

```dart
UpdateState get state;
```

- [ ] **Step 6.2: Preserve deprecated compatibility getters**

Derive these getters from typed state:

```dart
bool get needUpdate => state is UpdateAvailable || state is UpdateDownloading || state is UpdateReadyToInstall;
bool get isDownloading => state is UpdateDownloading;
bool get isDownloaded => state is UpdateReadyToInstall;
double get downloadProgress;
```

- [ ] **Step 6.3: Keep widget behavior stable**

Widgets may continue reading legacy getters internally during the migration, but new docs must prefer typed state.

## Task 7: Add E2E And Migration Fixtures

**Files:**
- Create: `test/fixtures/release_fixture_builder.dart`
- Create: `test/fixtures/update_server.dart`
- Create: `test/e2e/zip_first_update_flow_test.dart`
- Create: `example/migration/README.md`
- Create: `example/migration/app_archive_v3.json`
- Create: `example/migration/release.json`
- Modify: `example/integration_test/plugin_integration_test.dart`

- [ ] **Step 7.1: Build local fixtures**

Fixture builder must create:

- installed v1 app directory.
- v2 release directory.
- v2 zip artifact.
- v2 `release.json`.
- v2 `app-archive.json`.

- [ ] **Step 7.2: Build fake server**

Fake server must serve:

- valid index.
- valid descriptor.
- valid artifact.
- bad checksum descriptor.
- missing artifact.
- unsupported platform item.
- downgrade item.

- [ ] **Step 7.3: Add e2e tests**

Cover:

- no update when current version is equal.
- update available when build number is newer.
- download emits progress.
- checksum mismatch fails before extraction.
- path traversal inside zip is rejected.
- staging directory is verified.
- install scheduling receives staged path.
- post-install smoke verifies final file contents.

## Task 8: Verification Gates

**Files:**
- All touched files.

- [ ] **Step 8.1: Run package checks**

Run:

```sh
dart format --set-exit-if-changed .
flutter analyze --no-fatal-infos
flutter test --no-pub
dart run desktop_updater:package --help
dart run desktop_updater:verify --help
dart pub publish --dry-run
```

- [ ] **Step 8.2: Run platform integration where available**

Run only where host support exists:

```sh
cd example && flutter test integration_test -d macos
cd example && flutter test integration_test -d windows
cd example && flutter test integration_test -d linux
```

If unavailable, record the exact skipped platform, reason, and required CI runner.

- [ ] **Step 8.3: Final security check**

Confirm:

- no bucket listing.
- no public folder hosting requirement.
- exact URL fetch only.
- length and SHA-256 verification before extraction.
- production authenticity verification path exists.
- safe zip extraction rejects traversal.
- macOS native gates preserved.
- Windows rollback exists.
- Linux no longer depends on CWD.

## Execution Prompt

```text
Use superpowers:subagent-driven-development or superpowers:executing-plans to implement docs/plans/2026-06-11-zip-first-2-0-rewrite-v2-plan.md. Keep canonical docs, source identifiers, JSON fields, method names, and comments in English.

First verify pub.dev live state for desktop_updater with `curl -s https://pub.dev/api/packages/desktop_updater`. If latest stable is still 1.4.0, prepare a stable 1.4.1 maintenance warning release from the isolated 1.4.0 baseline. Local evidence says commit 2b6de3b contains `version: 1.4.0`; do not create, switch, rename, or delete branches unless I explicitly approve that branch action during execution. Ask before creating a detached worktree or using the pub.dev archive. Do not publish until `dart pub publish --dry-run` passes and I explicitly confirm publish.

After the 1.x maintenance lane is isolated, implement the 2.0 zip-first rewrite on the current 2.x development lane. Create docs/2.0-roadmap.md, docs/migration/1.x-to-2.0.md, and docs/migration/agent-prompt.md. Implement the release contract where app-archive.json points to release.json and release.json points to one verified zip artifact. Do not require S3 bucket listing or public folder hosting.

Use one shared Dart core for release index parsing, release descriptor parsing, exact-URL transport, artifact verification, safe zip extraction, staging, typed update state, and orchestration. Avoid duplicated platform logic. Keep native code platform-specific only where it must be: macOS whole .app replacement with ditto/codesign/Gatekeeper/stapler/bundle ID/Team ID gates, Windows locked-file directory replacement with rollback, and Linux installUpdate(stagingPath, removedFiles) without current-working-directory assumptions.

Replace boolean controller state with typed UpdateState while preserving deprecated compatibility getters where feasible. Add unit, widget, native, and e2e tests for check, download, verify, stage, install scheduling, rollback, path traversal, signature/integrity failures, and migration examples. Run the verification gates in the plan. Do not commit, push, publish, or include unrelated files unless I explicitly approve that action.
```

