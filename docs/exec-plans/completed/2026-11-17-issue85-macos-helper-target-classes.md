# Issue 85: macOS helper target-class parity

## Scope

Fix [issue #85](https://github.com/MarlonJD/flutter_desktop_updater/issues/85):
a standard macOS user sends `protectedApplication` for an app installed in
`/Applications`, but the helper rejects the request before sealed-policy
authorization. Align the Swift parser, request schema, and Dart fixture
validator with the existing C++ target-class contract. Keep sealed-policy
authorization and strategy restrictions intact.

Work stays on the existing `main` branch. Preserve the pre-existing `.gitignore`
and plan-index edits and the two untracked October backport plans. Versioning,
publication, GitHub writes, and privileged installed-system mutation are outside
this local fix.

## Progress

- [x] Read issue, repository guidance, client classification, helper parser,
  sealed policy, C++ contract, and shared fixtures.
- [x] Reproduce the rejection with native regression tests.
- [x] Align request validation and add shared accepted/rejected fixtures.
- [x] Run focused and broad local verification, review the diff, and record
  evidence and remaining target-host limits.

## Surprises & Discoveries

- The request schema and Dart fixture validator omit both target classes too;
  the policy schema and C++ parser already support them.
- Existing shared request fixtures never exercise either omitted class.
- Native regression tests reproduced `unknownTargetClass` before the fix and
  passed afterward (8 focused tests). The first Flutter attempt could not
  compile because its existing package configuration referenced missing cached
  dependencies; `flutter pub get --enforce-lockfile --no-example` restored them
  without changing lockfiles.
- The working-tree harness passed the full test suite, structural gate, version
  check, and documentation tests. Its format/analyze checks also visited old
  ignored release probes; analysis additionally found stale example package
  paths. Publish dry-run reported only the uncommitted-file warning. Rechecked
  these three gates in a temporary copy of current source files and lockfiles,
  excluding ignored reports and resolving dependencies with
  `flutter pub get --enforce-lockfile`. All three passed there; existing
  non-fatal analyzer infos remain.

## Decision Log

- Accept `protectedApplication` for `directoryReplace` and
  `verifiedInstallerHandoff`, and `sameUserWritable` for `directoryReplace`,
  exactly as the existing C++ parser does.
- Exercise sealed-policy acceptance and denial after parsing. Recognizing a
  target class does not grant install authority.
- Use local fixture/native tests without changing user accounts, registering a
  daemon, or mutating `/Applications`.

## Verification

Start with `swift test --package-path macos/install_helper --filter
'NativeInstallRequestTests|MacSealedInstallPolicyTests'` before and after the
fix. Then run the complete helper and root Swift suites, portable C++ request
fixtures, `flutter test --no-pub test/native_install_helper_contract_test.dart`,
fixture generation `--check`, and `dart run tool/harness_check.dart`.
Keep task logs under `reports/issue85/`; the `.log` files are ignored.

| Command / check | Local result |
| --- | --- |
| Focused helper command above, before the fix | Reproduced `unknownTargetClass` in valid requests and policy authorization setup |
| Focused helper command above, after the fix | 8 tests passed |
| `swift test --package-path macos/install_helper` | 150 passed, 6 skipped because their dedicated CI/crash fixtures were not supplied |
| `swift test --package-path .` | 155 tests passed |
| Portable `native_install_request_fixture_tests.cc`, compiled with `clang++ -std=c++17 -Wall -Wextra -Werror -pthread` and repository-pinned GoogleTest 1.16.0 | 4 tests passed, including all 8 valid shared fixtures |
| `dart run tool/generate_native_install_helper_fixtures.dart --check` | Passed; 8 valid and 49 invalid request cases |
| `flutter test --no-pub test/native_install_helper_contract_test.dart` | 10 tests passed; schema coverage test rerun after removing new analyzer infos |
| `dart run tool/harness_check.dart` | Full Flutter suite: 1,161 passed, 7 skipped; structural, version, and focused documentation gates passed; working-tree limitations described above |
| `dart format --output=none --set-exit-if-changed .` in source copy | Passed |
| `flutter analyze --no-fatal-infos --no-pub` in source copy | Passed with existing non-fatal infos |
| `dart pub publish --dry-run` in source copy | Passed, zero warnings |
| `git diff --check` | Passed |

## Outcomes & Retrospective

The helper now recognizes both existing protocol classes and enforces their
strategy restrictions. Shared fixtures cover the previously missing valid
requests and reject invalid single-file/installer combinations. A native
regression verifies that a parsed protected-application request still requires
explicit sealed-policy permission. The request schema, fixture validator,
portable C++ fixture count, and normative protocol documentation agree.

Verified locally only. A real standard-user, administrator-approved SMAppService
update, notarization, Windows/Linux host runs, and new CI runs were not run.
No package version, lockfile, branch, commit, GitHub issue, or release was
changed. Release publication remains pending. Task-owned C++ dependency/build
files, temporary source copies, and .NET test build outputs are cleaned up;
verification logs remain available.

The user subsequently authorized commit, push, package publication, and a
GitHub CLI reply to the reporter. That follow-up is tracked in the
[3.2.12 release plan](../active/2026-11-17-desktop-updater-3-2-12-release.md).
