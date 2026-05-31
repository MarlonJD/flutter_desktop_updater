# macOS Artifact Hardening Plan

Date: 2026-06-01

Owner subtree: root package, `bin/`, `lib/src/`, `macos/`, `test/`, and `README.md`

## Goal

Tighten the macOS updater artifact change before merging by clarifying the release artifact model, separating build from notarized artifact generation, enforcing manifest invariants, and making runtime trust decisions use the installed app identity instead of remote metadata.

## Assumptions And Open Questions

- The active branch is `macos-updater-packaging`.
- macOS release artifacts are generated after the app has been signed, notarized, and stapled.
- The artifact directory, not a raw `.app` tree and not a ZIP-only release, is the published unit.
- The existing untracked `AGENTS.md` file is user/local context and should not be staged.

## Scope

- Explain why macOS publishes an artifact directory containing `release-manifest.json`, `payloads/`, and the full fallback ZIP.
- Change macOS `release` CLI behavior so it builds only and points users to sign/notarize/staple before `archive`.
- Add macOS `archive` flags for an explicit signed app path, channel, and output directory.
- Enforce `payloads/<sha256>.gz` in release manifests.
- Reject unsafe symlink targets during manifest parsing as well as staging.
- Verify the target manifest bundle ID and Team ID against the currently installed app identity before staging/replacement.
- Make the native macOS helper derive expected bundle ID and Team ID from the installed app before replacement, not from the remote manifest sidecar.
- Add focused tests for the new manifest and identity checks.
- Rewrite the branch commit message to `feat(macos)!` because the macOS release contract changes.

## Non-Goals

- Do not introduce Sparkle or any third-party updater framework.
- Do not redesign the UI.
- Do not change Windows or Linux artifact formats.
- Do not implement notarization itself.

## Steps

1. Harden manifest validation for payload paths and symlink targets.
2. Add installed-app identity verification and use it in macOS staging and native replacement.
3. Split macOS release build from macOS artifact generation in the CLI.
4. Update README and changelog wording around artifact directories and ZIP fallback.
5. Add focused tests for bad payload paths, unsafe symlink manifests, and installed identity mismatch.
6. Run `flutter test --no-pub` and `flutter analyze --no-fatal-infos`.
7. Amend the branch into a `feat(macos)!` commit with the required author and force-push with lease to `macos-updater-packaging`.

## Verification Gates

- `flutter test --no-pub`
- `flutter analyze --no-fatal-infos`
- Manual diff review for staged files only; leave untracked local guidance files untouched.

## Risks

- Existing macOS release scripts may need to pass `--app` to `desktop_updater:archive` if they sign/notarize outside the default Flutter build output.
- Rewriting the branch commit changes the commit SHA, but the branch is already a feature branch created for this work.

## Rollback Or Recovery

- If the hardened CLI flow blocks a valid release path, keep the explicit `--app` archive path as the supported escape hatch.
- If force-push fails, leave the corrected commit on the local branch and report the exact push failure.

## Affected Files Or Docs

- `bin/archive.dart`
- `bin/release.dart`
- `lib/src/macos_update.dart`
- `lib/src/release_manifest.dart`
- `macos/desktop_updater/Sources/desktop_updater/DesktopUpdaterPlugin.swift`
- `test/macos_updater_manifest_test.dart`
- `README.md`
- `CHANGELOG.md`

## Execution Prompt

Use `$google-eng-practices` and implement the saved plan at `docs/plans/2026-06-01-macos-artifact-hardening-plan.md` on branch `macos-updater-packaging`. Keep identifiers, comments, and docs in English. Preserve the macOS artifact directory model (`release-manifest.json`, `payloads/`, full `ditto` ZIP fallback), enforce manifest invariants, verify runtime identity against the installed app, update CLI/docs/tests, run `flutter test --no-pub` and `flutter analyze --no-fatal-infos`, then amend the branch commit to `feat(macos)!: use manifest and ditto artifacts for updates` with author `marlonjd <burak.karahan@mail.ru>` and push the same branch.
