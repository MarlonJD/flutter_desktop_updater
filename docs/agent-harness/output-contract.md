# Agent Output Contract

Use literal evidence labels and keep the claim no broader than the observed
command, host, commit, or authority.

## Required Handoff

1. Lead with the delivered behavior or repository artifact.
2. Name material paths changed.
3. Report exact commands and scoped outcomes.
4. Separate gaps, deferred debt, and approval-dependent work.
5. State external, privileged, release, target-host, or production work only
   when it actually occurred with the required authority.
6. For public API or platform changes, distinguish local tests from exact-head
   provider/target-host evidence.

## Evidence Labels

| Label | Meaning |
| --- | --- |
| `verified locally` | The exact command or behavior passed in the stated local task environment. |
| `not run` | The exact check was intentionally not exercised; include the reason. |
| `blocked` | A named host, dependency, secret, approval, clean source boundary, or authority prevented progress. |
| `candidate-only` | The implementation or contract exists but lacks evidence required for its stronger claim. |
| `harness-ready` | The current source/direct-child attestation pair, complete 31-row evidence set, project-native gate, and external verifier passed with `CERT000`. It is not release or production authority. |
| `release pending` | Local implementation is complete but required publisher, target-host, approval, or external release evidence does not exist. |
| `production-ready` | Use only after an explicitly requested provider-backed production attestation authenticates repository, target, approval, rollback, artifact, freshness, and revocation. Local HMAC evidence and `CERT000` alone are insufficient. |

## Repository-Specific Evidence

- Dart/package work: focused test plus the applicable broader ladder.
- Public API changes: focused compatibility behavior and documentation drift
  check.
- Native contract changes: Dart/native fixture parity and the relevant host
  build or test.
- Privileged install, recovery, signing, or notarization: named target-host
  evidence; source scans, mocks, dry runs, and workflow definitions do not
  substitute.
- UI behavior: widget assertions; add a screenshot only when it materially
  clarifies visual or interactive state.
- Harness changes: structural gate, focused docs test, external adaptive check,
  and a fresh `CERT000` only when claiming `harness-ready`.

Git staging, commits, pushes, pull requests, issue comments, releases, and
deployments must be reported only after they actually succeed.
