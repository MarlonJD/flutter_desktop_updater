# Harness Engineering For desktop_updater

The repository harness should let an agent discover intent, make a scoped
change, observe the result, and leave durable evidence without relying on chat
history.

## Agent-Readable Repository Map

[AGENTS.md](../AGENTS.md) is the concise entrypoint.
[ARCHITECTURE.md](../ARCHITECTURE.md) owns system boundaries and dependency
direction. [README.md](../README.md) owns the package overview and common user
flows. The [documentation map](index.md) routes deeper product and operational
guidance in `docs/` and `doc/`. The
[agent harness](agent-harness/index.md) owns repository-native capability,
verification, evidence, and certification contracts.

Use the [execution-plan ledger](exec-plans/index.md) for restartable work and
[GitHub Actions CI/CD](github-actions-ci-cd.md) for the current platform-lane,
secret, and target-host contract. Durable cross-cutting rationale belongs in
`docs/design-docs/`, not in tool- or skill-specific documentation trees.

## Mechanical Quality Gates

Run the narrowest useful command first:

```sh
flutter test --no-pub test/<focused_test>.dart
dart format --output=none --set-exit-if-changed .
flutter analyze --no-fatal-infos
flutter test --no-pub
dart pub publish --dry-run
```

Run the complete local ladder and write a review artifact with:

```sh
dart run tool/harness_check.dart
```

The secretless runner executes format, analyze, version consistency, the
focused harness test, the full Flutter suite, and publish dry-run. It records
command output and exit status in the ignored `reports/harness-check.md`.
Platform services, signing credentials, release approval, and installed-system
mutation remain in the CI or manual lanes documented by
[GitHub Actions CI/CD](github-actions-ci-cd.md).

`test/harness_engineering_docs_test.dart` mechanically protects the repository
routes, plan index, local runner, and evidence naming contract.

For a harness authority or contract change, run the read-only structural gate
first:

```sh
dart run tool/harness_gate.dart --structural
```

The structural mode checks routing, authority configuration, the complete
31-capability inventory, manifest shape, and scaffold-marker removal. Full
certification uses `dart run tool/harness_gate.dart --attestation-key-file
"$HARNESS_ATTESTATION_KEY_FILE"` from a clean direct-child attestation commit.
See [Harness-ready certification](agent-harness/certification.md).

## Evidence Contract

Evidence language is literal:

- `preview` describes API maturity.
- `verified locally` and `verified in CI` identify where a command passed.
- `not run` means the exact gate was not exercised.
- `blocked` names a missing dependency, credential, approval, or host.
- `candidate-only` means release trust remains incomplete.
- `production-ready` requires every applicable target-host package, artifact,
  trust, cleanup, and release gate to pass.

A workflow definition is configuration, not execution evidence. Source scans,
mocks, unsigned helpers, and packaging dry runs cannot replace signed,
elevated, notarized, or installed-system behavior.

For UI or native behavior, keep a screenshot, bounded diagnostics log, or policy
response under `reports/` when it explains the result better than terminal
output. Platform smoke diagnostics use
`reports/<platform>-update-smoke-<mode>-diagnostics.jsonl`. macOS notarized
smoke requires manual release approval and secrets; Windows and Linux
target-host evidence normally belongs to their named CI or manual lanes.

## Agent Feedback Loops

1. Reproduce or protect behavior with a focused test.
2. Run the focused command and inspect the failure.
3. Make the smallest change that satisfies the behavior.
4. Widen to format, analyze, and relevant test groups.
5. Use native builds, platform smoke, or CI only when that boundary changed.
6. Record lasting decisions in the owning document and repeated failures in a
   focused test or the [tech-debt tracker](exec-plans/tech-debt-tracker.md).

## Entropy Controls

- Keep one canonical home for each rule; link instead of copying mutable CI or
  release detail.
- Keep active plans only under `docs/exec-plans/active/` and index every one.
- Keep durable design rationale under `docs/design-docs/`.
- Remove superseded examples, stale prompt routers, and redundant collection
  indexes after their consumers are updated.
- Add a mechanical guard only for a stable invariant or repeated failure, with
  an actionable failure message.

The completed
[agent harness engineering plan](exec-plans/completed/2026-07-01-agent-harness-engineering-plan.md)
retains adoption history; this operating document contains only the current
contract.

## Certification Boundary

`verified locally` means the named local command passed. It does not mean
`harness-ready`. That bounded claim requires every row in the
[coverage matrix](agent-harness/coverage-matrix.md) to have fresh HMAC-v2
evidence bound to a source commit, a clean direct-child attestation commit, the
repository-native full gate, and an external skill result of `CERT000`.

The default maintenance mode is manual. Installation of an external skill does
not run checks, schedule maintenance, grant Git or production authority, or
certify this repository. Hosted CI automation is not part of the current
adoption.
