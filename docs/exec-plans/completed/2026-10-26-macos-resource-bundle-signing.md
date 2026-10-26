# macOS resource bundle signing

## Context and acceptance

Issue #82 reports that 3.2.4 fails to extract entitlements from
`OrderedSet.framework/Versions/A/Resources/OrderedSet_privacy.bundle`.
Preflight currently promotes every validated `.bundle` to a signing target,
including resource bundles without `CFBundleExecutable`. Keep those bundles
in topology validation and seal their data through the enclosing code object;
only executable bundles should become independent signing targets. Continue
scanning every file for Mach-O code and rejecting malformed code declarations.

This fix is based on main `a911ee4212f087ec1b32dbd5702ceef45294c24e`.
After local validation, the user authorized committing and pushing to the
current branch. Version changes and publication are outside this task.

## Progress

- [x] Inspect the issue, signing pipeline, existing fixtures, and repository rules.
- [x] Reproduce the failure with a realistic unsigned privacy bundle.
- [x] Fix inventory classification and add positive and negative regressions.
- [x] Add a macOS resource-seal fixture and document the behavior.
- [x] Run the applicable validation ladder and record host limitations.

## Surprises & Discoveries

- `_principalExecutable` already permits `.bundle` directories without code,
  but the target-building loop ignores that distinction.
- Both signing and final-artifact verification read entitlements for every
  target. Catching extraction failures globally would weaken code checks.
- The initial validation host was Linux; actual Apple signing commands were
  unavailable for that run. The macOS follow-up below covers real signing.
- The original topology fixture treated a resource-only bundle as code. It
  now contains an executable plugin bundle, while dedicated fixtures cover
  resource-only bundles in all three supported Info.plist layouts.
- Flat executable bundles also need their root-level executable resolved so
  that tightening malformed executable declarations does not reject valid code.

## Decision Log

- 2026-10-26: classify by validated metadata and executable discovery, never by
  the bundle name or an allowlist of privacy packages. Resource bundles remain
  traversal boundaries, and embedded native code remains subject to inventory.
- 2026-10-26: keep real entitlement-read failures fatal for code targets.
- 2026-10-26: preserve flat and Contents/MacOS executable bundle layouts.
  Reject missing, empty, or non-string declared executables before signing.

## Verification and recovery

Initial validation host: Linux, Flutter 3.47.8, Dart 3.13.7. Local SDKs and caches live
outside the repository. The full suite additionally needed Clang 19 and .NET 8.
Use a conventional `umask 022`, writable `PUB_CACHE`,
`ANALYZER_STATE_LOCATION_OVERRIDE`, and .NET cache/state locations when
reproducing in a restricted container.

- `verified locally`: against the original source, the focused suite passed
  25 existing tests and failed the eight initial regressions. The privacy
  fixture produced the reported `Unable to extract macOS entitlements` error
  at `App.framework/Versions/A/Resources/OrderedSet_privacy.bundle`.
- `verified locally`: the final focused trust/notarization/native-fixture
  command passed 39 tests with one explicit macOS-only skip. Both real macOS
  fixture bodies were not exercised on Linux (the older test returns early).
  New coverage includes resource layouts, entitlement preservation and cleanup,
  malformed executable declarations, executable plugin bundles, embedded
  Mach-O rejection on entitlement-read failure, nested non-Mach-O rejection,
  publisher ordering, and final ZIP audit classification.
- `verified locally`: formatting checked all 287 Dart files without changes;
  native/package version consistency remains 3.2.4. Analysis exited 0 with
  777 informational diagnostics, no warnings, and no errors.
- `verified locally`: the final full Flutter suite passed 965 tests with
  13 skipped. Initial container-only failures (umask, analyzer cache location,
  and missing Clang/.NET) were resolved without changing product code or tests
  to bypass checks.
- `verified locally`: after completing the plan, the structural harness gate
  passed with 31/31 coverage rows and all 10 harness documentation tests passed.
  Final formatting and `git diff --check` passed.
- Before committing, publish dry-run exited 65 solely because the four changed
  source/test files were uncommitted. No release/version changes or publication
  are part of this fix.
- `not run`: real Apple `codesign`, Developer ID signing, notarization,
  Gatekeeper, hosted CI, the reporter's app, or a production update. The new
  macOS fixture checks unsigned resource bundles, ad hoc signing, ZIP round
  trips, and rejection of a modified privacy manifest when run on macOS.

Commands (with the local SDK/cache environment described above):

```sh
flutter test --no-pub test/release_cli/macos_release_trust_test.dart --reporter expanded
flutter test --no-pub test/release_cli/macos_release_trust_test.dart test/release_cli/macos_notarization_test.dart test/release_cli/macos_release_trust_real_test.dart --reporter expanded
dart format --output=none --set-exit-if-changed .
flutter analyze --no-fatal-infos --no-pub
dart run tool/version_check.dart
flutter test --no-pub --reporter expanded
dart pub publish --dry-run
dart run tool/harness_gate.dart --structural
flutter test --no-pub test/harness_engineering_docs_test.dart --reporter expanded
git diff --check
```

