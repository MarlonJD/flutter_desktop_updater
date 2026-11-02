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
- [x] Pass the complete local harness for release commit fa476bf.
- [x] Commit the scoped release metadata and push main without force.
- [x] Repair the observed Linux CI fixture assumption and validate it on Ubuntu 26.
- [x] Observe nine successful exact-head CI jobs, including Windows and Linux.
- [x] Record the user's authorization to replace queued macOS CI with local checks.
- [ ] Complete local macOS SwiftPM, CocoaPods, native, and ARM64 CLI checks.
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
- The initial release gate required the full standard CI matrix. After hosted
  macOS ARM jobs expired without runners, the user explicitly authorized local
  macOS testing without waiting for CI. Retain the nine successful jobs for
  `1b2186368f992572044374f1e4fdd9063df9f051` and verify the remaining macOS
  integration/CLI surfaces locally. Subsequent changes are limited to the
  macOS test fixture and this release ledger. Signed/elevated Inno installation
  and fresh notarized macOS E2E remain separate evidence boundaries.
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
- The first export's generated folder name changed SwiftPM's path-dependency
  identity, causing two removed-API tests to fail before reaching their
  intended compiler errors. A fresh export named `flutter_desktop_updater`
  passed the focused contract tests and the complete local harness without
  changing source. Both reports are retained.
- Initial full CI 41418954713 ran on Ubuntu 26.04.1 and failed the Linux
  `FexecveLauncherConfirmsChildExec` fixture because `/usr/bin/true` is a
  symlink. Reproduced the exact no-follow failure in an isolated official
  Ubuntu 26 container as an unprivileged user. Reuse the existing compiled
  caller fixture and keep production no-follow enforcement unchanged.
  The corrected unprivileged recovery group passed with 11 tests and 3
  prerequisite skips; its separate root credential-drop test also passed.
- The same CI run's macOS main-nib restart test timed out waiting for its first
  `launched.json` proof. Preserve its failure logs and require this gate to
  pass on the final candidate; do not weaken or skip the test.
- Run 41420741395 passed nine jobs, including the complete Windows, Linux,
  and native macOS lanes. Three hosted macOS ARM jobs expired after 15 minutes
  with "The job was not acquired by Runner of type hosted even after multiple
  attempts" and capacity notices. A retry was queued, then canceled after the
  user authorized local macOS checks instead of waiting.
- Local restart testing reproduced the first-launch fixture failure in the
  full native suite after the focused case passed. Pass its root explicitly
  with `open --env`, which is the documented application-environment option,
  instead of relying solely on the environment of the `open` subprocess.
  Three consecutive focused cases and the complete 155-test suite then passed.
- Local verification uses separate source exports of the release candidate,
  Flutter 3.44.8, Swift 6.4, and macOS 27.2 arm64. Signing and per-project
  SwiftPM/CocoaPods settings change only in the owned example fixtures; the
  user's global Flutter configuration and repository example remain intact.

## Outcomes & Retrospective

Release pending. No new package, tag, release, or reporter comment exists yet.

## Revision history

- 2026-11-02: accepted publication and reporter-reply authorization, checked
  current versions and remote history, and committed the scoped issue fix.
