# Execution Plan Policy

Use an ExecPlan for cross-cutting, risky, multi-hour, uncertainty-heavy work or
work that must remain resumable without chat history. Narrow mechanical changes
may use a lightweight task plan.

## Repository Lifecycle

[`exec-plans/index.md`](exec-plans/index.md) is the canonical ledger.
In-progress or blocked plans live under `exec-plans/active/`; verified plans
move to `exec-plans/completed/`; confirmed recurring cleanup belongs in
[`exec-plans/tech-debt-tracker.md`](exec-plans/tech-debt-tracker.md).

The ledger predates the external harness skill's strict `harness-plan:v1`
schema and contains large task-specific plans that remain authoritative. The
repository therefore does not declare `exec_plan_index` in
[`agent-harness/config.json`](agent-harness/config.json). This preserves the
repo-native lifecycle and prevents a config declaration from falsely asserting
that legacy plans satisfy a different schema.

New cross-cutting plans should use the following living sections even while the
legacy archive remains:

- `Progress`
- `Surprises & Discoveries`
- `Decision Log`
- `Outcomes & Retrospective`

They should also explain context, work milestones, exact commands, acceptance
evidence, retry/recovery behavior, dependencies, and revision history. Keep a
plan self-contained, written in English, safe to resume, and explicit about the
observable user or operator outcome.

## Authoring and Execution

1. Inspect the working tree and applicable instructions before adding a plan.
2. Create a lowercase-hyphenated Markdown file under `active/` and add exactly
   one link under the Active heading in the ledger.
3. Record independently verifiable milestones rather than treating code
   completion as behavior proof.
4. Keep progress, discoveries, decisions, outcomes, commands, and observed
   evidence current at every stopping point.
5. Preserve unresolved blockers in the active plan or debt tracker. Do not
   move a plan merely because implementation paused.
6. Before completion, run the applicable validation ladder, account for every
   unchecked item, document remaining gaps, move the same plan to `completed/`,
   and replace its Active entry with one Completed entry in the same edit.
7. Run `flutter test --no-pub test/harness_engineering_docs_test.dart` to
   verify index links and harness routes after a lifecycle change.

An ExecPlan can describe Git checkpoints, external review, CI, release, or
production steps. It does not grant authority for those actions. Current user
instructions and repository policy remain controlling.
