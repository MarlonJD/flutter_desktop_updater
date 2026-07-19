# macOS Privileged Updater Production Closure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce current-head, signed, notarized, stapled, real `/Applications` elevation and installer-active crash-recovery evidence for the SMAppService/XPC macOS PKG updater.

**Architecture:** Close artifact trust first by verifying the source app and the app extracted from the final signed PKG before notarization. Then run a smoke-owned target application through typed approval, privileged installation, and a controlled installer-active daemon crash while binding recovery to the durable manager PID/start identity. Keep unit fault coverage and real target-host evidence separate, sanitize the evidence, and issue a literal GO/NO-GO decision only from fresh current-head outputs.

**Tech Stack:** Dart/Flutter tests and smoke tools, Swift/XCTest, `SMAppService`, authenticated XPC, `MacVerifiedInstallerTransaction`, fixed-argv `/usr/sbin/installer`, Developer ID Application/Installer identities, `codesign`, `pkgutil`, `spctl`, `notarytool`, `stapler`, and `launchctl`.

## Global Constraints

- Work directly on `feat/native-sdk-platform-split`; do not create, switch, rename, or delete branches.
- Preserve unrelated user changes and inspect `git status`/`git diff` before every logical slice.
- Use SMAppService/XPC only. Do not introduce `SMJobBless`, `AuthorizationExecuteWithPrivileges`, `sudo`, AppleScript elevation, shell-based provider execution, or an actual `Installer.app` handoff.
- The privileged provider executes only `/usr/sbin/installer -pkg <owned-stage>/installer.pkg -target /` through the existing fixed worker.
- Keep release schema v3 and the package version unchanged.
- Parsers accept legacy `install.macosPkg.launchMode: "installerApp"`; publishers emit only `"privilegedInstallerTool"`, with PKG `minimumUpdaterVersion` at least `2.7.0`.
- Use only identities and notary profiles already present in Keychain. Never print passwords, private keys, API keys, keychain item contents, or unredacted credential paths.
- Only replace/remove the smoke-owned bundle when bundle ID, owner marker, app name, and receipt ID all match.
- A successful PKG submission does not prove nested integrity. Verify source app, expanded PKG payload app, installed app, main executable, and embedded helper separately.
- `manualActionRequired` retains the owned stage. `completed` and verified rollback remove it. Recovery never mutates or cleans while the exact manager PID/start identity is live.
- Preserve Flutter code `PrivilegedHelperApprovalRequired` and remediation `openMacOSBackgroundItemsSettings`.
- If approval is required, pause at the explicit System Settings action and continue after approval without rebuilding.
- Use literal evidence labels: `verified locally`, `not run`, `blocked`, `candidate-only`, and `production-ready`.
- Use focused TDD, then widen. Run `git diff --check` and a privilege-boundary review before every Conventional Commit; push every verified slice.

## Current Baseline

- Pushed HEAD at plan creation: `46e7bd97c3b1ed4e793b3da85805cfb5b0207b44`.
- Installed smoke target reports `2.7.1+271`, receipt `net.monolib.updater.pkg`, Team ID `UPK4SC93AN`, and `root:wheel`.
- That fixture is not acceptance evidence: it predates `ccfbe52`, and fresh strict checks fail for both its main executable and `DesktopUpdaterInstallHelper`.
- Authenticated SMAppService directory-replacement recovery has scoped target-host evidence. Current-head privileged PKG installer-active recovery does not.
- Unit tests already cover spawn-before-journal, journal-before-gate, manager-started, verification-pending, completion, rollback, cleanup, and exact process-start identity decisions.

## File Map

- Artifact integrity: modify `lib/src/release_cli/macos/pkg_packager.dart`, `example/native/macos-runtime/package_smoke_app.sh`, and their focused tests.
- Artifact audit: create `tool/macos_pkg_artifact_audit.dart` and `test/macos_pkg_artifact_audit_test.dart`.
- Target-host install: create `tool/macos_privileged_pkg_smoke.dart`, its contract test, and emit typed JSON smoke events from `example/native/macos-runtime/Sources/MacOSRuntimeCompile/main.swift`.
- Recovery: create `example/native/macos-runtime/pkg-scripts/recovery/preinstall`, `tool/macos_privileged_pkg_recovery_smoke.dart`, and its contract test.
- Evidence/docs: update the self-hosted CI lane, macOS docs, harness docs, diagnostics docs, and the cross-platform helper ledger; write sanitized reports under `reports/macos-privileged-updater/`.

---

### Task 1: Make Final PKG Payload Integrity a Publishing Gate

**Files:**

- Modify: `lib/src/release_cli/macos/pkg_packager.dart`
- Modify: `example/native/macos-runtime/package_smoke_app.sh`
- Test: `test/release_cli/pkg_packager_test.dart`
- Test: `test/macos_production_smoke_tool_test.dart`
- Test: `test/native_runtime_smoke_contract_test.dart`

**Interfaces:**

- Consumes: `AppleTrustCommands.verifyApp(Directory app)`.
- Produces: source-app verification, `pkgbuild`, `productbuild`, `pkgutil --expand-full`, exact payload verification, then notarization/stapling/package checks.

- [x] **Step 1: Write RED order and failure tests**

Add ordered assertions:

