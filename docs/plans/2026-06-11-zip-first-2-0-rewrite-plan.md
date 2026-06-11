# Desktop Updater 2.0.0 Zip-First Rewrite Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a reliable 2.0.0 final rewrite whose default update path is zip-first, private-bucket friendly, fully verified, and easy for existing 1.x users to migrate to with agentic coding tools.

**Architecture:** Split the updater into a small pure Dart core, transport adapters, artifact packaging and verification, and native platform installers. The default release contract becomes version index -> release descriptor -> single verified zip artifact; delta updates can be added later as an optional optimization without being the primary install path.

**Tech Stack:** Dart 3.6+, Flutter desktop plugins, MethodChannel platform adapters, `archive` for non-macOS zip handling, `/usr/bin/ditto` for macOS app zip creation and extraction, `crypto`/`cryptography_plus` for hashes and signatures, Flutter test, native Windows/Linux plugin tests, and desktop integration smoke tests.

---

Date: 2026-06-11

Owner subtree: root package, `bin/`, `lib/`, `macos/`, `windows/`, `linux/`, `example/`, `test/`, `README.md`, `CHANGELOG.md`, and `docs/`

## Context

The package is currently published on pub.dev with stable `1.4.0` as the latest stable version and `2.0.0-dev.5` as the latest dev version, checked against the pub.dev package API on 2026-06-11. Before any publish step, verify pub.dev again because published versions are live external state.

The existing 2.0.0 dev line already improved macOS safety with release manifests, content-addressed payloads, full zip fallback, symlink handling, and native gate checks. The final rewrite changes the product contract: zip-first is the default for every platform, open folder hosting is no longer required, and migration guidance is explicit.

## Goals

- Publish a 1.x maintenance release that warns users that 2.x is under active development and that a migration path is coming.
- Add a GitHub-readable roadmap page that explains what will change in 2.0.0 final and why.
- Add a migration guide that humans and tools such as Codex, Claude Code, and Antigravity can follow.
- Redesign the 2.0.0 update contract around one verified zip artifact per platform/version/channel.
- Keep S3/private bucket usage clean: no bucket listing, no public folder requirement, exact artifact URLs only, and signed URL/CDN support.
- Make installer behavior testable and platform-specific without hiding risky file-system operations inside UI/controller code.
- Add e2e coverage for check -> download -> verify -> stage -> install scheduling -> post-install verification.

## Non-Goals

- Do not publish 2.0.0 final until the zip-first flow has passed the verification gates in this plan.
- Do not rely on S3 public folder listing or public object enumeration.
- Do not introduce Sparkle, WinSparkle, Squirrel, or another updater framework in this rewrite.
- Do not preserve the 2.0.0-dev macOS content-addressed payload format as the default release format.
- Do not change package ownership or publish credentials.
- Do not run `dart pub publish` without an explicit human confirmation at execution time.

## Recommended Version Strategy

- `1.4.1`: maintenance release for existing stable users.
  - Purpose: docs and CLI warning only.
  - Compatibility: no behavior-breaking API or artifact format changes.
  - Required message: "WARNING: desktop_updater 2.x is in active development and will move to a zip-first release format. See docs/2.0-roadmap.md and docs/migration/1.x-to-2.0.md before adopting 2.x."
- `2.0.0-dev.6` or next dev version: optional rewrite preview once the new zip-first core exists.
- `2.0.0`: final release after all migration docs, e2e tests, and platform smoke gates pass.

If `1.4.1` is no longer the next valid stable patch at execution time, choose the next patch above the latest stable version on pub.dev.

## Release Contract

### Version Index

`app-archive.json` remains the small public or signed index file that the app checks first.

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

### Release Descriptor

