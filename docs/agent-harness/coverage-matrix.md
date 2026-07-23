# Harness Engineering Coverage Matrix

This is the complete 31-capability inventory. During adoption, `candidate` and
`blocked` keep incomplete evidence visible. A `harness-ready` attestation may
contain only `verified` or justified `N/A` rows, each linked from the status
cell to exactly one fresh HMAC-v2 evidence record.

## Status Contract

- `verified`: exercised through the declared boundary with a fresh linked
  HMAC-v2 record for certification.
- `candidate`: the repository implementation exists but source-bound evidence
  is not complete.
- `blocked`: a named dependency or authority prevents verification.
- `N/A`: genuinely inapplicable, with a durable reason and fresh applicability
  record for certification.

## Coverage

| Source principle or capability | Repository implementation | Required evidence | Status and reason |
| --- | --- | --- | --- |
| Humans set intent; agents execute within authority | [`operating-loop.md`](operating-loop.md), root instructions, and owning product/platform docs | Named judgment boundaries and one completed task trace | candidate — boundaries are documented; source-bound task evidence is pending |
| Break large goals into reusable design, code, review, test, and verification steps | [`../PLANS.md`](../PLANS.md) and active ExecPlans | Restartable plan with independently verified milestones | candidate — the current convergence plan uses living sections; attested completion is pending |
| Agents can self-review and respond to feedback | [`operating-loop.md`](operating-loop.md) and [`output-contract.md`](output-contract.md) | Review procedure plus a resolved finding trace | candidate — review policy exists without a current HMAC-v2 trace |
| Application behavior is directly readable | [`environment-contract.md`](environment-contract.md), fixture tests, and example tools | Reproduced CLI/widget/native behavior with observed evidence | candidate — package surfaces are mapped; attested observation is pending |
| Logs, metrics, and traces are queryable when relevant | [`environment-contract.md`](environment-contract.md) and [`registry.md`](registry.md) | Project-appropriate query/result or justified applicability | candidate — logs are mapped and metrics/traces are explicitly package-scoped |
| Repository knowledge is the durable record | [`../index.md`](../index.md), [`../../AGENTS.md`](../../AGENTS.md), and canonical docs | Resolved routes and decisions independent of chat | candidate — structural and focused checks must be rerun after adoption edits |
| Repository tools and authorized work context are directly invocable | [`registry.md`](registry.md), `tool/`, Git read-only commands, and configured workflow docs | Exercised repository command plus source-control/CI context or justified applicability | candidate — local commands and Git context are mapped; provider context was not queried |
| Dependencies and abstractions remain agent-legible | [`../../ARCHITECTURE.md`](../../ARCHITECTURE.md), schemas, fixtures, and native contracts | Discoverable upstream/contract behavior with executable proof | candidate — contracts exist; current source-bound conformance evidence is pending |
| `AGENTS.md` is a concise map, not an encyclopedia | [`../../AGENTS.md`](../../AGENTS.md) and [`../index.md`](../index.md) | Routes before the 32 KiB cutoff and applicable instruction-chain evidence | candidate — root file is 2.4 KiB before edits and has no nested instruction layer; post-edit evidence pending |
| Plans are versioned living artifacts | [`../PLANS.md`](../PLANS.md), [`../exec-plans/index.md`](../exec-plans/index.md), and active plans | Unambiguous lifecycle with current progress, decisions, and evidence | candidate — legacy plans remain repo-native; the new plan demonstrates the preferred living sections |
| Architecture and critical taste boundaries are mechanical | [`../../ARCHITECTURE.md`](../../ARCHITECTURE.md), contract fixtures, and focused structural tests | Actionable failing and passing invariant check | candidate — selected boundaries are mechanized; current attested run is pending |
| Local autonomy exists inside enforced central boundaries | [`operating-loop.md`](operating-loop.md), root instructions, and security/release policy | Allowed actions, escalation gates, and recovery path | candidate — documented and awaiting task-trace evidence |
| Verification proves working behavior, not only code changes | [`verification-matrix.md`](verification-matrix.md), focused tests, and smoke contracts | Exact commands plus user-visible or operational evidence | candidate — matrix is implemented; current evidence set is incomplete |
| Failures and review judgment feed back into the harness | [`operating-loop.md`](operating-loop.md), docs tests, and debt tracker | Finding promoted into docs, a test, guard, runbook, or debt item | candidate — Flutter SDK cache denial and legacy-plan mismatch are recorded; attestation pending |
| Entropy and technical debt are continuously controlled | [`entropy-cleanup-checklist.md`](entropy-cleanup-checklist.md) and [`../exec-plans/tech-debt-tracker.md`](../exec-plans/tech-debt-tracker.md) | Dated sweep evidence and bounded follow-up | candidate — manual sweep is defined and current findings are triaged |
| Autonomy increases only after test, review, recovery, and escalation loops exist | [`operating-loop.md`](operating-loop.md), [`registry.md`](registry.md), and [`output-contract.md`](output-contract.md) | Evidence for the granted level and unavailable higher levels | candidate — local reversible work is separated from Git/external/release authority |
| Merge throughput policy matches project risk | Root policy, [`../../SECURITY.md`](../../SECURITY.md), and [`../github-actions-ci-cd.md`](../github-actions-ci-cd.md) | Project-specific gate rationale based on failure cost and recovery | candidate — risky trust and target-host gates remain explicit; review trace pending |
| Release, deployment, and production actions require repository-local authority | [`operating-loop.md`](operating-loop.md), [`output-contract.md`](output-contract.md), [`../publishing.md`](../publishing.md), and CI contract | Denial/escalation plus approval and rollback evidence | blocked — this package documents release tooling, but no production owner/provider attestation was authorized for this task |
| Repository-specific OpenAI examples are treated as options, not universal mandates | Case-study ledger below and architecture decisions | Independent decision and repository-specific reason for every listed choice | candidate — all choices are resolved below; applicability records are pending |