```dart
final verifies = commands.where(
  (command) => command.startsWith(
    "/usr/bin/codesign --verify --deep --strict --verbose=2",
  ),
).toList();
expect(verifies, hasLength(2));
expect(verifies.first, contains("Example.app"));
expect(commands, contains(contains("/usr/sbin/pkgutil --expand-full")));
expect(verifies.last, contains("expanded/component.pkg/Payload/Example.app"));
expect(
  commands.indexOf(verifies.last),
  lessThan(commands.indexWhere((c) => c.contains("notarytool submit"))),
);
```

Add a runner that fails expanded-payload verification; expect `ProcessException` and no `notarytool submit`.

Run:

```sh
flutter test --no-pub test/release_cli/pkg_packager_test.dart
```

Expected: FAIL because the packager does not expand/verify the final payload.

Evidence (`verified locally`, 2026-07-17): the focused RED run failed with two
expected assertions: zero source/payload strict verifications were observed,
and an invalid expanded payload still returned a successful package result.
Adversarial follow-up RED coverage also proved that top-level source and payload
application symlinks were accepted before the fixed-node hardening.

- [x] **Step 2: Implement exact payload verification**

In `PkgPackager.package`, verify the input app, then after `productbuild` and before temp cleanup/notarization:

```dart
final trust = AppleTrustCommands(runProcess: runProcess);
await trust.verifyApp(request.input as Directory);
final expanded = Directory(path.join(tempDir.path, "expanded"));
await _runChecked("/usr/sbin/pkgutil", [
  "--expand-full",
  artifact.path,
  expanded.path,
]);
final payloadApp = Directory(path.join(
  expanded.path,
  "component.pkg",
  "Payload",
  request.appName,
));
if (!await payloadApp.exists()) {
  throw FileSystemException(
    "Signed PKG does not contain the expected application payload.",
    payloadApp.path,
  );
}
await trust.verifyApp(payloadApp);
```

Keep `component.pkg` fixed; do not search alternate members.

Evidence (`verified locally`, 2026-07-17): the publisher now verifies the
source application before packaging, expands only the final product archive,
requires the exact non-symlink
`component.pkg/Payload/<request.appName>` directory, and verifies it before any
notarization submission. A simulated payload-signature failure throws
`ProcessException` and records no `notarytool submit` command.

- [x] **Step 3: Add the same gate to the runtime packager**

After `productbuild`, before `notarytool submit`:

```sh
expanded_pkg="$work/expanded-product"
/bin/rm -rf "$expanded_pkg"
/usr/sbin/pkgutil --expand-full "$pkg_output" "$expanded_pkg"
payload_app="$expanded_pkg/component.pkg/Payload/$(/usr/bin/basename "$app_bundle")"
[ -d "$payload_app" ] || fail "final PKG payload app is missing"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$payload_app"
/usr/bin/codesign --verify --strict --verbose=2 \
  "$payload_app/Contents/Helpers/DesktopUpdaterInstallHelper"
```

Evidence (`verified locally`, 2026-07-17): the runtime shell packager expands
the final product archive at the fixed component path, rejects a missing or
top-level symlink payload app, and independently verifies the payload app and
embedded helper before notarization. `sh -n` completed successfully.

- [x] **Step 4: Verify, review, commit, and push**

```sh
flutter test --no-pub \
  test/release_cli/pkg_packager_test.dart \
  test/macos_production_smoke_tool_test.dart \
  test/native_runtime_smoke_contract_test.dart
sh -n example/native/macos-runtime/package_smoke_app.sh
git diff --check
```

Review component traversal, symlinks, temp reuse, ignored exit codes, and notarization order.

```sh
git add lib/src/release_cli/macos/pkg_packager.dart \
  example/native/macos-runtime/package_smoke_app.sh \
  test/release_cli/pkg_packager_test.dart \
  test/macos_production_smoke_tool_test.dart \
  test/native_runtime_smoke_contract_test.dart
git commit -m "fix(macos): verify nested pkg payload signatures"
git push origin feat/native-sdk-platform-split
```

Evidence (`verified locally`, 2026-07-17): 33 focused Flutter tests passed;
`sh -n example/native/macos-runtime/package_smoke_app.sh`, focused Dart format,
and `git diff --check` passed. The adversarial review confirmed a unique temp
expansion root, a fixed non-symlink `component.pkg` payload node, checked command
failures, strict app/helper verification, and payload verification before PKG
notarization. No unresolved privilege, traversal, or notarization-order finding
remains in this slice.

### Task 2: Build and Audit a Fresh Current-Head Artifact

**Files:**

- Create: `tool/macos_pkg_artifact_audit.dart`
- Create: `test/macos_pkg_artifact_audit_test.dart`
- Produce: `reports/macos-privileged-updater/artifact-trust.json`

**Interfaces:**

- Consumes: source app, final PKG, expected Team ID/version/build/bundle/receipt, notary submission ID, and git commit.
- Produces: sanitized schema-1 JSON with hashes, identifiers, booleans, and literal status; no paths or credential data.

- [x] **Step 1: Write the RED audit contract**

Require options `--source-app`, `--pkg`, `--expected-team-id`, `--expected-version`, `--expected-build`, `--expected-bundle-id`, `--expected-receipt-id`, `--git-commit`, `--notarization-submission-id`, and `--evidence`.

Require strict app/helper checks, `pkgutil --expand-full`, `pkgutil --check-signature`, both `spctl` assessments, and both staple validations. Reject absolute paths, identity display names, keychain paths, notary profile names, environment dumps, and raw command output in evidence.

