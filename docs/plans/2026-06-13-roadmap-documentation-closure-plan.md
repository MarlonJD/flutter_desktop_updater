# Roadmap Documentation Closure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the documentation gaps in the Trust, UX, and product roadmap by syncing implementation status, reader-facing docs, and roadmap-only boundaries.

**Architecture:** Treat `docs/plans/2026-06-13-trust-ux-and-product-roadmap-plan.md` as the execution ledger, and treat `README.md`, `docs/publishing.md`, `docs/ui-widgets.md`, and `SECURITY.md` as reader-facing product documentation. This is a documentation-only slice unless verification proves a referenced feature is missing from code; do not change runtime behavior while executing this plan.

**Tech Stack:** Markdown, existing `desktop_updater` Dart/Flutter tests, `rg`, `git diff --check`, and targeted `flutter test --no-pub` commands.

---

## Non-Negotiable Constraints

- Do not create, switch, rename, delete, or otherwise operate on branches.
- Do not commit, push, publish, post GitHub comments, or mutate release resources unless the user explicitly asks in the execution turn.
- Preserve the current dirty worktree. Stage only explicitly approved files if a later task asks for staging.
- Keep canonical docs, type names, method names, JSON field names, and source comments in English.
- Keep `SECURITY.md` concise and public-facing; detailed remediation logs and execution evidence stay in plan docs.
- Use `flutter test --no-pub` for validation so `example/pubspec.lock` does not churn.

## File Structure

- Modify: `docs/plans/2026-06-13-trust-ux-and-product-roadmap-plan.md`
  - Add a documentation closure audit table.
  - Sync checkboxes with verified implementation and docs status.
  - Keep roadmap-only items visibly unchecked and labeled as planned.
- Modify: `docs/publishing.md`
  - Add reader-facing documentation for staged rollouts.
  - Add reader-facing documentation for resumable downloads.
  - Add a short roadmap-only boundary for rollback/cleanup reports and delta artifacts.
- Modify: `docs/ui-widgets.md`
  - Add controller guidance for `installationIdentity` and staged rollout behavior.
- Inspect: `README.md`
  - Confirm the quick-start stays small and links to detailed docs instead of duplicating advanced policy.
- Inspect: `SECURITY.md`
  - Confirm no long remediation detail is added.
- Optional inspect: `docs/plans/2026-06-13-native-helper-diagnostics-recovery-plan.md`
  - Cross-link only if native-helper diagnostics are mentioned as future install/rollback evidence.

## Task 1: Verify And Sync Roadmap Status

**Files:**
- Modify: `docs/plans/2026-06-13-trust-ux-and-product-roadmap-plan.md`

- [ ] **Step 1.1: Capture implementation evidence**

Run:

```sh
git status --short
rg -n "Ed25519ReleaseSignatureVerifier|runSignCommand|buildDoctorParser|UpdateRetryPolicy|UpdatePreferences|DesktopUpdaterTelemetry|UpdateProblemReport|ReleaseRollout|resumeFrom|Content-Range|isMinimumOSSupported" lib test docs README.md SECURITY.md
rg -n "^- \\[[ x]\\]" docs/plans/2026-06-13-trust-ux-and-product-roadmap-plan.md
```

Expected:

```text
git status shows existing dirty worktree files.
rg finds implementation evidence for signed descriptors, doctor, runtime policy, diagnostics, staged rollout, and resumable download.
roadmap checkboxes are still mixed and need syncing.
```

- [ ] **Step 1.2: Add a documentation closure audit table**

In `docs/plans/2026-06-13-trust-ux-and-product-roadmap-plan.md`, add this section immediately after `## Scope Split`:

```markdown
## Documentation Closure Audit

Last reviewed: 2026-06-13.

| Lane | Implementation state | Reader-facing documentation state | Closure action |
| --- | --- | --- | --- |
| Platform-independent signed `release.json` | Implemented in `release_signature_verifier.dart`, `sign_command.dart`, `ArtifactVerifier`, and release validation tests. | Covered in `docs/publishing.md`, `SECURITY.md`, and README trust guidance. | Mark roadmap steps complete after targeted tests pass. |
| Quiet startup check failures | Implemented in `DesktopUpdaterController.init()` quiet automatic checks and manual/strict behavior tests. | Covered in `docs/ui-widgets.md`. | Mark roadmap steps complete after targeted tests pass. |
| `release doctor` and release hooks | Implemented in `doctor_command.dart`, release command help, publish config, and docs. | Covered in `README.md` and `docs/publishing.md`. | Mark roadmap steps complete after targeted tests pass. |
| Persistent skip, retry/backoff, telemetry, and `minimumOS` | Implemented in controller, transport, client, descriptor, and policy tests. | Partially covered in `docs/publishing.md` and `docs/ui-widgets.md`. | Add missing staged rollout and resumable-download details before closing. |
| Update diagnostics and problem report UI | Implemented in diagnostics types, recorder, controller, stock UI, and widget tests. | Covered in `docs/ui-widgets.md` and `docs/publishing.md`. | Mark roadmap steps complete after targeted tests pass. |
| Staged rollout percentage | Implemented in `ReleaseRollout`, index selection, client filtering, and tests. | Missing reader-facing explanation outside the plan. | Add `docs/publishing.md` and `docs/ui-widgets.md` sections. |
| Resumable downloads | Implemented in `HttpUpdateTransport` with Range and `Content-Range` tests. | Missing reader-facing explanation outside the plan. | Add `docs/publishing.md` section. |
| Rollback and cleanup report | Not implemented as a public runtime report in this roadmap slice. | Mentioned only as planned roadmap work. | Leave unchecked and label as planned. |
| Delta updates | Not implemented; descriptor shape remains a design gate. | Mentioned only as planned roadmap work. | Leave unchecked and label as planned. |
| Native helper diagnostics and recovery | Split into `docs/plans/2026-06-13-native-helper-diagnostics-recovery-plan.md`. | Not a default runtime feature. | Cross-link from this plan only. |
```

