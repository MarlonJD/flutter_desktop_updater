<!-- harness-plan:v1
id: 2026-07-23-harness-engineering-convergence-plan
status: completed
created: 2026-07-23
updated: 2026-07-23
completed: 2026-07-23
owner: Repository maintainers
-->

# Harness Engineering Convergence Plan

Maintain this plan according to the repository's
[execution-plan policy](../../PLANS.md). The existing plan ledger predates the
strict managed schema supplied by the external harness skill, so
`docs/agent-harness/config.json` intentionally does not opt into
`exec_plan_index` validation. This plan nevertheless uses the newer living
sections so it remains restartable without chat history.

## Purpose / Big Picture

Make `desktop_updater` agent-readable and mechanically checkable through
repository-owned documentation, a Dart-native harness gate, explicit authority
and evidence contracts, and the complete 31-capability coverage inventory.
Ordinary local adoption is complete when the structural gate and project checks
pass. The narrower `harness-ready` claim additionally requires a clean source
commit, a direct-child attestation commit, fresh HMAC-v2 evidence, and `CERT000`.

## Progress

- [x] (2026-07-23 12:05Z) Read repository instructions, architecture, existing
  harness documents, plan ledger, validation runner, CI contract, and current
  working-tree state.
- [x] (2026-07-23 12:08Z) Ran the adaptive skill audit and the focused existing
  harness documentation test; both completed without errors.
- [x] (2026-07-23 12:12Z) Classified the repository as an existing partial
  adoption and selected an adaptive, standard-like migration that preserves
  current authorities.
- [x] (2026-07-23 13:18Z) Added the authority map, harness contracts, full
  coverage matrix, documentation router, and manual entropy policy.
- [x] (2026-07-23 13:31Z) Added and exercised the repository-native Dart
  structural/prospective/final certification gate and deterministic evidence
  generator; integrated structural mode into the existing validation runner.
- [x] (2026-07-23 13:34Z) Reran the structural gate, focused docs suite, and
  focused Dart analysis: structural validation passed, all ten tests passed,
  and both harness tools reported no analyzer issues.
- [x] (2026-07-23 13:42Z) Ran the complete clean-source harness ladder:
  structural gate, non-mutating format, analyze, version check, focused harness
  test, full Flutter suite, and publish dry-run all exited zero.
- [x] (2026-07-23 13:44Z) Created source/attestation pair
  `1becd53407df33ef0b109e8725b2e55d7fa3c7d4` /
  `04ee6e7329683dd2d9e2563b09c42bec31a1f442`; final native gate, external
  warning-intolerant check, and external certification passed with `CERT000`.
- [x] (2026-07-23 13:47Z) Fast-forwarded the attestation commit onto
  `feat/native-sdk-platform-split` and pushed it to `origin` without staging or
  modifying the user's unrelated working-tree changes.
- [x] (2026-07-23 13:51Z) Closed this living plan, repaired the focused
  coverage test to recognize both pre-attestation and linked attestation
  statuses, and reran its ten tests successfully before renewing evidence.

## Surprises & Discoveries

- Observation: The existing adaptive audit reports zero errors and warnings,
  but only five informational discovery items and no explicit certification
  inventory.
  Evidence: `python3
  /Users/marlonjd/.codex/skills/harness-engineering/scripts/harness.py audit
  --root /Users/marlonjd/Developer/library/flutter_desktop_updater`.
- Observation: The repository already has a useful local runner and docs test,
  while its active plans use several older, task-specific schemas.
  Evidence: `tool/harness_check.dart`,
  `test/harness_engineering_docs_test.dart`, and
  `docs/exec-plans/active/*.md`.
- Observation: The working tree contains unrelated user changes, including an
  active macOS production plan, public Dart APIs, tests, and release docs.
  Evidence: `git status --short --branch` on 2026-07-23.
- Observation: `flutter --version` attempted to update the Flutter SDK cache
  outside the workspace and was denied by the filesystem sandbox, while the
  focused Flutter test itself passed.
  Evidence: the version command failed on
  `flutter/bin/cache/engine.stamp.tmp`; the focused test reported
  `All tests passed!`.
- Observation: The first warning-intolerant external check reported exactly 31
  `COVERAGE002` warnings and no errors.
  Evidence: every canonical row was intentionally `candidate` or `blocked`
  before source-bound evidence generation; routing, config, links, and table
  structure produced no warning.
