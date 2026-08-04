# Windows and Linux Privileged Updater Production Readiness Implementation Plan

**Goal:** Bring Windows and Linux native privileged updater readiness to evidence-backed completion in the fastest safe order: unblock Windows compilation, fix and verify Linux in Docker/hosted CI, complete Linux polkit VM evidence, then harden and prove Windows smoke/UAC/Inno—without regressing the production-ready macOS scope.

**Architecture:** Preserve the existing fail-closed, descriptor-relative native transaction architecture and fix only demonstrated defects. Hosted secretless gates precede privileged target-host work; Docker proves Linux mechanics but never substitutes for a real polkit host, and hosted signed Inno never substitutes for interactive UAC. Readiness documentation remains platform-scoped and literal until exact-revision evidence exists.

**Tech Stack:** Flutter/Dart tests, C++17, CMake/CTest/GoogleTest, Win32/NT APIs, Linux `openat`/`renameat`/identity checks, Docker, GitHub Actions, polkit/pkexec, PowerShell, Inno Setup, Authenticode.

## Current Release Scope Decision

As of 2026-07-28, Linux production distribution is outside the current release
scope. This release exposes Linux only as a source-first native SDK and
direct-ZIP `preview`; it remains `candidate-only` and is not
`production-ready`. AppImage, deb/APT, rpm/DNF, Flatpak/Flathub, Snap
Store/Brand Store, and installed-polkit production closure remain future work.

Accordingly, Task 7 and the Linux distribution-artifacts plan are not merge or
publication gates for this scoped release. Their unchecked steps remain
literal `not run`; Docker and hosted Linux CI can verify portable mechanics but
must not be relabeled as store, repository, or real-polkit evidence. Windows
readiness and ordinary Linux direct-ZIP preview regressions remain in scope.

## Global Constraints

- Work only on `feat/native-sdk-platform-split`; do not create, switch, rename, or delete branches.
- Baseline is clean `afce36d50d256ee216661c84b6648d68e8ac5967`, equal to `origin/feat/native-sdk-platform-split`.
- Keep Windows and Linux changes in separate Conventional Commits and push every independent platform fix.
- Do not modify macOS production code, installed macOS state, or `reports/macos-privileged-updater/` evidence in Windows/Linux commits.
- Windows, Linux, and overall native runtime remain literal `candidate-only` / `NO-GO` until their real required evidence passes.
- Do not start signing, UAC, polkit, or release-costly loops until hosted/secretless prerequisites are green.
- Never weaken a test or security check to obtain green; preserve fail-closed/manual behavior and hostile backup retention.
- Do not post GitHub comments or reviews through connector identities.
- The plan does not grant commit, push, branch, release, or external-write
  authority; current user and repository instructions remain authoritative.
- Use the narrowest test first, widen before commit, and run fresh verification immediately before every success claim.

## Baseline Evidence

- GitHub Actions run `29813766489` is exact baseline SHA `afce36d50d256ee216661c84b6648d68e8ac5967`: <https://github.com/MarlonJD/flutter_desktop_updater/actions/runs/29813766489>.
- Windows job `88580297318` fails in `Build standalone Windows native SDK tests` with C2065 for `FILE_OPEN`, `FILE_CREATE`, `FILE_OPEN_IF`, `FILE_DIRECTORY_FILE`, `FILE_NON_DIRECTORY_FILE`, `FILE_SYNCHRONOUS_IO_NONALERT`, and `FILE_WRITE_THROUGH` in the two portable storage translation units.
- Linux job `88580297423` builds, then fails `LinuxTransactionRegistry.RetainsOnlyTheTransactionScopedHelperAndPolicyGeneration` with `transaction state directory identity changed`; `LinuxCrashRecovery.InvalidBackupIdentityIsManual` is also a required focused reproduction before changing recovery code.
- Dart Package job `88580297419` reports 793 passed, 1 failed, 10 skipped; the failing scope test scans macOS Swift together with Linux providers and rejects macOS `/bin/sh`.
- The same run also exposes a macOS Swift compiler regression at `MacPrivilegeService.swift:787`; record it as an independent regression and do not mix its remediation into Windows/Linux commits or alter macOS production-ready evidence.