```sh
flutter test --no-pub test/macos_pkg_artifact_audit_test.dart
```

Expected: FAIL because the tool does not exist.

Evidence (`verified locally`, 2026-07-19): the first focused RED run failed
because `tool/macos_pkg_artifact_audit.dart` did not exist. After the CLI/schema
surface was introduced, a second behavioral RED run failed because the executor
returned `audit-not-implemented` instead of verified evidence and did not
classify an injected payload-helper signature failure.

- [x] **Step 2: Implement fail-closed evidence**

Write this shape only after every check passes:

```json
{
  "schemaVersion": 1,
  "status": "verified locally",
  "gitCommit": "<40 lowercase hex>",
  "artifactSHA256": "<64 lowercase hex>",
  "bundleIdentifier": "net.monolib.updater",
  "receiptIdentifier": "net.monolib.updater.pkg",
  "version": "2.7.1",
  "build": "271",
  "teamIdentifier": "UPK4SC93AN",
  "sourceAppSignatureValid": true,
  "payloadAppSignatureValid": true,
  "payloadHelperSignatureValid": true,
  "packageSignatureValid": true,
  "appStapleValid": true,
  "packageStapleValid": true,
  "gatekeeperExecuteAccepted": true,
  "gatekeeperInstallAccepted": true,
  "notarizationSubmissionId": "<UUID>"
}
```

On failure, write `candidate-only` plus a stable failure class, never stderr.

Evidence (`verified locally`, 2026-07-19): 4 focused tests passed. The audit
validates source and expanded-payload app/main/helper signatures independently,
requires matching Team ID and hardened runtime, binds the fixed component
receipt/version, checks the package signer, app/PKG staples, and execute/install
Gatekeeper assessments, and writes only the exact sanitized success or failure
schema. An injected helper failure containing an identity display name and
private-looking Keychain path produced only
`payload-helper-signature-invalid`.

- [x] **Step 3: Validate Keychain and build fresh v1/v2 artifacts**

Run:

```sh
dart run tool/macos_production_smoke.dart doctor
```

Expected: Application identity, Installer identity, and notary profile report `OK`. Do not copy identity listings/notary history into reports.

Build from exact `git rev-parse HEAD` with:

```text
version/build: 2.7.0+270 and 2.7.1+271
package ID: net.monolib.updater
receipt ID: net.monolib.updater.pkg
allowed install root: /Applications
```

Pass existing identity/profile environment values by reference. Never reuse the pre-`ccfbe52` fixture.

Evidence (`verified locally`, 2026-07-19): the sanitized production doctor
confirmed the existing Developer ID Application identity, Developer ID Installer
identity, and notary profile. Fresh smoke-owned `2.7.0+270` and `2.7.1+271`
source apps and PKGs were built from exact implementation commit
`53f01cc2a60872a878b22b253dd3544f9430a456`, package ID
`net.monolib.updater`, receipt ID `net.monolib.updater.pkg`, and allowed root
`/Applications`. Accepted submissions were
`dede09ff-9c33-4290-99fa-dd0d05684dff` and
`1081ff38-00ad-47fd-b4be-ef5122305863` for v1, and
`6fc6647f-68ed-4756-ad10-2aadb45ad628` and
`5559ae5f-09bc-4da2-999a-e9f8542729e9` for v2. No prior fixture was reused.

- [x] **Step 4: Notarize, staple, audit, commit reusable code**

Run the audit only after source app and PKG are notarized/stapled. Require source, expanded payload, and independent helper checks to pass.

```sh
flutter test --no-pub test/macos_pkg_artifact_audit_test.dart
git diff --check
git add tool/macos_pkg_artifact_audit.dart test/macos_pkg_artifact_audit_test.dart
git commit -m "test(macos): audit signed pkg payload integrity"
git push origin feat/native-sdk-platform-split
```

Do not commit evidence until Tasks 3 and 4 bind to the same commit/artifact hash.

Evidence (`verified locally`, 2026-07-19): the v2 source app and final PKG were
notarized and stapled, and the system trust-context audit passed with artifact
SHA-256 `22debe73bf7381ce34a2bf3e3c29ba5c133f4775850d607c6d8b0a5a7b865143`.
The sanitized `artifact-trust.json` reports `verified locally`, binds commit
`53f01cc2a60872a878b22b253dd3544f9430a456`, contains no raw path, credential,
environment, command, stdout, or stderr field, and matches the independently
computed PKG hash. A sandbox-only `codesign` false negative was isolated by
running the identical six app/main/helper checks in both contexts; all six
passed in the required system trust context. A real PackageInfo XML-declaration
parser defect was then reproduced RED and fixed GREEN by scoping attributes to
the root `<pkg-info>` tag. The final focused suite passed 6 tests, focused format
and `git diff --check` passed, and the privilege/signing review found no
alternate component traversal, followed top-level symlink, caller-controlled
executable, ignored exit code, or raw failure-output evidence path.

### Task 3: Prove Typed Approval and Real Privileged Installation

**Files:**

- Create: `tool/macos_privileged_pkg_smoke.dart`
- Create: `test/macos_privileged_pkg_smoke_contract_test.dart`
- Modify: `example/native/macos-runtime/Sources/MacOSRuntimeCompile/main.swift`
- Test: `test/native_runtime_api_contract_test.dart`
- Test: `test/macos_privileged_helper_approval_test.dart`
- Test: `test/update_ready_ui_test.dart`
- Test: `test/update_dialog_listener_test.dart`
- Produce: `reports/macos-privileged-updater/approval.json`
- Produce: `reports/macos-privileged-updater/elevation.json`