- Observation: The prospective gate exposed two implementation defects before
  certification: trimmed Git porcelain paths and a manifest issuance timestamp
  older than the finalized project-gate observation.
  Evidence: both candidate attempts failed closed, the implementation was
  corrected in source commits `3e7d867` and `1becd53`, and the full ladder was
  rerun after each source change.
- Observation: The external certifier rejects ignored dependency and report
  outputs in its certification worktree even when Git status is otherwise
  clean.
  Evidence: the first external run returned `CERT014`; certification was rerun
  read-only in a second detached worktree with no ignored files and returned
  `CERT000`.
- Observation: The focused coverage test recognized plain `candidate` rows but
  not the evidence-linked `[verified](...)` form produced by successful
  attestation.
  Evidence: the post-attestation focused run found zero canonical rows; its
  parser now accepts both lifecycle forms and all ten tests pass.

## Decision Log

- Decision: Preserve the existing ExecPlan ledger and omit the explicit
  `exec_plan_index` authority from the new harness config.
  Rationale: Opting into the skill's strict validator would require a wholesale
  migration of large active plans and would overlap an unrelated dirty plan.
  The skill explicitly allows an incompatible repository-native lifecycle to
  remain unmapped.
  Date/Author: 2026-07-23 / Repository harness maintainer.
- Decision: Use an adaptive, standard-like authority map rather than copying
  the full standard scaffold.
  Rationale: Root `SECURITY.md`, `ARCHITECTURE.md`,
  `docs/diagnostics-and-recovery.md`, `docs/github-actions-ci-cd.md`, and the
  existing plan ledger are already canonical. Full-profile product and visual
  design authorities are not justified for this package-level adoption.
  Date/Author: 2026-07-23 / Repository harness maintainer.
- Decision: Keep hosted CI unchanged and use manual revalidation.
  Rationale: The user authorized repository adoption, not CI automation, and
  the skill requires manual mode by default.
  Date/Author: 2026-07-23 / Repository harness maintainer.
- Decision: Create a harness-only source commit and use a clean detached
  worktree for the broad runner, evidence preparation, and attestation commit.
  Rationale: The current branch contains unrelated user edits. Selecting only
  the known harness paths for the source commit and exercising that exact
  snapshot in an isolated worktree prevents those edits from contaminating
  evidence while avoiding a branch create/switch operation.
  Date/Author: 2026-07-23 / Repository harness maintainer.
- Decision: Separate broad command execution from the final external
  certification worktree.
  Rationale: Flutter dependency resolution and the ignored harness report are
  necessary for broad verification but violate the certifier's zero-extra-file
  boundary. A second read-only detached worktree preserves the exact same
  attestation commit without copied or deleted evidence.
  Date/Author: 2026-07-23 / Repository harness maintainer.

## Outcomes & Retrospective

The repository now has a concise router, mapped canonical authorities, a
complete 31-row inventory, deterministic HMAC-v2 evidence generation, a
three-mode Dart-native gate, manual maintenance rules, and a clean
source/direct-child attestation that returned `CERT000`.

The result is `harness-ready` for the bounded commit pair and evidence window;
it is not production attestation. Hosted CI automation, provider-authenticated
production proof, privileged target-host work, release, and deployment remain
outside this adoption. The user's unrelated API, release-documentation, and
test changes remained uncommitted and untouched.

## Context and Orientation

`desktop_updater` is a Flutter desktop plugin with Dart runtime and release
tooling plus macOS, Windows, and Linux native helpers. `AGENTS.md` is the root
router, `ARCHITECTURE.md` owns boundaries, `docs/harness-engineering.md` owns
the current validation philosophy, and `docs/exec-plans/index.md` owns the
existing task ledger. The installed skill is external bootstrap/cross-check
tooling and must not become a repository runtime dependency.

The target adds `docs/agent-harness/` as progressive disclosure, not as a
replacement for existing product, security, release, or architecture
documents. `tool/harness_gate.dart` will own deterministic repository-native
structure checks and fail closed for full certification when coverage or
evidence is incomplete. `tool/harness_check.dart` remains the broader,
secretless validation ladder.

## Plan of Work

First add the authority map and project-specific contracts, routing each topic
to an existing source of truth where possible. Add the complete canonical
coverage inventory with literal `candidate`, `blocked`, `verified`, or
justified `N/A` states.

Next implement a Dart-native gate with a structural mode suitable before a
source commit and a certification mode that validates resolved coverage,
manifest freshness, HMAC-v2 records, a clean source/direct-child attestation
boundary, and allowed attestation paths. Integrate structural validation into
the broader local runner and protect the new routes through the focused docs
test.