## File Map

- Modify `windows/native/src/helper/windows_portable_transaction_index.cpp`: explicitly import the NT file disposition/option constants used by this TU.
- Modify `windows/native/src/helper/windows_portable_user_storage.cpp`: explicitly import the same NT constants used by this TU.
- Modify proven compile-successor TUs `windows_archive_restage.cpp`, `windows_persistent_recovery.cpp`, and `windows_portable_recovery_host.cpp` only for their directly used Windows SDK declarations.
- Modify `linux/native/src/helper/linux_transaction_registry.cc`: repair demonstrated retained-directory identity handling without relaxing ownership, mode, no-follow, link-count, or descriptor checks.
- Modify `linux/native/src/helper/linux_recovery_service.cc` only if focused RED proves production behavior removes or mutates an invalid backup; keep identity mismatch manual and non-destructive.
- Modify/add focused cases in `linux/native/test/helper/linux_transaction_registry_test.cc` and `linux/native/test/helper/linux_crash_recovery_test.cc` before production changes.
- Modify `test/linux_helper_strategy_scope_test.dart`: separate the Linux command-execution scan from macOS/Windows provider coverage and scan only intended Linux helper/policy/script surfaces.
- Modify `tool/windows_install_helper_smoke.ps1`, `tool/windows_inno_smoke.ps1`, `.github/workflows/desktop-updater-ci.yml`, and focused Dart contract tests only during Windows hardening after hosted compilation/tests are green.
- Create evidence beneath `reports/linux-privileged-updater/` and `reports/windows-privileged-updater/` using the established repository report schema; never edit `reports/macos-privileged-updater/`.
- Modify readiness/docs only in evidence-specific commits after exact target-host gates pass.

## Safety and Rollback

- Before every edit/commit, run `git status --short` and stop on unexpected user changes in the target files.
- Stage exact paths, inspect `git diff --cached --check` and `git diff --cached`, then commit; never use broad destructive reset/checkout commands.
- If a candidate fix fails, revert only the uncommitted candidate with an `apply_patch` inverse and return to root-cause investigation.
- Privileged Docker runs use a throwaway named container and exact mounted targets under `/tmp`; Linux VM paths use a run-specific `/opt/desktop-updater-polkit-e2e-*` root.
- Failed target-host runs must preserve hostile/ambiguous backup and journal state for diagnosis unless the harness explicitly proves safe cleanup.

---

### Task 1: Phase 0 — Baseline, Plan, and Evidence Ledger

**Files:**
- Create: `docs/exec-plans/active/2026-07-21-windows-linux-production-readiness.md`

**Interfaces:**
- Consumes: current branch, remote tracking ref, Actions run `29813766489`.
- Produces: immutable baseline facts, phase ordering, exact gates, and commit boundaries used by all later tasks.

- [x] **Step 1: Verify clean exact baseline**

Run:
```bash
git status --short --branch
git branch --show-current
git rev-parse HEAD
git rev-parse origin/feat/native-sdk-platform-split
```
Expected: clean status; branch `feat/native-sdk-platform-split`; both SHAs equal `afce36d50d256ee216661c84b6648d68e8ac5967`.

- [x] **Step 2: Inspect exact-head CI, not summaries**

Run:
```bash
gh run view 29813766489 --json headSha,status,conclusion,url,jobs
gh run view 29813766489 --job 88580297318 --log-failed
gh run view 29813766489 --job 88580297423 --log-failed
gh run view 29813766489 --job 88580297419 --log-failed
```
Expected: exact SHA match and the literal failures recorded under Baseline Evidence.

- [x] **Step 3: Track execution state**

Run `git status --short` after saving this plan. Expected: only this new plan before Task 2 edits.

