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
- [x] Commit only release work, pass local release checks, and push main normally.
- [x] Run a fresh consumer through automatic setup, notarized DMG 1-to-2 update,
  and relaunch using an immutable export of the release candidate.
- [x] Pass exact-candidate full CI, including macOS native, SwiftPM, and CocoaPods.
- [x] Publish immutable pub.dev 3.2.8 and matching GitHub tag/release.
- [x] Verify package inventory/bytes, tag commit, public versions, and links.
- [x] Post and verify the issue comment, close issue 82, and clean owned fixtures.

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

Published package 3.2.8 and annotated tag `v3.2.8` at immutable release commit
`d8db11f065bc8140b8cbbd338562db52f7928744`
(`chore(release): prepare desktop_updater 3.2.8`). Both originally required
signing/verification commits remain ancestors. Main was pushed normally without
branch operations or unrelated changes.

### Validation

- Focused pre-commit validation passed 103 Dart tests and 6 Swift helper-version
  tests. Version synchronization and formatting passed.
- `FLUTTER_ROOT=/Users/marlonjd/Developer/flutter dart run tool/harness_check.dart`
  passed structural checks (31/31), formatting, analysis with existing nonfatal
  infos, version synchronization, 10 documentation tests, 1,054 Flutter tests
  (4 skipped), and a zero-warning publication dry run.
- The full test suite generated .NET fixture `bin/` and `obj/` directories that
  were included by the first dry run. Removed only those generated outputs and
  repeated `dart pub publish --dry-run`; it passed with zero warnings. Compared
  all 869 resulting package files byte-for-byte with the release commit before
  publication.
- [Exact-candidate CI 40881159986](https://github.com/MarlonJD/flutter_desktop_updater/actions/runs/40881159986)
  passed all 13 standard jobs, including Windows, Linux, macOS native, and both
  macOS Flutter integration lanes (SwiftPM and CocoaPods). Four credential-gated
  privileged/notarization jobs were skipped. The native macOS lane now explicitly
  runs automatic setup and real helper packaging regressions that are
  platform-skipped on Linux.

### Fresh notarized consumer E2E

Created a fresh Flutter consumer from `git archive` of the release commit with
fixture identity `com.example.desktopUpdaterRelease328`. `helper-policy`
configured the managed helper phase; rerunning setup was byte-identical. The
phase resolved the package through `helper-embed` and consumed the reviewed
policy and digest. Both consecutive app builds retained all four helper fields
and unchanged policy inputs, and passed real release trust preflight.

Developer ID Application signing, Hardened Runtime, timestamp, entitlements,
strict signature validation, stapling, and Gatekeeper checks passed for both
app builds and the final DMG. Apple accepted these submissions through the
existing `general-notary` profile without a keychain override:

- Build 1: `ce5f6d5e-ebca-48be-b232-56e356eb757d`.
- Build 2: `900d1944-fd95-43d3-bfed-3119e36f57fa`.
- DMG: `0fd6e8ca-22ab-48ce-ba27-c9d0cb78775e`.

The final DMG SHA-256 is
`5a6b12b2c34ca7fc6f1e120a5a4009bf0d994c900d26f9c64026ca647ee9deb2`.
The signed local feed drove the installed 1.0.0+1 app through DMG replacement
and relaunch as 1.0.0+2. The original process (PID 81449) exited with code 0;
replacement PID 81490 emitted the relaunch marker from the installed app path.
The installed bundle reported build 2 and passed trust checks. Package source
and the unrelated existing example recovery receipt remained unchanged.

The initial fixture submission
`df5a7fc6-bec4-43f8-887d-7aaaba70129c` was rejected because the fresh Runner
template did not enable Hardened Runtime. Apple identified both executable
architectures. Rebuilt the owned fixture with `ENABLE_HARDENED_RUNTIME=YES`
and reran the complete passing test without changing package source. The
rejection and passing results are retained separately. A rebuild command first
ran from the repository instead of the consumer and failed to find its Xcode
workspace; the corrected consumer-directory invocation succeeded.

### Publication and issue closure

- `dart pub publish --force` uploaded 3.2.8 at
  `2026-10-29T13:44:35.212358Z`.
- [pub.dev 3.2.8](https://pub.dev/packages/desktop_updater/versions/3.2.8)
  exposes an archive whose 869 files match the release commit exactly. Archive
  SHA-256: `973cb2de51fe7e92a4f3b7341c86db821208b05bd59c1d11fb2cf8b97c9640c6`.
- Created and normally pushed annotated tag `v3.2.8`, tag object
  `307fa02e36bcec029cad3930b3eab102f48fd84c`. Local and remote tag resolution
  both identify the release commit; no existing tag was moved.
- [GitHub release](https://github.com/MarlonJD/flutter_desktop_updater/releases/tag/v3.2.8)
  ID `427920688` is public and stable, with the prepared notes. Verified the
  version-specific pub.dev link, GitHub release, tagged README, and changelog.
  Both pub.dev and GitHub latest pointers resolve to 3.2.8. The pub.dev latest
  cache initially returned 3.2.7 and then converged; publication was not retried.
- Posted and read back [comment 6498408036](https://github.com/MarlonJD/flutter_desktop_updater/issues/82#issuecomment-6498408036)
  through the MarlonJD CLI keyring identity. Closed issue 82 as completed at
  `2026-10-29T13:46:59Z`; API readback confirmed the state, reason, and actor.

Retained the notarized test DMG, accepted/rejected Apple responses, build and
update logs, policy/project evidence, CI receipt, package archive and inventory,
and publication/issue receipts under the ignored release report directory.
Removed the uniquely identified installed fixture, temporary export and build
directories, owned failed result bundle, and generated test outputs. No owned
test process or DMG mount remained. Preserved unrelated `.gitignore` changes,
the two 2.x plans, and their existing index entries.

Release-ledger structural validation and all 10 focused documentation tests
passed. This record closes the release task; the immutable release tag remains
on the tested package commit rather than the documentation closure commit.
