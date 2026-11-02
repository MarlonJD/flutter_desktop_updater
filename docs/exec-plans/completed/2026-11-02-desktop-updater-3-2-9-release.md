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
- [x] Complete local macOS SwiftPM, CocoaPods, native, and ARM64 CLI checks.
- [x] Publish immutable pub.dev 3.2.9 and matching GitHub tag/release.
- [x] Verify package archive bytes, tag identity, versions, and public links.
- [x] Post and read back the reporter comment through MarlonJD's CLI account.
- [x] Close this release ledger and clean only owned temporary outputs.

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
- The installed Xcode 27 SDK rejects the CocoaPods fixture's macOS 10.15
  deployment target. Set the owned fixture's Podfile and pod target settings
  to macOS 12.0, then pass its build and integration tests. No package platform
  requirement changed.

## Outcomes & Retrospective

Published [desktop_updater 3.2.9](https://pub.dev/packages/desktop_updater/versions/3.2.9)
and [GitHub release v3.2.9](https://github.com/MarlonJD/flutter_desktop_updater/releases/tag/v3.2.9)
at immutable release commit `6a9855734d971bb2a5dfd048936698db7c4bad78`.
The four scoped commits contain the issue fix, synchronized versions, Linux
test fixture, and explicit macOS fixture environment. Main and the annotated
tag were pushed normally; no branch or existing tag was changed.

### Verification

- The complete local harness passed for the final release source export:
  structural 31/31, 297 formatted files without changes, analysis under the
  repository's nonfatal-info policy, synchronized versions, 10 harness docs
  tests, 1,068 Flutter tests (4 skipped), and a zero-warning publish dry-run.
- Focused release/version coverage passed 98 Dart tests and 6 Swift helper
  version tests before publication. Ubuntu 26 reproduced the old Linux fixture
  failure and passed the repaired unprivileged recovery group plus the separate
  root credential-drop test.
- Local macOS checks passed 155 native tests, three integration tests in each
  SwiftPM/CocoaPods example, a separate forged-channel boundary test per mode,
  and compilation/startup/arm64 inspection of the standalone CLI. The CLI is
  retained as candidate-only evidence, not uploaded as a distribution asset.
- [CI run 41420741395](https://github.com/MarlonJD/flutter_desktop_updater/actions/runs/41420741395)
  passed nine jobs on `1b2186368f992572044374f1e4fdd9063df9f051`, including the
  full Windows, Linux, Dart, and native macOS lanes. Only the macOS test fixture
  and this ledger differ in the final commit. Three hosted ARM jobs expired
  without runners; the user explicitly replaced that wait with local checks.
  The aggregate canceled CI run is not reported as a passing full matrix.
- Signed/elevated Inno installation, the reporter's own script, and fresh macOS
  notarization were not exercised for this release. Existing trust checks were
  retained; no stronger production or customer claim is made.

### Publication and reply

- Pub.dev accepted the upload at `2026-11-02T10:16:44.764183Z`. Downloaded and
  checked all **869** package files byte-for-byte against the release commit.
  Archive SHA-256:
  `a959e71df6759d8f7d22be1c7b23ef9e016f9490c9a7d33af639bb5505f50d98`.
- Annotated tag object `d3719f9d52bc0deedfcf1b17f10cada461e644cd` resolves
  locally and remotely to the release commit. The stable public GitHub release
  was created at `2026-11-02T10:18:12Z`; its exact notes were read back.
- Both pub.dev and GitHub latest pointers resolve to 3.2.9. Pub.dev initially
  returned the previous latest version; the metadata converged without another
  upload.
- Posted and read back [comment 6574661115](https://github.com/MarlonJD/flutter_desktop_updater/issues/83#issuecomment-6574661115)
  as MarlonJD. The reply explains the fix, upgrade, explicit executable option,
  and cleanup of an empty directory left by an earlier failed attempt. Issue 83
  remains open for reporter confirmation.

### Evidence and cleanup

Retained source hashes, package archives, local and CI logs, platform summaries,
release/comment receipts, and cleanup audit under the ignored release evidence
directory. The first local full SwiftPM failure's raw log was overwritten by its
successful rerun; its nonzero check record, observed diagnostic summary, and
the matching original CI failure log remain available. Other failed and passing
checks are retained separately.

Removed the owned exports, build trees, test apps, and generated .NET fixture
output. No owned GUI process or Docker test container remains. Global Flutter
configuration is unchanged. The pre-existing .gitignore edit, two old 2.x plans,
and their index entries remain local and untouched by the release commits.

## Revision history

- 2026-11-02: accepted publication and reporter-reply authorization, checked
  current versions and remote history, and committed the scoped issue fix.
- 2026-11-02: repaired platform test fixtures, accepted the user's local-macOS
  verification override, passed final checks, published 3.2.9, verified the
  immutable archive/tag and reporter reply, and cleaned owned temporary output.