**Exit criterion:** Baseline, actual CI failures, file map, RED/GREEN commands, safety rules, phase gates, and commit/push boundaries are explicit.

### Task 2: Phase 1 — Minimal Windows Compile Unblock

**Files:**
- Modify: `windows/native/src/helper/windows_portable_transaction_index.cpp`
- Modify: `windows/native/src/helper/windows_portable_user_storage.cpp`

**Interfaces:**
- Consumes: Microsoft SDK constants declared by `<winternl.h>` and the existing explicit-include pattern in `windows_relaunch_service.cpp`, `windows_transaction_journal.cpp`, `windows_recovery_service.cpp`, and `windows_file_transaction.cpp`.
- Produces: both offending translation units compile with their directly used NT constants declared.

- [x] **Step 1: Preserve the RED compile evidence**

Run:
```bash
gh run view 29813766489 --job 88580297318 --log-failed
```
Expected: C2065 errors in exactly the two mapped TUs. A macOS host cannot claim local MSVC compilation.

- [x] **Step 2: Verify the working include pattern**

Run:
```bash
rg -n '#include <winternl.h>' windows/native/src/helper/{windows_relaunch_service.cpp,windows_transaction_journal.cpp,windows_recovery_service.cpp,windows_file_transaction.cpp}
```
Expected: all four references explicitly include the header.

- [x] **Step 3: Apply the minimal GREEN change**

Add after the local header in each offending TU:
```cpp
#include <winternl.h>
```
Do not refactor declarations, duplicate constant values, or change behavior.

- [x] **Step 4: Run static and package-surface checks**

Run:
```bash
rg -n '#include <winternl.h>' windows/native/src/helper/windows_portable_{transaction_index,user_storage}.cpp
flutter test --no-pub test/windows_native_sdk_layout_test.dart
git diff --check
```
Expected: both explicit includes found; Dart test passes; no whitespace errors. Record Windows compilation as `not run locally (macOS host)`.

- [x] **Step 5: Commit and push only the Windows unblock**

Run:
```bash
git add windows/native/src/helper/windows_portable_transaction_index.cpp windows/native/src/helper/windows_portable_user_storage.cpp
git diff --cached --check
git diff --cached
git commit -m "fix(windows): include native transaction constants"
git push origin feat/native-sdk-platform-split
```
Expected: one Windows-only commit is pushed.

- [ ] **Step 6: Monitor exact-head Actions and chase only proven compile successors**

Run:
```bash
gh run list --branch feat/native-sdk-platform-split --workflow "Desktop Updater CI" --limit 5 --json databaseId,headSha,status,conclusion,url
gh run watch <run-id> --exit-status
```
Expected: the run SHA equals the pushed commit and Windows passes the standalone compile step. If a subsequent minimal compile defect appears, reproduce from its log, make one Windows-only fix/commit/push, and repeat; do not suppress diagnostics or weaken tests.

**Exit criterion:** Exact-head hosted Windows passes `Build standalone Windows native SDK tests`; local evidence is not substituted for hosted MSVC evidence.

### Task 3: Phase 2A — Linux Registry Identity RED/GREEN

**Files:**
- Test: `linux/native/test/helper/linux_transaction_registry_test.cc`
- Modify: `linux/native/src/helper/linux_transaction_registry.cc`

**Interfaces:**
- Consumes: retained `directory_fd_`, `directory_identity_`, `ReadLinuxFileIdentity`, fd-relative operations.
- Produces: registry writes retain the authoritative directory descriptor/identity while rejecting replacement, symlink, owner, group, and mode changes.

- [ ] **Step 1: Build Linux tests in a disposable container**

