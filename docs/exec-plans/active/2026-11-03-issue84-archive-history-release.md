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
- [ ] Commit and validate an immutable source export with the full local harness.
- [ ] Pass fresh Developer ID/notarized DMG update and relaunch E2E on this Mac.
- [ ] Push scoped commits, publish pub.dev/tag/release, and verify archive bytes.
- [ ] Complete the ledger and clean only task-owned fixtures/processes.

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

Four guard cases failed on the original source because publishing succeeded
and discarded local history. After the fix, the release CLI/archive/version
focused suite passed. The guard covers signed/unsigned local records and
default/custom Unicode output paths before any build or output mutation.
Explicit signed history at the output path, empty first-feed indexes, hosted
cross-platform history, and mismatched snapshot rejection are covered.
Version 3.2.10 is unused on pub.dev and locally; publication remains pending.
