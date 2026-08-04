# Entropy Cleanup Checklist

Run this read-only sweep manually after a material harness/architecture change,
when a repeated stale-reference pattern appears, or before refreshing a
`harness-ready` claim. Small confirmed repairs may be made only within the
current request. Broad remediation belongs in an ExecPlan.

## Documentation and Navigation

- [ ] Run `dart run tool/harness_gate.dart --structural`.
- [ ] Run `flutter test --no-pub test/harness_engineering_docs_test.dart`.
- [ ] Compare documented commands with manifests and current workflow files.
- [ ] Check the plan index for missing links, abandoned active work, and
  completed work with unresolved checkboxes.
- [ ] Find duplicated or contradictory authority text and keep one canonical
  owner.

## Code, Contracts, and Runtime

- [ ] Check architecture and trust boundaries against current fixtures and
  source-shape tests.
- [ ] Find repeated review/incident patterns that justify a focused test.
- [ ] Exercise registry commands that are marked verified.
- [ ] Check ignored report paths, temporary artifacts, and task-owned processes
  for safe cleanup.
- [ ] Confirm target-host claims still name the exact host, revision, and
  evidence rather than workflow configuration.

## Certification

- [ ] Confirm every coverage row is present and uses one allowed status.
- [ ] For every `verified` or justified `N/A` row, verify exactly one fresh
  HMAC-v2 record bound to the source commit and stable identities.
- [ ] Confirm the native full gate runs from clean direct-child attestation
  `HEAD`, and the external verifier returns `CERT000`.
- [ ] Invalidate the claim after any later commit, expired evidence, identity
  change, coverage digest change, failed command, or applicability change.
- [ ] Keep production attestation separate; do not infer it from a local key or
  ordinary certification.

## Current Triage

| Finding | Evidence | Impact | Action | Destination | Owner | Status |
| --- | --- | --- | --- | --- | --- | --- |
| Existing ExecPlans use several pre-v1 schemas | `docs/exec-plans/active/*.md` and `docs/PLANS.md` | Enabling strict managed validation would create false failures and overlap active work | Preserve repo-native lifecycle; use living sections for new plans and migrate only through an explicit plan | `docs/PLANS.md` | Repository maintainers | mitigated |
| Certification source boundary is not clean during adoption | `git status --short --branch` on 2026-07-23 | Current tests cannot be bound to a harness-only source commit without isolating unrelated work | Complete structural adoption; keep `harness-ready` blocked until a trusted source/attestation pair can be created | Active harness convergence plan | Repository maintainers | open |

## Automation Decision

Maintenance is manual and report-only by default. No scheduled agent, automatic
repair, pull-request creation, merge, release, or production write is enabled.
Changing that decision requires an explicit user request, deterministic
baseline, named owner, failure notification, rollback path, and updated
coverage evidence.
