# Verification Matrix

Run the narrowest reliable proof first. Widen only to the surfaces affected by
the change, then use the broad local runner before a broad package handoff when
the working tree can be evaluated without overwriting unrelated work.

| Change surface | Fast check | Broader check | Behavioral evidence | Fallback or blocker | Owner/update trigger |
| --- | --- | --- | --- | --- | --- |
| Documentation or harness routes | `dart run tool/harness_gate.dart --structural` and `flutter test --no-pub test/harness_engineering_docs_test.dart` | External adaptive check with `--warnings-as-errors` | Routes resolve, 31 rows exist, and no scaffold marker remains | Record the exact broken path or marker | Repository maintainers after a route or contract change |
| Dart runtime or core logic | `flutter test --no-pub test/<focused_test>.dart` | `flutter test --no-pub` | Fixture output or public state transition | Name unavailable SDK/host dependency | Runtime maintainers |
| Public API or controller | Focused public/controller tests | Full Flutter suite plus publish dry-run | Consumer-visible call/state behavior and docs alignment | Keep release pending on compatibility uncertainty | Package API maintainers |
| Release CLI or metadata | Focused command/schema test | Relevant release CLI suite, version check, and publish dry-run | Exit/output contract and deterministic descriptor/artifact fixture | Credentials and hosted publication remain blocked unless authorized | Release-tooling maintainers |
| Flutter widget or localization | Focused widget/localization test | Relevant widget group or full Flutter suite | Rendered state, semantics/text, and justified screenshot when needed | Interactive platform work may require a selected desktop target | Widget maintainers |
| Native bridge, SDK, helper, or contract | Relevant Dart source-shape/fixture test and native focused test | Platform build, conformance, and named smoke lane | Native result plus structured diagnostics | Wrong OS, credentials, elevation, signing, or host is `blocked`/`not run` | Platform owner |
| CI or build configuration | Focused config/source-shape test | Exact-head provider job on the named OS | Job graph, artifact, and run identifier | Workflow text is configuration, not run evidence | CI/platform owner |
| Security, trust, install, or recovery boundary | Focused adversarial test or policy fixture | Relevant target-host trust/recovery smoke | Unauthorized or tampered input fails closed; authorized recovery converges | Human/secret/privileged authority may block | Security and platform owners |
| Repository harness certification | `dart run tool/harness_gate.dart --structural` | Full native gate plus external `certify` | Clean source/direct-child attestation commits, 31 fresh HMAC-v2 row records, and `CERT000` | Dirty tree, unresolved row, stale record, missing key, or Git authority fails closed | Repository maintainers before a harness-ready claim |
| Optional production attestation | Provider-specific verifier when explicitly requested | External `certify --require-production-attestation` | Provider-authenticated production authority and rollback proof | Report `CERT015` when no provider verifier exists | Production/release owner |

The broad local runner is `dart run tool/harness_check.dart`. It must remain
secretless and repository-owned; hosted CI must not depend on the external
skill installation path.
