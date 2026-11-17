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
- [x] Commit only task-owned changes, push, and observe exact-commit full CI.
- [x] Verify an immutable source export with the complete local harness.
- [x] Publish to pub.dev and GitHub; compare registry archive bytes with commit.
- [x] Post and read back the reporter reply; record release evidence and clean
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
- The initial export used a random directory basename. The two removed-Swift-API
  fixtures require the dependency identity `flutter_desktop_updater`, so their
  manifest lookup failed before reaching the intended compiler diagnostics.
  Recreated the same commit under a temporary parent with that exact basename;
  the complete harness then passed without changing source. Keep this basename
  for future immutable-export checks.
- pub.dev's version-specific metadata and archive became available immediately.
  The ordinary package-index response briefly retained 3.2.11 in its CDN cache;
  a fresh package-index request confirmed 3.2.12 as latest. This propagation
  delay did not require another upload.

## Outcomes & Retrospective

Published **desktop_updater 3.2.12** from immutable source commit
`f003943eecb6870f201db2629b113375e677fa76` on `main`.

- Package: https://pub.dev/packages/desktop_updater/versions/3.2.12
- GitHub release: https://github.com/MarlonJD/flutter_desktop_updater/releases/tag/v3.2.12
- Exact-commit CI: https://github.com/MarlonJD/flutter_desktop_updater/actions/runs/44000548708
- Reporter reply: https://github.com/MarlonJD/flutter_desktop_updater/issues/85#issuecomment-6936112903
- Registry archive SHA-256:
  `fabf380ea5b0157a33a1bb36984428f5680109b92b3ca57d5dc0a087a581b45f`.

The immutable-export harness passed structural 31/31, format, analysis with
existing non-fatal infos, version synchronization, documentation contracts,
1,161 Flutter tests (7 skipped), and zero-warning publish dry-run. Native local
verification passed 150 helper tests (6 skipped) and 155 SDK tests at this
source commit. Full CI passed all 13 required jobs, including Windows/Linux
native and update-smoke lanes, both macOS Flutter integration modes, the macOS
native consumer, and all four standalone CLI candidates. Four separately
credentialed/privileged jobs were skipped.

All 869 downloaded package files match the source commit byte-for-byte and the
expected inventory, with no extra or missing paths. The archive hash matches
pub.dev metadata. GitHub's latest release is v3.2.12; its tag points to the exact
source commit and its body matches the prepared notes.

The issue reply was posted through the GitHub CLI as `MarlonJD`; its author,
URL, and complete body were read back and verified. The issue remains open for
reporter confirmation. The reply explains rebuilding the embedded helper and
the possible administrator-assisted update/reinstall needed by affected apps.

Real standard-user Login Items/SMAppService installation, notarization, and
credentialed publisher-trust gates were not run and are not claimed by these
results. No unsigned CLI candidate assets were published. Task-owned source
copies and test-generated .NET outputs were removed; ignored evidence remains.
Unrelated `.gitignore`, backport-plan index entries, and untracked backport
plans remain untouched and excluded from commits.