Run:
```bash
docker build -f tool/linux-ci.Dockerfile -t desktop-updater-linux-ci .
docker run --rm -v "$PWD:/workspace" -w /workspace desktop-updater-linux-ci cmake -S linux/native -B /tmp/linux-build -DDESKTOP_UPDATER_BUILD_TESTS=ON -DCMAKE_BUILD_TYPE=Release
docker run --rm -v "$PWD:/workspace" -w /workspace desktop-updater-linux-ci cmake --build /tmp/linux-build --config Release --parallel
```
Expected: configure/build succeeds. If `tool/linux-ci.Dockerfile` does not exist, use the repository's CI Ubuntu image/dependency command from `.github/workflows/desktop-updater-ci.yml`; do not invent a permanent image in this task.

- [ ] **Step 2: Verify the focused RED**

Run in the same image/build volume:
```bash
ctest --test-dir /tmp/linux-build -R '^linux_transaction_registry\.LinuxTransactionRegistry\.RetainsOnlyTheTransactionScopedHelperAndPolicyGeneration$' --output-on-failure --no-tests=error
```
Expected: FAIL with `transaction state directory identity changed`.

- [ ] **Step 3: Add a regression assertion before production code**

Extend the focused test so it proves an unchanged registry directory accepts retention while an actual directory replacement remains rejected. Expected RED must be the unchanged-directory path, not a setup or permission error.

- [ ] **Step 4: Trace and minimally fix the identity mismatch**

Compare `fstat`/`ReadLinuxFileIdentity` observations at constructor, retained descriptor reopen, and pre-rename boundaries. Fix the source of the false mismatch; preserve `O_NOFOLLOW`, uid/gid, mode `0700`, link-count/file-mode checks, and descriptor-relative rename/fsync.

- [ ] **Step 5: Verify focused GREEN and hostile replacement RED remains enforced**

Run:
```bash
ctest --test-dir /tmp/linux-build -R '^linux_transaction_registry\.' --output-on-failure --no-tests=error
```
Expected: all registry tests pass, including rejection tests.

### Task 4: Phase 2B — Linux Invalid Backup Fail-Closed Recovery

**Files:**
- Test: `linux/native/test/helper/linux_crash_recovery_test.cc`
- Modify if RED confirms defect: `linux/native/src/helper/linux_recovery_service.cc`

**Interfaces:**
- Consumes: journal-bound `target_identity`, `Matches`, and fd-relative recovery operations.
- Produces: invalid replacement backup returns `kManualActionRequired` and retains the backup byte-for-byte for operator action.

- [ ] **Step 1: Verify focused RED before editing production**

Run:
```bash
ctest --test-dir /tmp/linux-build -R '^linux_crash_recovery\.LinuxCrashRecovery\.InvalidBackupIdentityIsManual$' --output-on-failure --no-tests=error
```
Expected: reproduce the hosted/current defect: outcome differs from `kManualActionRequired` and/or hostile backup disappears. If it passes in the clean container, capture environment/filesystem differences and do not make a speculative production change.

- [ ] **Step 2: Strengthen the test only to encode the stated invariant**

Record hostile backup identity/content before `Recover()`, then assert manual outcome, path existence, identity preservation, and content `attacker`. Re-run with the production candidate absent to prove correct RED.

- [ ] **Step 3: Implement the smallest fail-closed fix**

Ensure every backup identity mismatch returns before rename, unlink, tree cleanup, or journal removal. Do not authorize an attacker-controlled backup or loosen `Matches`.

- [ ] **Step 4: Verify recovery GREEN**

Run:
```bash
ctest --test-dir /tmp/linux-build -R '^linux_crash_recovery\.' --output-on-failure --no-tests=error
```
Expected: all crash-recovery tests pass; invalid backup remains present.

### Task 5: Phase 2C — Correct the Stale Dart Linux Scope

**Files:**
- Modify: `test/linux_helper_strategy_scope_test.dart`

**Interfaces:**
- Consumes: Linux provider files that can launch commands or encode package strategy.
- Produces: `/bin/sh`, `system(`, `popen(`, and dangerous flag rejection over the intended Linux surface only; cross-platform capability coverage remains separate.

- [ ] **Step 1: Verify Dart RED**

