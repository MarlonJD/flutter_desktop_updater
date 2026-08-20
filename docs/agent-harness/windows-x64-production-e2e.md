# Windows x64 Production E2E Runbook

This runbook records the reusable host-boundary workflow for Windows x64
production-readiness work. It describes how to produce and verify evidence; it
does not make a local test identity, App Control policy, or installed-system
mutation part of the package release.

The current product scope is B2C Windows distribution. App Control/WDAC
supplemental-policy authoring, enterprise base-policy authorization, and MDM
policy deployment are optional research lanes for a future enterprise feature;
they are out of scope and must not block the B2C release gate. If an enterprise
customer needs that integration, open an issue with the policy, signer,
deployment, rollback, and key-custody requirements before adding it to the
product contract.

## Scope and claims

Use this runbook for a clean, serial Windows x64 validation of native builds,
Flutter packaging, Authenticode, and installed-system smoke behavior. Keep
these claims separate:

- `verified locally` names the exact local command and host boundary that passed.
- `candidate-only` means local signing, trust, timestamp, release authority, or
  provider evidence is still incomplete.
- `not run` means the lane was intentionally not exercised.
- `blocked` identifies an external dependency, policy, approval, or host gate.
- `production-ready` is reserved for the complete applicable target-host,
  artifact, trust, cleanup, and release-authority convergence.

## Run lifecycle

Each stateful run gets a fresh run token and a bounded evidence directory.
Preserve the exact HEAD, branch, dirty state, owner and token identities,
integrity levels, UAC values, installed tools, active App Control policy
metadata, and pre-existing machine residue before mutation.

1. Resolve repository instructions and the active ExecPlan.
2. Capture the baseline without changing UAC, the base Code Integrity policy,
   or unrelated user/machine state.
3. Validate the official toolchain and perform a clean x64 native build.
4. Run focused native CTest, Flutter build, package, and integration gates.
5. Sign only the fresh test artifacts with a task-scoped non-exportable
   CurrentUser test identity when a local App Control lane requires it. Never
   export a private key or PFX, use LocalMachine certificate stores, or claim
   production trust from this identity.
6. If the host base policy blocks the fresh test artifacts, generate a
   supplemental App Control policy for this run only. Bind it to the observed
   base policy, add exact user-mode file-hash allow rules for the fresh PE
   files, and reject path, wildcard, or broad publisher rules. Validate the
   policy GUID, BasePolicyID, rule count, and rule scope before deployment.
7. Deploy the supplemental policy only with explicit task authority. Record
   the policy delta and keep the exact GUID for rollback.
8. Execute stateful lanes serially in this order: direct Flutter, ZIP, Release,
   and Inno/protected-install smoke. Do not start the next lane after a cleanup
   or evidence-integrity failure.
9. Remove the exact supplemental policy, test certificate, generated package,
   temporary profile/user/task/registry objects, and protected test root that
   this run created. Verify the base policy and baseline residue are unchanged.
10. Run final convergence and an independent residue/delta audit before
    reporting results.

## Evidence gates

Every failure keeps its first log and state snapshot. Classify it as
`environment`, `harness`, `product`, `timeout`, `cleanup`, or
`evidence-integrity`. A timeout may be diagnosed, but it is not fixed by
loosening a security control or silently extending the test until it passes.

Hard evidence for a stateful smoke should include the expected run marker,
exact process identity/PID, lifecycle and relaunch/recovery observations,
product-level result, and cleanup confirmation. Source scans, unsigned helper
launches, native crash/tamper CTest results, or packaging dry-runs do not count
as protected Program Files crash/tamper E2E evidence without a dedicated fault
harness.

UAC secure-desktop acceptance, standard-user elevation under normal policy,
production Authenticode with timestamp, and exact-head provider CI remain
separate gates. If UAC behavior cannot be exercised without changing policy,
leave that lane `not run` and preserve the existing UAC values.

## Artifact and policy retention

Keep the reusable procedure, validators, cleanup logic, and evidence schema in
the repository. Do not commit a run-specific XML/CIP policy, certificate,
private key, thumbprint, hash list, run token, absolute path, or generated
installer. Fresh signed artifacts and fresh exact-hash policy rules are
required for every future stateful run.

If production App Control support becomes an intentional product requirement,
create a separate security and release decision covering production signing,
timestamping, policy ownership, distribution, rollback, and revocation. This
local E2E runbook is not that approval.
