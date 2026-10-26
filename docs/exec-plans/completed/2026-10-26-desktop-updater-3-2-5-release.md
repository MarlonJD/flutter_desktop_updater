# desktop_updater 3.2.5 release

## Context and acceptance

The user authorized version/changelog changes, a Conventional Commit, normal
pushes to the existing main branch, an immutable release tag, pub.dev
publication, and a matching GitHub release. Issue comments and reviews are
outside this task. Preserve all unrelated workspace changes.

Both registries reported 3.2.4 as latest and no 3.2.5 release on 2026-10-26.
The release must include signing fix
`95cf5bbd5ff01ffff6357866db8defc3e006e04c` and verification record
`0b7b70fa09126e7f7ba3d0166261290c3d1d3123`.

Resource-only privacy bundles are sealed by their enclosing code object
without independent entitlement extraction. Native code discovery and fatal
entitlement-read errors for code targets remain enforced.

## Progress

- [x] Verify registry versions, GitHub authentication, required commits, and
  unrelated workspace changes; fast-forward the existing main branch.
- [x] Synchronize 3.2.5 metadata, review the release diff, and run focused checks.
- [x] Commit the candidate and pass the complete local release harness.
- [x] Push normally and verify every required CI job on the exact candidate,
  including macOS Native Consumer and both Flutter integration lanes.
- [x] Publish to pub.dev and GitHub without replacing versions or tags.
- [x] Verify registry metadata, archive contents, tag commit, and release links.

## Surprises & Discoveries

- Main initially stopped at `a911ee4212f087ec1b32dbd5702ceef45294c24e`.
  The unrelated plan-index edits were saved, temporarily stashed for the
  fast-forward, and restored. Unrelated `.gitignore` changes and two untracked
  legacy release records remain outside the release commit.
- Previous selective CI skipped macOS. Changing `pubspec.yaml` selects the
  full standard matrix for the release candidate.
- Prior Developer ID signing and both macOS integration modes passed locally.
  The intermittent native restart failure and Flutter-runner removed-API
  timeout remain unresolved historical evidence despite the passing release checks.

- `verified locally`: 63 focused signing/resource-seal/version/layout tests and
  all six Swift helper-version tests passed on the 3.2.5 metadata. Both real
  macOS signing fixtures executed. Local SDK: Flutter 3.44.8, Dart 3.12.2.

- Release candidate: `d5d246920ad91d8397e8ec2430ce7af426924d96`, committed
  as `chore(release): prepare desktop_updater 3.2.5` and pushed normally to main.
  Both required commits are ancestors.
- `verified locally`: `dart run tool/harness_check.dart` with `FLUTTER_ROOT`
  set to the installed Flutter SDK passed every step. Structural coverage was 31/31;
  formatting checked 287 files unchanged; analysis had 778 informational
  diagnostics and no warnings/errors; version consistency and ten harness
  documentation tests passed; the full suite passed 974 tests with four skips;
  publish dry-run had zero warnings. The explicit SDK root lets subprocess
  checks resolve the cached Dart executable. This passing run does not
  establish the cause of the earlier runner timeout on a different SDK.
- All 858 expected package files match the candidate commit. File additions
  and removals since 3.2.4 affect excluded documentation only.
- [Candidate CI](https://github.com/MarlonJD/flutter_desktop_updater/actions/runs/40383202096)
  selected the full standard matrix, including all three required macOS jobs;
  all 13 standard jobs passed on attempt 1. macOS native passed all 146 kit
  tests; both Flutter lanes passed three integration tests and two real
  signing/resource-seal fixtures. The hosted Dart suite passed 965 tests with
  13 skips. Windows and Linux native, integration, update, and publishing
  smoke gates passed. Four manual production/privilege lanes were skipped.

- Published pub.dev 3.2.5 at `2026-10-26T19:30:12.488537Z` and GitHub
  `v3.2.5` at `2026-10-26T19:30:35Z`. Both latest pointers identify 3.2.5.
  The remote annotated tag resolves to the tested candidate commit.
- The downloaded pub.dev archive contains exactly 858 expected files, all
  matching the candidate commit and working source. Its SHA-256 matches
  registry metadata:
  `327d7a480ddf7038e9a76b9f8cb2738efc8adfac9e5a4cf8a72df96b17b9dfea`.
  Both public release pages returned HTTP 200 and show 3.2.5; GitHub release
  notes match the saved publication text.
- Package: https://pub.dev/packages/desktop_updater/versions/3.2.5.
  GitHub: https://github.com/MarlonJD/flutter_desktop_updater/releases/tag/v3.2.5.

## Decision Log

- 2026-10-26: select 3.2.5 after checking pub.dev and GitHub; keep the existing
  branch, required commits, and unrelated edits intact.
- 2026-10-26: require the complete local harness and exact-candidate hosted CI
  before publication. A failed check must be resolved without weakening tests.
- 2026-10-26: do not claim notarization, production Gatekeeper acceptance,
  a real signed Flutter A-to-B-to-C update, or verification of the reporter's
  original post-update file-selection scenario.

## Verification and recovery

Run focused macOS trust/notarization/real-codesign tests and version/layout
tests, `swift test --package-path macos/install_helper --filter
HelperVersionTests`, and `dart run tool/harness_check.dart`. Retain logs,
candidate identity, CI receipts, publication receipts, and archive comparisons
under ignored `reports/releases/desktop_updater-3.2.5/`.

Use the authenticated GitHub CLI keyring with `GH_TOKEN` and `GITHUB_TOKEN`
unset. Check destination state before retrying an uncertain publication.
Never overwrite a version or move a tag. Download the published package,
verify its registry SHA-256, compare every member with the candidate commit,
and verify the GitHub release tag resolves to the tested commit.

Release-ledger closure passed `dart run tool/harness_gate.dart --structural`
(31/31 canonical rows) and all ten `harness_engineering_docs_test.dart` tests.
This structural result is not a new `harness-ready` certification. Closure
logs are retained with the release evidence.

## Outcomes & Retrospective

3.2.5 is published and verified on both registries. Its immutable tag points
at the exact commit that passed the complete local harness and all 13
standard hosted CI jobs on the first attempt. The longer Linux dependency
installation completed successfully without retry or source changes.

The earlier intermittent native restart failure and Flutter-runner timeout
remain unexplained historical evidence. This release does not claim Apple
notarization, production Gatekeeper acceptance, a real signed Flutter
A-to-B-to-C update, privileged installation, or verification of the reporter's
original post-update file-selection scenario. Four manual
production/privilege CI lanes were not run.

Unrelated `.gitignore`, plan-index edits, and two untracked legacy release
records remain outside the release commits. Task-generated .NET probe output
was removed; no local test processes remained. No issue comments or reviews
were posted. The release tag was created once and was never moved.

## Revision history

- 2026-10-26: created after explicit release authorization and registry checks.
- 2026-10-26: recorded passing local/hosted checks, verified publication and
  archive/tag/link receipts, and moved the release plan to completed.