Run:
```bash
flutter test --no-pub test/linux_helper_strategy_scope_test.dart
```
Expected: FAIL because macOS `VerifiedInstallerHandoff.swift` contains `/bin/sh`.

- [ ] **Step 2: Narrow the security scan without an allowlist**

Keep capability presence checks cross-platform, but apply forbidden command/mount token checks to a `linuxSurface` assembled only from the relevant Linux helper/provider/policy/script files. Do not add a macOS exception and do not change Swift production code.

- [ ] **Step 3: Verify Dart GREEN and guard sensitivity**

Run:
```bash
flutter test --no-pub test/linux_helper_strategy_scope_test.dart
```
Expected: PASS. Temporarily inject a forbidden token into the in-memory test fixture/list or use a test-local negative sample to prove the matcher still rejects Linux `/bin/sh`; leave no production mutation.

### Task 6: Phase 2D — Widen Linux Verification, Commit, Push, Hosted Gate

**Files:**
- Modify: only Linux production/tests and the Dart Linux scope test from Tasks 3–5.

- [ ] **Step 1: Run focused and full Linux lanes**

Run:
```bash
ctest --test-dir /tmp/linux-build -R '(LinuxHelperAuth|linux_transaction|linux_crash_recovery)' --output-on-failure --no-tests=error
ctest --test-dir /tmp/linux-build --output-on-failure --no-tests=error
cmake -S linux/native -B /tmp/linux-release -DDESKTOP_UPDATER_BUILD_TESTS=ON -DCMAKE_BUILD_TYPE=Release
cmake --build /tmp/linux-release --config Release --parallel
ctest --test-dir /tmp/linux-release --output-on-failure --no-tests=error
./tool/linux_install_helper_smoke.sh --mode unprivileged --build-directory /tmp/linux-release
flutter test --no-pub test/linux_helper_strategy_scope_test.dart test/linux_native_sdk_layout_test.dart test/native_runtime_merge_gate_contract_test.dart
```
Expected: all non-privileged gates pass; every skip is listed by name and reason.

- [ ] **Step 2: Run privileged mount/safety tests only in throwaway Docker**

Run the exact workflow command from `Run Linux privileged mount namespace rejection test` inside `docker run --rm --privileged` with only a run-specific `/tmp/desktop-updater-*` target. Expected: root-owned path, bind-mount, symlink, identity, and permission attacks are rejected; no host path outside the exact temp root is writable.

- [ ] **Step 3: Commit Linux changes in reviewer-independent units**

Use exact staging and Conventional Commits, for example:
```bash
git add linux/native/src/helper/linux_transaction_registry.cc linux/native/test/helper/linux_transaction_registry_test.cc
git commit -m "fix(linux): retain authoritative registry identity"
git push origin feat/native-sdk-platform-split
git add linux/native/src/helper/linux_recovery_service.cc linux/native/test/helper/linux_crash_recovery_test.cc test/linux_helper_strategy_scope_test.dart
git commit -m "fix(linux): preserve invalid recovery backups"
git push origin feat/native-sdk-platform-split
```
If recovery production code needs no change, commit the Dart scope correction separately as `test(linux): constrain helper strategy scope`. Never stage Windows files.

- [ ] **Step 4: Require exact-head hosted Linux GREEN**

Run:
```bash
gh run list --branch feat/native-sdk-platform-split --workflow "Desktop Updater CI" --limit 5 --json databaseId,headSha,status,conclusion,url
gh run watch <run-id> --exit-status
```
Expected: exact final Linux SHA; hosted Linux job and privileged mount rejection step pass. Skips remain classified, never promoted to production evidence.

**Exit criterion:** Exact-head hosted Linux is green, privileged disposable mount/safety tests pass, Dart scope is correct, and Linux remains candidate-only pending real polkit/distribution evidence.

### Task 7: Phase 3 — Real Linux Polkit VM Evidence

**Files:**
- Create: `reports/linux-privileged-updater/<exact-sha>-polkit-e2e.md` and sanitized fixed-field artifacts used by the established report format.
- Modify only after all gates pass: scoped readiness docs/tests.

