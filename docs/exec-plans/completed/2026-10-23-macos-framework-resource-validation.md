# macOS framework resource validation

## Context and scope

Issue #82 reports that the 3.2.3 release preflight rejects
`App.framework/Versions/A/Resources/flutter_assets/packages/flutter_inappwebview/assets/t_rex_runner/t-rex.css`
as executable non-Mach-O code. The published flutter_inappwebview 6.1.5 and
6.2.0-beta.3 archives both contain the CSS and HTML assets with mode 0755.
The current validator reproduces the failure with those assets in a temporary
versioned framework. The reporter's exact dependency version remains unknown.

Fix the resource classification on the current branch without changing file
permissions, Mach-O discovery, signing, package versions, or release state.
Preserve the unrelated existing working-tree changes. No GitHub write is part
of this task.

## Milestones and acceptance

1. Reproduce executable resource rejection in focused regression tests.
2. Recognize standard resource paths relative to the nearest validated
   bundle. Keep native code detection and executable code-location rejection.
3. Document the behavior and verify published assets, focused tests, and the
   repository validation ladder.

## Progress

- [x] Inspect the validator, bundle inventory, published assets, and repo rules.
- [x] Add regressions and observe the original resource failure.
- [x] Implement bundle-aware resource classification and document it.
- [x] Complete local validation and record its limits.

## Surprises & Discoveries

- `_isAllowedCodeLocation` accepts every descendant of `Contents/Frameworks`,
  including framework resources, so an execute bit triggers the code gate.
- Removing execute bits from both published assets makes the original
  preflight succeed; changing only one leaves the other failure.
- Mach-O discovery already examines file bytes independently of permissions
  and extension. That behavior must remain unchanged.

## Decision Log

- 2026-10-23: classify non-Mach-O resources using the nearest validated bundle
  and its standard resource layout. Do not add extension exceptions or mutate
  permissions in the read-only preflight.
- 2026-10-23: stop at nested bundle boundaries, so a nested app's code path
  cannot inherit its containing framework's resource classification.

## Verification

- `verified locally`: before the fix, the focused trust suite passed 17 tests
  and failed the 8 new resource-acceptance cases, including the exact reported
  versioned framework asset path. Mach-O discovery and negative code-location
  cases passed against the original implementation.
- `verified locally`: the fixed trust suite passed all 25 tests. The 16 new
  cases cover versioned and flat framework resources, other supported bundle
  resource layouts, byte/mode preservation, native code disguised as CSS, and
  executable non-Mach-O rejection including a nested app's code directory.
- `verified locally`: the downloaded-asset probe passed all 12 assertions
  across flutter_inappwebview 6.1.5 and 6.2.0-beta.3. Both 0755 assets are
  accepted unchanged; a real Mach-O named `.css` remains a target and a shell
  script in `Contents/MacOS` remains rejected. No signing was invoked.
- `verified locally`: a separate native fixture with a compiled app and
  versioned framework retained the published 0755 CSS/HTML through ad hoc
  signing, ZIP packaging, extraction, and strict signature verification.
  Tampering with either resource was rejected by `codesign --verify --deep
  --strict`. The fixture was removed. This is resource-seal evidence only,
  not Developer ID/notarized release acceptance.
- `verified locally`: the combined trust and notarization suites passed all
  27 tests. The publisher regression preserves a 0755 CSS resource and signs
  only the two framework targets and the outer app.
- `verified locally`: formatting passed for all 287 Dart files without
  changes. `flutter analyze --no-fatal-infos` exited 0 with 778 informational
  diagnostics and no warnings or errors; the changed code adds no diagnostic.
- `verified locally`: the full Flutter suite passed 962 tests with 4 skipped.
- `verified locally`: after moving this plan to the completed ledger, all 10
  harness documentation tests passed, including the structural gate. Final
  `git diff --check` passed.
- `dart pub publish --dry-run` exited 65 with one warning: the three edited
  source/test files are uncommitted. There were no other package validation
  warnings. Publication remains pending.
- The analyzer's example lockfile changes were reverted, and generated
  .NET compatibility-test `bin/` and `obj/` directories were removed. Existing
  user changes remain intact. Temporary app/framework fixtures were removed;
  no fixture application was launched.
- `not run`: hosted CI, the reporter's application, Developer ID signing,
  notarization, or a production update. The original file-picker symptom is
  outside this focused CSS/HTML preflight fix.

Validation commands:

```sh
flutter test --no-pub test/release_cli/macos_release_trust_test.dart --reporter expanded
flutter test --no-pub test/release_cli/macos_release_trust_test.dart test/release_cli/macos_notarization_test.dart --reporter expanded
dart format --output=none --set-exit-if-changed .
flutter analyze --no-fatal-infos
flutter test --no-pub --reporter expanded
dart pub publish --dry-run
flutter test --no-pub test/harness_engineering_docs_test.dart --reporter expanded
git diff --check
```

The temporary published-asset probe preserved CSS/HTML bytes and modes,
inventoried a Mach-O file named `.css` with mode 0644, rejected executable
non-Mach-O code in `Contents/MacOS`, and removed its fixture bundles. Probe
scripts, downloaded assets, and reports remain temporary local evidence,
not package dependencies.

## Recovery and dependencies

The fix uses the existing validated bundle inventory and path utilities; no
new dependency is needed. Tests create temporary bundles and remove them with
teardown. If a boundary regression fails, keep signing blocked and correct the
classification before continuing. Do not change unrelated dirty files or
commit merely to satisfy a publish dry-run warning.

## Outcomes & Retrospective

The read-only preflight now accepts executable-bit data in standard validated
bundle resource directories, including versioned Flutter framework assets.
It does not change their bytes or permissions. All files still undergo
Mach-O detection, and nested bundle code paths remain subject to the existing
non-Mach-O executable rejection.

The regression needed both a real versioned-framework layout and executable
resource permissions; the previous topology fixture did not combine those
conditions. Local fixture verification establishes the classification fix
and resource sealing, not the reporter's file-picker behavior or a Developer
ID/notarized production release.

## Revision history

- 2026-10-23: created the bounded implementation and verification plan.
- 2026-10-23: completed the local fix, negative-boundary regressions,
  published-asset and ad hoc resource-seal probes, and validation ladder;
  moved to the completed ledger with release limits recorded.
