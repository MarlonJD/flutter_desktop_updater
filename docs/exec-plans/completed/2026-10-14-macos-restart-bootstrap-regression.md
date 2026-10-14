# macOS restart bootstrap regression

## Context and scope

Complete the local follow-up to PR #80 on the existing `main` branch. Apply
its host bootstrap and setup guidance, protect the ordering before AppKit,
and explain why the 3.2.0 verification missed the failure. No branch change,
commit, push, merge, package version change, or signed production install is
part of this work.

## Milestones and acceptance

1. Apply the reviewed PR #80 changes and document the public early-bootstrap
   requirement.
2. Replace the simplified bundle fixture with `NSApplicationMain` loading a
   main nib. Exercise two consecutive executable replacements and verify a
   fresh, single LaunchServices registration after each restart.
3. Protect the example and README bootstrap ordering. Demonstrate that moving
   the wait after AppKit initialization fails the focused regression.
4. Run the relevant native tests and repository validation ladder. Record
   exact evidence and the limits of the unsigned/ad hoc fixture.

## Progress

- [x] Inspect the current branch, PR #80, PR #75, and the 3.2.0 tag.
- [x] Apply the three reviewed PR files without changing branches.
- [x] Add the nib-based, repeated-restart regression and bootstrap contract.
- [x] Demonstrate the regression rejects the old startup ordering.
- [x] Complete verification, cleanup, and the release retrospective.

## Surprises & Discoveries

- PR #75 merged as `7d0805f` on 2026-09-22. The 3.2.0 tag is `a415bd5`,
  contains that change, and was published the same day.
- Its bundle regression (`9954f22`) initializes `NSApplication.shared` and
  calls `application.run()`. It does not call `NSApplicationMain` or load a
  main nib, where Flutter registers plugins.
- The normal macOS CI lanes build and test both Flutter integrations, but
  their integration tests do not perform an actual successful update and
  observe its restart. The signed production update lane is explicitly
  manual (`workflow_dispatch`), not an automatic PR gate.
- The outgoing executable owns restart. An older app updating into 3.2.0
  cannot establish that 3.2.0's changed restart code works when it becomes the
  outgoing executable. The historical manual report does not identify both
  outgoing and incoming updater revisions, so its transition coverage cannot
  be independently established.
- The [3.2.0 tag CI run](https://github.com/MarlonJD/flutter_desktop_updater/actions/runs/35744902170)
  passed the native and both Flutter lanes; notarized and privileged macOS
  jobs were skipped. The same-commit pre-tag selective run `35744230998`
  skipped macOS lanes. Thus a green aggregate did not imply a signed Flutter
  update/restart test had run.

## Decision Log

- 2026-10-14: strengthen the existing secretless SwiftPM bundle regression
  rather than adding another production signing dependency. Keep its claim
  scoped to restart/bootstrap behavior, not helper installation or notarization.
- 2026-10-14: retain the plugin's defensive handoff validation; the host must
  consume valid restart requests before AppKit loads the nib.

## Verification

- `verified locally`: `swift test --filter MacApplicationBundleRestartTests`
  passed the real-main-nib fixture through two consecutive replacements.
- `verified locally`: temporarily removing the pre-AppKit wait, leaving the
  registration-time wait in `awakeFromNib`, made the same test fail both
  lifecycle assertions. Source was restored in a `finally` block. Evidence:
  `reports/pr80-late-bootstrap-mutation.log`.
- `verified locally`: `flutter test --no-pub
  test/macos_cocoapods_source_layout_test.dart
  test/macos_swift_package_test.dart test/native_helper_script_test.dart
  --reporter expanded` passed 35 tests, including the example/README bootstrap
  checks and negative late/unchecked/commented-wait cases.
- `verified locally`: `swift test --package-path .` passed all 146 XCTest
  tests, including the restored early-bootstrap fixture. Evidence:
  `reports/pr80-swift-suite.log`.
- `verified locally`: `dart run tool/harness_check.dart` passed the structural
  gate, format, analyze, version check, harness docs, and full Flutter suite
  (943 passed, 4 skipped). `dart pub publish --dry-run` exited 65 with exactly
  one warning: modified checked-in files. Its aggregate status remains
  `failed`; the warning was not suppressed by making an unauthorized commit.
  Evidence: `reports/harness-check.md`.
- After adding bootstrap checks to both the documentation and macOS native CI
  jobs, `flutter test --no-pub test/macos_cocoapods_source_layout_test.dart
  test/native_runtime_merge_gate_docs_test.dart --reporter expanded` passed
  all 24 tests. Evidence: `reports/pr80-ci-contracts.log`.
- `git diff --check` passed. Final process inspection found no remaining
  task-owned restart fixture, XCTest, or Flutter test process. Test temporary
  bundles were removed by their scoped teardown.
- `not run`: hosted CI for these uncommitted changes, a full Flutter-engine
  update, or Developer ID/notarized/privileged installation. The fixture uses
  ad hoc signing and direct executable replacement; it does not claim those
  production boundaries.

## Outcomes & Retrospective

A passing bundle-shaped test did not establish parity with Flutter's
application startup lifecycle. Version 3.2.0's regression initialized
`NSApplication.shared` without loading the main nib and therefore could not
catch a wait placed inside plugin registration. Passing normal Flutter
integration tests and skipped signed-update jobs did not fill that gap.

The fixture now loads a real main nib through `NSApplicationMain`, observes
the pre-AppKit restart child and the fully launched replacement separately,
and repeats the transition from the replacement process. A deliberate return
to the old late wait fails the test. Source contracts independently protect
the actual example and README entrypoint, and both relevant CI lanes run them.

Release acceptance must identify the outgoing updater revision and observe
the replacement process/version; a single update into new restart code may
still execute the old outgoing implementation. Consumer apps must add the
documented early bootstrap. This work is locally verified and remains
uncommitted on the original branch.

## Revision history

- 2026-10-14: plan created after PR review and release-history inspection.
- 2026-10-14: implementation, mutation verification, validation, and cleanup
  completed; moved to the completed ledger with production limits explicit.
