# Issue 84 archive history protection and patch release

## Context and acceptance

The user authorized fixing issue 84, running fresh notarized macOS update E2E
on the maintainer Mac, and publishing the next patch release. Work on existing
main; preserve the unrelated .gitignore change, two old 2.x plans, and their
index links. Publication includes scoped commits, normal pushes, pub.dev, and
an immutable matching GitHub tag/release. No issue comment or closure is
included in this invocation.

Live preflight on 2026-11-03 found local main equal to origin/main at
e646ee46c63114001086f20f8d318518f07ad774. Pub.dev and GitHub latest are 3.2.9.
The existing Developer ID Application identity and general-notary profile are
available. Resolve the profile without a keychain override.

## Progress

- [x] Inspect issue, current source, workspace, registry, and notarization access.
- [x] Add regression tests and observe the original archive-loss behavior.
- [x] Reject ambiguous initial local history before build or output mutation.
- [x] Verify explicit signed history, hosted history, and empty first feeds.
- [x] Document sequential and pre-upload multi-platform publication.
- [x] Synchronize the next unused patch version and review the scoped diff.
- [x] Commit and validate an immutable source export with the full local harness.
- [x] Pass fresh Developer ID/notarized DMG update and relaunch E2E on this Mac.
- [x] Push scoped commits, publish pub.dev/tag/release, and verify archive bytes.
- [x] Complete the ledger and clean only task-owned fixtures/processes.

## Decision Log

- Fail before building when an absent hosted feed and unselected local history
  would otherwise discard items. Do not implicitly trust or merge local data.
- Keep --existing-app-archive verification and hosted byte/revision checks.
  A signed source may be the same path as the output archive because history
  is verified and frozen before writes.
- Use an immutable release export for package validation and the fresh macOS
  consumer. Existing ignored reports must not enter package artifacts or cause
  historical scripts to be reformatted.
- Follow the existing notarized consumer fixture flow: automatic helper setup,
  Hardened Runtime, accepted app and DMG submissions, stapling/Gatekeeper,
  signed local feed, real installation, and a distinct relaunch process.

## Verification and recovery

Evidence belongs in reports/releases/desktop_updater-3.2.10/. Start with focused
release tests, then format/analyze/version checks, the full local harness, and
native helper tests. Keep failed attempts separate. A hosted CI definition or
old release result is not current evidence. Local macOS execution is explicitly
authorized instead of waiting for hosted macOS capacity.

Before publication, recheck version/tag availability, outgoing commits, staged
scope, remote head, and archive inventory. Read back an uncertain external
write before retrying. Never overwrite a version or move an existing tag.

## Surprises & Discoveries

- The local archive writer already retains other platforms. Signed publication
  initializes from verified hosted/explicit history and otherwise starts empty,
  which silently discards a copied local archive during feed initialization.
- Memory's unposted-follow-up note is stale: issue 84 is now posted and linked
  as a sub-issue of 83. Use current GitHub state and authorized scope.

## Outcomes & Retrospective

Published [desktop_updater 3.2.10](https://pub.dev/packages/desktop_updater/versions/3.2.10)
and [GitHub release v3.2.10](https://github.com/MarlonJD/flutter_desktop_updater/releases/tag/v3.2.10)
from immutable commit `3048418d0795ccfd9a9bea046046c9cd503c07db`.
Fix commit `c9c13ef` and the release preparation commit were pushed normally
on existing main. No branch or existing tag changed.

### Validation

- Four new guard cases failed on the old source because publication succeeded
  and discarded local history. After the fix, all 353 focused release CLI,
  archive, layout, and version tests passed, along with 6 Swift helper-version
  tests.
- The full local harness passed on an immutable source export: structural
  31/31, 297 formatted Dart files with no changes, analysis under the existing
  nonfatal-info policy, synchronized versions, 10 documentation tests, 1,076
  Flutter tests passed with 4 skipped, and a zero-warning publish dry run.
- All 155 native macOS tests passed for the release export.
- A real CLI smoke used a loopback HTTP server, real zip packaging, and real
  Ed25519 signatures. Ambiguous local history returned exit 64 and preserved
  the archive bytes without creating release output; explicitly selecting the
  same signed output path returned exit 0 and retained both macOS and Windows
  items with a valid final signature. The Windows input was a synthetic file,
  not a Windows runtime or signed/elevated installer test.
- [Exact-source CI 41574642220](https://github.com/MarlonJD/flutter_desktop_updater/actions/runs/41574642220)
  passed the Dart, documentation, standalone CLI, macOS native, SwiftPM, and
  CocoaPods lanes. Windows and Linux were still running at this observation;
  no failed jobs were observed. This is not a completed full-matrix claim.
  Credentialed privileged/notarized hosted lanes were skipped; notarized E2E
  was explicitly executed on the maintainer Mac instead.

### Fresh notarized macOS E2E

Created a new Flutter consumer using a separate export of the exact release
commit. Automatic helper setup was byte-identical on rerun; both consecutive
app builds retained all four helper metadata fields and unchanged policy
inputs. Developer ID signing, Hardened Runtime, entitlements, strict signature
validation, release trust preflight, stapling, and Gatekeeper checks passed.
The existing general-notary profile was used without a keychain override.

Apple accepted all three fresh submissions:

- App build 1: `ef2f96b0-d718-49d2-91cc-73210582a7a6`.
- App build 2: `f25a881a-bf84-4ae7-a72a-09faf50046e7`.
- Final DMG: `ccdddc32-e95d-499d-91d5-fd722a6ea499`.

The DMG SHA-256 is
`dcad8c1e73153a698e8877d3d7af8f048d03d6353d63481baa58a7499705cadb`.
A signed local feed drove the installed app from 1.0.0+1 to 1.0.0+2. The
original process exited with code 0 and a distinct replacement process emitted
the relaunch marker from the installed application path. The installed build
reported 2 and passed trust checks. This is same-user DMG update/relaunch
verification, not privileged-helper or reporter-environment evidence.

### Publication verification and cleanup

Pub.dev accepted 3.2.10 at `2026-11-03T03:57:06.598526Z`. Downloaded all 869
package files and checked each byte against the release commit. Archive
SHA-256:
`d370ff9004601c4f9f092961912af983155f260ec9973cdc8da13ec3a44ec78a`.
Annotated tag object `2ef63b768fd7f5b1c64f5e65f29ee96ac21c26f3` resolves to the
release commit locally and remotely. GitHub published the stable release at
`2026-11-03T03:57:36Z`; both latest pointers resolve to 3.2.10 and the release
notes were read back exactly.

Removed only the owned installed app and two temporary source/build roots
after verification. The E2E stopped its app/feed processes, no owned disk-image
mount remained, and the unrelated recovery receipt and original workspace edits
were preserved. Retained logs, JSON receipts, the QA DMG, and the pub.dev archive
under the ignored evidence directory. No generated binaries or logs entered
the commits. No browser automation, GitHub issue comment, or issue-state write
was performed for this release.