- [ ] **Step 1.3: Sync completed roadmap checkboxes**

In the same roadmap plan, change these checkbox groups from `- [ ]` to `- [x]` only after Step 1.1 evidence is present:

```text
Task 1: Step 1.1 through Step 1.6
Task 2: Step 2.1 through Step 2.3
Task 3: Step 3.1 through Step 3.4
Task 5: Step 5.1 through Step 5.4
Task 6: Step 6.1 through Step 6.7
Task 7: Step 7.1 and Step 7.2
```

Leave these unchecked:

```text
Task 4: Step 4.1 through Step 4.4
Task 7: Step 7.3
Task 7: Step 7.4
```

- [ ] **Step 1.4: Label planned roadmap-only items**

Under `Step 7.3: Rollback and cleanup report`, add this sentence after the introductory paragraph:

```markdown
Status: planned. Do not document this as a public runtime feature until a concrete report type, controller surface, and platform helper evidence exist.
```

Under `Step 7.4: Delta update design gate`, add this sentence after the introductory paragraph:

```markdown
Status: planned design gate. Runtime must continue using full zip artifacts until delta verification and patch application have fail-first tests and public API documentation.
```

- [ ] **Step 1.5: Add the native-helper diagnostics cross-link**

At the end of `Task 6: Update Diagnostics And Problem Report UI`, before `## Task 7`, add:

```markdown
Follow-up native helper diagnostics, recovery markers, and post-exit install or rollback evidence are tracked separately in [Native helper diagnostics and recovery](2026-06-13-native-helper-diagnostics-recovery-plan.md).
```

## Task 2: Document Staged Rollouts

**Files:**
- Modify: `docs/publishing.md`
- Modify: `docs/ui-widgets.md`

- [ ] **Step 2.1: Add publishing docs for staged rollout metadata**

In `docs/publishing.md`, add this section after the `Runtime Policies` section and before `## Common Minimum Setup`:

````markdown
### Staged Rollouts

Add optional rollout metadata to an `app-archive.json` item when a release
should be offered to only part of a channel:

```json
"rollout": {
  "percentage": 25,
  "salt": "stable-2026-06"
}
```

Rollout selection is deterministic for the tuple of `installationIdentity`,
channel, percentage, and salt. The app owns `installationIdentity`; pass a stable
opaque value to `DesktopUpdaterController` or `UpdateClient`. Do not use an
email address, license key, or other directly identifying value.

If no `installationIdentity` is supplied, partial rollouts are not eligible.
Items without rollout metadata remain eligible, and a rollout with
`percentage: 100` is eligible for everyone.
````

- [ ] **Step 2.2: Add UI/controller docs for installation identity**

In `docs/ui-widgets.md`, add this subsection inside `## Runtime Extension Points`, after the skip-preferences paragraph and before telemetry:

````markdown
Staged rollouts use an app-owned stable identity. Pass an opaque
`installationIdentity` when you want `rollout.percentage` metadata in
`app-archive.json` to filter update eligibility:

```dart
final controller = DesktopUpdaterController(
  appArchiveUrl: archiveUrl,
  installationIdentity: myInstallIdentity,
);
```

Use a generated install ID or hashed app-owned identifier. Avoid emails, license
keys, names, or support IDs. Without an identity, partial rollout items are
ignored; full rollout and non-rollout items still work normally.
````

- [ ] **Step 2.3: Verify rollout docs are discoverable**

Run:

```sh
rg -n "Staged Rollouts|installationIdentity|rollout.percentage|partial rollouts|percentage: 100" docs/publishing.md docs/ui-widgets.md
```

Expected:

```text
Both docs/publishing.md and docs/ui-widgets.md mention installationIdentity and partial rollout behavior.
```

## Task 3: Document Resumable Downloads

**Files:**
- Modify: `docs/publishing.md`

- [ ] **Step 3.1: Add publishing docs for resumable download behavior**

In `docs/publishing.md`, add this section after `### Staged Rollouts`:

