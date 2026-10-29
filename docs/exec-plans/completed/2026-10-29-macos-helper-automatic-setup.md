# Automatic macOS helper build-phase setup

## Context and acceptance

The user asked to automate the Xcode configuration needed after issue 82's
incremental-build metadata failure. Extend the existing `release helper-policy`
flow to configure the Flutter Runner helper phase without manual Xcode edits.
Preserve custom scripts, signing authority, unrelated targets, and worktree
changes. Work on the current main branch; no release or branch change is part
of this increment.

The user separately authorized the reporter reply. It was posted through the
MarlonJD `gh` keyring account, and the returned author and exact body were
verified: [comment 6496598916](https://github.com/MarlonJD/flutter_desktop_updater/issues/82#issuecomment-6496598916).
Evidence is `reports/releases/issue82-bundle-metadata-2026-10-29/reporter-repair-posted.json`.

## Progress

- [x] Inspect existing policy generation, Xcode phases, and available parsers.
- [x] Add atomic, scoped project edits with semantic verification and no-op reruns.
- [x] Configure or repair the Runner helper phase from `helper-policy`.
- [x] Resolve the package dynamically when a managed phase runs; retain reviewed
  policy/digest inputs without regenerating or repinning them during the build.
- [x] Test custom phases, ambiguous targets, malformed projects, no-op reruns,
  and untouched unrelated data.
- [x] Verify fresh SwiftPM and CocoaPods consumers through consecutive builds.
- [x] Run applicable package checks, preserve evidence, and clean owned fixtures.

## Decision Log

- Use macOS `plutil` as the authoritative OpenStep parser. Apply bounded text
  edits to selected project fields, then parse again and compare the entire
  semantic project to the intended result before writing atomically. This keeps
  unrelated formatting/comments and unknown attributes intact.
- Reviewed the current `xcodeproj`, `dart_xcodeproj`, and `xcode_parser` sources.
  Their full-project readers/writers either coerce scalar types, discard unknown
  attributes, raise the package's Dart floor, or use parsing that does not safely
  preserve arbitrary quoted lists. Do not add a dependency or rewrite unrelated
  project data for this narrow operation.
- Create a managed helper phase when absent. Preserve existing recognized custom
  helper scripts and exports while adding the generated plist input and repairing
  phase order. Reject ambiguous helper/Flutter phases before writing.
- The managed phase invokes a package CLI build entrypoint through Flutter's Dart
  SDK. Resolve its installed package path at runtime, so CocoaPods, SwiftPM, local
  dependencies, and package version changes do not require hardcoded cache paths.

## Verification

Start with focused project-edit and CLI tests. Exercise the actual generated
phase in fresh consumers, rerun setup to prove it is idempotent, then build
`1.0.0+1` and `1.0.0+2` and run real release preflight. Keep notarization and
installed-app behavior separate from this build/setup proof. Use the local
harness and an exact source export for package validation.

## Surprises & Discoveries

- The first packaging-test adaptation called `Isolate.resolvePackageUri` inside
  Flutter's test engine, which does not implement that operation. Exercise the
  actual Dart CLI subprocess instead. Its isolated environment also needs an
  explicit PATH to locate Dart. Both test setup failures are retained in the
  initial focused logs; the real CLI packaging test then passed.
- Xcode 27.1 requires macOS 12.0 for these fresh consumer fixtures. Set only the
  owned fixture and Pod deployment targets, leaving repository targets intact.
- While this work ran, the reporter confirmed that the already posted manual
  plist-input repair worked with 3.2.7: build 2 publication, the 1-to-2 update
  installation, and file access all succeeded. See
  [comment 6496938835](https://github.com/MarlonJD/flutter_desktop_updater/issues/82#issuecomment-6496938835).

## Outcomes & Retrospective

`verified locally`: `helper-policy` now creates or repairs the Runner helper
phase, its generated Info.plist input, phase order, and Runner user-script
sandboxing settings. Existing custom scripts, policy overrides, signing settings,
unrelated targets, unknown project attributes, and comments are preserved. The
editor uses plutil before and after scoped text changes, checks the whole
semantic result, rejects shared/ambiguous settings and symlinks, and refuses to
overwrite an intervening edit. `--no-configure-xcode` permits policy-only use.

New phases invoke `release helper-embed` through Flutter's Dart SDK and resolve
the installed package at build time. They read the reviewed canonical JSON and
pin without generating either during a build. The real packaging test proves
that a changed policy with a stale pin is rejected without modifying the signed
helper or host plist. It also covers paths containing spaces and Unicode.

Evidence is under `reports/releases/macos-helper-setup-2026-10-29/`:

- `verify-consumers.py`, `swiftpm/result.json`, and `cocoapods/result.json`:
  separate fresh consumers with no manually added helper phase. Both built
  `1.0.0+1` and `1.0.0+2`, preserved all four host fields, and passed actual
  `MacOSReleaseTrust.preflight` and `verifyInstallReadiness`. Both setup reruns
  were byte-identical. Source, canonical JSON, and pin stayed unchanged during
  builds. Logs, project snapshots, and final bundle plists are retained.
- `focused-setup-initial.log` and `focused-embed-native-after.log`: scoped
  editor/CLI checks and all 13 real packaging/pin checks passed. Initial failed
  test-environment attempts remain separately recorded.
- `harness-final.md`: structure, formatting, analysis with the repository's
  nonfatal-info policy, version consistency, 10 documentation tests, and the
  full **1,054-test suite passed (4 skipped)**. Workspace publish dry-run
  returned 65 solely for ten modified tracked package files; do not label this
  aggregate dirty-worktree harness passed.
- `source-export.json`, `verify-export.py`, and `export-publish-dry-run.log`:
  HEAD `139fc40cc15c5e4cd05161c8b8b1b3cbb49e8ab1` plus named local overlays;
  package dry-run passed with zero warnings. This is an uncommitted source
  export, not a release commit or published archive.
- `cleanup-and-preservation.json`: owned consumer/export/library-inspection
  directories and test-generated .NET outputs were removed; unrelated dirty
  files retained their original hashes. No GUI app was launched or installed.

The automatic-setup increment is complete locally. New hosted CI, publication,
notarization, and installed-app E2E were **not run** for this increment. The
reporter's successful update/file-access report is separate evidence for the
manual 3.2.7 repair. No branch, version, lockfile, tag, or release was changed.

## Revision history

- 2026-10-29: implemented automatic helper-phase setup and dynamic package
  resolution; verified fresh SwiftPM/CocoaPods consecutive builds and package
  checks, posted the authorized repair comment, and recorded reporter success.