`release.json` points to one zip artifact and carries integrity metadata.

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
  "minimumUpdaterVersion": "2.0.0",
  "generatedAt": "2026-06-11T00:00:00Z"
}
```

The release descriptor must not require clients to list S3 objects. The artifact URL can be a public CDN URL, a signed S3 URL, or a private proxy URL.

### Zip Rules

- macOS: create zip artifacts with `/usr/bin/ditto -c -k --keepParent --sequesterRsrc <App.app> <App.zip>`.
- macOS: extract only with `/usr/bin/ditto -x -k <App.zip> <staging-dir>`.
- Windows: zip the complete release directory and install by replacing the app directory after the process exits.
- Linux: choose one supported strategy for 2.0.0 final:
  - directory bundle zip, or
  - AppImage zip.
- Every platform: verify zip length and SHA-256 before extraction, extract into a fresh staging directory, verify the staged result before scheduling install.

## File Structure

Create or reshape the implementation around these files.

- Create: `lib/src/core/update_client.dart`
  - Owns check, download, verify, stage, and install orchestration.
- Create: `lib/src/core/update_state.dart`
  - Defines typed states: `idle`, `checking`, `available`, `downloading`, `readyToInstall`, `installing`, `failed`.
- Create: `lib/src/core/release_index.dart`
  - Parses `app-archive.json` schema v3 and keeps backward-compatible parsing for v1/v2 where possible.
- Create: `lib/src/core/release_descriptor.dart`
  - Parses and validates `release.json`.
- Create: `lib/src/core/artifact_verifier.dart`
  - Verifies length, SHA-256, and optional signature.
- Create: `lib/src/io/update_transport.dart`
  - Defines HTTP/file transport interfaces.
- Create: `lib/src/io/http_update_transport.dart`
  - Downloads exact URLs with progress, timeout, cancellation, and retry policy.
- Create: `lib/src/io/file_update_transport.dart`
  - Supports local-file fixtures and offline e2e tests.
- Create: `lib/src/package/release_packager.dart`
  - Shared package command logic.
- Create: `lib/src/package/zip_release_packager.dart`
  - Builds platform zip artifacts and release descriptors.
- Create: `lib/src/platform/platform_installer.dart`
  - Defines platform install contract.
- Create: `lib/src/platform/macos_installer.dart`
  - Whole `.app` staging, identity verification, codesign, Gatekeeper, stapler, helper scheduling.
- Create: `lib/src/platform/windows_installer.dart`
  - Whole directory staging, locked-file replacement helper, rollback manifest.
- Create: `lib/src/platform/linux_installer.dart`
  - Staging and replacement for the chosen Linux strategy.
- Modify: `lib/updater_controller.dart`
  - Convert boolean state to typed state while keeping deprecated 1.x-style getters where feasible.
- Modify: `lib/desktop_updater.dart`
  - Expose the new high-level API and preserve compatibility wrappers with deprecation notices.
- Modify: `bin/release.dart`
  - Keep or replace with a thin wrapper that prints the 1.x/2.x warning when running from a maintenance build.
- Modify: `bin/archive.dart`
  - Keep or replace with a thin wrapper that prints the 1.x/2.x warning when running from a maintenance build.
- Create: `bin/package.dart`
  - Generates zip-first release artifacts for 2.x.
- Create: `bin/verify.dart`
  - Verifies a release descriptor plus zip artifact before publishing.
- Create: `bin/smoke_update.dart`
  - Runs a local fake-server smoke test against a fixture app.
- Create: `docs/2.0-roadmap.md`
  - GitHub-readable page explaining the 2.0.0 plan and release contract.
- Create: `docs/migration/1.x-to-2.0.md`
  - Human and agent-friendly migration guide.
- Create: `docs/migration/agent-prompt.md`
  - Copy-paste prompts for Codex, Claude Code, and Antigravity migrations.
- Create: `test/fixtures/update_server.dart`
  - Local test server for e2e flows.
- Create: `test/fixtures/release_fixture_builder.dart`
  - Builds v1/v2 app fixtures and release descriptors.
- Create: `test/e2e/zip_first_update_flow_test.dart`
  - Exercises check, download, verify, stage, install scheduling, and post-install verification.

## Phase 0: 1.x Maintenance Warning Release

**Purpose:** protect current stable users and set expectations before the 2.0.0 final rewrite lands.

- [ ] Step 0.1: Verify current pub.dev versions.

Run:

```sh
curl -s https://pub.dev/api/packages/desktop_updater
```

Expected: latest stable is read from the `latest.version` field. On 2026-06-11 it was `1.4.0`; if still true, prepare `1.4.1`.

- [ ] Step 0.2: Prepare the 1.x maintenance source.

If the local repository has no `1.4.0` tag, find the commit with:

```sh
git log --all --oneline -S "version: 1.4.0" -- pubspec.yaml
```

If no matching commit exists locally, use the pub.dev `1.4.0` archive as the maintenance baseline, then commit the maintenance patch back to the repository after human approval of any branch operation.

- [ ] Step 0.3: Add the CLI warning banner.

Add this exact warning text to the start of every 1.x CLI command in `bin/`:

```text
WARNING: desktop_updater 2.x is in active development and will move to a zip-first release format. The current 1.x folder-based release flow remains supported for 1.x, but new projects should review docs/2.0-roadmap.md and docs/migration/1.x-to-2.0.md before adopting 2.x.
```

Print it to stderr so CI logs show it without changing normal stdout parsing.

- [ ] Step 0.4: Add README and CHANGELOG entries.

`README.md` must link to:

```markdown
- [2.0 roadmap](docs/2.0-roadmap.md)
- [1.x to 2.0 migration guide](docs/migration/1.x-to-2.0.md)
```

`CHANGELOG.md` must include:

```markdown
## 1.4.1

