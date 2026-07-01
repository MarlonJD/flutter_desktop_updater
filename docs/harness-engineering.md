# Harness Engineering For desktop_updater

This document applies harness-engineering principles to `desktop_updater`: make
the repository readable to agents, turn project taste into mechanical checks,
and keep feedback loops local, repeatable, and cheap.

## Agent-Readable Repository Map

`AGENTS.md` is the compact entrypoint. It should point agents to the relevant
project knowledge without becoming a long handbook.

The durable knowledge base is:

- `README.md` for package overview and common user-facing flows.
- `docs/` and `doc/` for publishing, diagnostics, localization, UI, migration,
  and runtime policy guidance.
- `docs/exec-plans/index.md` for repository-backed execution plans.
- `docs/harness-engineering.md` for the agent operating model.
- `.github/workflows/desktop-updater-ci.yml` for the broad CI truth.

When a decision must survive future agent runs, put it in one of those files and
add a focused test when drift would be expensive.

## Mechanical Quality Gates

Prefer gates that an agent can run, read, and fix without external context.

The local validation ladder is:

```sh
flutter test --no-pub test/<focused_test>.dart
dart format --set-exit-if-changed .
flutter analyze --no-fatal-infos
flutter test --no-pub
dart pub publish --dry-run
```

To run the full local ladder with a small review artifact:

```sh
dart run tool/harness_check.dart
```

The runner executes format, analyze, the focused harness docs test, the full
Flutter test suite, and publish dry-run in that order. It writes command output
and exit status to `reports/harness-check.md`. Keep it local and secretless;
platform services, signing credentials, and release approvals belong in CI or
manual release lanes.

The broad platform gates are in GitHub Actions:

- Dart package formatting, analysis, tests, CLI entrypoints, and publish dry
  run.
- Windows debug/release builds, native tests, integration tests, release publish
  smoke, and update smoke.
- Linux debug/release builds, native tests, integration tests, release publish
  smoke, and update smoke.
- macOS notarized publish smoke only when explicitly dispatched with secrets.

`test/harness_engineering_docs_test.dart` is the first harness guard. It keeps
the agent map, this document, and the staged implementation plan discoverable.

## Agent Feedback Loops

Use feedback loops in this order:

1. Reproduce or protect the behavior with a focused Dart or Flutter test.
2. Run the focused command and read the failure.
3. Make the smallest change that satisfies the test.
4. Widen to format, analyze, and relevant test groups.
5. Use platform smoke tests or CI lanes only when native behavior changed.

For UI or native update behavior, leave evidence under `reports/` when a
screenshot, diagnostics log, or policy response explains the result better than
terminal output alone.

Use mechanical platform smoke evidence names:
`reports/<platform>-update-smoke-<mode>-diagnostics.jsonl`. Local work can use
that path when no secrets are needed. Windows and Linux smoke evidence usually
belongs to CI. macOS notarized smoke requires manual release approval and
secrets.

## Entropy Controls

Agents copy local patterns. Keep the patterns worth copying:

- Put long-lived decisions in docs instead of one-off prompt text.
- Add doc drift tests for important user-facing claims.
- Avoid broad rewrites when a focused rule or test would preserve the invariant.
- Keep plan status in `docs/exec-plans/index.md` so future work can resume
  without chat history.
- Remove obsolete examples and docs when replacing a workflow.

## Staged Adoption Plan

Stage 0 is the foundation added with this document:

- Add a short `AGENTS.md` repo map.
- Add this harness model.
- Add `docs/exec-plans/active/2026-07-01-agent-harness-engineering-plan.md`.
- Add `test/harness_engineering_docs_test.dart`.

Stage 1 should harden doc freshness:

- Check that `docs/exec-plans/index.md` links every active plan that should
  remain discoverable.
- Check that important README claims have matching deeper docs.
- Check that harness and diagnostics docs avoid stale references to plans as
  user-facing guidance.

Stage 2 should add a local harness runner:

- Create a single Dart tool that runs the validation ladder in a predictable
  order.
- Emit a small Markdown report under `reports/` for agent and human review.
- Keep the tool local and secretless.

Stage 3 should improve app-readable evidence:

- Standardize screenshot and diagnostics-log naming under `reports/`.
- Document when a platform smoke requires manual approval, CI, or secrets.
- Add focused tests for any new evidence format before relying on it in plans.

Do not treat these stages as release gates for unrelated feature work. They are
scaffolding that makes agent-driven changes easier to verify.
