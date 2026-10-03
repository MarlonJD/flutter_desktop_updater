# Project review findings remediation

## Context and scope

Address F01–F10 from `reports/project-review-2026-10-02.md` on the current
branch. The starting working tree is clean. Preserve the existing macOS native
implementation, the package release version, changelog headings, and lockfiles. No branch,
commit, hosted publication, or privileged installation is part of this task.

The user requested Luna agents at maximum reasoning for each fix. There is
only one writer per source tree. Independent fixes can run in isolated
temporary source copies, with separate test/build outputs; the parent reviews
and integrates their changed files sequentially into this checkout.

## Milestones and acceptance

1. F01: serialize install handoff before persistence; retain the dispatched
   transaction through repeats and ambiguous failures; authorize retry only
   through authenticated recovery evidence and verified staging.
2. F02: make immutable release paths include channel, version, build, and
   platform; reject accidental replacement and test feed variants.
3. F03: bound HTTP body consumption and cancel stalled streams before retry
   or cleanup, including unsuccessful responses.
4. F04: subscribe direct cards before testing state visibility.
5. F05: close only the owned dialog route after a successful skip.
6. F06: keep failure reports and recovery actions visible in public wrappers.
7. F07: compare decrypted Windows key seed bytes and preserve equal blobs.
8. F08: reject native HTTP error bodies before artifact writes on Linux and
   Windows, retaining only legitimate partial data.
9. F09: reset Windows partial downloads before streaming a full HTTP 200.
10. F10: exhaust Windows metadata status retries without advancing redirects.

Each milestone adds a focused regression, runs its relevant local tests, and
updates the owning documentation where behavior changes. Native target-host
tests are added to existing suites; unavailable hosts are recorded literally
as `not run`, without substituting source inspection for runtime evidence.

## Validation

Run the relevant focused Flutter tests after each Dart change, then run
`dart run tool/harness_check.dart` for format, analysis, version consistency,
harness docs, the full Flutter suite, and package publish dry-run. Native
transport changes use existing platform test fixtures and available native
build/test tools. Review the complete diff and clean up task-owned processes.

## Progress

- [x] Read repository instructions, architecture, harness policy, and report.
- [x] Inspect F01–F03 source and identify their primary failure mechanisms.
- [x] F01: protect install receipt identity and add authenticated approval
  retry; focused controller, recovery/store, and widget tests pass locally.
- [x] F02: isolate immutable publication identities and reject replacements;
  layout and publisher regressions pass.
- [x] F03: bound HTTP response consumption, finish cancellation before retry,
  and discard late responses; transport regressions pass.
- [x] F04: keep direct cards subscribed while initially idle; regression passes.
- [x] F05: dismiss only the owned update dialog after skip, including when
  another route overlays it; route safety regressions pass.
- [x] F06: keep failed updates visible in the wrapper/sliver; problem reports,
  check-again, and approval recovery actions pass widget tests.
- [x] F07: compare decrypted Windows key seeds and preserve equal ciphertext;
  fake-process and key-management tests pass.
- [x] F08: reject native error bodies before artifact writes; shared fixture passes.
- [x] F09: restart ignored Range responses before consuming full bodies;
  shared live HTTP fixture passes with the portable Curl backend.
- [x] F10: bound Windows metadata retry counts independently from redirects;
  status-count and oversized error-body fixtures pass with portable Curl.
- [x] Complete F01–F10 implementation and focused verification.
- [x] Complete broad validation and final review; record the publish dry-run
  working-tree warning and unavailable target-host checks.

## Surprises & Discoveries

- At task start, the checkout was clean; the report's historical uncommitted macOS
  work is not present as a working-tree diff in this task.
- The macOS helper reports authenticated transaction absence as a terminal
  successful query with an all-zero journal digest. Approval retry verifies
  the transaction ID and both digest fields before acting on that result.

## Decision Log

- 2026-10-03: use one writer at a time; all fixes are assigned to
  `gpt-6-luna` with `max` reasoning, as requested.
- 2026-10-03: retain single-use verified-stage and native recovery trust
  boundaries when fixing repeated install calls.
- 2026-10-03: use isolated temporary source copies for independent release,
  HTTP, and native fixes. No Git worktrees or branch operations are needed.

- 2026-10-03: raise the existing `http` dependency minimum to `1.5.0`,
  which introduced abortable requests required by F03. The package release
  version and lockfiles remain unchanged.

## Verification evidence

- F01, `verified locally`: `flutter test --no-pub
  test/updater_controller_test.dart` (16 tests), recovery/file-store tests
  (8 tests), and `test/update_ready_ui_test.dart` plus
  `test/update_dialog_listener_test.dart` (31 tests). Tests use the installed
  Flutter tools snapshot with analytics and version checking disabled.
- F01: touched Dart files formatted and `git diff --check` passed. Native
  helper code is unchanged; privileged real-helper approval smoke is `not run`.
- F02, `verified locally`: layout and publisher tests (32 tests), covering
  channel/build variants, unchanged earlier bytes, and duplicate identity
  rejection before packaging. Additional release command, app-archive command,
  and macOS package docs tests passed after updating two old generated-path
  expectations.
