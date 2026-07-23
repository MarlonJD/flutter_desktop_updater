# Human and Agent Operating Loop

Use this loop only after an explicit repository-scoped request. Skill
installation, a previous task, or a configured workflow does not start work or
grant authority.

## Responsibilities

| Role | Owns |
| --- | --- |
| Package maintainers | Package intent, public API and compatibility policy, risk acceptance, release policy, and final acceptance |
| Platform/release owner | Target-host prerequisites, signing and notarization credentials, privileged smoke approval, rollback decisions, and publication authority |
| Agent | Discovery, planning, reversible repository-local implementation, focused verification, self-review, evidence capture, and durable documentation within the current request |
| Mechanical harness | Deterministic tests, format/analyze checks, schema and fixture checks, structural harness validation, and actionable failure output |

## Task Loop

1. Read `AGENTS.md`, the architecture map, this harness, and the owning product
   or platform document.
2. Inspect branch and working-tree state; preserve unrelated changes.
3. Reproduce behavior or establish a measurable baseline.
4. Create or resume an ExecPlan when work is cross-cutting, risky, or must
   survive context loss.
5. Implement the smallest independently verifiable increment.
6. Run the focused check, review its output, then widen according to the
   verification matrix.
7. Exercise package, CLI, widget, or native behavior through the environment
   contract when that surface changed.
8. Review the diff, tests, public API compatibility, generated artifacts,
   failure modes, cleanup, and recovery.
9. Capture lasting judgment in the owning document, a test, a guard, or the
   debt tracker.
10. For a `harness-ready` claim, refresh every affected HMAC-v2 record, create
    the clean source/direct-child attestation pair, run both native and external
    gates, and require `CERT000`.
11. Hand off with literal evidence labels from the output contract.

## Review Policy

| Change surface | Local self-review | Independent review | Stop condition | Human review | Failure or escalation |
| --- | --- | --- | --- | --- | --- |
| Documentation or narrow Dart tests | Diff plus focused test | Optional when risk remains low | Commands pass and links/claims match the tree | Risk-based | Keep the change local and record unresolved ambiguity |
| Public API, trust, install, recovery, or cross-platform contract | Diff, focused tests, compatibility fixtures, and broader relevant suite | Required before merge according to repository practice | Findings resolved or explicitly accepted by maintainers | Required for compatibility or product judgment | Keep release claims pending and update the active plan |
| CI, signing, privileged target-host, release, or production | Local config validation only | Provider/target-host owner review and observed run | Exact-head named gate and required approval pass | Required | Stop without secrets, host, approval, rollback authority, or external-write authority |
| Harness certification | Structural gate, coverage review, full native gate, and external cross-check | Maintainer review of identities, applicability, evidence, and commit boundary | `CERT000` for current attestation `HEAD` | Required before treating evidence as a durable repository claim | Keep `harness-ready` invalid and expose the exact failed row or boundary |

## Feedback and Recovery

| Signal | Immediate response | Durable feedback |
| --- | --- | --- |
| Focused test failure | Diagnose the smallest current increment | Improve the reproducing fixture when it exposes a gap |
| CI-only or target-host failure | Reproduce safely or isolate the environment difference | Update the exact lane, prerequisites, diagnostics, and recovery path |
| Repeated review finding | Fix the occurrence and inspect adjacent surfaces | Promote a stable invariant to docs, a test, or a focused guard |
| User-visible defect | Capture input, state, and expected behavior | Add acceptance evidence and update product/reliability knowledge |
| Harness drift | Run structural mode, repair only authorized local drift, and rerun checks | Update coverage, registry, entropy finding, or active plan |
| Certification failure | Keep the claim invalid; do not weaken coverage or fabricate records | Refresh from a trusted source snapshot or record the authority blocker |

## Escalation Boundaries

Ask or stop when work requires destructive cleanup, branch operations, secrets,
signing/notarization identities, privileged mutation, target-host access,
external writes, issue or review posting, merge, release, publication,
production access, rollback approval, or product judgment not already granted.
The user invocation authorizes ordinary reversible harness adoption and local
verification only.
