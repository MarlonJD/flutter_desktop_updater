# Issue 82: macOS install preparation and DMG naming

## Context and outcome

Issue [82, October 28 report](https://github.com/MarlonJD/flutter_desktop_updater/issues/82#issuecomment-6459504958)
reports a 3.2.6 app installed in `/Applications` failing a DMG update from
`1.0.0+1` to `1.0.0+2`. Download, staging, and release validation succeed;
native preparation returns `InstallError` with no details. The reporter's
installed app and helper configuration are unavailable. The supplied YAML
configures distribution signing, not the mandatory host install helper.

Make native preparation failures actionable without exposing paths or raw
errors. Prevent notarized publishing from accepting a host without the
mandatory helper. Support the comment's separate request for a configurable
DMG artifact filename while preserving descriptor and manifest URL binding.
Do not claim the original consumer's cause is confirmed from its generic error.

## Progress

- [x] Inspect issue, current 3.2.6 recovery fix, native preparation, publishing,
  and existing tests; confirm a clean `main` at `feb49cb`.
- [x] Add bounded native preparation diagnostics and regression coverage.
- [x] Reject missing helper and invalid host build metadata before notarization.
- [x] Add safe configurable DMG filenames and publishing integration tests.
- [x] Update canonical setup, diagnostics, and publishing guidance.
- [x] Run focused tests, formatting, analysis, and the full Linux test suite.
- [x] Verify the clean commit's publish dry-run and native macOS CI.

## Work and acceptance evidence

Keep signature, policy, stage provenance, helper authentication, and recovery
checks fail-closed. Diagnostics contain only enumerated phase/reason/action
values. Tests must cover hostile error text redaction, missing helper failure
before signing, valid helper acceptance, filename path rejection, defaults,
and matching custom artifact paths and URLs through packaging and publishing.

Validation commands (Flutter SDK at `/workspace/flutter-sdk/bin`, package
cache `/workspace/pub-cache`; Linux compiler and .NET fixtures installed):

```sh
flutter test --no-pub test/release_cli/macos_release_trust_test.dart test/release_cli/macos_notarization_test.dart test/release_cli/dmg_packager_test.dart test/release_cli/release_publish_config_test.dart test/release_cli/release_publisher_build_test.dart test/macos_swift_package_test.dart
dart format --output=none --set-exit-if-changed .
flutter analyze --no-fatal-infos
flutter test --no-pub
dart pub publish --dry-run
```

Native acceptance: `swift test --package-path .` and the CocoaPods 10.14
typecheck in the `macos-native` CI lane. Linux cannot execute Apple signing,
SMAppService, notarization, or the reporter's actual upgrade. No release or
version bump is part of this task. Existing authorization covers commit/push;
do not post issue comments through the connector.

## Surprises & Discoveries

- The failure message is emitted for multiple pre-handoff stages and restart
  preparation; `release validate` does not validate the installed host's helper.
- Low-level signing inventory allows helperless apps for general code-signing
  fixtures. Enforce host readiness at the production publishing boundary.
- Recovery parsing and failed-receipt cleanup were already fixed in 3.2.6;
  preserve those behaviors.

## Decision Log

- 2026-10-28: Proceed using public issue evidence only; user does not have the
  consumer's Xcode/helper configuration. Preserve uncertainty about its cause.
- 2026-10-28: Keep diagnostics typed and bounded instead of returning native
  localized descriptions, signing output, policy contents, or local paths.

## Outcomes & Retrospective

The helperless notarized-publish regression failed against the original code:
it reached signing and failed on the fixture's Team ID instead of rejecting
missing host setup. After the fix, it fails before any codesign, notarytool,
or packaging command with the required setup instructions.

Local evidence on Linux:

- Focused Dart suite: 134 passed.
- Formatting: 288 files checked, zero changes after formatting touched files.
- `flutter analyze --no-pub --no-fatal-infos`: exit 0; no errors or warnings
  (informational repository lints remain). The initial command without
  `--no-pub` attempted network resolution in a restricted sandbox; the cached
  dependency configuration was used for the successful analysis.
- Full `flutter test --no-pub --reporter expanded`: 993 passed, 22 skipped.
- Initial `dart pub publish --dry-run`: only the expected uncommitted-files
  warning; repeat on the clean commit.
- Added native tests for typed diagnostics, hostile native error redaction,
  missing host metadata, and retained DMG artifact binding/mutation rejection.
  These passed on the macOS CI host as recorded below; Linux source-contract
  checks alone were not used as native execution evidence.

Commit `bc89f64` passed the clean publish dry-run with zero warnings.
CI run `40640821371` passed Dart, documentation, and standalone CLI checks.
Both macOS integrations compiled, then exposed an outdated integration-test
expectation (`details: null`); the bridge correctly rejected the forged request
with bounded stage-verification details. Update that expectation to the exact
safe map. The native test build also exposed ambiguous Swift type inference in
the new DMG fixture's heterogeneous conditional dictionary; use an explicitly
typed install dictionary. Production code remains unchanged in this follow-up.

CI run `40641495512` on `6338591` passed both macOS Flutter integration lanes,
including forged-request rejection and real ad hoc release trust fixtures.
The native kit ran 155 tests: all diagnostics and host-metadata tests passed;
the new DMG fixture had one URL equality mismatch from macOS adding the
directory trailing slash. Compare standardized file URLs, matching the existing
ZIP fixture assertion. Artifact verification and mutation rejection succeeded.

Final implementation evidence at `71f984d`:

- [CI run 40642209911](https://github.com/MarlonJD/flutter_desktop_updater/actions/runs/40642209911):
  all six selected jobs passed, including the aggregate gate, macOS Native
  Consumer, SwiftPM and CocoaPods Flutter integration, and documentation.
- Native kit: 155 tests, zero failures; all four new preparation diagnostic
  tests and the DMG retained-artifact verification test passed.
- macOS 10.14 CocoaPods source-set typecheck, external SwiftPM consumer,
  forged-request rejection, real ad hoc release trust fixtures, and native
  runtime candidate-rejection smoke passed.
- The initial implementation run `40640821371` also passed its Dart, Linux,
  Windows, documentation, and four standalone CLI jobs. Its macOS failures
  were the test issues resolved above; final production code is identical.
- Follow-up local source-layout and documentation suite: 31 passed.
- Final analysis: exit 0, no errors or warnings (812 informational lints).
- Clean `71f984d` publish dry-run: zero warnings.

The implementation and available verification are complete. Credential-gated
notarized publish and SMAppService production lanes were not run. The original
consumer's signed app upgrade remains unverified; its generic 3.2.6 report
cannot establish whether helper setup, release keys, host metadata, or another
preparation step failed. No package version, release tag, or pub.dev release
was created.

The public report still cannot establish the original consumer's exact cause.
No reporter artifact, Apple credentials, or macOS host is available here.

## Retry, recovery, and dependencies

Retain current transaction recovery semantics. Fixing setup requires rebuilding
and reinstalling the outgoing app as well as rebuilding the update; rebuilding
only the incoming artifact cannot repair the already installed helper. Do not
delete ambiguous receipts or loosen trust policy to make an install pass.

## Revision history

- 2026-10-28: Initial plan after investigation of the 3.2.6 follow-up report.
- 2026-10-28: Complete after local validation and passing macOS CI; retain the
  explicit boundary between package verification and the unavailable consumer
  application's upgrade.
