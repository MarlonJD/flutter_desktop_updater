# desktop_updater 3.2.9 release

## Context and acceptance

The user authorized committing and pushing the issue 83 fix, publishing the
next patch release, and replying to the reporter. Use the existing main branch
and the MarlonJD GitHub CLI keyring identity. Preserve unrelated local changes,
never overwrite a published version, and never move an existing tag.

Live preflight found pub.dev and GitHub latest at 3.2.8, no 3.2.9 package/tag,
and local main equal to origin/main at
`826c14fb993c86f284e6cd434cf0306de1879714`. The issue fix is committed as
`7560b6a` and its local evidence is in the
[completed issue plan](../completed/2026-11-02-issue83-flutter-inno-executable.md).

## Progress

- [x] Check branch/history, remote head, registry/tag availability, and auth.
- [x] Commit only the two source files, three regression test files, and docs.
- [x] Synchronize release versions, changelog, README, and version assertions.
- [x] Pass focused validation: 98 Dart tests and 6 Swift helper version tests.
- [ ] Pass the complete local harness for the immutable release candidate.
- [ ] Commit the scoped release metadata and push main without force.
- [ ] Wait for the exact release commit's full standard CI matrix.
- [ ] Publish immutable pub.dev 3.2.9 and matching GitHub tag/release.
- [ ] Verify package archive bytes, tag identity, versions, and public links.
- [ ] Post and read back the reporter comment through MarlonJD's CLI account.
- [ ] Close this release ledger and clean only owned temporary outputs.

## Decision Log

- Ship issue 83's Flutter Windows executable resolution, actionable input
  diagnostics, and validation before output-directory creation. Retain the
  existing explicit executable override and all executable identity checks.
- The first commit contains the fix and the second synchronizes release
  versions. Preserve the unrelated .gitignore edit, two old 2.x plans, and their
  index entries through selective staging.
- Require the exact candidate's standard Windows, Linux, macOS, and CLI CI
  lanes. Signed/elevated Inno installation and fresh notarized macOS E2E are
  separate evidence boundaries for this Dart release-CLI fix.
- Publish the Dart package and release notes only; standalone CLI artifacts
  remain candidate-only outputs of their existing CI lanes.
- Keep the issue open for reporter confirmation; the requested action is a
  release reply, not an issue-state change.

## Verification and recovery

Use `tool/sync_versions.dart`, version checks, focused release and version
tests, Swift helper version tests, and the complete local harness. Keep prior
ignored release reports outside the release source export. Remove only
task-generated .NET fixture outputs before packaging. Compare the package
inventory to the release commit before publication and to pub.dev afterwards.

Evidence lives under `reports/releases/desktop_updater-3.2.9/`. If a publish or
GitHub write has an uncertain result, read the authoritative service state
before any retry. Preserve failures and exact-head CI receipts. Do not replace
an existing published package or move a tag to recover from a failed attempt.

## Surprises & Discoveries

- The workspace contains an ignored 3.2.8 preflight script with formatting
  differences. Use an immutable release export for the complete package check
  instead of editing or deleting historical evidence.
- The example path-dependency lock entry is updated only from 3.2.8 to 3.2.9;
  dependency constraints and unrelated locked packages are unchanged.

## Outcomes & Retrospective

Release pending. No new package, tag, release, or reporter comment exists yet.

## Revision history

- 2026-11-02: accepted publication and reporter-reply authorization, checked
  current versions and remote history, and committed the scoped issue fix.
