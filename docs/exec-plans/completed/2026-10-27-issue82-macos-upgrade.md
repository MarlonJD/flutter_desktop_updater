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
- [x] Verify two consecutive signed, notarized, stapled Flutter updates locally.
- [x] Complete repository gates and both macOS Flutter integration lanes.
- [x] Commit the patch candidate and verify every required CI lane at that SHA.
- [x] Publish the next available 3.2.x version and verify archives, tag, and links.
- [x] Record final evidence and remove task-owned test processes/artifacts.

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

## Final candidate local evidence

Release candidate: `4be55dfdfe039b14f1d026c6354b83aa7423c2de`, including
implementation commit `a785ad82924bc11f616701e44d7b8039c66fd303` and the
README version-example correction. Both original required signing/verification
commits remain ancestors. Version 3.2.6 was available on initial and subsequent
registry/tag checks; it must be checked again immediately before publication.

Host: macOS 27.0.1 (26A434), Apple Silicon, Xcode 27.1 (27A9275), Flutter
3.44.8 stable (`058e0af2c2b57e369d905a03ac9748b0ebf543c6`), Dart 3.12.2.

- `verified locally`: complete repository harness passed all seven steps.
  The full Flutter suite passed 983 tests with four explicit skips; formatting
  checked 287 files, analysis reported 786 infos with no warnings/errors,
  version consistency passed, the structural gate passed 31/31 rows, all ten
  harness documentation tests passed, and pub dry-run reported zero warnings.
  The first full run caught the README's old version example; it was corrected
  before the complete successful rerun. No test timeout or assertion was relaxed.
- `verified locally`: native kit passed all 150 tests on the isolated full run.
  The first run's bundled restart failure and successful focused/full retries
  are retained; the intermittent failure's root cause remains unresolved.
  Helper tests passed 148 tests with six skips for separately supplied baseline
  fixtures and crash-worker inputs, which are exercised by named CI steps.
- `verified locally`: both exported SwiftPM and CocoaPods example hosts built
  Debug and passed all three integration tests, including forged raw channel
  rejection. With Xcode 27, the CocoaPods host needed the generated Podfile and
  generated pod targets raised to 12.0. This modifies only the isolated host;
  the published package minimum remains unchanged. Flutter's foreground request
  returned 1 in both lanes, but both test runners attached and completed 3/3.
- `verified locally`: the final candidate's package/native source matches all
  195 entries in the E2E hash manifest. Three Developer ID/hardened-runtime apps
  were accepted by Apple notarization, stapled, and passed deep strict codesign,
  Gatekeeper `Notarized Developer ID`, and stapler validation. The smoke runner
  redacts submission UUIDs but retains all three Accepted responses.
- `verified locally`: real same-version updates 1.0.0+1 to +2 to +3 completed.
  Outgoing/replacement PIDs were 55926/55965 and 57399/57432, with one regular
  LaunchServices application and the expected build reported after each launch.
  Before each update the isolated test host modified a staged Info.plist,
  observed the real native generic prepare rejection, restored the exact bytes,
  authenticated transaction absence, cleared the failed receipt and unchanged
  stage, then downloaded and installed afresh. Product sources contain no probe
  hook or fault injection. This tests the absent-transaction path; interrupted
  preparation and orphan protocol states are covered by native/controller tests.
- The final installed smoke app and the first probe's saved helper were removed
  after checking the unique bundle ID, user ownership, build 3, and absence of
  a running app. Original installed applications and unrelated working files
  remain untouched. All seven task-owned source/build/artifact exports were
  removed after retaining logs, source manifests, and isolated host fixture
  changes. No task-owned app/build process remained in the process audit.

The full exact-candidate CI run is
https://github.com/MarlonJD/flutter_desktop_updater/actions/runs/40479573941.
It was dispatched explicitly because the final README-only push selects only
documentation checks. All 13 required jobs passed, including macOS native and both Flutter lanes,
Dart, Linux, Windows, all four standalone CLI candidate builds, documentation,
and the selective gate. Four optional production/privilege jobs were skipped;
local notarized E2E supplies the explicitly requested signing/notarization
evidence, not privileged-install evidence. The earlier source candidate's run
was canceled after it was superseded by the README correction.

## Publication verification

- Published pub.dev version 3.2.6 at `2026-10-27T09:44:33.031261Z`:
  https://pub.dev/packages/desktop_updater/versions/3.2.6.
- The downloaded archive's 858 files match the final release commit and local
  source byte-for-byte, including the recovery fixes and synchronized version
  surfaces. Archive SHA-256:
  `499fdd639804a7cb976d25e5c4960d1ee5051026e6b33e8cb04535c29a33bc8d`.
- Created annotated tag `v3.2.6`, object
  `13c2dc61c80d8d9422b22f59b1f6d2c48133769f`, without replacing or moving any tag.
  GitHub's tag API and remote peeled ref both resolve to release commit
  `4be55dfdfe039b14f1d026c6354b83aa7423c2de`.
- Published GitHub release at `2026-10-27T09:45:15Z`:
  https://github.com/MarlonJD/flutter_desktop_updater/releases/tag/v3.2.6.
  Its body matches the prepared notes; it is published, non-prerelease, and
  GitHub latest. Both release links returned HTTP 200.
- The first pub.dev package-list read still returned 3.2.5 during index
  propagation. The 3.2.6 version endpoint and its archive were independently
  accessible and fully verified. No upload was repeated because of stale
  latest metadata. Subsequent verification confirmed pub.dev latest is 3.2.6.
- Detailed command logs, source manifests, publication receipts, native CI
  logs, integration logs, controlled probe source, and cleanup records remain
  under `reports/releases/desktop_updater-3.2.6/`. This local directory is
  excluded from the package and Git; public evidence is linked above.

## Outcomes & Retrospective

The two reproduced recovery defects are fixed and version 3.2.6 is published.
Preparation/orphan protocol states now remain recoverable, and authenticated
absence or safe cleanup can release an unchanged failed attempt for a fresh
retry. Exact receipt checks run before staging cleanup and before clearing.
The first native preparation error remains generic and its consumer-specific
cause is not known; an older stuck consumer may need a manual app installation.
Do not label the reporter's entire issue resolved from this fixture evidence.

The historical intermittent native restart failure and Flutter-runner timeout
remain unresolved observations. This candidate passed its isolated native run,
full Flutter suite, local notarized smoke, and all required CI jobs; no timeout,
assertion, signature check, entitlement policy, or transaction authentication
was weakened. Intel/older macOS and privileged install flows were not exercised
by the local notarized fixture.
The reporter's actual application and post-update file-selection scenario
remain separate from local fixture evidence.

## Revision history

- 2026-10-27: created after explicit authorization for fixing, local notarized
  end-to-end verification, and a new patch release.
- 2026-10-27: completed independent review, exact-candidate gates, local notarized
  retries/updates, publication verification, and task-owned fixture cleanup.
