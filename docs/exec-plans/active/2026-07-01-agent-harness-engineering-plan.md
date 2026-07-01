# Agent Harness Engineering Plan

**Goal:** Keep `desktop_updater` easy for agents to inspect, change, and verify
without burying them in stale plans or long prompt-like instructions.

**Current shape:** `AGENTS.md` is the compact map, `docs/harness-engineering.md`
is the operating model, and `docs/exec-plans/` is the small execution ledger.

## Local Validation Ladder

```sh
flutter test --no-pub test/harness_engineering_docs_test.dart
dart format --set-exit-if-changed .
flutter analyze --no-fatal-infos
flutter test --no-pub
dart pub publish --dry-run
```

## Stage 0: Foundation

- [x] Add `AGENTS.md` as the short repo map.
- [x] Add `docs/harness-engineering.md` as the durable harness model.
- [x] Replace the old broad plan archive with `docs/exec-plans/`.
- [x] Add `docs/exec-plans/index.md`.
- [x] Add `docs/exec-plans/completed/README.md`.
- [x] Add `docs/exec-plans/tech-debt-tracker.md`.
- [x] Add `test/harness_engineering_docs_test.dart`.
- [x] Remove stale prompt-router files.

## Stage 1: Freshness Guards

- [x] Keep `docs/exec-plans/index.md` links resolving.
- [x] Keep old plan-archive references out of `AGENTS.md` and
  `docs/harness-engineering.md`.
- [x] Keep active plans short enough to read in one pass.

## Stage 2: Local Harness Runner

- [ ] Add `tool/harness_check.dart`.
- [ ] Have it run format, analyze, test, and publish dry-run in order.
- [ ] Write `reports/harness-check.md` with command output and exit status.

## Stage 3: Evidence Naming

- [ ] Standardize platform-smoke evidence under `reports/`.
- [ ] Document when platform smoke belongs to local work, CI, or manual release
  approval.

## Notes

- Do not treat harness stages as release gates for unrelated feature work.
- Prefer a focused test or small ledger entry over a long prompt-like plan.
