# Issue 82 macOS upgrade and patch release

## Context and acceptance

The 3.2.5 reporter confirms signing, file access, and manual installation but
reports an upgrade from app 1.0.0+1 to 1.0.0+2 failing with a generic native
prepare error, then an unverifiable native transaction on retry. The exact
consumer setup and underlying native error are not available. Reproduce a
concrete failure before claiming its cause, retain authenticated recovery
boundaries, and cover the fix with regression tests.

The user authorizes implementation, local tests including real notarized
macOS end-to-end updates, and a new pub.dev/GitHub patch release. Continue on
main, preserve unrelated work, and never replace a version or move a tag.
GitHub issue comments and reviews are outside this continuation.

## Progress

- [x] Read repository guidance, prior release/verification records, and report.
- [x] Check main, existing releases, Developer ID availability, and notary access.
- [x] Reproduce recovery failures and add focused regressions.
- [x] Implement and self-review authenticated recovery-state and retry fixes.
- [ ] Verify two consecutive signed, notarized, stapled Flutter updates locally.
- [ ] Complete repository gates and both macOS Flutter integration lanes.
- [ ] Commit the patch candidate and verify every required CI lane at that SHA.
- [ ] Publish the next available 3.2.x version and verify archives, tag, and links.
- [ ] Record final evidence and remove task-owned test processes/artifacts.

## Surprises & Discoveries

- Baseline is main `10f8751e80418238eb6a8a5c313600296c2e5c22`. GitHub and
  pub.dev latest are 3.2.5; v3.2.6 is absent at initial inspection.
- The available local notary profile is `general-notary`; the CI profile name
  `desktop-updater-notary` is not configured locally. Default keychain
  resolution for `general-notary` succeeds without exposing credentials.
- The first reported error is emitted by native preparation/commit, whereas
  the second is a recovery-status failure. These messages alone do not prove
  the reporter's root cause.

- Baseline 3.2.5 completed both notarized build-only updates locally. This
  does not reproduce the reporter's original preparation cause.
- Confirmed protocol mismatch: the helper emits `preparing`,
  `recoveryRequired`, and `orphanStateCleared`, but the client rejected these
  valid authenticated replies. Two focused regression tests failed on the
  original parser; the corrected native group passed 71 tests.
- Confirmed controller retry failure: after authenticated absence/orphan
  cleanup, the original app was still running but its receipt remained. Both
  regression cases failed before the fix. All 28 controller tests pass,
  including wrong identity/digests, changed receipt, modified stage, and a
  different running version. Recovery does not report an install as successful.
- The first full native run hit the previously recorded bundled restart
  timeout (`Missing launched.json`), with no fixture error file. The original
  log is retained; a new isolated run is required. No timeout was increased.
- The user has no additional reporter diagnostics and requested continuing
  from local reproduction. No consumer setup cause is assumed.
- Independent read-only review caught stage cleanup preceding exact receipt
  readback. The guard now runs before cleanup and again before clearing. The
  changed-receipt test asserts stage preservation; the orphan test follows
  query, recovery-required, recover, orphan cleanup, then a fresh retry.
  Follow-up review found no remaining blocking findings; 28 controller tests
  passed against this change.
- All 23 version/layout tests pass. The helper suite passes 148 tests with
  six explicit environment-gated skips after updating version assertions.
- The first candidate E2E test-host probe attempted to temporarily remove its
  own bundled helper. macOS denied restoring the file into the installed app;
  the next harness run replaced only the task-owned app and verified its full
  signature, Gatekeeper, and stapler acceptance. The revised test-host probe
  changes and restores a staged resource, leaving the installed app untouched.
  Neither injected failure identifies the reporter's original cause.

## Decision Log

- 2026-10-27: use a unique smoke bundle and isolated source/build copy, leaving
  the existing installed smoke app and unrelated working-tree changes intact.
- 2026-10-27: require app 1.0.0+1 to +2 to +3 transitions to cover build-only
  updates, outgoing process exit, replacement launch, trust, and recovery.
- 2026-10-27: preserve the historical intermittent restart failure and Flutter
  runner timeout as historical evidence; later passes do not identify causes.

## Verification and recovery

Start with focused native/controller regressions. Run `swift test`, the helper
suite, relevant Flutter tests, and `FLUTTER_ROOT=/Users/marlonjd/Developer/flutter
dart run tool/harness_check.dart`. Run local SwiftPM/CocoaPods integrations in
isolated exports and exact-candidate hosted CI including macOS native and both
Flutter lanes. Use the existing Developer ID and notary profile in place;
never export credentials. For each signed app, retain notarization acceptance,
stapler validation, strict signature/Gatekeeper checks, and real update/restart
observations. Evidence belongs under
`reports/releases/desktop_updater-3.2.6/` until the final version is selected.

Do not clear ambiguous recovery markers merely to enable retries. On failure,
retain logs and stop only task-owned processes. New test installations must
use unique paths, and cleanup must verify their ownership. Recheck version/tag
availability before publishing. After uncertain publication, inspect remote
state before retrying; compare every downloaded package member with the
release commit and resolve the immutable tag to that commit.

## Outcomes & Retrospective

Work in progress. Recovery fixes pass focused tests; final candidate notarized
updates, complete gates, and publication remain pending.
The reporter's actual application and post-update file-selection scenario
remain separate from local fixture evidence.

## Revision history

- 2026-10-27: created after explicit authorization for fixing, local notarized
  end-to-end verification, and a new patch release.