* Added CLI warnings and documentation links for the upcoming 2.0 zip-first updater rewrite.
* No runtime update behavior changed for 1.x users.
```

- [ ] Step 0.5: Verify and publish the maintenance release.

Run:

```sh
dart format --set-exit-if-changed .
flutter analyze --no-fatal-infos
flutter test --no-pub
dart pub publish --dry-run
```

Expected: dry run passes. Then ask for explicit human confirmation before:

```sh
dart pub publish
```

## Phase 1: Roadmap And Migration Documentation

- [ ] Step 1.1: Create `docs/2.0-roadmap.md`.

The page must include:

- Current state: 1.x stable, 2.x dev.
- Why zip-first replaces open folder hosting.
- New release contract: `app-archive.json` -> `release.json` -> verified zip artifact.
- S3/private bucket guidance: no listing, exact URLs, signed URL support.
- Platform behavior: macOS whole app bundle, Windows whole app directory, Linux chosen strategy.
- Testing plan and release milestones.
- Compatibility status for 1.x users.

- [ ] Step 1.2: Create `docs/migration/1.x-to-2.0.md`.

The guide must include:

- Before/after JSON examples.
- How to replace folder upload with zip artifact upload.
- How to create `release.json`.
- How to update app code from old controller boolean state to typed state.
- How to keep 1.x installed apps on 1.x until ready.
- How to validate migration with `bin/verify.dart` and `bin/smoke_update.dart`.
- Troubleshooting for S3, CDN caching, checksum mismatch, macOS signing, Windows locked files, and Linux permissions.

- [ ] Step 1.3: Create `docs/migration/agent-prompt.md`.

Include this copy-paste prompt:

```text
You are migrating a Flutter desktop app from desktop_updater 1.x to desktop_updater 2.x. Read docs/migration/1.x-to-2.0.md and the app's current update publishing scripts. Replace folder-based update publishing with the zip-first release contract: app-archive.json points to release.json, release.json points to one verified zip artifact. Keep existing app UI behavior where possible, update controller usage to the typed 2.x state API, add a local fake-server smoke test, and do not publish artifacts until dart run desktop_updater:verify and the smoke test pass.
```

## Phase 2: Zip-First Core

- [ ] Step 2.1: Write unit tests for schema v3 index parsing in `test/release_index_test.dart`.
- [ ] Step 2.2: Implement `ReleaseIndex` and `ReleaseIndexItem` in `lib/src/core/release_index.dart`.
- [ ] Step 2.3: Write unit tests for release descriptor validation in `test/release_descriptor_test.dart`.
- [ ] Step 2.4: Implement `ReleaseDescriptor`, `ReleaseArtifact`, and validation in `lib/src/core/release_descriptor.dart`.
- [ ] Step 2.5: Write verifier tests for length mismatch, SHA-256 mismatch, missing file, unsupported scheme, and path traversal.
- [ ] Step 2.6: Implement `ArtifactVerifier` in `lib/src/core/artifact_verifier.dart`.
- [ ] Step 2.7: Add typed state tests in `test/update_state_test.dart`.
- [ ] Step 2.8: Implement `UpdateState` and convert `DesktopUpdaterController` to derive legacy getters from typed state.

## Phase 3: Transport And Packaging CLI

- [ ] Step 3.1: Add HTTP and file transport tests with progress and cancellation.
- [ ] Step 3.2: Implement `UpdateTransport`, `HttpUpdateTransport`, and `FileUpdateTransport`.
- [ ] Step 3.3: Add package command tests that create a zip artifact and `release.json`.
- [ ] Step 3.4: Implement `bin/package.dart` and shared packaging helpers.
- [ ] Step 3.5: Add verify command tests for good and bad artifacts.
- [ ] Step 3.6: Implement `bin/verify.dart`.
- [ ] Step 3.7: Update `README.md` so new docs point to `package` and `verify`, while old `release` and `archive` commands are marked legacy.

## Phase 4: Platform Installers

- [ ] Step 4.1: macOS tests.

Cover:

- ditto zip preserves framework symlinks.
- normal zip is rejected for `.app` bundles.
- staged app hash mismatch fails.
- wrong bundle identifier fails.
- wrong Team ID fails.
- unsigned, unstapled, or Gatekeeper-rejected app fails in production mode.

- [ ] Step 4.2: macOS implementation.

Use whole-bundle replacement only. Verify identity from the currently installed app, then verify the staged app before scheduling helper replacement.

- [ ] Step 4.3: Windows tests.

Cover:

- helper script receives staging path.
- removed files cannot escape app root.
- failed copy restores backup or leaves old app intact.
- relaunch can be skipped for smoke tests with an environment variable.

- [ ] Step 4.4: Windows implementation.

Replace ad hoc file copy with a staged directory replacement flow and explicit rollback behavior.

- [ ] Step 4.5: Linux tests.

Cover:

- `installUpdate` is implemented.
- staging path is required.
- update script does not depend on current working directory.
- removed files cannot escape app root.
- selected Linux strategy is documented and enforced.

- [ ] Step 4.6: Linux implementation.

Implement the same `installUpdate(stagingPath, removedFiles)` contract as macOS and Windows.

## Phase 5: E2E And Smoke Harness

- [ ] Step 5.1: Add `test/fixtures/release_fixture_builder.dart`.

The fixture builder must create:

- installed v1 app directory,
- v2 release directory,
- v2 zip artifact,
- v2 `release.json`,
- v2 `app-archive.json`.

- [ ] Step 5.2: Add `test/fixtures/update_server.dart`.

The fake server must serve:

- valid index,
- valid descriptor,
- valid artifact,
- bad checksum descriptor,
- missing artifact,
- unsupported platform item,
- downgrade item.

- [ ] Step 5.3: Add `test/e2e/zip_first_update_flow_test.dart`.

Required cases:

- no update when current version is equal,
- update available when build number is newer,
- download emits progress,
- checksum mismatch fails before extraction,
- path traversal inside zip is rejected,
- staging directory is verified,
- install scheduling receives staged path,
- post-install smoke can verify final file contents.

- [ ] Step 5.4: Add example app integration tests.

Run per platform:

```sh
cd example
flutter test integration_test -d macos
flutter test integration_test -d windows
flutter test integration_test -d linux
```

Use platform-appropriate CI runners; skip unavailable devices explicitly with a documented reason.

## Phase 6: Compatibility And Migration Finish

- [ ] Step 6.1: Add deprecated compatibility wrappers for 1.x controller getters.
- [ ] Step 6.2: Add migration examples under `example/migration/`.
- [ ] Step 6.3: Add `docs/migration/agent-prompt.md` links from README and roadmap.
- [ ] Step 6.4: Add a final "Can I migrate now?" checklist to the migration guide.
- [ ] Step 6.5: Mark the old folder-based flow as legacy and supported only for 1.x.

## Phase 7: Release Gates

Run these before any 2.0.0 final publish:

```sh
dart format --set-exit-if-changed .
flutter analyze --no-fatal-infos
flutter test --no-pub
cd example && flutter test integration_test -d macos
cd example && flutter test integration_test -d windows
cd example && flutter test integration_test -d linux
dart run desktop_updater:package --help
dart run desktop_updater:verify --help
dart pub publish --dry-run
```

If a platform integration command cannot run on the current host, record the exact skipped platform, reason, and CI runner that covers it.

## Risks

- Publishing to pub.dev is irreversible for a version number. Always run `dart pub publish --dry-run` first and ask for explicit publish confirmation.
- macOS zip handling must remain `ditto` based or framework symlinks and metadata can break.
- Windows locked files need helper-level retry and rollback.
- Linux packaging varies by distribution; choosing one supported strategy is safer than pretending every packaging style works.
- Signed URLs can expire during long downloads; descriptor and transport errors must make this obvious.
- CDN caching can serve stale `app-archive.json`; docs must recommend cache policy for index, descriptor, and artifact separately.

## Rollback Or Recovery

- If 1.4.1 warning release has an issue, publish a new 1.4.x patch with corrected warning/docs; do not yank unless a severe package issue requires it.
- If 2.0.0 dev zip-first work regresses, keep 1.x stable docs visible and do not promote 2.0.0 final.
- If a staged install fails, leave the installed app intact and clean staging on next launch.
- If a package artifact is corrupt after publication, publish a corrected release descriptor pointing to a new artifact URL and new checksum; do not mutate an already cached artifact under the same URL.

## Affected Files Or Docs

- `pubspec.yaml`
- `CHANGELOG.md`
- `README.md`
- `bin/archive.dart`
- `bin/release.dart`
- `bin/package.dart`
- `bin/verify.dart`
- `bin/smoke_update.dart`
- `lib/desktop_updater.dart`
- `lib/updater_controller.dart`
- `lib/src/core/*`
- `lib/src/io/*`
- `lib/src/package/*`
- `lib/src/platform/*`
- `macos/desktop_updater/Sources/desktop_updater/DesktopUpdaterPlugin.swift`
- `windows/desktop_updater_plugin.cpp`
- `linux/desktop_updater_plugin.cc`
- `test/*`
- `test/e2e/*`
- `test/fixtures/*`
- `example/integration_test/*`
- `docs/2.0-roadmap.md`
- `docs/migration/1.x-to-2.0.md`
- `docs/migration/agent-prompt.md`

## Execution Prompt

Use `$google-eng-practices` and `superpowers:executing-plans` or `superpowers:subagent-driven-development` to implement the saved plan at `docs/plans/2026-06-11-zip-first-2-0-rewrite-plan.md`. Keep canonical docs and source identifiers in English. First verify pub.dev live state for `desktop_updater`; prepare a stable 1.x maintenance warning release from the latest stable baseline, expected `1.4.1` if `1.4.0` is still latest stable, and do not publish until `dart pub publish --dry-run` passes and the user explicitly confirms publish. Then create `docs/2.0-roadmap.md`, `docs/migration/1.x-to-2.0.md`, and `docs/migration/agent-prompt.md`. Implement the 2.0.0 zip-first release contract where `app-archive.json` points to `release.json` and `release.json` points to one verified zip artifact; do not require S3 bucket listing or public folder hosting. Replace boolean controller state with typed update state while preserving deprecated compatibility getters where feasible. Add unit, widget, native, and e2e tests for check, download, verify, stage, install scheduling, rollback, and migration examples. Run the verification gates listed in the plan. Do not create, switch, rename, or delete branches unless the user explicitly approves that branch action during execution; do not commit, push, or publish unrelated files.
