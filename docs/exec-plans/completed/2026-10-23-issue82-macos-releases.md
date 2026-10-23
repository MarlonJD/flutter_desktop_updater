# Issue 82 macOS patch releases

## Context and acceptance

The user explicitly authorized publishing the 3.x resource-validation fix,
then preparing and publishing the necessary 2.x signing fix, then replying to
issue #82. Publish 3.2.4 first, followed by 2.7.3. The issue's original file
selection symptom was reported on 2.7.1; the later CSS preflight failure was
reported on 3.2.3. Do not claim the original symptom is conclusively diagnosed.

Keep the main checkout on its existing branch. Preserve unrelated dirty
files. Prepare 2.7.3 from immutable v2.7.2 in a separate source export with an
alternate Git index, without branch creation or switching. Keep 3.2.4 latest
on pub.dev and GitHub when publishing the legacy patch. Use the user's
authenticated gh identity for the explicitly requested issue comment.

## Milestones and acceptance

1. Synchronize 3.2.4 metadata, verify the source, commit/push, observe CI,
   publish, and compare the uploaded package with its source.
2. Reproduce 2.x entitlement loss and implement bounded per-target entitlement
   preservation with verification. Exercise actual ad hoc codesign locally and
   run the applicable local and hosted checks for the exact 2.7.3 candidate.
3. Publish 2.7.3, verify package bytes and latest pointers, then post a concise
   issue reply explaining which fix belongs to which release and asking the
   reporter to rebuild/publish and retest file selection.

## Progress

- [x] Confirm current branch, source changes, registry state, and gh identity.
- [x] Publish and verify 3.2.4.
- [x] Implement and verify the 2.x entitlement-preservation fix.
- [x] Publish and verify 2.7.3 while preserving 3.2.4 as latest.
- [x] Post and verify the issue reply, then complete the release ledger.

## Surprises & Discoveries

- v2.7.2 has no Mach-O resource preflight, so the CSS fix does not apply there.
  Its codesign calls still replace signatures without preserving entitlements.
- The 3.x fix already passed 962 Flutter tests, 16 new boundary regressions,
  published flutter_inappwebview asset probes, and a native ad hoc resource-seal
  probe. Release version changes need their own version checks and CI.
- Before this task, the registry latest was 3.2.3, the latest 2.x version was
  2.7.2, and neither patch version was published. Main started at 9e9d9c1.

## Decision Log

- 2026-10-23: release in the user-requested order. Keep both fixes bounded and
  preserve existing entitlements rather than inventing permissions.
- 2026-10-23: use normal main pushes for 3.x and an immutable tagged commit
  descended from v2.7.2 for 2.x. No branch operations or force pushes.
- 2026-10-23: use gh with GH_TOKEN and GITHUB_TOKEN unset. Local ad hoc signing
  tests do not claim Developer ID, notarization, or reporter-app evidence.
- 2026-10-23: use codesign's documented `--preserve-metadata=entitlements`
  option in both existing 2.x application-signing entrypoints. The native
  regression demonstrates actual entitlement loss before the fix, then distinct
  outer/nested app permissions and unsigned-input behavior after it. No plist
  parser or signing-policy abstraction is needed for this bounded backport.

## Current evidence

- 3.2.4 source: `150ae1045c60603cfceeab1b3f8519aaf0d5900b`, pushed to main.
  All 23 focused version/layout tests and 6 native helper version tests passed.
  The complete local harness passed with 962 Flutter tests, 4 skips, and zero
  publish dry-run warnings. CI run 39930649589 passed all 13 standard jobs;
  four manually dispatched production/privilege lanes were skipped.
- 3.2.4 was published to pub.dev at `2026-10-23T09:38:41.393924Z` and GitHub
  at `2026-10-23T09:38:50Z`. The downloaded archive's 858 files match the
  release commit and working source. Its SHA-256 is
  `0a7845ffd81febc06399529c7bbf336db3a7340235bdf9fa3bd3bec851d9047e`.
  Both pub.dev and GitHub now report 3.2.4 as latest. GitHub release:
  https://github.com/MarlonJD/flutter_desktop_updater/releases/tag/v3.2.4.