Finally run the focused docs/gate tests, create a harness-only source commit,
and exercise the broad runner from a clean detached worktree at that commit.
Prepare the evidence overlay, run its prospective gate, record that result,
commit the direct-child attestation, and run both final native and external
certification. This sequence completed and was pushed; future changes must
repeat it because any later source commit invalidates the bounded claim.

## Concrete Steps

Work from `/Users/marlonjd/Developer/library/flutter_desktop_updater`.

1. Edit repository files only with the controlled patch mechanism.
2. Run `dart run tool/harness_gate.dart --structural`; expect a zero exit only
   after every declared structural authority is valid.
3. Run
   `flutter test --no-pub test/harness_engineering_docs_test.dart`; expect
   `All tests passed!`.
4. Run
   `python3 /Users/marlonjd/.codex/skills/harness-engineering/scripts/harness.py
   check --root /Users/marlonjd/Developer/library/flutter_desktop_updater
   --warnings-as-errors`; expect no error or warning for the adaptive custom
   shape.
5. Run the safe applicable portions of the validation ladder and preserve
   literal outcomes in this plan.
6. Only if the repository state can be committed without capturing unrelated
   work, create source commit `S`, generate fresh records with an owner-only key
   outside the repository, create direct-child attestation commit `A`, and run
   the external `certify` command against trusted `A`.

## Validation and Acceptance

The structural adoption is acceptable when all new Markdown links resolve, the
authority config is project-specific, all 31 canonical coverage rows are
present, no scaffold marker remains, the Dart structural gate passes, the
focused harness test passes, and the external adaptive check passes with
warnings as errors.

`harness-ready` is acceptable only when the Dart certification mode passes from
a clean attestation `HEAD` and the external verifier emits `CERT000`. A
candidate manifest, a valid structure check, a workflow definition, or a local
HMAC key does not satisfy that claim.

## Idempotence and Recovery

All documentation and Dart checks are read-only. Re-running structural or
focused tests is safe. The broad harness runner writes only the ignored
`reports/harness-check.md`; failure leaves the report for inspection.

Do not delete, stash, reset, format, stage, or commit unrelated user changes.
If a certification attempt cannot isolate the harness source snapshot, leave
coverage and certification explicitly incomplete, record the blocker here,
and resume after the tree has a trusted clean source boundary.

## Artifacts and Notes

The baseline focused test passed eight tests before adoption. The final focused
suite passed ten tests. The final broad report recorded seven zero-exit stages,
including the full Flutter suite and publish dry-run. The adaptive external
check returned `0 error(s), 0 warning(s)`, and external certification emitted
`CERT000`. HMAC records under `docs/agent-harness/evidence/` retain the bounded
source observation; the raw key remains outside the repository.

## Interfaces and Dependencies

The repository-native gate is a Dart CLI under `tool/` and uses only
`dart:convert`, `dart:io`, and the existing `crypto` package. Its stable entry
points are `--structural` and the full `--attestation-key-file <absolute-path>`
mode. The external Python skill remains an independent cross-check and is never
called by repository CI or Dart tooling.

The authority declaration is `docs/agent-harness/config.json`. It maps the
canonical instructions, architecture, planning, registry, environment,
verification, coverage, and certification paths. It intentionally does not
declare `exec_plan_index`.

## Revision History

- (2026-07-23 12:15Z) Change: Created the convergence plan from repository
  discovery, adaptive audit, scaffold preview, and baseline focused-test
  evidence.
  Reason: Preserve a restartable record for the cross-cutting harness migration
  while protecting unrelated working-tree changes.
- (2026-07-23 13:36Z) Change: Recorded the implemented authority/coverage
  contracts, three-mode native gate, deterministic evidence generator, focused
  verification, and detached-worktree certification strategy.
  Reason: Keep the plan synchronized with the observed migration state before
  creating the source snapshot.
- (2026-07-23 13:47Z) Change: Recorded broad verification, fail-closed
  convergence fixes, `CERT000`, branch integration, push, remaining production
  boundaries, and completed the plan.
  Reason: Close the repo-native lifecycle with literal observed evidence while
  keeping future manual revalidation explicit.
- (2026-07-23 13:51Z) Change: Recorded the post-attestation focused-test parser
  repair and moved the plan into the completed ledger.
  Reason: Keep the durable plan synchronized with the last local feedback loop
  before issuing its successor source-bound evidence.
