# Agent Environment Contract

The default harness surface is a Flutter/Dart package and fixture-driven test
suite. It does not require a persistent service, database, browser, or
telemetry stack. Platform smoke work uses the explicit target-host lanes and
diagnostics paths documented by the repository.

## Isolation Model

| Concern | Contract | Evidence |
| --- | --- | --- |
| Workspace isolation | Work in the current repository; inspect `git status --short --branch` before edits and avoid overlapping unrelated files | Adoption discovery recorded the pre-existing changed-path list |
| Dependency and cache isolation | Use the configured Flutter/Dart SDK and existing package cache; do not modify SDK installation files | Focused `flutter test --no-pub` passed; `flutter --version` cache mutation was denied and recorded instead of bypassed |
| Port and process allocation | Default unit/docs tests need no persistent port; e2e fixture servers own bounded test-process ports and teardown | Test fixtures under `test/fixtures/` and command-specific tests |
| Data and state isolation | Tests use repository fixtures and temporary directories; release or install mutation requires a named smoke lane | `fixtures/compat/`, test helpers, and platform runbooks |
| Artifact and log location | Ignored broad-run report at `reports/harness-check.md`; bounded platform diagnostics under documented `reports/` paths | Harness docs and `.gitignore` |

## Lifecycle Commands

| Stage | Exact command | Expected signal | Safe retry or cleanup | Status |
| --- | --- | --- | --- | --- |
| Setup | `flutter pub get` | Exit 0 and package config exists | Safe to rerun; do not change lockfiles for this package task | candidate during adoption |
| Structural harness check | `dart run tool/harness_gate.dart --structural` | Exit 0 and 31 canonical rows declared | Read-only and safe to rerun | candidate until post-edit validation |
| Focused behavior | `flutter test --no-pub test/<focused_test>.dart` | Exit 0 and all named tests pass | Test temp directories clean up on process exit | verified for the baseline harness docs test |
| Example app start | `flutter run -d <desktop-device>` from `example/` | App window starts on an explicitly selected desktop target | Stop the Flutter process; inspect for leftover app/test processes | candidate and only needed for interactive UI work |
| Reset | Remove only task-owned temporary fixtures or stop task-owned processes; do not reset Git or shared SDK state | The bounded temp/process target is absent | Resolve exact targets before cleanup | verified as policy; command is task-specific |
| Broad validation | `dart run tool/harness_check.dart` | Exit 0 and `reports/harness-check.md` says `passed` | Safe to rerun; report is overwritten and ignored | candidate for this adoption |

## Agent-Readable Surfaces

| Surface | Access path | Useful action | Expected evidence | Status |
| --- | --- | --- | --- | --- |
| Dart package and CLI | Focused tests under `test/`, CLI entry points under `bin/` | Run the closest fixture-driven test | Exit code and assertion output | repeatable |
| Flutter widgets | Widget tests under `test/`; example app when interactive proof is required | Pump state, inspect semantics/text, or capture a justified screenshot | Test output or bounded screenshot | repeatable |
| Native bridges and helpers | Platform test directories, native contract fixtures, and named smoke tools | Run on the relevant OS/host with prerequisites | Native test output and diagnostics artifact | candidate or blocked outside the named host |
| Logs | `reports/harness-check.md` and platform JSONL/log paths | Inspect the failed step or correlated update events | Bounded command transcript or structured event | repeatable |
| Metrics | No persistent service-level metrics system is part of this package | Use durations and provider job results only for the command being evaluated | Command/report timing, not an availability claim | N/A — library/package harness |
| Traces | No distributed tracing backend is part of this package | Use structured helper diagnostics and test transcripts | Correlated local event sequence | N/A — no distributed service topology |

## Concurrency and Cleanup

Do not let concurrent agents edit the same working tree. Read-only inspection
and independent verification can run in parallel only when they do not mutate
formatting, build outputs, reports, SDK caches, ports, or shared target-host
state. Before handoff, stop task-owned Flutter, browser, test-server, native
smoke, or helper processes and preserve unrelated user processes. Never clean
with a broad recursive target or reset the user's working tree.
