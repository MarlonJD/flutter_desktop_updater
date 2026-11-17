# desktop_updater 3.2.12 release

## Scope and authority

The user explicitly requested commit, push, publication, and a reply to issue
#85 after accepting the [local fix](../completed/2026-11-17-issue85-macos-helper-target-classes.md).
Publish package version 3.2.12 and a GitHub release from one immutable commit on
the existing `main` branch. Post the concise reporter reply using the
keyring-authenticated GitHub CLI, with `GH_TOKEN` and `GITHUB_TOKEN` unset.

Remote `main` and local HEAD both start at
`4bae8f1e7375dad37f0b4ab96ec5c20c3bca38fb`; there are no outgoing commits.
GitHub and pub.dev both report 3.2.11 as latest. Neither registry contains the
3.2.12 release identity. Preserve the pre-existing `.gitignore` change, the two
October backport-plan index entries, and their untracked plan files.

## Progress

- [x] Verify remote branch, existing releases, publication authority, and scope.
- [x] Synchronize all version surfaces and current-version tests; prepare notes.
- [ ] Commit only task-owned changes, push, and observe exact-commit full CI.
- [ ] Verify an immutable source export with the complete local harness.
- [ ] Publish to pub.dev and GitHub; compare registry archive bytes with commit.
- [ ] Post and read back the reporter reply; record release evidence and clean
  up task-owned temporary files.

## Decisions

- Patch release 3.2.12 contains the issue #85 fix and matching protocol fixtures,
  tests, documentation, and version metadata only.
- Use an immutable commit export for local validation and publication so old
  ignored report probes and unrelated working-tree edits cannot enter the
  package.
- Require the full applicable secretless CI matrix for the release commit.
  Credentialed and separately provisioned privileged lanes are not substitutes
  for the reporter's exact standard-user scenario and remain explicitly scoped.
- Explain that applications must rebuild the embedded helper. An already
  affected installation may require an administrator-assisted update or
  reinstall to obtain the corrected helper.
- Do not publish unsigned standalone executable candidates as trusted assets.
  Do not close the issue automatically; leave room for reporter confirmation.

## Validation and publication

Run `dart run tool/sync_versions.dart`, focused version/helper tests, and
`dart run tool/version_check.dart`. Use the commit export for
`FLUTTER_ROOT=/Users/marlonjd/Developer/flutter dart run tool/harness_check.dart`
and native helper/version verification. Confirm every required CI job is green
for that same source commit before `dart pub publish --force` and GitHub
release creation. Verify package metadata, downloaded archive SHA-256, archive
inventory/content, release tag commit, release body, and posted comment body.

Evidence belongs under ignored `reports/releases/desktop_updater-3.2.12/`.
No developer credentials or raw user-specific helper logs belong in commits.

## Surprises & Discoveries

- Local issue-fix tests already passed 1,161 Flutter tests (7 skipped), 305
  Swift tests (6 additional skipped), and four portable C++ request tests.
- `dart pub token list` has no explicit repository tokens; pub.dev OAuth
  credentials are a separate mechanism. The existing macOS OAuth credential
  file is present; its secret contents were not printed and publication has
  not yet been tried.
- Version synchronization and `git diff --check` passed. Focused verification
  passed 33 Dart tests and 14 helper/parser/policy Swift tests at 3.2.12.

## Outcomes & Retrospective

Release pending. No new release, tag, registry upload, or reporter reply has
been published at plan creation. Real standard-user SMAppService installation
is not claimed by the local parser/policy regression tests.
