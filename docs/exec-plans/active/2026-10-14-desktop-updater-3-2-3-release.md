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
- [ ] Commit and push the verified implementation and regression coverage.
- [ ] Merge PR #80 at its reviewed head and synchronize `main`.
- [ ] Prepare 3.2.3 metadata and synchronized native versions.
- [ ] Pass local release checks and hosted CI for the release source.
- [ ] Publish the immutable tag, pub.dev package, and GitHub release.
- [ ] Verify public publication and post the concise PR follow-up.

## Surprises & Discoveries

- PR #80 is a mergeable fork PR at
  `6fb7b4d0309da434e2cc39f11fbea6ba35005d5d`; its existing checks passed.
- `main` starts at the 3.2.2 tag, `1859f3b`, with no intervening remote work.
- The repository has no automatic pub.dev publication workflow. Publishing
  follows a locally validated package upload and an explicit GitHub release.

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

Release pending. Local signed-update evidence predates the version-only bump;
hosted CI and publication results will be recorded separately.

## Revision history

- 2026-10-14: created after explicit commit, push, merge, publish, and comment
  authorization.