- [ ] **Step 1: Confirm prerequisites and harness configuration**

Run:
```bash
rg -n 'self-hosted, Linux, X64, desktop-updater-polkit|DESKTOP_UPDATER_RUN_POLKIT_HELPER_E2E' .github/workflows/desktop-updater-ci.yml docs/github-actions-ci-cd.md
gh run view <hosted-green-run-id> --json headSha,status,conclusion,url,jobs
```
Expected: hosted exact-head gates green; runner labels and variable guard exactly match the specification.

- [ ] **Step 2: Dispatch on a disposable interactive Ubuntu VM**

Enable `vars.DESKTOP_UPDATER_RUN_POLKIT_HELPER_E2E == '1'` only when the labeled self-hosted runner has real `polkit`, `pkexec`, and an interactive auth agent. Dispatch the workflow for the exact commit. Expected: the polkit job starts on `[self-hosted, Linux, X64, desktop-updater-polkit]`; Docker output is not accepted here.

- [ ] **Step 3: Prove installation, mutation, recovery, and cleanup**

The existing harness must prove exact-byte/static root-owned broker/policy/caller installation, non-root `pkexec` mutation and durable query, crash after target-to-backup rename, fresh-broker recovery, completed/succeeded result, and cleanup. Expected: every operation binds transaction ID, exact commit SHA, runner/OS, and literal outcome.

- [ ] **Step 4: Record and hash evidence**

Record run/job URLs, exact SHA, Ubuntu version, commands, sanitized results, transaction outcome, cleanup status, and artifact SHA-256 values. Run `shasum -a 256` over downloaded evidence and include hashes in the report.

- [ ] **Step 5: Make evidence/readiness commits**

Commit/push the Linux evidence separately. Update Linux to scoped `production-ready` only if every real gate passes and the Linux distribution-artifacts plan prerequisite is satisfied; otherwise retain `candidate-only / external evidence pending` and name the missing distribution prerequisite. Any explicit platform-scoped prerequisite decision is a separate documentation commit.

**Exit criterion:** Exact-revision real VM polkit evidence and cleanup exist, or all safe hosted work is complete with literal `candidate-only / external evidence pending` (not falsely production-ready).

### Task 8: Phase 4A — Harden Hosted Windows Smoke and Inno Gates with TDD

**Files:**
- Modify: `tool/windows_install_helper_smoke.ps1`
- Modify: `tool/windows_inno_smoke.ps1`
- Modify: `.github/workflows/desktop-updater-ci.yml`
- Test: `test/windows_native_sdk_layout_test.dart`, `test/native_runtime_merge_gate_contract_test.dart`, and focused Windows native tests.

- [ ] **Step 1: Write RED contract tests for false-green behavior**

Require the install-helper smoke to perform portable v1→v2 public prepare/commit/query, after-backup death with fresh-process recovery, and journal/stage cleanup. Require the Inno smoke to fail if it only validates prerequisite scaffolding; preserve installed CMake, .NET/NuGet/PInvoke/CRT/package inventory gates.

- [ ] **Step 2: Run RED**

Run:
```bash
flutter test --no-pub test/windows_native_sdk_layout_test.dart test/native_runtime_merge_gate_contract_test.dart
```
Expected: FAIL because current scripts only prove `--version`/CTest or prerequisite scaffolding.

- [ ] **Step 3: Implement minimal hosted E2E**

Drive the built public Windows surface through prepare/commit/query, inject the existing after-backup crash point, start a fresh process for recovery, and assert exact cleanup. Add Program Files helper/policy ACL checks where hosted elevation permits them. Keep signed Inno install/update/uninstall and metadata cleanup conditional on real signing secrets, with a literal non-success result when absent.

- [ ] **Step 4: Run GREEN locally where possible and on exact-head hosted Windows**

Run focused Dart tests locally, then commit/push Windows-only hardening and require the hosted Windows job to pass the exact PowerShell/native commands. A non-Windows local host records PowerShell/native execution as `not run locally`.

