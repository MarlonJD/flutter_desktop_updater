# macOS Updater Packaging And Extraction Plan

Date: 2026-05-31

Owner subtree: root package, `bin/`, `lib/src/`, `macos/`, `test/`, and `README.md`

## Goal

Replace the macOS raw `.app` tree update path with a manifest-driven flow that publishes only a release manifest, content-addressed compressed payloads, and a `ditto`-created full ZIP fallback archive. Runtime staging must build a complete `.app`, verify it, and hand it to the native helper for whole-bundle replacement.

## Assumptions And Open Questions

- Existing Windows and Linux `hashes.json` behavior should remain compatible.
- macOS release artifacts are produced on macOS from a signed, notarized, stapled app bundle.
- The existing method-channel API can keep passing a staged path if the macOS helper reads expected metadata from the staged app's sidecar manifest.
- Actual signing, notarization, and stapling happen before `desktop_updater:archive macos`.

## Scope

- Add a macOS v2 release manifest with file and symlink entries.
- Generate SHA-256 based gzip payloads for regular files.
- Generate full fallback ZIPs with `/usr/bin/ditto -c -k --keepParent --sequesterRsrc`.
- Extract full fallback ZIPs with `/usr/bin/ditto -x -k` into a fresh staging directory.
- Recreate symlinks from manifest target strings and reject unsafe symlink targets.
- Verify hashes, file modes, symlink targets, and unexpected files in staged apps.
- Run macOS replacement gates before replacing the installed app.
- Replace the installed macOS `.app` as a complete staged bundle, not by patching live `Contents`.
- Add tests for framework symlink preservation and manifest validation failures.
- Update release documentation.

## Non-Goals

- Do not introduce Sparkle or any third-party updater framework.
- Do not redesign the update UI.
- Do not change Windows or Linux artifact formats beyond preserving existing behavior.
- Do not implement signing, notarization, or stapling itself.

## Steps

1. Add manifest models and macOS packaging/staging helpers.
2. Update macOS archive/release CLI behavior to output only manifest, payloads, and full ZIP fallback.
3. Update macOS runtime update preparation and staging to use the v2 manifest.
4. Update the macOS native helper to verify and replace a whole staged `.app`.
5. Add regression and safety tests.
6. Update README release documentation.
7. Run `dart format`, `flutter test` or the closest available test command, then commit and push relevant files.

## Verification Gates

- `dart format --set-exit-if-changed` after formatting.
- `flutter test` for package tests.
- macOS-specific tests must cover default ZIP dereferencing, `ditto` preservation, unsafe symlinks, bad hashes, broken manifests, wrong bundle ID, and wrong team ID.

## Risks

- Unsigned local example apps cannot pass production macOS gates; tests should fake command execution for metadata gate failures.
- Existing consumers publishing macOS raw trees must update their release process.
- Whole-bundle replacement still needs write permission to the installed app's parent directory.

## Rollback Or Recovery

- Keep Windows and Linux on the previous `hashes.json` flow.
- If a staged macOS replacement fails, the helper keeps the old app backup and attempts to restore it before relaunch.
- Full ZIP fallback remains available if delta staging fails before replacement.

## Affected Files Or Docs

- `bin/archive.dart`
- `bin/release.dart`
- `lib/src/app_archive.dart`
- `lib/src/app_paths.dart`
- `lib/src/file_hash.dart`
- `lib/src/prepare.dart`
- `lib/src/update.dart`
- `lib/src/version_check.dart`
- new macOS manifest/helper files under `lib/src/`
- `macos/desktop_updater/Sources/desktop_updater/DesktopUpdaterPlugin.swift`
- macOS updater tests under `test/`
- `README.md`
- `CHANGELOG.md`

## Execution Prompt

Use `$google-eng-practices` and implement the saved plan at `docs/plans/2026-05-31-macos-updater-packaging-plan.md`. Keep source identifiers, comments, and canonical docs in English. For macOS, publish only release manifests, content-addressed compressed payloads, and a full `ditto` ZIP fallback; never publish a raw `.app` tree. Stage complete `.app` bundles into temporary directories, verify manifest integrity and Apple signing/notarization/stapling gates, then replace the installed app as a whole bundle. Add the requested symlink, manifest, hash, bundle ID, and team ID tests. Run `flutter test` or the closest documented package command, then commit only relevant files with a Conventional Commit message and author `marlonjd <burak.karahan@mail.ru>`, and push immediately.
