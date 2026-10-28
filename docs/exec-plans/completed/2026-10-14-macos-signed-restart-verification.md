# macOS signed restart verification

## Context and acceptance

The user authorized additional macOS validation after the local PR #80
bootstrap fix, including Developer ID signing and notarization with the
existing keychain profile. Test the current uncommitted sources without
changing branches or publishing GitHub changes. Use an isolated source copy
and a uniquely named smoke app so existing installed apps remain untouched.

Acceptance is two consecutive real Flutter updates, A to B to C, with the
early bootstrap present in all three builds. Each transition must replace
the signed bundle, launch a new process with the expected version/build,
retain valid Apple trust, and leave exactly one regular LaunchServices app.
Also run the SwiftPM and CocoaPods build/integration lanes locally.

## Progress

- [x] Verify the designated keychain profile and available Developer ID identities.
- [x] Extend the existing production smoke to verify consecutive updates.
- [x] Run focused smoke-tool tests and prepare isolated source copies.
- [x] Build/test the SwiftPM and CocoaPods integrations.
- [x] Sign, notarize, and test A to B to C.
- [x] Record scoped evidence, validate repository changes, and clean task artifacts.

## Surprises & Discoveries

- The profile is named `general-notary`; its credential check succeeded.
  Use default Data Protection Keychain resolution without `--keychain`; see
  the [local profile note](../../publishing.md#local-notarization-profile-general-notary).
- The existing app-update smoke only builds two versions and rejects an
  installed sentinel, so it cannot establish consecutive-update behavior.
- `/Applications/Desktop Updater Smoke.app` predates this task and is owned
  by root. Use a distinct task app name and never remove that existing app.
- The first SwiftPM Debug build passed. The stock CocoaPods build failed
  because Xcode 27 rejects the generated Pods deployment target of 10.15.
  Only the isolated CocoaPods copy's generated Podfile raises that setting
  to 12.0; the package's supported minimum and repository sources are unchanged.
- The first signed release passed notarization, stapling, signature
  verification, and Gatekeeper assessment before installation in the unique
  `/Applications/Desktop Updater PR80 Smoke.app` path.

## Decision Log

- 2026-10-14: preserve signed sentinels and compare exact new content, so a
  previous update cannot produce a false positive during the next update.
- 2026-10-14: run CI-equivalent platform commands locally on isolated copies;
  hosted CI remains a separate claim until the current changes are published.
- 2026-10-14: use the existing signing identities in place; never export
  certificates or record credential contents or notarization history.

## Commands and recovery

Run focused Flutter tests for the production smoke and sentinel contract.
In isolated source copies, select SwiftPM/CocoaPods through the example's
local `flutter.config` setting, then run `flutter build macos --debug` and
`flutter test integration_test -d macos` with the CI ad hoc signing setup.
For the signed copy, run `dart run tool/macos_production_smoke.dart app-update`
with the required trust environment and a unique app/work directory.

Keep command logs under `reports/`. On a failed stage, retain diagnostics,
stop only task-owned app processes, and retry the failed stage after fixing
the cause. Remove only task-owned bundles and temporary source/build roots.
Do not install a PKG or alter privileged service approval for this test.

## Outcomes & Retrospective

`verified locally`: both signed update transitions passed on macOS with
Flutter 3.44.8 and Xcode 27.0. All three app bundles were universal
arm64/x86_64 builds, Developer ID signed, notarized, and stapled. Runtime
execution was on the local Apple Silicon host.

| Transition | Outgoing PID | Replacement PID | Observed version/build | Regular LaunchServices apps |
| --- | ---: | ---: | --- | ---: |
| A to B | 19187 | 19211 | 1.1.0+110 | 1 |
| B to C | 20296 | 20313 | 1.2.0+120 | 1 |

Both outgoing processes exited with code 0. Each replacement emitted its
Dart relaunch marker, finished launching at the expected bundle path, and
passed strict deep signature verification, Gatekeeper's Notarized Developer
ID assessment, and staple validation. Both updates also verified controller
staging cleanup. The runner terminates the verified B process and starts
the same installed B bundle to drive the next hop; it does not reinstall or
alter B between transitions. The LaunchServices check establishes one
regular application registration; it is not a screenshot-based Dock check.

`verified locally`: SwiftPM and CocoaPods each built the Debug example and
passed all three integration tests, including the forged raw MethodChannel
rejection. CocoaPods needed the documented generated-Pods target adjustment
for Xcode 27. Flutter reported a non-fatal foreground warning in both test
launches; all plugin assertions ran and passed.

`verified locally`: the repository harness passed structure, format,
analysis, version checks, harness documentation, and all 946 Flutter tests
(4 skipped). The full suite includes the secretless ad hoc macOS trust
fixture. Publish dry-run exited 65 solely for the warning about modified
checked-in files; the aggregate remains `failed` and no commit was made to
hide that warning. The focused production-tool/docs checks passed 30 tests,
and the Swift LaunchServices probe typechecked and ran successfully twice.

Evidence is retained in:

- `reports/pr80-signed-app-update.log`: build, notarization, both update
  transitions, relaunch observations, and trust checks.
- `reports/pr80-signed-result.log`: executable/resource signature hashes and
  structured PID/version evidence for both transitions.
- `reports/pr80-signed-verification-state.log`: source manifest, base commit,
  temporary-copy settings, lane outcomes, and cleanup record.
- `reports/pr80-swiftpm-build.log` and
  `reports/pr80-swiftpm-integration.log`: SwiftPM lane.
- `reports/pr80-cocoapods-build.log`,
  `reports/pr80-cocoapods-build-xcode27.log`, and
  `reports/pr80-cocoapods-integration.log`: original toolchain failure and
  successful scoped retry.
- `reports/pr80-signed-harness-check.log`: complete repository validation.

The task-owned app, signed artifact copies, source/build roots, and generated
.NET fixture output were removed. The pre-existing root-owned smoke app was
preserved. No package version, lockfile, branch, commit, push, or release was
changed. `not run`: hosted CI for these uncommitted changes, a privileged
installation lane, and execution on an Intel host or older macOS versions.

The real Flutter/helper path now complements the secretless nib regression
and its negative mutation check. These results verify this local update and
restart scenario; they do not certify a package release.

## Revision history

- 2026-10-14: created after the user authorized signed macOS testing.
- 2026-10-14: both signed transitions, integration lanes, repository checks,
  and cleanup completed; moved to the completed ledger.