**Exit criterion:** Hosted Windows cannot be green from version/CTest/prerequisite-only scaffolding and proves the unprivileged public transaction/recovery lifecycle.

### Task 9: Phase 4B — Real Interactive Windows UAC and Signed Inno Evidence

**Files:**
- Create: `reports/windows-privileged-updater/<exact-sha>-uac-inno-e2e.md` plus sanitized hashed artifacts.
- Modify only after all gates pass: scoped readiness docs/tests.

- [ ] **Step 1: Confirm exact prerequisites**

Verify `[self-hosted, Windows, X64, desktop-updater-uac]`, `vars.DESKTOP_UPDATER_RUN_ELEVATED_HELPER_E2E == '1'`, and presence (not value) of `WINDOWS_CODE_SIGNING_P12_BASE64` and `WINDOWS_CODE_SIGNING_P12_PASSWORD`. Do not print secrets.

- [ ] **Step 2: Dispatch exact SHA to an interactive Windows VM**

Expected: real secure-desktop UAC can be accepted/cancelled; the hosted signed Inno lane alone is explicitly insufficient.

- [ ] **Step 3: Prove literal privileged outcomes**

Prove UAC cancel/no mutation, elevation success, machine-wide protected Program Files update, crash recovery from after-backup death with a fresh process, ACL/policy integrity, signed Inno install/update/uninstall, metadata and journal/stage cleanup.

- [ ] **Step 4: Record evidence and update readiness only when complete**

Bind run/job URLs, exact SHA, runner/OS, signing certificate fingerprint (never secret material), artifact hashes/submission IDs, transaction outcomes, and cleanup. Commit/push evidence separately. Update Windows scoped readiness only after all target-host gates pass.

- [ ] **Step 5: Re-evaluate the scoped native runtime**

The current release may be evaluated with macOS and Windows as production
platforms while Linux is explicitly shipped only as a direct-ZIP `preview`.
Linux distribution and installed-polkit evidence must not be inferred, and the
overall cross-platform native preview remains `candidate-only` while Linux is
not `production-ready`.

**Exit criterion:** Windows has exact-revision signed target-host UAC/Inno evidence, or all safe hosted work is complete with literal `candidate-only / external evidence pending`.

### Task 10: Final Verification and Goal Closure

**Files:**
- Verify all modified code, tests, plans, reports, and readiness docs.

- [ ] **Step 1: Run the full local ladder**

Run:
```bash
dart format --set-exit-if-changed .
flutter analyze --no-fatal-infos
flutter test --no-pub
dart pub publish --dry-run
git diff --check
git status --short --branch
```
Expected: all commands exit 0; worktree clean after final commits.

- [ ] **Step 2: Audit commit/platform boundaries**

Run:
```bash
git log --oneline afce36d50d256ee216661c84b6648d68e8ac5967..HEAD
git diff --name-status afce36d50d256ee216661c84b6648d68e8ac5967..HEAD
git diff --exit-code afce36d50d256ee216661c84b6648d68e8ac5967..HEAD -- reports/macos-privileged-updater
```
Expected: separate Windows/Linux commits and no macOS privileged evidence changes.

- [ ] **Step 3: Audit evidence language and exact revisions**

Run:
```bash
rg -n 'production-ready|candidate-only|NO-GO|external evidence pending' docs reports test
```
Expected: every readiness claim is supported by a linked exact-SHA run and required target-host evidence; missing secrets/runners are described as pending, not silently passed.

- [ ] **Step 4: Close the active goal only on genuine completion**

Call `update_goal(status="complete")` only when no required implementation or evidence remains. If external runners/secrets are absent after all safe work, keep the goal active and report `candidate-only / external evidence pending`; mark blocked only after the tool-defined repeated-impasse threshold.

**Exit criterion:** Fresh verification supports every completion claim, all independent commits are pushed, and goal status matches literal evidence.