**Interfaces:**

- Consumes: Task 2 v1 app/v2 PKG and existing typed runtime error.
- Produces: typed approval evidence and verified `2.7.0+270` to `2.7.1+271` SMAppService/XPC installation.

- [x] **Step 1: Write RED typed smoke contracts**

Require this event without message matching:

```json
{
  "event": "installFailed",
  "code": "PrivilegedHelperApprovalRequired",
  "remediationActions": ["openMacOSBackgroundItemsSettings"]
}
```

Require stock card/dialog permission copy and preserve structured data for custom clients.

```sh
flutter test --no-pub \
  test/native_runtime_api_contract_test.dart \
  test/macos_privileged_helper_approval_test.dart \
  test/update_ready_ui_test.dart \
  test/update_dialog_listener_test.dart \
  test/macos_privileged_pkg_smoke_contract_test.dart
```

Expected: new smoke contract FAILS; existing SDK/UI tests stay green.

Evidence (`verified locally`, 2026-07-19): the first 44-test focused run
reported exactly the two intended RED failures: the Swift smoke executable did
not emit the typed diagnostic JSON and
`tool/macos_privileged_pkg_smoke.dart` did not exist. The existing typed SDK,
custom-client diagnostic, stock card, and dialog permission behavior remained
green. A follow-up bootstrap-integrity RED failed until the smoke adapter
accepted explicit current version/build inputs, preventing a test descriptor
from misrepresenting the physical v1 PKG version.

- [x] **Step 2: Emit typed JSON from the smoke adapter**

Use existing typed values:

```swift
if let runtimeError = error as? RuntimeError,
   let diagnostic = runtimeError.failureDiagnostic,
   diagnostic.code == .privilegedHelperApprovalRequired {
    emit([
        "event": "installFailed",
        "code": diagnostic.code.rawValue,
        "remediationActions": diagnostic.remediationActions.map(\.rawValue),
    ])
}
```

Keep it inside the smoke executable; add no second public API.

Evidence (`verified locally`, 2026-07-19): the private Swift smoke adapter now
serializes the existing typed diagnostic code and remediation values with
`JSONSerialization`; it retains the existing human-readable line and adds no
public SDK API. The fail-closed target-host tool fixes the target path, bundle,
receipt, owner marker, Team ID, v1/v2 versions, schema-v3 PKG authority, and
evidence schema. It performs no direct installer execution and exposes settings
only behind explicit `--open-settings`. The semantic bootstrap first refreshes
the exact current v2 package, then uses explicit smoke-only current-version
inputs to install the physical `2.7.0+270` package with matching descriptor
metadata. The Swift executable built successfully; 44 focused Flutter tests,
20 root-harness `UpdateClientTests`, and targeted Dart analysis passed. The
plan's nested `macos/desktop_updater` SwiftPM command remains unavailable
outside a generated Flutter host because `FlutterMacOS` is not exposed by that
generated package; the root package runs the same `DesktopUpdaterKit` sources
and tests and passed 20/20.

- [ ] **Step 3: Install verified v1 safely and exercise approval**

Before replacement require:

```text
path=/Applications/Desktop Updater SMAppService PKG E2E.app
bundleIdentifier=net.monolib.updater
ownerMarker=desktop_updater macOS production smoke
receiptIdentifier=net.monolib.updater.pkg
```

Reject any mismatch. Verify v1 app/helper signatures, Team ID, runtime flag, staple, Gatekeeper, LaunchDaemon metadata, and `root:wheel`.

Run the update once. If status is `requiresApproval`, write typed `approval.json` and pause with:

```text
System Settings > General > Login Items & Extensions > Allow in the Background:
enable the Desktop Updater smoke helper, then return to continue.
```

The tool opens settings only with explicit `--open-settings`; it never toggles approval.

Interim evidence (`candidate-only`, 2026-07-19): the first real target-host
bootstrap failed closed before mutation because an on-demand registered daemon
had no active PID; the precondition now requires an active PID only for the
terminal v2 gate. A second candidate run installed the fresh `2.7.1+271`
payload but exposed a validated P1: the root-protected provider stage was
removed while the exact client-owned source stage remained after completion.
The focused RED transaction run failed 9 of 16 tests at completed and verified
rollback cleanup boundaries. The GREEN implementation journals the exact
source stage name, parent path, parent identity, and stage identity; removes
only that direct child after `completed` or verified rollback; retains both
stages for `manualActionRequired` and while the exact manager PID/start identity
is live; rejects tampered source-stage authority; and continues parsing legacy
journal schema 1 without claiming source cleanup authority. The widened focused
set passed 18/18. The bootstrap tool additionally permits exactly one
provenance-, package-ID-, and artifact-hash-bound cleanup after the old helper
has installed and the tool has independently verified the fresh v2 target;
the final v1-to-v2 acceptance path cannot call this transition-only fallback.
Its focused contract test was RED before the implementation and GREEN after
it. This candidate run is not Task 3 acceptance evidence; a new artifact from
the P1-fix commit is still required. Commit-gate widening passed the complete
install-helper package at 136 tests with 1 intentional crash-harness skip,
root-harness `UpdateClientTests` at 20/20, the approval/UI/smoke Flutter set at
45/45, the macOS runtime Swift build, targeted Dart analysis and formatting,
and `git diff --check`. Adversarial review confirmed that schema 2 accepts only
the exact new identity fields, schema 1 remains read-only with respect to the
source stage, deletion is an identity-bound direct-child `removefileat`,
manual-action state retains both stages, and recovery cannot reach cleanup
while the exact manager PID/start identity remains live.

