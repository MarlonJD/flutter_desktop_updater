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
- The available host is Linux; actual Apple signing commands are unavailable.
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

Validation host: Linux, Flutter 3.47.8, Dart 3.13.7. Local SDKs and caches live
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

## Outcomes & Retrospective

The local fix is complete: valid resource bundles remain validated topology
and resource-seal inputs without becoming independent code-signing targets.
Every native file is still inspected, and code entitlement failures remain
fatal. No bundle-name exceptions, blanket extraction-error suppression, or
permission changes were added.

The previous tests exercised resource bytes and executable bundles separately,
but did not send an unsigned resource bundle through signing and final audit.
Those paths now have regressions. Actual macOS signing and the reporter's app
still require target-host validation before release; this is not a production
trust claim.

## Revision history

- 2026-10-26: created the implementation and verification plan.
- 2026-10-26: completed the local fix and validation, recorded macOS host
  limitations, and moved the plan to the completed ledger.
