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
- [ ] Publish and verify 3.2.4.
- [ ] Implement and verify the 2.x entitlement-preservation fix.
- [ ] Publish and verify 2.7.3 while preserving 3.2.4 as latest.
- [ ] Post and verify the issue reply, then complete the release ledger.

## Surprises & Discoveries

- v2.7.2 has no Mach-O resource preflight, so the CSS fix does not apply there.
  Its codesign calls still replace signatures without preserving entitlements.
- The 3.x fix already passed 962 Flutter tests, 16 new boundary regressions,
  published flutter_inappwebview asset probes, and a native ad hoc resource-seal
  probe. Release version changes need their own version checks and CI.
- The current registry latest is 3.2.3, the latest 2.x version is 2.7.2, and
  neither 3.2.4 nor 2.7.3 is published. Remote main matches local HEAD 9e9d9c1.

## Decision Log

- 2026-10-23: release in the user-requested order. Keep both fixes bounded and
  preserve existing entitlements rather than inventing permissions.
- 2026-10-23: use normal main pushes for 3.x and an immutable tagged commit
  descended from v2.7.2 for 2.x. No branch operations or force pushes.
- 2026-10-23: use gh with GH_TOKEN and GITHUB_TOKEN unset. Local ad hoc signing
  tests do not claim Developer ID, notarization, or reporter-app evidence.

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

In progress. Package publication is authorized; real customer installation
and the original file-picker symptom still require reporter confirmation.

## Revision history

- 2026-10-23: plan created after explicit authorization for both releases and
  the issue reply.
