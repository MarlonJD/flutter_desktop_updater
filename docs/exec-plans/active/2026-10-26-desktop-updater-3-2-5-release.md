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
- [ ] Commit the candidate and pass the complete local release harness.
- [ ] Push normally and verify every required CI job on the exact candidate,
  including macOS Native Consumer and both Flutter integration lanes.
- [ ] Publish to pub.dev and GitHub without replacing versions or tags.
- [ ] Verify registry metadata, archive contents, tag commit, and release links.

## Surprises & Discoveries

- Main initially stopped at `a911ee4212f087ec1b32dbd5702ceef45294c24e`.
  The unrelated plan-index edits were saved, temporarily stashed for the
  fast-forward, and restored. Unrelated `.gitignore` changes and two untracked
  legacy release records remain outside the release commit.
- Previous selective CI skipped macOS. Changing `pubspec.yaml` selects the
  full standard matrix for the release candidate.
- Prior Developer ID signing and both macOS integration modes passed locally.
  The intermittent native restart failure and Flutter-runner removed-API
  timeout remain unresolved historical evidence, even if this candidate passes.

- `verified locally`: 63 focused signing/resource-seal/version/layout tests and
  all six Swift helper-version tests passed on the 3.2.5 metadata. Both real
  macOS signing fixtures executed. Local SDK: Flutter 3.44.8, Dart 3.12.2.

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

## Outcomes & Retrospective

Release pending local checks, exact-candidate CI, and verified publication.
The historical macOS evidence boundaries above remain explicit.

## Revision history

- 2026-10-26: created after explicit release authorization and registry checks.
