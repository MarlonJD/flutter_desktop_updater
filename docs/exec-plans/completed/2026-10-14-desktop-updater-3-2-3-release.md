# desktop_updater 3.2.3 release

## Context and acceptance

The user explicitly authorized committing and pushing the verified changes,
merging PR #80, publishing the next package version, and posting a PR comment.
Continue on the existing `main` branch. The latest GitHub and pub.dev release
is 3.2.2, so this macOS restart fix ships as patch version 3.2.3.

The bootstrap regression and signed A-to-B-to-C verification are documented
in the completed plans from 2026-10-14. Preserve the contributor's PR commit
in merge history and identify the host AppDelegate change in release notes.

## Progress

- [x] Inspect current source, PR head, GitHub identity, and published versions.
- [x] Commit and push the verified implementation and regression coverage.
- [x] Merge PR #80 at its reviewed head and synchronize `main`.
- [x] Prepare 3.2.3 metadata and synchronized native versions.
- [x] Pass local release checks and hosted CI for the release source.
- [x] Publish the immutable tag, pub.dev package, and GitHub release.
- [x] Verify public publication and post the concise PR follow-up.

## Surprises & Discoveries

- PR #80 is a mergeable fork PR at
  `6fb7b4d0309da434e2cc39f11fbea6ba35005d5d`; its existing checks passed.
- `main` starts at the 3.2.2 tag, `1859f3b`, with no intervening remote work.
- The repository has no automatic pub.dev publication workflow. Publishing
  follows a locally validated package upload and an explicit GitHub release.
- Implementation commit `7d3e3f6` was pushed to `main`. PR #80 merged as
  `8bf7cdd` at the reviewed head, and the local checkout fast-forwarded to it.
- Version synchronization and all 23 focused Dart version/layout tests passed.
  The six native helper version tests passed. The example's path dependency
  lock entry now records 3.2.3; no unrelated dependency versions changed.

## Decision Log

- 2026-10-14: use `gh` authenticated as the owner's keyring account with
  injected token variables unset. Do not use connector identities.
- 2026-10-14: keep the existing branch and use normal pushes. No force push,
  new branch, branch deletion, or certificate export is needed.
- 2026-10-14: publish 3.2.3 only after the release source passes checks.

## Commands and recovery

Use `git commit`, `git push origin HEAD:main`, and `gh pr merge 80 --merge`
with the reviewed head SHA. Synchronize version surfaces with
`dart run tool/sync_versions.dart`, then run version tests, the native helper
version tests, and `dart run tool/harness_check.dart`. Await the hosted CI run
for the exact release commit. Use `dart pub publish` for pub.dev and `gh
release create` for the annotated release tag and reader-facing notes.

Keep logs under `reports/`. If a command's external outcome is uncertain,
query GitHub or pub.dev before retrying. Never replace a published version or
move a published tag. Resolve test failures before publication. Keep API
credentials out of logs and write multiline GitHub prose via body files.

## Outcomes & Retrospective

Published `desktop_updater` 3.2.3 from
`77eec61276f8f72c03b2167bb969c95d1026aacf`. The annotated `v3.2.3` tag and
GitHub release both identify that exact commit.

- `verified locally`: the clean-source harness passed structure, formatting,
  analysis, version checks, all 946 Flutter tests (4 skipped), and pub.dev
  dry-run with zero warnings. The focused version/layout tests passed 23
  tests; the native helper version suite passed all 6 tests.
- `verified in CI`: [release-source run 38523720777](https://github.com/MarlonJD/flutter_desktop_updater/actions/runs/38523720777)
  passed all 13 standard jobs, including Windows, Linux, macOS native,
  SwiftPM/CocoaPods Flutter, Dart, documentation, and all CLI candidates.
  Four explicitly manual signing/privilege jobs were skipped; the prior
  local signed macOS update evidence remains separately scoped. The earlier
  intermediate-source runs `38523302318` and `38523328558` were cancelled
  after this full release-source run was queued.
- [pub.dev 3.2.3](https://pub.dev/packages/desktop_updater/versions/3.2.3)
  was published at `2026-10-14T07:09:37.152794Z`. The downloaded archive's
  SHA-256 matched the registry metadata:
  `33e9fba27871d5756cc8179d1570ecec94459dbfbcec2d5079c13008e7e0a87f`.
  Seven critical files, including the host bootstrap, plugin, restarter,
  helper version, README, and package versions, matched the release source
  byte for byte.
- [GitHub release v3.2.3](https://github.com/MarlonJD/flutter_desktop_updater/releases/tag/v3.2.3)
  is published as the latest stable release. Its notes explain the required
  host entrypoint change and the outgoing-executable transition boundary.
- [PR #80 follow-up](https://github.com/MarlonJD/flutter_desktop_updater/pull/80#issuecomment-6162957017)
  was posted through `gh` as `MarlonJD`, thanking the contributor and linking
  the release and verification results.

Local signed-update evidence predates the version-only bump. Hosted CI passed
for the exact published release commit. The tag push also triggers the normal
workflow for the same source; that duplicate run is separate from the passed
release gate. No branch creation, switch, force push, or branch deletion was
performed. The contributor's original commit remains a parent of the merge.

Evidence: `reports/pr80-release-harness-check.log`,
`reports/pr80-release-ci-result.log`, `reports/pr80-pub-publish.log`,
`reports/pr80-publication-verification.log`, and
`reports/pr80-release-state.log`.

## Revision history

- 2026-10-14: created after explicit commit, push, merge, publish, and comment
  authorization.
- 2026-10-14: release source passed local and hosted gates, public package
  bytes and GitHub release were verified, and the PR follow-up was posted;
  moved to the completed ledger.