Follow-up bootstrap evidence (`candidate-only`, 2026-07-19): Apple Installer's
bundle-version downgrade gate accepted the v1 receipt but intentionally left
the exact fresh v2 app in place. Post-install verification failed closed,
entered `manualActionRequired`, and retained the stage as required. The
scripts-free, signed/notarized baseline-only v1 package disables bundle version
checking for this controlled smoke downgrade, but the next attempt stopped
before mutation because the smoke precondition did not recognize the known
`(v2 app, v1 receipt)` recovery pair. A focused RED contract now confines that
pair to the initial bootstrap inspection; all approval, final install, and
terminal inspections continue requiring app and receipt versions to match.
The focused contract was RED before implementation and GREEN at 4/4; the
widened approval/UI/smoke set passed 46/46, targeted analysis and formatting
passed, and `git diff --check` passed. Adversarial review confirmed that the
exception does not bypass path, bundle, marker, Team ID, signature, Gatekeeper,
or staple checks and appears at exactly one call site before the exact v1/v2
payload identity comparisons.

Second follow-up evidence (`candidate-only`, 2026-07-19): the approved
baseline-only install reached the runtime handoff but the exact target lock
from the earlier post-installer `manualActionRequired` transaction correctly
rejected a concurrent reservation. No provider journal or lock was deleted
out-of-band. A private signed-smoke-app adapter now invokes only the existing
authenticated XPC `recoverPendingInstall` operation for the single exact
provider-journal UUID discovered under `/Applications`; its typed output
contains only event/state/result code and never the transaction ID. Bootstrap
requires the first recovery to report `manualActionRequired/recoveryRequired`
and release the target lock, then after the verified v1 target requires the
same journal to report `completed/succeeded` and disappear. The two focused
contracts were RED before implementation and GREEN in the 14-test combined
set; targeted analysis/formatting, the Swift runtime build, 47 widened
approval/UI/smoke tests, 20 `UpdateClientTests`, and `git diff --check` passed.

Current-head continuation evidence (`blocked`, 2026-07-19): exact implementation
commit `251a3c12b5dba50f59fff70bd1af7682a2861599` produced a fresh signed,
notarized, and stapled v1 source app and PKG. Their accepted submissions were
`bdbd9948-c92c-4f5e-8b82-6b71573ffec8` and
`6f6c934d-bdb3-40ae-88fe-b8d0db71d332`. The execution environment then denied
the external notarization submission required for the matching v2 artifact, so
no exact-commit v2 submission ID or installable v2 acceptance artifact exists.
The authenticated recovery operation released the retained transaction's exact
target lock while preserving its provider journal, but the login Keychain later
became unavailable and independent app/helper/PKG verification failed closed.
No artifact was handed to the installer after that trust failure. Task 3 remains
unaccepted; the target is still the known v2-app/v1-receipt recovery pair and no
production claim is made from this candidate state.

- [ ] **Step 4: Complete v2 elevation and verify terminal state**

Use `artifactKind=pkgInstaller`, `launchMode=privilegedInstallerTool`, and `minimumUpdaterVersion=2.7.0`. Require:

```text
version/build=2.7.1+271
receipt version=2.7.1
app/helper/LaunchDaemon owner=root:wheel
app Team ID=helper Team ID=UPK4SC93AN
app/helper strict signature=pass
app Gatekeeper/staple=pass
LaunchDaemon active PID=nonzero
owned client stage empty after completed
```

- [ ] **Step 5: Verify, review, commit, and push**

```sh
swift test --package-path macos/desktop_updater --filter UpdateClientTests
flutter test --no-pub \
  test/native_runtime_api_contract_test.dart \
  test/macos_privileged_helper_approval_test.dart \
  test/update_ready_ui_test.dart \
  test/update_dialog_listener_test.dart \
  test/macos_privileged_pkg_smoke_contract_test.dart
git diff --check
```

Review message matching, auto-approval, broad cleanup, alternate executables, caller-controlled installer args, premature success, and success-stage retention.

```sh
git add tool/macos_privileged_pkg_smoke.dart \
  test/macos_privileged_pkg_smoke_contract_test.dart \
  example/native/macos-runtime/Sources/MacOSRuntimeCompile/main.swift \
  test/native_runtime_api_contract_test.dart
git commit -m "test(macos): prove privileged pkg target install"
git push origin feat/native-sdk-platform-split
```

### Task 4: Prove Installer-Active Crash Recovery

**Files:**

- Create: `example/native/macos-runtime/pkg-scripts/recovery/preinstall`
- Modify: `example/native/macos-runtime/package_smoke_app.sh`
- Create: `tool/macos_privileged_pkg_recovery_smoke.dart`
- Create: `test/macos_privileged_pkg_recovery_smoke_contract_test.dart`
- Test: `macos/install_helper/Tests/DesktopUpdaterInstallHelperTests/MacVerifiedInstallerTransactionTests.swift`
- Test: `macos/install_helper/Tests/DesktopUpdaterInstallHelperTests/MacInstallerWorkerTests.swift`
- Produce: `reports/macos-privileged-updater/recovery.json`

