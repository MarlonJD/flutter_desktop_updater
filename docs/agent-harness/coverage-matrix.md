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
| Humans set intent; agents execute within authority | [`operating-loop.md`](operating-loop.md), root instructions, and owning product/platform docs | Named judgment boundaries and one completed task trace | [verified](evidence/human-intent.json) - Authority roles and escalation boundaries were reviewed. |
| Break large goals into reusable design, code, review, test, and verification steps | [`../PLANS.md`](../PLANS.md) and active ExecPlans | Restartable plan with independently verified milestones | [verified](evidence/reusable-steps.json) - The convergence plan records restartable milestones and proof. |
| Agents can self-review and respond to feedback | [`operating-loop.md`](operating-loop.md) and [`output-contract.md`](output-contract.md) | Review procedure plus a resolved finding trace | [verified](evidence/self-review.json) - The review loop and current repair findings were exercised. |
| Application behavior is directly readable | [`environment-contract.md`](environment-contract.md), fixture tests, and example tools | Reproduced CLI/widget/native behavior with observed evidence | [verified](evidence/readable-behavior.json) - Fixture-driven package, CLI, widget, and native surfaces are mapped. |
| Logs, metrics, and traces are queryable when relevant | [`environment-contract.md`](environment-contract.md) and [`registry.md`](registry.md) | Project-appropriate query/result or justified applicability | [verified](evidence/observable-signals.json) - Package-appropriate reports and diagnostics are declared. |
| Repository knowledge is the durable record | [`../index.md`](../index.md), [`../../AGENTS.md`](../../AGENTS.md), and canonical docs | Resolved routes and decisions independent of chat | [verified](evidence/durable-knowledge.json) - Canonical documentation routes passed structural validation. |
| Repository tools and authorized work context are directly invocable | [`registry.md`](registry.md), `tool/`, Git read-only commands, and configured workflow docs | Exercised repository command plus source-control/CI context or justified applicability | [verified](evidence/invocable-tools-context.json) - Repository commands and read-only Git context are directly discoverable. |
| Dependencies and abstractions remain agent-legible | [`../../ARCHITECTURE.md`](../../ARCHITECTURE.md), schemas, fixtures, and native contracts | Discoverable upstream/contract behavior with executable proof | [verified](evidence/legible-dependencies.json) - Architecture, schemas, fixtures, and native contracts are linked. |
| `AGENTS.md` is a concise map, not an encyclopedia | [`../../AGENTS.md`](../../AGENTS.md) and [`../index.md`](../index.md) | Routes before the 32 KiB cutoff and applicable instruction-chain evidence | [verified](evidence/concise-agents.json) - Root routes fit the conservative instruction byte budget. |
| Plans are versioned living artifacts | [`../PLANS.md`](../PLANS.md), [`../exec-plans/index.md`](../exec-plans/index.md), and active plans | Unambiguous lifecycle with current progress, decisions, and evidence | [verified](evidence/living-plans.json) - The repo-native ledger and preferred living sections are explicit. |
| Architecture and critical taste boundaries are mechanical | [`../../ARCHITECTURE.md`](../../ARCHITECTURE.md), contract fixtures, and focused structural tests | Actionable failing and passing invariant check | [verified](evidence/mechanical-boundaries.json) - Selected trust, contract, and harness invariants have executable checks. |
| Local autonomy exists inside enforced central boundaries | [`operating-loop.md`](operating-loop.md), root instructions, and security/release policy | Allowed actions, escalation gates, and recovery path | [verified](evidence/bounded-autonomy.json) - Local reversible work is separated from Git and external authority. |
| Verification proves working behavior, not only code changes | [`verification-matrix.md`](verification-matrix.md), focused tests, and smoke contracts | Exact commands plus user-visible or operational evidence | [verified](evidence/behavioral-verification.json) - Focused and broad commands report observable outcomes. |
| Failures and review judgment feed back into the harness | [`operating-loop.md`](operating-loop.md), docs tests, and debt tracker | Finding promoted into docs, a test, guard, runbook, or debt item | [verified](evidence/feedback-capture.json) - Adoption findings were converted into docs, tests, and gate behavior. |
| Entropy and technical debt are continuously controlled | [`entropy-cleanup-checklist.md`](entropy-cleanup-checklist.md) and [`../exec-plans/tech-debt-tracker.md`](../exec-plans/tech-debt-tracker.md) | Dated sweep evidence and bounded follow-up | [verified](evidence/entropy-control.json) - A manual sweep, current findings, and debt destinations exist. |
| Autonomy increases only after test, review, recovery, and escalation loops exist | [`operating-loop.md`](operating-loop.md), [`registry.md`](registry.md), and [`output-contract.md`](output-contract.md) | Evidence for the granted level and unavailable higher levels | [verified](evidence/graduated-autonomy.json) - The granted local level and unavailable higher levels are explicit. |
| Merge throughput policy matches project risk | Root policy, [`../../SECURITY.md`](../../SECURITY.md), and [`../github-actions-ci-cd.md`](../github-actions-ci-cd.md) | Project-specific gate rationale based on failure cost and recovery | [verified](evidence/risk-matched-merge.json) - Trust and target-host gates remain risk-based instead of throughput-based. |
| Release, deployment, and production actions require repository-local authority | [`operating-loop.md`](operating-loop.md), [`output-contract.md`](output-contract.md), [`../publishing.md`](../publishing.md), and CI contract | Denial/escalation plus approval and rollback evidence | [verified](evidence/production-authority.json) - Release approval and rollback ownership are explicit; no production action was inferred. |
| Repository-specific OpenAI examples are treated as options, not universal mandates | Case-study ledger below and architecture decisions | Independent decision and repository-specific reason for every listed choice | [verified](evidence/case-study-options.json) - Every case-study choice has an independent repository decision. |