Fixtures use temporary directories and teardown. Generated .NET `bin/` and
`obj/` output is removed before handoff. No signing credentials or live update
feed are required for local verification. The new real fixture is picked up
by the existing macOS CI lane; workflow configuration is not execution evidence.

## macOS follow-up verification

Source: `95cf5bbd5ff01ffff6357866db8defc3e006e04c`. Verification ran on
2026-10-26 with macOS 27.0.1 (26A434), Apple Silicon arm64, Xcode 27.1
(27A9275), Flutter 3.48.0-0.1.pre at
`aadfc384985debe5c4f6c05832a6a6127c505631`, and Dart 3.13.0-266.0.dev.

- `verified locally`: the focused trust, notarization-process, and real
  codesign suites passed all 40 tests; neither real macOS fixture was skipped.
- `verified locally`: the parent commit's signer reproduced the reported
  entitlement-extraction error on an unsigned `OrderedSet_privacy.bundle`.
  The current signer completed Developer ID signing on the same fixture,
  with framework and application targets only, equal Team IDs, hardened
  runtime, and unchanged application entitlements and privacy-resource bytes
  and permissions. The extracted ZIP passed signature verification; changing
  its privacy manifest correctly invalidated the enclosing framework seal.
- `verified locally`: the native kit passed all 146 tests on a full rerun.
  Its first run failed the bundled restart test while waiting for
  `launched.json`; the unchanged isolated retry and full rerun passed. The
  test exercises two replacements through AppKit and LaunchServices. The
  initial intermittent failure's cause remains unresolved.
- `verified locally`: the install-helper suite passed 148 tests with six
  skips requiring separately supplied CI fixture or crash-worker inputs.
- `verified locally`: isolated SwiftPM and CocoaPods example exports each
  built for macOS Debug and passed all three integration tests, including
  forged raw MethodChannel rejection. The exports used ad hoc signing and
  project-local integration settings. Xcode's iOS CoreSimulator warning did
  not prevent either macOS lane from passing.
- The broad Flutter suite was **not fully green**: 972 tests passed, four
  skipped, and two timed out. The Windows ABI compile test passed on a
  focused retry. The unchanged removed-Dart-API test timed out again at its
  existing two-minute limit. All nine equivalent analyzer assertions passed
  directly outside the Flutter runner, but this does not convert the full
  suite into a pass. No timeout or assertion was weakened.
- `verified locally`: after restoring the example's generated dependency
  configuration, analysis exited 0 with 777 infos and no errors or warnings.
  Formatting left all 287 Dart files unchanged; version consistency, the
  31/31 structural gate, and all ten harness documentation tests passed.
  Publish dry-run exited 0 with zero warnings. Tracked lockfiles and package
  versions were preserved.
- [CI run 40312411349](https://github.com/MarlonJD/flutter_desktop_updater/actions/runs/40312411349)
  succeeded for the tested commit, but its macOS native and Flutter jobs were
  skipped. The path classifier selects CLI/Dart checks for release-tooling
  changes before reaching the platform patterns. Selecting macOS jobs for
  macOS release-tooling and real codesign-test changes remains a follow-up.
- `not run`: Apple notarization, stapling/Gatekeeper production acceptance,
  a real signed Flutter A-to-B-to-C update, privileged installation, the
  reporter's app or its original post-update file-selection scenario, and
  execution on Intel or older macOS/Flutter versions.

Detailed local evidence is retained under
`reports/issue82-macos-verification/`, including the baseline/current signing
probe, native and integration logs, the initial failed harness report,
focused retries, and direct analyzer results. These reports are local
artifacts, not committed package files. Task-owned temporary source/build
exports, signed fixtures, generated .NET probe output, and test processes
were cleaned up. No release or production-readiness claim follows from these
bounded checks.

## Outcomes & Retrospective

The local fix is complete: valid resource bundles remain validated topology
and resource-seal inputs without becoming independent code-signing targets.
Every native file is still inspected, and code entitlement failures remain
fatal. No bundle-name exceptions, blanket extraction-error suppression, or
permission changes were added.

The previous tests exercised resource bytes and executable bundles separately,
but did not send an unsigned resource bundle through signing and final audit.
Those paths now have regressions. The macOS follow-up verifies real Developer
ID signing and the platform integration lanes. The unresolved test-runner
timeout and intermittent restart failure remain recorded; the reporter's app
and production trust/update gates still require validation before release.

## Revision history

- 2026-10-26: created the implementation and verification plan.
- 2026-10-26: completed the local fix and validation, recorded macOS host
  limitations, and moved the plan to the completed ledger.
- 2026-10-26: recorded real macOS signing, native and Flutter integration
  verification, CI selection limits, and unresolved full-suite boundaries.