- 2.7.3 source: `889080480696fcbbced733e3ae843b33d21f5385`, parent v2.7.2
  `5be2c7e478c06b8450ff1560265834d93763b596`, candidate tag v2.7.3-rc.1.
  The source export is `../desktop_updater-2.7.3/`; the alternate index and
  provenance are under its evidence directory in the main checkout.
- The 2.x baseline failed three focused tests, including real codesign reducing
  the app's entitlement map to empty while signature verification still passed.
  With the fix, all four focused tests and 445 full-suite tests passed locally
  (four skips). Formatting passed for 179 files. Analysis has no errors or
  warnings and 376 existing infos. Publish dry-run has zero warnings and the
  expected older-version hint. A secretless macOS signing CI job now runs the
  native fixture, alongside the existing Dart, Windows, and Linux jobs.
- CI run 39931866103 passed Dart, Linux, and the new native macOS test (all four
  focused tests executed). Its first Windows attempt failed in the unchanged
  CMake example test target's post-build commands before any macOS path ran.
  The failed-job log is retained; only the failed Windows job was rerun at the
  identical source commit. Attempt 2 passed Windows, including native tests,
  integration tests, and update/release smoke checks in debug and release.
  All four standard jobs passed; the manual notarized-publish job was skipped.
- 2.7.3 was published to pub.dev at `2026-10-23T09:43:32.801643Z` and GitHub
  at `2026-10-23T09:43:49Z`. Its final tag points to the tested candidate
  commit. The downloaded archive's 319 files match the commit and export;
  its SHA-256 is
  `b36f3d2c8327026f7e6cce06bf5951331f1c391675ea1061a53350bb9f56e16c`.
  Both registries still identify 3.2.4 as latest. GitHub release:
  https://github.com/MarlonJD/flutter_desktop_updater/releases/tag/v2.7.3.
- Issue reply posted at `2026-10-23T09:44:34Z` using the user's gh identity.
  The API receipt confirms author `MarlonJD` and the exact drafted body:
  https://github.com/MarlonJD/flutter_desktop_updater/issues/82#issuecomment-6362087704.
  It links both packages, distinguishes the fixes, explains rebuilding with
  production entitlements, and requests publishing/file-selection retests.
- Release-ledger closure passed `dart run tool/harness_gate.dart --structural`
  and `flutter test --no-pub test/harness_engineering_docs_test.dart` (10 tests).
  Structural coverage is not a new certification claim. Logs are retained as
  `closure-structural.log` and `closure-docs-test.log` in the 3.2.4 evidence folder.

## Verification and recovery

Use `dart run tool/sync_versions.dart`, focused version/platform tests,
`dart run tool/harness_check.dart`, and hosted CI for the 3.2.4 source. For the
2.x export use focused signing tests, format, analyze, the full Flutter suite,
native signing fixtures, and publish dry-run before publication. Keep exact
commands, logs, diffs, archive hashes, and external receipts under
`reports/releases/desktop_updater-3.2.4/` and
`reports/releases/desktop_updater-2.7.3/`.

Never replace a published version or move a release tag. After an uncertain
upload or comment result, read the destination before retrying. Fix failing
checks before uploading. A failed or skipped production signing lane is not
production acceptance; keep evidence labels scoped to the observed checks.
After publication, compare all uploaded archive members with the release
source and verify pub.dev/GitHub latest pointers.

## Outcomes & Retrospective

Both patch releases are published on pub.dev and GitHub in the requested
order. Their downloaded package contents match the exact commits that passed
the applicable local and hosted checks. 3.2.4 remains the latest release.
The requested issue reply is posted and verified.

The 2.x regression demonstrates entitlement loss without assuming it caused
the reporter's original symptom. Real customer installation, the original
file-picker symptom, and consumer-app Developer ID/notarization evidence
still require reporter confirmation. No production signing claim is made
from the local ad hoc fixture or secretless CI lane.

The Windows candidate's initial failure was resolved by rerunning the same
source; no unrelated Windows implementation changes were needed. Both
release tags are immutable. The user's pre-existing workspace changes remain
outside the release commits.

## Revision history

- 2026-10-23: plan created after explicit authorization for both releases and
  the issue reply.
- 2026-10-23: recorded passing CI, publication/archive receipts, latest-pointer
  checks, and the verified issue reply; moved the plan to completed.