```markdown
### Resumable Downloads

HTTP downloads keep an in-progress `.part` file in the staging area. If a later
attempt sees that partial file, the transport sends a `Range` request and
resumes only when the server replies with `206 Partial Content` and a valid
`Content-Range` starting at the partial length.

If the server ignores the range request and returns `200 OK`, the updater
restarts the download from byte zero. If the server returns an invalid
`Content-Range`, the updater deletes the partial file and fails the attempt. A
final length or SHA-256 mismatch also deletes the partial file and fails before
staging or install handoff.

Apps do not need a separate API to opt in. Use HTTPS storage that supports
range requests for the best recovery behavior, especially for large artifacts.
```

- [ ] **Step 3.2: Verify resumable docs are discoverable**

Run:

```sh
rg -n "Resumable Downloads|Range|206 Partial Content|Content-Range|\\.part|SHA-256 mismatch" docs/publishing.md
```

Expected:

```text
docs/publishing.md explains the resume, restart, delete, and fail rules.
```

## Task 4: Clarify Roadmap-Only Boundaries

**Files:**
- Modify: `docs/publishing.md`
- Inspect: `README.md`
- Inspect: `SECURITY.md`

- [ ] **Step 4.1: Add a short roadmap-only note**

In `docs/publishing.md`, add this section after `### Resumable Downloads`:

```markdown
### Roadmap-Only Update Features

Rollback and cleanup reports are still roadmap work. The current native helpers
perform rollback-focused replacement behavior, but the package does not yet
expose a public rollback report object after install scheduling or next startup.

Delta artifacts are also roadmap work. The runtime continues to choose the full
zip artifact until delta descriptor support, patch verification, and patch
application have their own fail-first tests and public API documentation.
```

- [ ] **Step 4.2: Keep README concise**

Run:

```sh
rg -n "rollout|resumable|delta|rollback report|cleanup report|installationIdentity" README.md
```

Expected:

```text
No matches are required in README.md. README should continue linking to docs/publishing.md and docs/ui-widgets.md instead of duplicating advanced policy.
```

- [ ] **Step 4.3: Keep SECURITY.md scoped to security boundaries**

Run:

```sh
rg -n "rollback report|cleanup report|delta|resumable|rollout" SECURITY.md
```

Expected:

```text
SECURITY.md may mention rollback as an impact category, but it should not gain long roadmap or remediation detail.
```

## Task 5: Verify Documentation Closure

**Files:**
- Verify: `docs/plans/2026-06-13-trust-ux-and-product-roadmap-plan.md`
- Verify: `docs/publishing.md`
- Verify: `docs/ui-widgets.md`
- Verify: `README.md`
- Verify: `SECURITY.md`

- [ ] **Step 5.1: Scan for weak placeholders**

Run:

```sh
rg -n "TB[D]|TO[D]O|implement late[r]|fill in detail[s]|Similar to Tas[k]|Add appropriat[e]|Write tests for the abov[e]" docs/plans/2026-06-13-trust-ux-and-product-roadmap-plan.md docs/publishing.md docs/ui-widgets.md README.md SECURITY.md
```

Expected:

```text
No matches.
```

- [ ] **Step 5.2: Check markdown patch hygiene**

Run:

```sh
git diff --check -- docs/plans/2026-06-13-trust-ux-and-product-roadmap-plan.md docs/publishing.md docs/ui-widgets.md README.md SECURITY.md
```

Expected:

```text
No trailing whitespace or conflict marker errors.
```

- [ ] **Step 5.3: Run targeted behavior tests for the documented features**

Run:

```sh
flutter test --no-pub \
  test/release_signature_verifier_test.dart \
  test/artifact_verifier_test.dart \
  test/release_cli/release_sign_command_test.dart \
  test/release_cli/release_validate_test.dart \
  test/release_cli/release_doctor_test.dart \
  test/release_index_test.dart \
  test/update_transport_test.dart \
  test/update_client_security_test.dart \
  test/update_diagnostics_test.dart \
  test/update_problem_report_dialog_test.dart \
  test/updater_controller_test.dart \
  test/update_ready_ui_test.dart \
  test/update_dialog_listener_test.dart
```

Expected:

```text
All targeted tests pass. Existing opt-in release-publish E2E tests remain skipped unless their environment flags are explicitly set.
```

- [ ] **Step 5.4: Review final doc diff**

Run:

```sh
git diff -- docs/plans/2026-06-13-trust-ux-and-product-roadmap-plan.md docs/publishing.md docs/ui-widgets.md README.md SECURITY.md
```

Expected:

```text
Diff shows roadmap status sync, staged rollout docs, resumable download docs, roadmap-only boundaries, and no unrelated README or SECURITY.md expansion.
```

## Self-Review Notes

- This plan closes documentation and status-tracking gaps only.
- Runtime code changes belong in the original roadmap plan or the native-helper diagnostics plan, not in this closure slice.
- `rollback and cleanup report` and `deltaArtifacts` must stay visibly planned until they have concrete runtime types, tests, and public API docs.
- Public documentation should say what apps can safely use today; plan docs can carry future implementation detail.
