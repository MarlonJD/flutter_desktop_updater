# Agent Capability Registry

Commands run from the repository root unless a row says otherwise. A command
marked `verified` has been exercised in the named local environment; this table
does not replace source-commit-bound certification evidence.

| Capability | Entry point or command | Purpose | Expected signal | Owner or update trigger | Status |
| --- | --- | --- | --- | --- | --- |
| Repository setup | `flutter pub get` | Resolve Dart and Flutter dependencies | Exit 0 and `.dart_tool/package_config.json` exists | Package maintainers when dependencies or SDK bounds change | candidate — dependencies are currently resolved, but setup was not rerun during adoption |
| Focused tests | `flutter test --no-pub test/<focused_test>.dart` | Verify a narrow behavior or contract | Exit 0 and `All tests passed!` | Author of the affected surface | verified locally on 2026-07-23 for `test/harness_engineering_docs_test.dart` |
| Harness structure | `dart run tool/harness_gate.dart --structural` | Validate routes, authority declarations, complete coverage inventory, and manifest shape without claiming certification | Exit 0 with `structural validation passed` | Repository maintainers after a harness authority change | candidate until the post-edit gate run is recorded |
| Full local validation | `dart run tool/harness_check.dart` | Run the secretless format, analysis, version, harness, test, and publish ladder and write `reports/harness-check.md` | Exit 0 and report status `passed` | Package maintainers before a broad handoff | candidate — broad runner is intentionally deferred until focused structure is green |
| Project-native harness certification gate | Prepare records with `tool/harness_evidence.dart`, run `dart run tool/harness_gate.dart --candidate --attestation-key-file "$HARNESS_ATTESTATION_KEY_FILE"`, create the direct-child attestation, then run the full gate without `--candidate` | Fail closed on incomplete coverage, stale or inconsistent HMAC-v2 records, dirty state, or an invalid source/direct-child attestation boundary | Prospective overlay pass followed by a clean final source/attestation pass | Repository maintainers, manually before a `harness-ready` claim | blocked — current unrelated working-tree changes require isolated clean source/attestation verification |
| Safe harness convergence | Follow [`certification.md`](certification.md); use `dart run tool/harness_evidence.dart --prepare ...` and `--record-project-gate ...` only after a passed broad report | Repair authorized local drift and regenerate deterministic HMAC-v2 records without inventing authority | Restored native gates plus current external `CERT000` | Repository maintainers on explicit adoption or maintenance request | candidate — repository-native path exists; completed trace is pending |
| Optional production attestation | External provider verifier plus `certify --require-production-attestation` | Authenticate production repository, target, approval, rollback, artifact, freshness, and revocation evidence | Provider-authenticated success | App/release owner with explicit production authority | blocked — no provider verifier or production authority is provisioned by this package harness |
| Source-control context | `git status --short --branch` and `git diff --name-status` | Inspect current branch and preserve unrelated work | Exact branch plus changed-path list | Every implementation task | verified locally on 2026-07-23 |
| CI context | Inspect `.github/workflows/desktop-updater-ci.yml` and [`../github-actions-ci-cd.md`](../github-actions-ci-cd.md); use provider status only with explicit read authority | Discover configured target-host and credential gates | Job graph or exact-head run status with a provider identifier | CI or platform lane changes | candidate — configuration inspected; no external run was queried |
| Dependency and API references | [`../../fixtures/compat/`](../../fixtures/compat/), [`../../schemas/`](../../schemas/), [`../native-contract.md`](../native-contract.md), and [`../native-install-helper-protocol.md`](../native-install-helper-protocol.md) | Keep cross-language behavior inspectable | Focused contract or conformance test passes | Contract owners when a schema or fixture changes | verified by repository tests; rerun the focused contract suite for changes |
| CLI behavior | `flutter test --no-pub test/desktop_updater_cli_test.dart` and command-specific tests under `test/release_cli/` | Exercise exit, validation, and output contracts | Exit 0 and expected fixture assertions | Release-tooling maintainers | candidate for the current adoption environment |
| Widget behavior | Focused tests such as `flutter test --no-pub test/update_ready_ui_test.dart` | Exercise user-visible Flutter states | Exit 0; screenshot only when visual evidence adds information | Widget maintainers | candidate for the current adoption environment |
| Native/platform behavior | Platform tests and smoke commands documented by [`../github-actions-ci-cd.md`](../github-actions-ci-cd.md) | Prove native build, trust, install, recovery, and relaunch boundaries | Named host result plus bounded diagnostics artifact | Platform owner for the affected OS | blocked locally when the required OS, credentials, elevation, or signing authority is absent |
| Logs and artifacts | `reports/harness-check.md`, `reports/<platform>-update-smoke-<mode>-diagnostics.jsonl`, and plan-specific report paths | Preserve bounded command and runtime evidence | Timestamped report, JSONL, screenshot, or provider artifact identifier | Command owner after execution | verified as a repository contract; individual observations retain their own status |

## Status Meanings

- `verified`: exercised with named local or provider evidence.
- `candidate`: implemented or documented but not exercised in the current
  evidence scope.
- `blocked`: a named host, secret, approval, clean source boundary, or authority
  is missing.
- `N/A`: intentionally absent with a durable reason.

No row grants external-write, merge, release, deployment, privileged mutation,
or production authority.