**Interfaces:**

- Consumes: fixed gated worker and durable manager PID/start identity.
- Produces: proof that a fresh daemon does not race/clean a live installer and converges to `completed`.

- [x] **Step 1: Re-run the unit fault matrix cleanly**

```sh
rm -rf /private/tmp/desktop-updater-macos-helper-build
swift test --package-path macos/install_helper \
  --scratch-path /private/tmp/desktop-updater-macos-helper-build \
  --filter MacVerifiedInstallerTransactionTests
swift test --package-path macos/install_helper \
  --scratch-path /private/tmp/desktop-updater-macos-helper-build \
  --filter MacInstallerWorkerTests
```

Expected: all boundary, identity, cleanup, and idempotence tests PASS.

Evidence (`verified locally`, 2026-07-19): after removing only the plan-owned
scratch build directory, `MacVerifiedInstallerTransactionTests` passed 18/18
and `MacInstallerWorkerTests` passed 4/4 with zero failures. The matrix covers
exact manager PID/start-identity liveness, timeout retention, no relaunch after
manager start, completed/rollback cleanup idempotence, source-stage authority,
protected-copy immutability, root-only execution, and rejection of any package
path other than the protected `installer.pkg`.

- [x] **Step 2: Write RED fixed-gate/harness contracts**

The smoke-only `preinstall` is fixed:

```sh
#!/bin/sh
set -eu
ready=/private/var/tmp/net.monolib.updater.pkg-recovery.ready
release=/private/var/tmp/net.monolib.updater.pkg-recovery.release
trap '/bin/rm -f "$ready" "$release"' EXIT HUP INT TERM
/bin/rm -f "$ready" "$release"
/usr/bin/printf '%s\\n' "$PPID" > "$ready"
while [ ! -f "$release" ]; do /bin/sleep 0.1; done
```

Require `pkgbuild --scripts` to use only this repository directory when `DESKTOP_UPDATER_RUNTIME_PKG_RECOVERY_SMOKE=1`.

Require the Dart harness to assert `managerStarted`, record the unique live `/usr/sbin/installer` PID/start identity, kill only the launchd helper PID, prove recovery remains nonterminal and stage-retaining while the manager is live, release the gate, then prove `completed`.

```sh
flutter test --no-pub test/macos_privileged_pkg_recovery_smoke_contract_test.dart
```

Expected: FAIL because fixture/harness do not exist.

Evidence (`verified locally`, 2026-07-19): after correcting a test-only string
escape that was not counted as RED, the valid focused RED run passed 1 test and
failed the intended 4 contracts because the fixed preinstall, recovery-only
packager branch, typed query adapter, and harness did not exist. The minimal
GREEN implementation passed all 6 focused tests, including a real
`proc_pidinfo` identity-shape/stability test. The widened runtime/PKG/recovery
contract set passed 20/20, targeted Dart analysis reported no issues, both shell
files passed `sh -n`, the preinstall is executable, and the Swift runtime adapter
built successfully. The packager can enable only the one fixed repository
preinstall for the exact v2 smoke identity. The harness binds the exact current
HEAD and artifact hash, observes only the fixed `/usr/sbin/installer` argv,
compares the same microsecond-resolution process start identity used by the
helper, revalidates launchd service PID/executable/start identity immediately
before SIGKILL, retains the identity-bound source stage while that manager is
live, and excludes PID, start identity, command line, stage path, and helper log
from evidence. The real sequence remains `not run` because no exact-current-HEAD
v2 notarized artifact exists and the login Keychain trust context is unavailable.

Final-review follow-up evidence (`verified locally`, 2026-07-19): exhaustive
service-identity review found a validated P1 in the recovery harness: it bound
launchd inspection to `net.monolib.updater.installer` while the fixed packager,
sealed policy, signed helper, and installed smoke target use
`net.monolib.updater.helper`. A focused RED run passed 6 contracts and failed
the new packaged-service assertion; the minimal GREEN fix changed only the
fixed service identifier. The widened recovery/runtime/install contract set
passed 21/21, targeted analysis reported no issues, focused format changed no
files, and `git diff --check` passed. Adversarial review confirmed that the
identifier now matches the packager default and installed app metadata and is
used only to bind launchd PID/executable/start-identity checks; it adds no
caller-controlled service or executable authority.

- [ ] **Step 3: Implement and run the real sequence**

The fixed sequence:

1. Reinstall verified v1.
2. Build/notarize v2 recovery PKG with the fixed preinstall gate.
3. Start update and wait for the ready marker.
4. Query and require `managerStarted/recoveryRequired`.
5. Resolve exactly one installer PID/start identity and fixed argv.
6. Resolve `system/<service-id>`; SIGKILL only that helper PID.
7. Start recovery from a fresh process; assert it stays nonterminal and preserves stage while manager is live.
8. Create release marker; wait for installer exit.
9. Require `completed/newTarget`, version/build/receipt/signatures/ownership/LaunchDaemon, stage cleanup, and idempotent repeat query.
10. Remove only fixed markers and smoke-owned roots.

Run:

```sh
dart run tool/macos_privileged_pkg_recovery_smoke.dart \
  --app "/Applications/Desktop Updater SMAppService PKG E2E.app" \
  --pkg "$DESKTOP_UPDATER_RECOVERY_PKG" \
  --receipt-id net.monolib.updater.pkg \
  --expected-version 2.7.1 \
  --expected-build 271 \
  --evidence reports/macos-privileged-updater/recovery.json
```

