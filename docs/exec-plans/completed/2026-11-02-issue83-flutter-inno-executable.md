# Issue 83: Flutter Windows Inno executable resolution

## Context and acceptance

[Issue 83](https://github.com/MarlonJD/flutter_desktop_updater/issues/83) reports
that custom Inno packaging rejects an existing Flutter Windows Release
directory before compiling its script. Work on the current branch and preserve
unrelated local changes. This task covers local implementation and validation;
publication and GitHub feedback are outside its scope.

Acceptance: the Flutter adapter supplies the actual application executable to
the real Inno packager, which reaches compilation and records the correct
executable path and SHA-256. Custom executable overrides retain precedence.
Unresolved metadata and missing executables must fail before compilation with
actionable diagnostics.

## Progress

- [x] Reproduce the exact reported exception with a publisher-to-packager test.
- [x] Resolve literal Windows CMake `BINARY_NAME` after the Flutter build.
- [x] Preserve explicit overrides and reject computed or ambiguous inference.
- [x] Separate missing-directory and missing-executable diagnostics.
- [x] Validate executable inputs before creating the release output directory.
- [x] Document executable resolution and the existing explicit CLI option.
- [x] Run the focused adapter, Inno packager, and publisher tests: 63 passed.
- [x] Run the full local validation ladder and review the final diff.

## Surprises & Discoveries

- `FlutterProjectAdapter` forwarded only the optional executable override.
  The real Inno packager requires this metadata in both installer modes.
- The existing publisher test replaced the Inno packager entirely, so it did
  not exercise its required executable validation.
- Flutter itself reads Windows `BINARY_NAME` and appends `.exe`; the display
  name and custom installer filename do not identify the application binary.

## Decision Log

- Resolve one literal `BINARY_NAME` from `windows/CMakeLists.txt`; leave complex
  CMake evaluation to the existing `--executable-relative-path` override.
- Keep the packager's executable existence, safe-path, and SHA-256 checks.
  Do not infer an application by scanning helper executables.
- Defer output-directory creation until input validation completes, so missing
  executable metadata does not reserve a release identity with an empty folder.
- Use a stub compiler for local publisher-to-packager coverage, including a
  Unicode installer filename and a bundled helper. This does not establish
  real Windows ISCC, Authenticode, installation, or relaunch behavior.

## Verification

- `flutter test --no-pub test/release_cli/project_adapter_test.dart test/release_cli/inno_installer_packager_test.dart test/release_cli/release_publisher_build_test.dart --reporter expanded`: 63 passed.
- `git diff --check`: passed.
- `FLUTTER_ROOT=/Users/marlonjd/Developer/flutter dart run tool/harness_check.dart`:
  structure 31/31, analysis, version consistency, 10 harness documentation tests,
  and 1,068 full-suite tests passed (4 skipped). The aggregate runner returned
  1: its format command encountered the existing ignored
  `reports/releases/desktop_updater-3.2.8/preflight.dart`, and publish dry-run
  reported five modified package files. Neither exception was hidden or fixed
  by changing unrelated workspace files.
- After deferring directory creation, reran the 63 focused tests, the full
  1,068-test suite (4 skipped), and
  `flutter analyze --no-fatal-infos --no-pub`: all returned 0. Existing analyzer
  information diagnostics remain under the repository's nonfatal-info policy.
- A temporary `git archive HEAD` export with exactly the two changed source
  files, three changed test files, and owning product documentation overlaid
  passed `dart format --output=none --set-exit-if-changed .` (297 files,
  zero changes) and `FLUTTER_ROOT=/Users/marlonjd/Developer/flutter dart pub
  publish --dry-run` (zero warnings). This is an uncommitted source export.
- Final logs and source hashes are retained under
  `reports/releases/issue83-inno-executable-2026-11-02/`.

## Outcomes & Retrospective

The reported failure is reproduced and fixed locally. The real publisher and
Inno packager reach the stub compiler, preserve the custom script and Unicode
installer filename, and bind the correct application executable and SHA-256 in
the descriptor. Missing executables and unresolved metadata fail before
compilation and leave no output directory. Real Windows compilation and
installation are not run on this macOS host. No branch, package version,
lockfile, release, or GitHub state changed.

## Revision history

- 2026-11-02: reproduced issue 83, implemented executable inference and
  diagnostics, verified focused/full suites and clean-export package checks,
  and preserved the workspace harness's unrelated failure boundaries.
