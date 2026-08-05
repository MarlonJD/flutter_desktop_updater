# Documentation Map

Use this page to locate the canonical source for repository knowledge. Link to
an existing authority instead of copying mutable rules into a second document.

| Topic | Canonical source | Update trigger |
| --- | --- | --- |
| Agent working instructions | [`../AGENTS.md`](../AGENTS.md) | Commands, constraints, or definition of done changes |
| Architecture and dependency direction | [`../ARCHITECTURE.md`](../ARCHITECTURE.md) | Components, trust boundaries, or data flow changes |
| Package overview and user setup | [`../README.md`](../README.md) | Public capabilities or installation steps change |
| Harness operating model | [`harness-engineering.md`](harness-engineering.md) | Validation, evidence language, or maintenance rules change |
| Agent harness contracts | [`agent-harness/index.md`](agent-harness/index.md) | Capabilities, authority paths, or certification inputs change |
| ExecPlan policy | [`PLANS.md`](PLANS.md) | Plan authoring or lifecycle expectations change |
| Active and completed work | [`exec-plans/index.md`](exec-plans/index.md) | A plan starts, completes, pauses, or is superseded |
| Durable design rationale | [`design-docs/`](design-docs/) | A cross-cutting design decision changes |
| Desktop Updater 3.0 frozen breaking contract | [`design-docs/2026-08-03-desktop-updater-3-0-contract.md`](design-docs/2026-08-03-desktop-updater-3-0-contract.md) | 3.0 public, ABI, or durable-state contract changes |
| Desktop Updater 3.1 release-key profile contract | [`design-docs/2026-08-05-release-key-management.md`](design-docs/2026-08-05-release-key-management.md) | Release-key profile, storage, backup, adoption, or rotation contract changes |
| Security policy and reporting | [`../SECURITY.md`](../SECURITY.md) | Reporting path or security policy changes |
| Runtime diagnostics and recovery | [`diagnostics-and-recovery.md`](diagnostics-and-recovery.md) | Failure modes, diagnostics, or recovery semantics change |
| CI, target-host, and secret boundaries | [`github-actions-ci-cd.md`](github-actions-ci-cd.md) | Workflow lanes, credentials, or target-host contracts change |
| Publishing and rollback-sensitive release flow | [`publishing.md`](publishing.md) | Artifact, trust, upload, or validation behavior changes |
| Release key profiles and backups | [`release-key-management.md`](release-key-management.md) | Key generation, local storage, backup, adoption, or rotation changes |
| Native contracts | [`native-contract.md`](native-contract.md) and [`native-install-helper-protocol.md`](native-install-helper-protocol.md) | Cross-language schema or helper protocol changes |
| Public widget behavior | [`ui-widgets.md`](ui-widgets.md) | Widget states, accessibility, or integration examples change |
| Localization | [`localization.md`](localization.md) and [`i18n.md`](i18n.md) | Locale assets, directionality, or translation workflow changes |
| Migration guidance | [`migration/1.x-to-2.0.md`](migration/1.x-to-2.0.md) and [`migration/2.x-to-3.0.md`](migration/2.x-to-3.0.md) | Compatibility or upgrade behavior changes |

The repository is a package and native-plugin source tree, not a deployed
service. Production evidence belongs to the app or target-host authority named
by the relevant release plan; configured workflows are not execution evidence.
