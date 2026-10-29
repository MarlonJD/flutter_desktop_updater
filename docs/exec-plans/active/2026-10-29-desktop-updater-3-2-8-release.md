# desktop_updater 3.2.8 release

## Context and acceptance

The user authorized a Conventional Commit on existing main, local notarized
macOS E2E, complete exact-candidate CI, pub.dev and GitHub publication, then a
comment and closure of issue 82. Use the MarlonJD GitHub CLI keyring route for
the authorized issue actions; never a connector identity. Preserve unrelated
work and never overwrite a release or move a tag.

Live preflight on 2026-10-29 found latest pub.dev 3.2.7 and GitHub v3.2.7, no
3.2.8 package/tag, and origin/main equal to local main at
`139fc40cc15c5e4cd05161c8b8b1b3cbb49e8ab1`. Existing `general-notary` works
without a keychain override and Developer ID Application signing is available.

## Progress

- [x] Verify registry/tag availability, branch, authentication, and notarization prerequisites.
- [x] Prepare synchronized 3.2.8 versions/changelog and review the complete patch.
- [ ] Commit only release work, pass local release checks, and push main normally.
- [ ] Run a fresh consumer through automatic setup, notarized DMG 1-to-2 update,
  and relaunch using an immutable export of the release candidate.
- [ ] Pass exact-candidate full CI, including macOS native, SwiftPM, and CocoaPods.
- [ ] Publish immutable pub.dev 3.2.8 and matching GitHub tag/release.
- [ ] Verify package inventory/bytes, tag commit, public versions, and links.
- [ ] Post and verify the issue comment, close issue 82, and clean owned fixtures.

## Decision Log

- Include the completed incremental-build/helper-policy and automatic-setup
  changes. Keep strict digest and identity comparisons; edit only the policy
  source and consume its generated pin during a build.
- Use a fresh Flutter consumer, new fixture identity, the automatic helper
  phase, and the documented restart bootstrap. Never copy an old custom helper
  phase or precompute a literal build-phase digest for this proof.
- Export the exact commit without branch operations. Keep app-specific build,
  signing, and fixture settings outside package source. Compare package bytes
  against the commit before and after E2E and against the pub.dev archive.
- Preserve `.gitignore`, the two unrelated 2.x completed plans, and their
  existing index entries. Stage only this task's index additions.
- Use `general-notary` without `--keychain` or `macos.keychain`; do not read,
  recreate, or modify credentials. Retain accepted IDs and artifact hashes.

## Verification and recovery

Evidence lives under `reports/releases/desktop_updater-3.2.8/`. Run version
synchronization, focused Dart/helper tests, and the full `tool/harness_check.dart`
ladder. Require the full hosted matrix for the same commit; resolve actual
failures before publication. An uncertain registry write must be read back
before any retry. Recheck version/tag availability immediately before publishing.

The fresh local E2E must observe both app builds, all four helper fields, stable
policy/digest inputs, Developer ID signatures and entitlements, notarization,
stapling/Gatekeeper acceptance, exact DMG digest, installation, and relaunch of
build 2. Preserve unrelated apps and recovery receipts and remove only owned
processes, mounts, app bundles, and temporary directories.

## Evidence boundaries

The reporter confirmed successful publication, 1-to-2 installation, and normal
file access on 3.2.7 after the manual plist-input repair in
[comment 6496938835](https://github.com/MarlonJD/flutter_desktop_updater/issues/82#issuecomment-6496938835).
That is reporter-confirmed behavior, not local inspection of their application.
The new isolated E2E does not reproduce their original file-selection workflow.
Prior intermittent restart and Flutter-runner timeout observations remain
historical limitations; a successful run does not establish their causes.
Privileged/manual CI lanes require their own credentials and are separate from
same-user notarized DMG replacement. Resource-only privacy bundles remain sealed
by their enclosing code object without independent entitlement extraction.

## Outcomes & Retrospective

Release preparation is in progress.

Focused pre-commit validation passed 103 Dart tests and 6 Swift helper-version
tests. Version synchronization and formatting passed. The macOS native CI lane
now explicitly runs automatic setup and real helper packaging regressions,
which are platform-skipped on Linux. Both originally required signing/verification
commits remain ancestors of main.