Expected booleans: `managerObservedLive=true`, `stageRetainedWhileManagerLive=true`, `concurrentMutationObserved=false`, `finalState=completed`, `verifiedOutcome=newTarget`, `stageRemovedAfterCompletion=true`.

- [ ] **Step 4: Review, commit, and push**

Review PID reuse, weak start identity, stale gates, non-owned kills, cleanup while live, duplicate installer launch, shell interpolation, missing receipt verification, and premature evidence.

```sh
git add example/native/macos-runtime/pkg-scripts/recovery/preinstall \
  example/native/macos-runtime/package_smoke_app.sh \
  tool/macos_privileged_pkg_recovery_smoke.dart \
  test/macos_privileged_pkg_recovery_smoke_contract_test.dart
git commit -m "test(macos): prove installer-active pkg recovery"
git push origin feat/native-sdk-platform-split
```

### Task 5: Publish Sanitized Evidence and Truthful CI/Docs

**Files:**

- Modify: `.github/workflows/desktop-updater-ci.yml`
- Modify: `docs/macos-dmg-pkg-installer-updates.md`
- Modify: `docs/github-actions-ci-cd.md`
- Modify: `docs/harness-engineering.md`
- Modify: `docs/diagnostics-and-recovery.md`
- Modify: `docs/exec-plans/active/2026-07-11-cross-platform-privileged-install-helper-plan.md`
- Create: four JSON files under `reports/macos-privileged-updater/`
- Test: `test/native_runtime_smoke_contract_test.dart`
- Test: `test/macos_dmg_pkg_docs_test.dart`
- Test: `test/harness_engineering_docs_test.dart`

**Interfaces:**

- Consumes: Tasks 2-4 reports.
- Produces: one internally consistent evidence set bound to one commit/artifact hash, plus distinct hosted-approval and self-hosted success/recovery rows.

Current gate evidence (`blocked`, 2026-07-19): Tasks 3 and 4 did not produce
accepted exact-current install or recovery reports, so the four-report set
cannot truthfully share one current commit and artifact SHA-256. The existing
documentation already distinguishes hosted approval-required evidence from
self-hosted `/Applications` install and recovery evidence, but the self-hosted
workflow still uploads its earlier JSONL/text outputs rather than the required
four sanitized reports. The sole local `artifact-trust.json` is untracked,
binds older commit `96cc4ecbb009d5be5a50adcbeeedf8fae2dedfa4`, and is not
current-head publication evidence. No Task 5 report or CI success claim was
published.

- [ ] **Step 1: Write RED evidence/docs tests**

All reports share schema, commit, artifact hash, bundle/version/build/team, and literal status. Reject temp paths, credential names, env dumps, raw process command lines, or key material.

Docs must state:

```text
installerApp is a legacy wire token normalized to privilegedInstallerTool behavior.
Hosted approvalRequired evidence is not install-success evidence.
Only the self-hosted preapproved lane owns /Applications install and recovery evidence.
```

- [ ] **Step 2: Update self-hosted lane and ledgers**

After local success, call the audit/install/recovery tools from `macos-smappservice-helper`. Upload only four sanitized reports. On `completed`, require stage removal; on `manualActionRequired`, require stage retention and a non-production label.

Close only macOS ledger items; leave Windows/Linux and overall cross-platform gates open.

- [ ] **Step 3: Verify, commit, and push**

```sh
flutter test --no-pub \
  test/native_runtime_smoke_contract_test.dart \
  test/macos_dmg_pkg_docs_test.dart \
  test/harness_engineering_docs_test.dart \
  test/ci_failure_annotation_contract_test.dart
ruby -e 'require "yaml"; YAML.load_file(".github/workflows/desktop-updater-ci.yml")'
git diff --check
```

```sh
git add .github/workflows/desktop-updater-ci.yml \
  docs/macos-dmg-pkg-installer-updates.md \
  docs/github-actions-ci-cd.md \
  docs/harness-engineering.md \
  docs/diagnostics-and-recovery.md \
  docs/exec-plans/active/2026-07-11-cross-platform-privileged-install-helper-plan.md \
  reports/macos-privileged-updater \
  test/native_runtime_smoke_contract_test.dart \
  test/macos_dmg_pkg_docs_test.dart \
  test/harness_engineering_docs_test.dart
git commit -m "docs(macos): record privileged updater evidence"
git push origin feat/native-sdk-platform-split
```

### Task 6: Run the Final macOS GO/NO-GO Gate

**Files:**

- Modify: this plan
- Modify only for validated P0/P1 fixes: files named by the finding

**Interfaces:**

- Consumes: all fresh current-head code, tests, artifacts, and evidence.
- Produces: macOS-only GO/NO-GO without changing Windows/Linux readiness.

- [x] **Step 1: Run the full validation ladder**

```sh
dart run tool/generate_native_contract_fixtures.dart
dart run tool/generate_native_install_helper_fixtures.dart
dart run tool/generate_native_install_helper_fixtures.dart --check
dart format --set-exit-if-changed .
flutter analyze --no-fatal-infos
flutter test --no-pub
dart pub publish --dry-run
swift test --package-path macos/install_helper
swift test --package-path macos/desktop_updater
swift test
git diff --check
```