- F03, `verified locally`: `test/update_transport_test.dart` (13 tests) and
  the two bounded HTTP size-limit cases. Tests cover stalled success/error
  bodies, invalid ranges, abort signaling, a cancellation barrier, and late
  responses. The deadline begins after app-owned header generation. The
  dependency minimum must include the abortable request API.
- F04, `verified locally`: `test/update_ready_ui_test.dart` (23 tests), including
  a raw card transitioning from idle to an available update.
- F05, `verified locally`: `test/update_dialog_listener_test.dart` (15 tests),
  including asynchronous skip, optional fresh install, overlays, replaced
  routes, and embedded widgets with or without a Navigator. Targeted analysis reported no issues.
- F06, `verified locally`: `test/update_sliver_failure_test.dart` (2 tests).
  The macOS approval actions use a fake controller; native approval is not
  claimed by these widget tests.
- F07, `verified locally`: fake DPAPI process and key-management tests
  (21 tests). Real Windows CurrentUser repeated write and backup reimport
  regressions were added but are `not run` on macOS.
- F08, `verified locally`: `test/native_runtime_transport_contract_test.dart`
  (5 tests), plus the shared C++ transport fixture compiled against the Curl
  backend and run with a live HTTP fixture server on macOS. This verifies the
  portable Curl code, not a Linux target-host run. Windows native compilation
  and runtime tests are `not run` on this macOS host.
- F09, `verified locally`: native transport contract tests and the portable
  Curl C++ fixture on macOS, including a seeded partial and an ignored Range
  response. WinHTTP runtime tests are `not run` on this host.

- F10, `verified locally`: native transport contract tests (6 tests) and
  portable Curl C++ fixtures on macOS. Exhausted 503 responses make three
  requests; oversized 404 responses make one. Neither reports redirect-limit
  exhaustion. WinHTTP runtime verification remains `not run`.

## Broad validation

`dart run tool/harness_check.dart` ran against the combined changes on
2026-10-03. See `reports/harness-check.md` for full output.

| Check | Result |
| --- | --- |
| Harness structural gate | Passed; 31/31 declared coverage rows |
| Dart format | Passed; 287 files, zero changes |
| Flutter analyze, `--no-fatal-infos --no-pub` | Passed; informational lint output remains |
| Version consistency | Passed |
| Focused harness documentation tests | Passed |
| Full Flutter suite | Passed; 929 tests, 4 skipped |
| Publish dry-run | Exit 65; only warning is modified checked-in files |
| Whitespace/diff check | Passed |

The harness aggregate status is `failed` because pub treats the uncommitted
working-tree warning as exit 65. Package validation reported no other issue.
No commit or publication was requested. This warning is retained rather than
changing Git state to suppress it. The package release version,
changelog, lockfiles, and macOS native sources are unchanged.

The runner used temporary `dart` and `flutter` PATH wrappers that execute the
installed Dart binary and Flutter tools snapshot directly, with
`FLUTTER_ROOT=/Users/marlonjd/Developer/flutter`, analytics disabled, and
Flutter version checking disabled. The wrappers do not modify the SDK.

After moving this plan to `completed/`, the structural gate and all ten
focused harness documentation tests passed again. Task-owned temporary
source copies, fixture binaries, and generated .NET test outputs were
removed; no fixture server or Flutter test process remained. A second publish
dry-run after cleanup reported the same sole working-tree warning; its output
is in `reports/review-remediation-publish-dry-run.log`.

The final portable native transport fixture was built with:

```sh
clang++ -std=c++17 -Ilinux/native/src/runtime -Inative_runtime/cpp \
  -I/opt/homebrew/opt/openssl@3/include \
  linux/native/test/runtime/transport_fixture_test.cc \
  native_runtime/cpp/transport_fixture_tests.cc \
  linux/native/src/runtime/update_transport_curl.cc \
  linux/native/src/runtime/sha256_openssl.cc \
  native_runtime/cpp/redirect_url.cc \
  -L/opt/homebrew/opt/openssl@3/lib -lcurl -lcrypto \
  -o /tmp/desktop_updater_transport_fixture_f10
```

It ran against `tool/native_transport_fixture_server.dart --port 0`, with
`DESKTOP_UPDATER_TRANSPORT_FIXTURE_URL` set to the server's reported URL.
This is portable Curl verification on macOS. Windows WinHTTP, real Windows
CurrentUser DPAPI, Linux target-host suites, and privileged macOS approval
smoke remain `not run`.

## Outcomes & Retrospective

F01–F10 are implemented, reviewed, and covered by focused regressions. Every
finding's implementation was assigned to a Luna agent at maximum reasoning.
All combined local tests pass. Publication is not part of this task, and no
release or production-readiness claim is made.

Remaining target-host checks belong to the existing Windows/Linux CI lanes
and the privileged macOS smoke lane. The HTTP dependency minimum is now
`1.5.0` because cancellation requires its abortable request API.

## Revision history

- 2026-10-03: created the scoped remediation plan.
- 2026-10-03: completed all ten fixes, local validation, and evidence review.
