# Release Publishing Hardening

## Context

This plan tracks issue [#73](https://github.com/MarlonJD/flutter_desktop_updater/issues/73)
and the branch `fix/release-publishing-hardening`. The branch starts directly
from `origin/main` at `7d01eb64ecbea878dd6c860df7dac859f28f2ea7` with package
version `3.1.5`.

The work upstreams and safely adapts four production findings credited to
[@Nicoeevee](https://github.com/Nicoeevee):

- [macOS environment references](https://github.com/Nicoeevee/flutter_desktop_updater/pull/2)
- [macOS signing and notarization](https://github.com/Nicoeevee/flutter_desktop_updater/pull/3)
- [Windows DPAPI streams](https://github.com/Nicoeevee/flutter_desktop_updater/pull/4)
- [hosted artifact retry](https://github.com/Nicoeevee/flutter_desktop_updater/pull/5)

Additional production context is recorded in:

- https://github.com/MarlonJD/flutter_desktop_updater/pull/71#discussion_r3772283998
- https://github.com/MarlonJD/flutter_desktop_updater/pull/71#issuecomment-5278105213

FTP behavior is already upstream-equivalent and is explicitly outside this
plan.

## Scope and constraints

The implementation must remain compatible with the current release-key
profile workflow and current publish/package abstractions. It must not bump the
package version, change changelog headings, modify FTP behavior, merge, tag,
publish to pub.dev, or create a release. GitHub writes are limited to issue,
branch, plan, draft PR, review requests, and evidence updates authorized by the
task. The draft PR stays draft when target-host, credential, or independent
approval evidence is unavailable.

No production claim may be inferred from a workflow definition, source scan,
mock, unsigned fixture, or local dry run. Evidence labels remain literal:
`verified locally`, `candidate-only`, `not run`, `blocked`, and
`release pending`.

## Acceptance areas

1. **Canonical macOS environment configuration**
   - Thread injectable `Map<String, String>? environment` through
     `ReleasePublishConfig.load` and `fromYaml`.
   - Enable notarization only through `--notarize` or `macos.notarize: true`.
   - Read only the four canonical `DESKTOP_UPDATER_MACOS_*` references.
   - Let nonblank YAML win, reject explicit blank/non-string values, and use a
     trimmed environment value only when the YAML field is absent.
   - Keep PKG requirements and make publish smoke credentials environment-only.

2. **Two-phase macOS trust pipeline**
   - Validate configuration, run `prePackage`, complete read-only preflight,
     then sign inner-to-outer with the outer app last.
   - Inventory bundle topology using bounded plist parsing, bundle executable
     metadata, and Mach-O/fat magic without extension-only assumptions.
   - Reject symlink escapes, signing-target symlink ancestors, malformed or
     duplicate topology, unexpected executable code, and unsafe entitlements.
   - Preserve only each app/appex/xpc target's own validated entitlements;
     reject `get-task-allow` by key presence; never propagate entitlements to
     frameworks, dylibs, normal helpers, or the install helper.
   - Treat an embedded install helper's sealed policy as authoritative when it
     exists, and enforce exact identifiers, requirements, policy digests,
     hardened runtime, and equal nonempty Team IDs.
   - Require typed `Accepted` notarization, staple/validate/assess the app and
     exact DMG/PKG container, audit the exact final distributable, sign release
     metadata, and upload without further mutation.

3. **Windows DPAPI process safety**
   - Inject a process adapter and keep fake tests runnable off Windows.
   - Suppress PowerShell progress, write Base64 through stdin, drain streams
     concurrently with bounded stdout and bounded/discarded stderr, and cover
     timeout/kill/await behavior.
   - Accept one bounded canonical Base64 value, fail safely on invalid UTF-8,
     redact all process data, and cover process/start/stdin failures, output
     attacks, exit failures, hangs, kill, protect, and unprotect behavior.
   - Add a separate Windows-only `CurrentUser` round-trip test and run that
     exact file in the `cli-candidates` lane.

4. **Bounded hosted artifact retry**
   - Inject the existing `UpdateRetryPolicy` and delay callback into
     `ReleaseValidator`.
   - Keep metadata requests fail-fast; stream artifact bytes with
     `client.send`, enforce descriptor length and optional `Content-Length`,
     reject truncation/oversize, and retry only artifact `http.ClientException`
     and `SocketException` transport failures.
   - Create one attempt directory after successful 2xx headers, clean failed
     attempts while preserving the primary exception, and transfer successful
     file cleanup ownership to the caller.

## Milestones and verification

### M1 — Baseline and plan

- [x] Read repository instructions, architecture, publishing/security,
  harness, and ExecPlan guidance.
- [x] Confirm clean source tree, fetch `origin/main`, record base SHA/version,
  and create the requested branch.
- [x] Create and index this active plan.
- [x] Push the plan commit and open the draft PR with issue closure, sources,
  credit, and explicit exclusions. Issue #73 and draft PR #74 are open.

### M2 — macOS configuration and trust pipeline

- [x] Add injectable environment resolution and strict YAML presence/type
  semantics.
- [x] Refactor publish sequencing so no `codesign` command can run before the
  complete read-only preflight.
- [x] Add target inventory, topology, symlink, identity, entitlement, sealed
  helper-policy, requirement, and Team ID validation.
- [x] Add typed notary result parsing and exact app/container/final-artifact
  audit with cleanup guarantees.
- [x] Add mocked signing tests, secretless ad-hoc real-codesign fixtures,
  versioned/nested/extensionless/login-item/system-extension/symlink/dedup
  fixtures, entitlement negatives, zero-mutation tests, and DMG/PKG regressions.

Focused evidence: `verified locally` when the named macOS release CLI tests
pass. Real Developer ID, notarization, stapling, Gatekeeper, and hosted
artifact evidence remains `candidate-only` or `blocked` until the credentialed
exact-head workflow runs.

### M3 — Windows DPAPI

- [x] Introduce the injectable process adapter and bounded concurrent stream
  implementation.
- [x] Add fake process tests for malformed/non-UTF8/oversized output, large
  stderr, exit/start/stdin failure, hang/kill, redaction, and round trips.
- [x] Add and wire the Windows-only real `CurrentUser` test to the exact
  `cli-candidates` lane. Host execution remains `not run` locally.

Focused fake evidence can be `verified locally`; Windows host evidence is
`not run` or `blocked` until the named Windows job executes on the final head.

### M4 — Hosted artifact retry

- [x] Integrate `UpdateRetryPolicy` and injected no-sleep delay.
- [x] Implement streamed bounded artifact transfer, status/header/length
  handling, retry classification, and ownership-safe cleanup.
- [x] Add transport, status, length, filesystem, retry ownership, cleanup,
  metadata fail-fast, and trust-failure non-retry tests.

Focused validator tests are `verified locally` only after the exact test
commands pass.

### M5 — Documentation, workflow, and drift contracts

- [x] Update `docs/publishing.md`, `docs/macos-dmg-pkg-installer-updates.md`,
  `docs/github-actions-ci-cd.md`, and `SECURITY.md` for the new trust and
  credential boundaries.
- [x] Update release-key documentation only if DPAPI operator behavior changes.
- [x] Add workflow/publish-smoke contract tests and keep credentials in the
  environment rather than generated YAML or logs.
- [x] Keep README unchanged unless the canonical environment fallback is part
  of common public configuration.

### M6 — Final verification and external evidence

- [x] Run focused tests, formatting, analysis, full Flutter tests, publish dry
  run, structural ExecPlan/harness checks, and lifecycle documentation checks.
- [x] Commit all implementation and documentation changes in green,
  bisectable Conventional Commits.
- [ ] Freeze the final PR head SHA before external evidence.
- [ ] Run normal CI and the exact Windows DPAPI host test.
- [ ] Dispatch the credentialed macOS workflow with
  `--ref fix/release-publishing-hardening`.
- [ ] Verify every relevant run `headSha` equals the frozen PR head.
- [ ] Record final SHA, run URLs, final artifact SHA-256/length, pre-staple
  digest, typed notary IDs/status, inventory, identifiers/requirements, Team
  IDs, runtime flags, entitlement hashes, no-propagation/get-task-allow,
  strict signatures, staple, and Gatekeeper evidence in the PR body/check
  output without a follow-up commit.
- [ ] Request applicable maintainers and invite `@Nicoeevee` formally when
  GitHub permits it; otherwise keep the mention as the review invitation.
- [ ] Keep the PR draft if credentials, host evidence, or independent approval
  is blocked. Do not merge or release.

## Exact command ladder

Focused commands will be selected per changed surface, then widened to:

```sh
dart format --output=none --set-exit-if-changed .
flutter analyze --no-fatal-infos
flutter test --no-pub
dart pub publish --dry-run
dart run tool/harness_gate.dart --structural
flutter test --no-pub test/harness_engineering_docs_test.dart
```

The final external checks are provider/host-bound and must be reported with
their exact run URL and `headSha`; configured workflow text alone is
`candidate-only`.

## Decision log

- **D1 — Preserve current opt-in semantics.** Environment variables supply only
  signing/notary references. They never enable notarization and legacy aliases
  are ignored.
- **D2 — Preflight is read-only.** A complete inventory and policy validation
  must finish before the first `codesign` process starts.
- **D3 — Target-specific entitlements.** A target keeps only its own semantic
  entitlements, and no global preserve/propagation option is used.
- **D4 — Final bytes are the trust subject.** App/container notarization and
  the final distributable audit precede release metadata signing and upload;
  no later hook may mutate the trusted artifact.
- **D5 — Retry only transport.** Metadata and all semantic, trust, filesystem,
  status, and length failures remain fail-fast.

## Surprises and discoveries

- The current `origin/main` is version `3.1.5` and is two commits ahead of the
  local pre-fetch `main`; the hardening branch was based on the fetched SHA.
- Nico's fork fixes are merged in the fork but are intentionally narrower than
  this task: they do not provide the required complete preflight, sealed-policy
  validation, bounded process adapter, or exact final-artifact audit.
- FTP changes from PR #71 are already upstream-equivalent and are excluded.

## Progress

| Date | Milestone | Evidence | Notes |
| --- | --- | --- | --- |
| 2026-08-13 | Repository and source discovery | `verified locally` | Instructions, architecture, publishing/security docs, harness/ExecPlan docs, and credited PRs read. |
| 2026-08-13 | GitHub baseline | `verified locally` | Issue #73 created; `bug` label confirmed; clean tree; base `origin/main` SHA recorded. |
| 2026-08-13 | Branch and plan | `verified locally` | Branch created from exact base; plan commit pushed; draft PR #74 opened. |
| 2026-08-13 | macOS trust/configuration | `verified locally` | Focused config, trust, real ad-hoc codesign, notarization, DMG/PKG, publisher, smoke, and docs tests passed; credentialed Developer ID/notary/Gatekeeper evidence is `blocked` or `not run` pending external host credentials. |
| 2026-08-13 | Windows DPAPI | `verified locally` | Fake process suite passed, including bounded output, stream draining, timeout/kill, redaction, and round trips; Windows `CurrentUser` host test is `not run` locally and is wired to `cli-candidates`. |
| 2026-08-13 | Hosted artifact retry | `verified locally` | Streamed transport retry, length/content/status non-retry, and cleanup ownership tests passed with injected no-sleep delay. |
| 2026-08-13 | Structural validation | `verified locally` | `dart format`, `git diff --check`, focused test suite (106 tests), and `dart run tool/harness_gate.dart --structural` passed. |

## Outcomes and retrospective

Implementation is complete in bisectable Conventional Commits covering macOS
configuration and trust sequencing, Windows DPAPI process safety, hosted
artifact transport retry, final-artifact evidence, workflow contracts, and
publishing/security documentation. Local focused and structural checks are
`verified locally`; the full validation ladder and final commit SHAs are
recorded in the handoff. Credentialed Developer ID/notary/staple/Gatekeeper
evidence, the Windows host lane, and independent maintainer approval remain
`blocked` or `not run` until the corresponding external gates execute on the
frozen final head. Workflow configuration is `candidate-only` until then.
The PR remains draft; merge, publication, tagging, version bump, and release
were not performed.

## Revision history

- 2026-08-13: Initial plan created from `origin/main` SHA
  `7d01eb64ecbea878dd6c860df7dac859f28f2ea7`.
