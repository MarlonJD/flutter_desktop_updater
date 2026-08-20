# Agent Harness

This directory is the progressive-disclosure entry point for repository-owned
capabilities that help an agent discover intent, execute scoped work, observe
behavior, prove outcomes, and preserve durable knowledge.

Its presence records an explicit adoption. The external skill remains
independent bootstrap and cross-check tooling: installation does not inspect,
modify, monitor, schedule, or certify this repository.

## Capability Map

| Need | Source of truth |
| --- | --- |
| Adopted authority paths | [`config.json`](config.json) |
| Available commands and expected signals | [`registry.md`](registry.md) |
| Human/agent workflow, review, and escalation | [`operating-loop.md`](operating-loop.md) |
| Local isolation, lifecycle, runtime signals, and cleanup | [`environment-contract.md`](environment-contract.md) |
| Windows x64 production E2E lifecycle and host-boundary evidence | [`windows-x64-production-e2e.md`](windows-x64-production-e2e.md) |
| Completion language and evidence labels | [`output-contract.md`](output-contract.md) |
| Change-to-verification mapping | [`verification-matrix.md`](verification-matrix.md) |
| Manual drift and entropy sweep | [`entropy-cleanup-checklist.md`](entropy-cleanup-checklist.md) |
| Complete capability inventory | [`coverage-matrix.md`](coverage-matrix.md) |
| Harness-ready convergence and invalidation | [`certification.md`](certification.md) and [`certification.json`](certification.json) |
| Long-running work | [`../PLANS.md`](../PLANS.md) and [`../exec-plans/index.md`](../exec-plans/index.md) |

## Route by Task

| Task | Read first | Continue with |
| --- | --- | --- |
| Understand the repository | [`../../AGENTS.md`](../../AGENTS.md) | [`../../ARCHITECTURE.md`](../../ARCHITECTURE.md) and [`../index.md`](../index.md) |
| Start or resume complex work | [`../PLANS.md`](../PLANS.md) | [`../exec-plans/index.md`](../exec-plans/index.md) and the matching active plan |
| Implement and verify a change | [`operating-loop.md`](operating-loop.md) | [`registry.md`](registry.md), [`verification-matrix.md`](verification-matrix.md), and [`output-contract.md`](output-contract.md) |
| Reproduce package, CLI, widget, or native behavior | [`environment-contract.md`](environment-contract.md) | The relevant runbook or exact command in [`registry.md`](registry.md) |
| Change a trust or release boundary | [`../../SECURITY.md`](../../SECURITY.md) | [`../publishing.md`](../publishing.md), [`../github-actions-ci-cd.md`](../github-actions-ci-cd.md), and a current ExecPlan |
| Audit or certify the harness | [`coverage-matrix.md`](coverage-matrix.md) | [`certification.md`](certification.md) and the repository-native gate |

## Current Maturity

| Dimension | State | Evidence | Next useful increment |
| --- | --- | --- | --- |
| Knowledge routing | Enforced | Root routes and focused docs test | Keep links aligned when authorities move |
| Planning continuity | Repeatable | Existing active/completed ledger and policy | Gradually use living sections in new plans |
| Executable verification | Repeatable | Focused tests and `tool/harness_check.dart` | Preserve deterministic, non-mutating checks |
| Agent-readable runtime | Repeatable | Fixture-driven Flutter/Dart tests, example tools, report paths | Add target-host evidence only on the relevant platform |
| Mechanical boundaries | Enforced in selected areas | Contract fixtures, source-shape tests, version and harness checks | Promote only stable or security-critical invariants |
| Entropy control | Repeatable | Manual checklist and debt tracker | Record a dated sweep after material harness changes |
| Safe autonomy | Repeatable | Repository instructions and operating loop | Keep Git, external, release, and production authority explicit |

The structural gate can validate this adopted shape before certification.
`harness-ready` remains a separate expiring source/attestation-bound result.