Expected: PASS. The package-local Swift command may be `blocked` only for the documented missing generated Flutter host when exact source-set typecheck and real Flutter Release build pass.

Evidence (`verified locally`, 2026-07-19, exact HEAD
`ce6d318ad34d8640d9392b0626ea2848b3b2e2a7`): both fixture generators ran and
the install-helper fixture check was current; Dart format inspected 236 files
with zero changes; `flutter analyze --no-fatal-infos` exited zero with 483
existing info diagnostics and no error/warning gate; the complete Flutter suite
passed 788 tests with 3 conditional E2E skips; and `dart pub publish --dry-run`
reported 0 warnings and 1 version-history hint. The install-helper Swift package
passed 136 tests with 1 intentional crash-worker skip, and root SwiftPM passed
97 tests. Package-local `macos/desktop_updater` remained `blocked` only by the
documented absent generated `FlutterMacOS` host module; the exact six-source
macOS 10.14 typecheck exited zero and a real Flutter macOS Release application
built successfully. `git diff --check` exited zero and the pushed branch and
local HEAD matched.

- [ ] **Step 2: Apply required completion skills**

Use `build-macos-apps:signing-entitlements` and `build-macos-apps:packaging-notarization` against the actual source app, expanded payload app, installed app, helpers, and PKG. Then use `superpowers:verification-before-completion` against fresh output only.

Evidence (`blocked`, 2026-07-19): the signing/entitlements and
packaging/notarization reviews were applied fail-closed, followed by fresh
verification-before-completion checks. There is no signed/notarized/stapled v2
artifact from exact HEAD `ce6d318`; the last exact-implementation v1 artifact
belongs to older commit `251a3c12b5dba50f59fff70bd1af7682a2861599`, and
its matching v2 submission was denied by the execution environment. The login
Keychain currently reports zero valid code-signing identities. The installed
smoke target reports bundle `net.monolib.updater`, `2.7.1+271`, Team ID
`UPK4SC93AN`, hardened-runtime metadata, and root:wheel ownership for app,
main executable, helper, and LaunchDaemon, but receipt
`net.monolib.updater.pkg` remains `2.7.0`; fresh app/main/helper signature,
staple, and Gatekeeper checks fail closed; and the LaunchDaemon is not loaded.
Consequently source/payload/PKG/installed trust cannot be accepted for current
HEAD and this step remains open.

- [x] **Step 3: Run fresh exhaustive adversarial review**

Use `killcritic-complete-review` over:

1. nested signing/notarization/stapling/Gatekeeper/component shape;
2. SMAppService approval, XPC authentication, fixed installer authority;
3. durable gate/PID/start identity and installer-active concurrency;
4. receipt/version/build/bundle/helper/LaunchDaemon/root ownership;
5. cleanup/retention, evidence sanitization, CI truth, compatibility tokens.

Resolve each validated P0/P1 with RED/GREEN regression coverage and a separate commit.

Evidence (`verified locally`, 2026-07-19): `killcritic-complete-review` scanned
962 repository files and the active plan, then each required macOS boundary was
reviewed directly in source, tests, workflow, documentation, target state, and
fresh command output. Nested source/payload/PKG trust is `blocked`; typed
approval and real elevation are `not run` for current HEAD; SMAppService/XPC
authentication, fixed `/usr/sbin/installer` argv authority, durable manager
PID/start identity, and cleanup/retention are `verified locally` in focused and
full unit/contract coverage; installer-active target-host recovery is `not
run`; installed receipt/trust/daemon state is `candidate-only`; and the
four-report/CI publication gate is `blocked`. Schema v3, legacy `installerApp`
parsing, `privilegedInstallerTool` publication, minimum updater 2.7.0, typed
approval code/remediation, and stock/custom UI contracts remain `verified
locally`. One validated P1 service-identity mismatch was resolved in separate
RED/GREEN commit `ce6d318ad34d8640d9392b0626ea2848b3b2e2a7`; no validated
P0/P1 remains in the reviewed implementation. Missing production evidence is a
gate blocker, not a downgraded code finding.

- [x] **Step 4: Issue verdict and close**

macOS is `production-ready` only when current-head source/payload/installed signatures, notarization/stapling/Gatekeeper, typed approval, real v1-to-v2 elevation, receipt/ownership/helper/LaunchDaemon, installer-active recovery, stage cleanup, full validation, and evidence consistency all pass with no P0/P1.

If any gate fails or is not run, record `candidate-only / NO-GO` and leave this plan active.

Final macOS verdict (`candidate-only / NO-GO`, 2026-07-19): exact-current v2
artifact trust/notarization is `blocked`; typed target-host approval and real
2.7.0+270 to 2.7.1+271 elevation are `not run`; installer-active daemon crash
recovery is `not run`; and four-report evidence/CI publication is `blocked`.
The last candidate recovery released the exact target lock without deleting the
single retained provider journal; no accepted real crash point, terminal
`completed/newTarget` result, or completed-stage cleanup exists. The plan stays
active. Windows and Linux readiness were not changed.

- [x] **Step 5: Commit and push final status**

```sh
git add docs/exec-plans/active/2026-07-17-macos-privileged-updater-production-closure-plan.md
git commit -m "docs(macos): close privileged updater production gate"
git push origin feat/native-sdk-platform-split
```

## Completion Boundary

This plan closes only the macOS privileged updater. Windows target-host/Authenticode/UAC and installed Linux polkit/root-broker gates retain their current literal status.