## Case-Study Decision Ledger

| OpenAI case-study choice | Local decision or implementation | Required evidence | Status and reason |
| --- | --- | --- | --- |
| Zero human-authored code as an operating constraint | Rejected; maintainers own intent, judgment, acceptance, and may author any repository surface | Responsibility model and provenance policy | [N/A](evidence/na-zero-human-code.json) - Not adopted; maintainers may author code and retain judgment. |
| Reported repository size, pull-request throughput, elapsed-time speedup, and long agent-run duration as targets | Rejected as targets; use behavior, safety, compatibility, and evidence quality | Outcome measures remain independent of case-study metrics | [N/A](evidence/na-case-study-metrics.json) - Not adopted; behavior, safety, and compatibility are the measures. |
| Local and cloud agent review loops continue until reviewers are satisfied while human review is optional | Not adopted universally; independent and human review are risk-based and required for trust/release boundaries | Review policy, stop condition, and one exercised trace | [N/A](evidence/na-review-loop-default.json) - Not a universal policy; review and human gates are risk-based. |
| Per-worktree application isolation | Current mode preserves one explicit working tree; clean detached worktrees may be used only for authorized isolated verification | Collision-free setup/reset/teardown proof | [N/A](evidence/na-per-worktree-app.json) - Not required by default; this package uses explicit workspace preservation. |
| Per-worktree observability stack | Not adopted; this package uses task reports, test output, and platform diagnostics rather than a persistent stack | Signal correlation or applicability record | [N/A](evidence/na-per-worktree-observability.json) - Not required; bounded reports and platform diagnostics fit this package. |
| Chrome DevTools Protocol for UI control | Not a default; Flutter widget tests and selected desktop-host inspection are the primary UI evidence | Widget/host evidence or applicability record | [N/A](evidence/na-cdp.json) - Not required; Flutter widget and selected desktop-host tests are primary. |
| Victoria Logs, Metrics, and Traces with LogQL/PromQL/TraceQL | Not adopted; the package has no persistent distributed service and uses bounded reports/diagnostics | Package-specific observability evidence or applicability record | [N/A](evidence/na-victoria.json) - Not required; no persistent distributed service is operated here. |
| OpenAI's fixed layered domain architecture | Not adopted; use the Dart runtime, transport, platform bridge, native helper, and release-tool dependency direction in `ARCHITECTURE.md` | Executable project-specific boundary evidence | [N/A](evidence/na-fixed-layers.json) - Not adopted; the repository uses its own documented dependency direction. |
| Reimplementing upstream dependency behavior locally | Not a default; use stable dependencies, checked-in contracts, adapters, and fixtures unless a design decision justifies local code | Tradeoff covering inspectability, maintenance, security, licensing, and compatibility | [N/A](evidence/na-reimplementation-default.json) - Not a default; contracts and stable dependencies are preferred. |
| Minimally blocking merge gates and short-lived pull requests | Not inherited; gate strength follows trust, compatibility, platform, and recovery risk | Failure-cost and recovery rationale | [N/A](evidence/na-minimal-blocking.json) - Not inherited; gate strength follows compatibility and trust risk. |
| Scheduled Codex documentation gardening and quality-scoring agents open targeted repair pull requests | Not enabled; manual read-only entropy sweeps are the current policy | Cadence, write authority, review/merge gate, rollback, and observed trace | [N/A](evidence/na-scheduled-gardening.json) - Not enabled; maintenance is manual and external writes need authority. |
| Automated merge and agent-authored release tooling | Automated merge is not authorized; release tooling exists, but execution requires app/release-owner policy, credentials, target-host evidence, and approval | Automation/gate rationale without inferred production authority | [N/A](evidence/na-automated-merge-release.json) - Automated merge is not authorized; release execution stays owner-gated. |

Review this matrix after harness, architecture, CI, runtime, release-authority,
or agent-workflow changes. Candidate and blocked rows keep `harness-ready`
invalid.