## Case-Study Decision Ledger

| OpenAI case-study choice | Local decision or implementation | Required evidence | Status and reason |
| --- | --- | --- | --- |
| Zero human-authored code as an operating constraint | Rejected; maintainers own intent, judgment, acceptance, and may author any repository surface | Responsibility model and provenance policy | candidate — rejection is documented in the operating loop without an applicability record |
| Reported repository size, pull-request throughput, elapsed-time speedup, and long agent-run duration as targets | Rejected as targets; use behavior, safety, compatibility, and evidence quality | Outcome measures remain independent of case-study metrics | candidate — decision is documented and awaiting applicability evidence |
| Local and cloud agent review loops continue until reviewers are satisfied while human review is optional | Not adopted universally; independent and human review are risk-based and required for trust/release boundaries | Review policy, stop condition, and one exercised trace | candidate — policy exists; exercised trace pending |
| Per-worktree application isolation | Current mode preserves one explicit working tree; clean detached worktrees may be used only for authorized isolated verification | Collision-free setup/reset/teardown proof | candidate — current dirty-tree preservation is observed; detached verification was not run |
| Per-worktree observability stack | Not adopted; this package uses task reports, test output, and platform diagnostics rather than a persistent stack | Signal correlation or applicability record | candidate — package-specific alternative is documented |
| Chrome DevTools Protocol for UI control | Not a default; Flutter widget tests and selected desktop-host inspection are the primary UI evidence | Widget/host evidence or applicability record | candidate — no browser surface requires CDP |
| Victoria Logs, Metrics, and Traces with LogQL/PromQL/TraceQL | Not adopted; the package has no persistent distributed service and uses bounded reports/diagnostics | Package-specific observability evidence or applicability record | candidate — alternative is documented |
| OpenAI's fixed layered domain architecture | Not adopted; use the Dart runtime, transport, platform bridge, native helper, and release-tool dependency direction in `ARCHITECTURE.md` | Executable project-specific boundary evidence | candidate — architecture and selected tests exist; attested run pending |
| Reimplementing upstream dependency behavior locally | Not a default; use stable dependencies, checked-in contracts, adapters, and fixtures unless a design decision justifies local code | Tradeoff covering inspectability, maintenance, security, licensing, and compatibility | candidate — policy is documented and native vendoring remains governed by existing notices/contracts |
| Minimally blocking merge gates and short-lived pull requests | Not inherited; gate strength follows trust, compatibility, platform, and recovery risk | Failure-cost and recovery rationale | candidate — repository risk policy is documented; provider review evidence pending |
| Scheduled Codex documentation gardening and quality-scoring agents open targeted repair pull requests | Not enabled; manual read-only entropy sweeps are the current policy | Cadence, write authority, review/merge gate, rollback, and observed trace | candidate — explicit user authority would be required for automation |
| Automated merge and agent-authored release tooling | Automated merge is not authorized; release tooling exists, but execution requires app/release-owner policy, credentials, target-host evidence, and approval | Automation/gate rationale without inferred production authority | candidate — tooling and boundaries are documented; production execution is blocked |

Review this matrix after harness, architecture, CI, runtime, release-authority,
or agent-workflow changes. Candidate and blocked rows keep `harness-ready`
invalid.
