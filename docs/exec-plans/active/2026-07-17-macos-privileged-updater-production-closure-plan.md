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

Current exact-head rerun (`verified locally`, 2026-07-19): system-context
Keychain checks found the existing Developer ID Application and Installer
identities after sandbox-only queries had reported a false zero. Fresh v1 and
v2 source apps were built and signed from exact HEAD
`464cef9b5d0e5f156cb1aaf597ac472bba1d2ed8`. The source apps were notarized
before packaging so the final PKG payloads retain their app tickets. Accepted
v1 app and final-PKG submissions were
`9ac5a23d-12f5-4c31-b5ce-0b763c347766` and
`6072afd4-dbbf-4a06-893a-afb5b92c80f7`; accepted v2 app and final-PKG
submissions were `3ea288d3-586a-4291-b207-f0aa644a7955` and
`78ee7ea0-6530-4391-81e3-d3d8e5cce686`. No earlier artifact was reused.

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

Current exact-head audit (`verified locally`, 2026-07-19): the stapled final
v1 PKG SHA-256 is
`f3b97cf91c6f56f6578a7df9594b3100915973d5e86338690ae2dc6b17767331`.
The stapled final v2 recovery PKG SHA-256 is
`26c8c7dd191677962d5ae6f427d8e9786a821e2e558aefe1e6c77eb943de049f`.
System-context checks independently passed the source app, source main
executable, source helper, expanded final-PKG app, expanded main executable,
expanded helper, PKG signature, app and PKG staples, execute and install
Gatekeeper assessments, Team ID, hardened runtime, bundle/version/build, fixed
receipt metadata, and the single fixed recovery preinstall shape. A temporary
sanitized artifact-trust document reports `verified locally` and binds the v2
hash, exact HEAD, and final v2 PKG submission. It remains outside the repository
until Tasks 3 and 4 can truthfully bind the complete four-report set.

Final implementation-head refresh (`verified locally`, 2026-07-20): exact
HEAD `9e4bd55ca4257eded5a772f34e04d2b2cff7a57a` produced fresh signed,
notarized, stapled, and Gatekeeper-approved v1 and v2 source apps and final
PKGs. The v1 app/PKG submissions were
`28e02b13-b1f1-46dd-8233-ba53501be42f` and
`278da9df-f78b-44c8-9198-a93e691a95e8`, and its final PKG SHA-256 was
`d8677422a56729228581ecb457c0f133c390cb576c342704097bef0955ba53da`.
The v2 app/PKG submissions were
`5fb2eec5-d2e8-4c21-9109-716ba91ba259` and
`d6709b3c-3b40-4b7c-9aca-6c141e5945d4`, and its final PKG SHA-256 was
`936b2bda3cfe2384b8f4225f8a506035fa443dba86a151506b564defae09faaf`.
Both independent audits passed every source and extracted app/main/helper,
Team ID, hardened runtime, package signature, staple, Gatekeeper, fixed receipt,
version, build, and payload-shape check. The sanitized repository trust report
binds only the v2 implementation commit, final package hash, and final package
submission ID; it contains no identity name, credential/profile data, path,
environment, command, stdout, or stderr field.

Final current-implementation refresh (`verified locally`, 2026-07-20): exact
HEAD `ac2d2dcdb737325a5751adc7a05150ffaa56c315` produced fresh signed v1
and v2 source applications. Their app notarization submissions
`bf83219b-16f9-4167-bf3a-2e91dfdc301d` and
`1c9d3abe-f975-4ff9-a64b-ff1b98866d3e` were accepted and stapled before
packaging. The final BOM-correct v1 and v2 packages were separately submitted
as `bfaf3fdf-e023-4c19-8871-e06e0d9f7dfe` and
`2ccf4099-60d8-407b-966b-55c9861e07a7`, accepted, and stapled; their final
SHA-256 values are
`7f87ff35982b22260b77e6ea325539cdc5172072279784e20c0a0579c17e4dfb`
and
`d771a55d469e030b895da3d7e8f5459c5974c6c19041a81880b101903e4de817`.
Fresh independent audits passed each source and expanded-payload application,
main executable, helper, Team ID, hardened runtime, package signature, app and
package staple, Gatekeeper execute/install assessment, fixed receipt metadata,
version/build, and payload shape. The sanitized v2 trust report binds only the
exact implementation commit, final v2 hash, and final v2 package submission;
the prior same-name packages with stale BOM inventories were rejected from
acceptance evidence. The focused artifact-audit suite passed 6/6,
`git diff --check` passed, and an explicit post-staple comparison confirmed
that each final component BOM covers every non-directory payload node. The
adversarial trust review found no extra component, unbound payload node,
unsigned nested executable, raw trust output, credential value, or stale
submission/hash accepted by this evidence boundary.

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

- [x] **Step 3: Install verified v1 safely and exercise approval**

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

Exact-head target continuation (`blocked`, 2026-07-19): system-context checks
now validate the smoke-owned installed app, main executable, helper, staple,
Gatekeeper assessment, Team ID, hardened runtime, root:wheel ownership, and
active LaunchDaemon. The target remains `2.7.1+271` with receipt `2.7.0`. The
single retained provider journal reports typed
`manualActionRequired/recoveryRequired`; its exact target lock is absent and no
installer manager process remains. Registering the current signed helper made
typed query/recovery available, but both the trusted installed host and current
signed source host correctly rejected a new transaction with
`installRecoveryRequired`. The source host also fails closed because its bundle
is outside the sealed `/Applications` target root. No provider journal, target,
receipt, or retained stage was removed or mutated out-of-band. The documented
no-relaunch-after-manager-start recovery rule cannot safely recreate the old
installer manager, and a verified new v1 target is unavailable. Therefore the
real v1 baseline, typed approval, and v1-to-v2 elevation remain `not run`.

Caller-exit continuation (`candidate-only`, 2026-07-19): after removing only
the previously authorized smoke-owned retained transaction state, the trusted
installed host completed a normal exit after the helper accepted a fresh v1
commit. The provider journal remained `commitAccepted`, no installer manager
or `/usr/sbin/installer` process appeared, and the exact lock and owned stages
were retained until the 300-second reservation expiry triggered verified
rollback cleanup. This reproduced the same missing manager transition without
the smoke executable's separate uncaught-error crash path and validated a P1:
the system caller-exit monitor trusted only a PID and had no exact start-identity
fallback when the real XPC `NOTE_EXIT` notification was missed. The focused RED
failed because the monitor API did not accept a process-start identity. The
minimal GREEN binds the already authenticated caller PID to its exact
microsecond start identity, polls that identity while retaining the kqueue
exit notification, treats PID reuse as exit only after an exact identity
change, and continues fail-closed to reservation expiry when identity cannot be
inspected. `MacOneShotWireTests` passed 6/6 and the complete install-helper
package executed 137 tests with zero failures and one intentional crash-worker
skip. Real target-host GREEN remains `not run` until fresh signed, notarized,
and stapled v1/v2 artifacts contain this helper fix, so Task 3 remains open.

Baseline-component continuation (`verified locally`, 2026-07-19): independent
expansion of the previous v1 final PKG confirmed that it still emitted normal
`bundle-version` authority. This matches the real target result in which Apple
Installer downgraded the receipt to `2.7.0` but left the newer v2 application
in place, and invalidated the earlier candidate statement that the baseline
package disabled version checks. A focused RED failed because the packager had
no baseline-only authority. An adversarial follow-up RED also rejected the
unbound output bundle basename. The minimal GREEN adds a default-off flag
confined to the exact smoke package, receipt, app name and `.app` basename,
`2.7.0+270`, and `/Applications`; rejects any combination with the
recovery-script flag; requires the
`pkgbuild --analyze` result to contain exactly the fixed app bundle; and sets
only `BundleIsVersionChecked=false`, `BundleIsRelocatable=false`, strict
identifier, and atomic `upgrade` replacement before
`pkgbuild --component-plist`. The
baseline path remains scripts-free and normal/recovery package behavior is
unchanged. The focused contract passed 6/6; the widened install, recovery,
runtime, and production packager set passed 39/39; focused format changed no
files; and shell syntax plus `git diff --check` passed. Fresh
signed/notarized target-host proof remains required.

Final-Distribution continuation (`candidate-only`, 2026-07-19): the first
fresh app and PKG submissions from commit
`22750d26a9c8021d8baadf738122a9b498a27895` were accepted, but independent
final-PKG expansion found that `productbuild`
reintroduced the exact v1 `bundle-version` node even after the component plist
disabled it. Those artifacts are rejected as acceptance inputs. A third
focused RED required an exact outer-product expansion, Distribution patch,
flatten, and final `productsign` boundary. The GREEN path accepts only the two
tool-generated outer nodes and the scripts-free three-node component shape,
validates the single reintroduced version rule against the fixed receipt,
bundle, version, build, and path before removing it, flattens and signs the
outer archive with a trusted timestamp, and then independently requires the
final expanded Distribution to contain no version rule while PackageInfo keeps
an empty version gate and the exact atomic-upgrade identifier. A real signed
local package traversed every new shape, payload-signature, Distribution, and
package-signature gate; its final Gatekeeper assessment rejected only because
that diagnostic artifact was intentionally not notarized. Fresh notarized
artifacts from the eventual fix commit remain required. The focused contract
passed 6/6 and the widened install/recovery/runtime/packager set passed 39/39;
focused format, shell syntax, and `git diff --check` passed.

SMAppService activation continuation (`candidate-only`, 2026-07-19): exact
HEAD `2de155e0871b6f7ca3a370bb65c2d1f4179c527a` produced new accepted,
stapled v1 and v2 apps and final PKGs. The final PKG submission IDs were
`ac758784-41d5-469b-99f3-57244468792b` and
`d96f99e4-bfef-4e52-bf75-97b5ddad6d97`; their SHA-256 values were
`c0d19ec5ee8e832fa90093aff86018fb431fe04e4acc8b761f085c90d4fcaeb8`
and
`2580c37b4ce1cfecc80857c0391e9dbd620fc356b909cf7f29f4d616e0f274a5`.
Both independent artifact audits passed source/payload app and helper signing,
hardened runtime, package signing, app/PKG staples, and Gatekeeper
execute/install assessment. The scripts-free v1 final Distribution contained
no bundle-version gate, and the v2 package contained only the byte-identical
fixed recovery preinstall script. These artifacts then reproduced a new P1 at
the target-host bootstrap boundary: SMAppService unregister/register was
accepted as `enabled, allowed`, but the client performed only one immediate XPC
health check before launchd had activated the new job and failed closed with
`endpointUnavailable`. The focused RED required an injectable activation
retry boundary. The minimal GREEN retries only `endpointUnavailable` after the
same fixed registration, remains bounded to 30 authenticated health checks at
100 ms intervals, validates the exact signed helper endpoint identity on every
successful response, and never retries an invalid response or identity
mismatch. The three adversarial activation tests passed 3/3, the complete
`MacPackagedHelperTransportTests` passed 22/22, and the full isolated
`DesktopUpdaterKitTests` suite passed 100/100 with repository fixtures at their
canonical relative paths. `git diff --check` passed. The accepted `2de155e`
artifacts are diagnostic-only after this code change; real target-host GREEN is
`not run` until fresh artifacts are rebuilt from the fix commit.

Preinstall-verifier continuation (`verified locally`, 2026-07-19): fresh
accepted and stapled artifacts from `cc1e2a4c56d8597ad0b5a097743c2163f53d8712`
passed independent source, payload, component, package-signature, staple, and
Gatekeeper checks, then the target host reproduced `installRecoveryRequired`
before any provider journal or protected stage was created. Expansion of the
same v2 package isolated the P1: the helper's final-PKG verifier accepted only
the scripts-free component shape even though the recovery artifact is required
to contain the single fixed repository `preinstall`. The focused RED executed
one test and failed with `invalidExpectation`. The minimal GREEN accepts either
the original scripts-free component or exactly `Scripts/preinstall`, requires
the script to be a non-symlink regular executable no larger than 64 KiB with a
UTF-8 `#!/bin/sh` body, and binds PackageInfo to exactly one
`<preinstall file="./preinstall" timeout="600"/>`. The signed release descriptor
continues binding the complete PKG SHA-256, and the provider still invokes only
`/usr/sbin/installer -pkg <owned-stage>/installer.pkg -target /` through the
fixed-argv worker. The focused GREEN passed 1/1, the adversarial
`InstallStrategyTests` passed 17/17, and the complete helper package executed
138 tests with zero failures and one intentional crash-harness skip. The
related PKG, recovery, helper, audit, and native-retail Flutter contracts passed
31/31; both packaging scripts passed `sh -n`. Review confirmed that an empty or
extra Scripts shape, a postinstall, a symlink/non-executable/unsafe-mode script,
unexpected PackageInfo attributes or children, and caller-controlled installer
arguments remain rejected. The `cc1e2a4` artifacts are diagnostic-only after
this fix; real target-host GREEN remains `not run` until fresh artifacts are
built from the eventual fix commit.

Baseline-verifier continuation (`verified locally`, 2026-07-19): exact HEAD
`8ad576a82034e81cb700ffcc874bf5f950348eeb` produced fresh accepted and stapled
v1 and v2 source apps and final PKGs. The v1 app/PKG submission IDs were
`9a4ca111-1ed7-49ac-b8af-62d69f3e57ad` and
`8f3dd485-086c-4291-90f0-f2e702e16732`; the v2 app/PKG submission IDs were
`f7733a4e-f6bd-4ae1-a998-3796d33b02f2` and
`78e97860-9fd9-42a4-b567-5f027a7d3ae8`. Their final PKG SHA-256 values were
`c2e36343e0c90dfc5dbb4998e53db952e2c2ea3cb09dd3c2a323a016655dca4e` and
`b4cd6a283fc4884f19c50d6353adabc1f017b9308de8c020a2fc2bba2184ba4f`.
Both sanitized artifact audits and a separate system-context audit passed all
12 source/payload app, main-executable, and helper signature/runtime nodes; both
app and PKG staples; both execute/install Gatekeeper assessments; and the exact
scripts-free v1 and single-preinstall v2 component shapes. The verified
smoke-owned target was refreshed with the exact v2 source helper, but a real v1
bootstrap then failed closed before journal, lock, protected-stage, or installer
creation. Expansion isolated a second verifier P1: the baseline packager
intentionally removes the outer Distribution `bundle-version` authority, while
the helper still required that redundant outer record even though the signed
component PackageInfo retained the exact app identifier, version, build, and
path. The focused RED executed one test and failed with
`invalidExpectation`. The minimal GREEN makes the signed PackageInfo direct
bundle records authoritative for payload verification, permits the outer
Distribution to contain either zero bundle-version records or exactly one, and
still requires a present outer record to match PackageInfo exactly. The real
payload Info.plist and signed app remain independently verified. The focused
GREEN passed 1/1, the adversarial `InstallStrategyTests` passed 18/18, the
complete helper package executed 139 tests with zero failures and one
intentional crash-harness skip, and the related Flutter contracts passed
31/31; both shell scripts passed `sh -n`. The `8ad576a` artifacts are
diagnostic-only after this fix. Fresh exact-fix artifacts and target-host
acceptance remain `not run`.

Approval-probe crash continuation (`verified locally`, 2026-07-19): a fresh
target-host bootstrap plus the user-supplied macOS crash report reproduced a
P1 in the signed smoke adapter. When SMAppService approval was already granted,
the adapter deliberately raised the successful probe sentinel as a top-level
Swift error. Unified logging confirmed that exact sentinel reached
`swift_errorInMain`, producing `EXC_BREAKPOINT/SIGTRAP` instead of a normal
probe result. The focused RED failed because the sentinel was still thrown.
The minimal GREEN prints the same fixed sentinel and returns normally, so the
existing harness can distinguish already-approved bootstrap without an OS
crash report. It changes no typed approval event, XPC authentication, helper
authority, or installer arguments. The focused test passed 1/1; the widened
runtime and privileged-PKG contracts passed 16/16; the signed runtime sample
completed a release Swift build; and `git diff --check` passed. Fresh artifacts
from the eventual Task 3 fix commit remain required.

Approval-continuation continuation (`verified locally`, 2026-07-19): the exact
`78e83aa25db3095a669c71a959be9e23bf21dfa0` v2 artifact produced the required
typed `PrivilegedHelperApprovalRequired` event and remediation, retained its
owned source stage, and left the verified `2.7.0+270` target and receipt
unchanged. After approval, two diagnostic installs reached a real fixed-argv
installer and installed `2.7.1+271` with a matching receipt, root ownership,
terminal provider cleanup, and an empty source stage. They also exposed a P1 in
the test continuation: the recovery PKG gate required external release, the
separate approval process left an earlier stage, and the on-demand helper exited
before the harness's late PID check. Those runs are diagnostic-only and did not
write elevation evidence. The focused RED failed both the approval-continuation
and installed-helper probe contracts. The minimal GREEN now accepts cleanup
authority only from the exact sanitized approval report and its inventory-bound
stage provenance, resolves one provider transaction and only the fixed
`/usr/sbin/installer -pkg <protected-stage>/installer.pkg -target /` process,
releases the fixed smoke gate, and probes the installed helper through the
fixed signed target host and authenticated typed XPC query while binding the
observed launchd PID to the exact helper executable. The fixed probe has no
caller-controlled executable, transaction, duration, or installer argument.
Both focused tests passed 1/1; the widened Task 3 Flutter set passed 51/51; the
root package's identical `UpdateClientTests` source set passed 20/20; targeted
Dart analysis reported no issues; the runtime sample completed a release Swift
build; and `git diff --check` passed. The nested package command retains its
documented generated-host `FlutterMacOS` module blocker; it introduced no new
test failure. Fresh exact-fix artifacts and the real approval/install rerun
remain required before checking Step 4.

Bootstrap recovery-gate continuation (`verified locally`, 2026-07-20): exact
HEAD `7318a42cd5d298819a2a4ca8d2daf99dddf79d71` produced fresh Developer ID
signed, accepted, stapled, and Gatekeeper-approved v1 and v2 source apps and
final PKGs. The v1 app/PKG submission IDs were
`3b1869cd-3085-4e4a-b0f0-dc94bef1a56f` and
`87446c9e-da20-4d38-8471-0e54021af0ec`; the v2 app/PKG submission IDs were
`be2ddbcb-1067-4023-a2a7-7c2a3cc436e7` and
`77693a74-f2fb-432f-b9bd-e5fe86a8a0dc`. Independent audits passed both final
PKGs; their SHA-256 values were
`ca922a409c44688c6f9e44494d1eeb558e90ab9e7e043feb6f24b1bd05a697a6` and
`775556a1a32a80ec6e1acaa4ad259f0ccbd02289aa0cec6cd82578312befdbf0`.
The real target-host bootstrap reached one exact fixed-argv installer and the
root-only ready marker, then exposed a P1: the bootstrap refresh path did not
release the recovery-only package gate. A diagnostic fixed-marker release let
the official harness converge to the verified `2.7.0+270` baseline; that run is
not acceptance evidence. The focused RED failed because no manager-bound
release existed between refresh handoff and payload verification. The minimal
GREEN reuses the existing exact provider transaction, fixed installer argv,
and manager resolver and releases only the fixed marker with that manager PID.
It adds no executable, argument, stage, journal, or installer authority. The
focused GREEN passed 1/1 and the complete privileged-PKG smoke contract passed
8/8; targeted analysis, format, and `git diff --check` passed. The accepted
`7318a42` artifacts are diagnostic-only after this code change; fresh artifacts
from the fix commit and the real approval/install rerun remain required before
checking Step 4.

Installed-helper identity continuation (`verified locally`, 2026-07-20): exact
HEAD `13f835eb59bfd523c3b919eb41c8a5a02605fbf4` produced fresh signed,
accepted, stapled, and Gatekeeper-approved v1 and v2 source apps and final
PKGs. The v1 app/PKG submission IDs were
`60833e71-e708-46c2-9044-f0927511d767` and
`aa90dde3-42e0-43c8-b0b0-71fca393bf3d`; the v2 app/PKG submission IDs were
`26dba162-a4c8-4572-bd05-a7feddb4d4bd` and
`0bd74cf7-4afd-4cd0-a661-73f21580afe4`. Their final PKG SHA-256 values were
`d3fd3db100471b1762bde6ee7a4294ca19a9970b3370453718559da2d5247235`
and
`662c1143c4b46e6f3a9cc2af486863fb14eefd891c957972f9c32f21780de4c9`;
both independent audits passed. The official bootstrap and v1 verification
passed, and the user-controlled approval cycle produced the exact typed
`PrivilegedHelperApprovalRequired` event, remediation action, unchanged
`2.7.0+270` target and receipt, no installer, and one retained owned stage.
The continuation then installed `2.7.1+271`, updated the matching receipt, and
left the app, main executable, helper, and LaunchDaemon `root:wheel`, but the
final probe exposed a P1 and wrote no elevation report: SMAppService launches
the packaged daemon with a relative command display, so comparing the `ps`
command field to the absolute installed helper path produced a false mismatch.
The same assumption existed in the recovery harness. The focused RED failed
1/1 on the missing kernel executable-path binding. The minimal GREEN replaces
only those daemon argv comparisons with `proc_pidpath`, requires an absolute
path exactly equal to the fixed installed helper, and retains recovery's exact
PID plus microsecond start identity checks. It does not accept a relative path,
weaken launchd service binding, or expose the executable in evidence. The
focused static and real macOS FFI tests passed 1/1 each and the combined
install/recovery contract set passed 17/17. Fresh artifacts from the fix commit
and both real target-host sequences remain required before checking Step 4 or
Task 4 Step 3.

Terminal health-probe continuation (`verified locally`, 2026-07-20): exact
HEAD `b72420c360bbe3c0bb839cb139478f187b602176` produced fresh signed,
accepted, stapled, and Gatekeeper-approved v1 and v2 source apps and final
PKGs. The v1 app/PKG submission IDs were
`40f01551-374b-434d-b641-c3a4e8a58eaf` and
`e2a9be3b-cbfb-4df6-a6f7-b1e4445fcca4`; the v2 app/PKG submission IDs were
`8428e864-9886-4357-8822-49023115d55a` and
`ed59bdf0-6fe7-40d3-a550-f07e5c28ebe1`. Their final PKG SHA-256 values were
`f5f81814d585f04c114910a36dd8ffc673e6289b18e2e72d536dda8771cf3f74`
and
`6da6b0a19dd61cd8b79e62c9eec867851bb16b9697c4f5b36118ce04fca0fcd5`;
both independent audits passed. Official bootstrap and v1 verification passed,
and the repeated user-controlled approval cycle again produced exact typed,
stage-retaining, no-installer evidence bound to that commit and v2 hash. The
continuation installed `2.7.1+271` and passed the new kernel executable-path
binding, then exposed a P1 at the next probe boundary: successful terminal
provider cleanup had correctly removed the completed journal, so a post-install
transaction query could not be used as a helper health check. No elevation
report was written. Retaining or recreating that journal would violate cleanup
authority. The two focused RED contracts failed on the missing fixed health
operation. The minimal GREEN adds only an SPI-scoped, argument-free
`--probe-helper` mode to the signed smoke host. It authenticates the embedded
helper identity, sends the existing SMAppService XPC `health` operation without
installing or registering a service, requires the authenticated endpoint
identity to match, emits only `helperProbe/healthy`, and holds the connection
for the fixed PID observation window. The install harness no longer queries a
deleted transaction after completion. Both focused contracts passed 1/1, the
focused transport test passed 1/1 and proved zero installer calls, the complete
`MacPackagedHelperTransportTests` set passed 23/23, and the runtime sample
completed a release Swift build. The accepted `b72420c` artifacts are
diagnostic-only after this signed-host change; fresh artifacts and both real
target-host sequences remain required before checking Step 4 or Task 4 Step 3.

Post-install registration continuation (`candidate-only`, 2026-07-20): exact
HEAD `bbcb4ac53e5e05d641ac20cee9f59c77644e2190` produced fresh signed,
accepted, stapled, and Gatekeeper-approved v1 and v2 source apps and final
PKGs. The v1 app/PKG submission IDs were
`37a1d742-f62f-4038-9765-2e2ade1cb05a` and
`7878402c-b20c-4dfa-8db5-199c47cddca6`; the v2 app/PKG submission IDs were
`e51ebee3-a1a4-4860-a8a7-1778046e55d6` and
`54a39311-4341-4e6e-80af-edd3156be631`. Their final PKG SHA-256 values were
`ed1cfb6b17e52e442454b6e52836d42bf543a44a1ebf0702d9dfc81281db2878`
and
`9b1ff6ead7478778b623c38d5ce180ec0e3005aa9ece3964e4769efd6efafb73`;
both independent audits passed. Official bootstrap and v1 verification passed,
and the user-controlled approval cycle produced the exact typed code and
remediation, retained one owned stage, and launched no installer. The
continuation then installed `2.7.1+271`, updated the matching receipt, and left
the app root-owned, but the final authenticated probe exposed a P1: launchd
still held the v1 registration and running helper identity after the package
atomically replaced the app. The v2 client correctly rejected that valid but
stale endpoint identity as `invalidReservationResponse`; no elevation report
was written. The focused RED failed on the missing refresh operation. The
minimal GREEN keeps the no-mutation validation operation and adds a separate
SPI-only, argument-free refresh operation for the signed smoke host. It first
authenticates the current on-disk helper, accepts only an exact endpoint
identity match, and on a valid stale identity uses the existing fixed
SMAppService unregister/register path before requiring the exact new identity.
It does not add an installer executable, installer argument, provider request,
journal mutation, or approval bypass, and it does not retry malformed endpoint
responses. The focused Flutter contract passed 1/1, the identity-refresh Swift
test passed 1/1, the complete isolated `MacPackagedHelperTransportTests` set
passed 24/24, the Task 3 Flutter set passed 53/53, and the runtime sample
completed a release Swift build. Focused formatting and `git diff --check`
passed. The accepted `bbcb4ac` artifacts are diagnostic-only after this code
change; fresh artifacts and both real target-host sequences remain required
before checking Step 4 or Task 4 Step 3.

Registration-retry continuation (`candidate-only`, 2026-07-20): exact HEAD
`fdb86f4512e4eb9cf1ca8da2b2ceb971d274837b` produced fresh signed,
accepted, stapled, and Gatekeeper-approved v1 and v2 source apps and final
PKGs. The v1 app/PKG submission IDs were
`afd38af8-d8cf-4fc8-b076-d2fba8aff7ce` and
`d66706b3-bc3c-43c4-a19f-cc17c21a597f`; the v2 app/PKG submission IDs were
`f19fbc98-81d3-4a6a-90b1-ed0a0ee85e9b` and
`192fb1e4-7244-41b5-bca1-5308b95faf26`. Their final PKG SHA-256 values were
`b3833efc089d18c30b938b139ea9642ae9480e80267c68b31f2a5ba724e947f3`
and
`dcb26f9bb486e2fdac947c1760809ba71af43d50da7fdda64e54606dddd314e7`;
both independent audits passed. Official bootstrap, v1 verification, and the
user-controlled typed approval cycle passed against that exact commit and v2
hash. The continuation installed `2.7.1+271`, updated the matching receipt, and
left the app root-owned, then exposed a second activation P1: the asynchronous
SMAppService unregister completion arrived before ServiceManagement would
accept an immediate register, which returned `endpointUnavailable` and left no
registered service. The same fixed signed health probe succeeded without any
other mutation when repeated after that transient interval, confirming the
registration race. No elevation report was written. The focused RED executed
one test and failed with `endpointUnavailable`. The minimal GREEN retries only
that exact registration error through the same fixed SMAppService installer,
using the existing bounded 30-attempt, 100-ms activation delay. It never retries
`privilegedHelperApprovalRequired`, malformed endpoint responses, or identity
mismatches after registration, and it adds no executable, argument, provider,
stage, journal, or approval authority. Both focused registration tests passed
1/1, including the no-retry approval boundary; the complete isolated
`MacPackagedHelperTransportTests` set passed 26/26; the Task 3 Flutter set
passed 53/53; the runtime sample completed a release Swift build; and
`git diff --check` passed. The accepted `fdb86f4` artifacts are diagnostic-only
after this code change; fresh artifacts and both real target-host sequences
remain required before checking Step 4 or Task 4 Step 3.

ServiceManagement-settlement continuation (`candidate-only`, 2026-07-20):
exact HEAD `11ca63a9b901167c591536b47b688dd8d8ebf6a7` produced fresh signed,
accepted, stapled, and Gatekeeper-approved v1 and v2 source apps and final
PKGs. The v1 app/PKG submission IDs were
`93a3155b-0d45-4154-b746-cfe9010f7603` and
`af96907d-212c-4a04-ac62-205fa2732c79`; the v2 app/PKG submission IDs were
`2608a001-f0c9-4455-a84a-a909c71d5d30` and
`4a8fd26d-073f-4a50-83df-e8cc115f7810`. Their final PKG SHA-256 values were
`d861fec2378fb810313349599fc105cb84e4409f3e7f529faa17893ef69d9c2d`
and
`6ca85d4130a187e1999331440080a2d0ecd523d6fb6482783679c24b7f19d747`;
both independent audits passed. Official bootstrap, v1 verification, and the
user-controlled approval cycle passed with the exact typed code and
remediation, one retained owned stage, and no installer process. The
continuation installed `2.7.1+271` and updated the matching receipt, but its
terminal helper probe reproduced the registration P1: successful unregister
completion was followed by repeated ServiceManagement `Operation not
permitted` responses during the 100-ms retry burst. The same fixed signed probe
registered successfully after the transient interval without any stage,
journal, receipt, or installer mutation. The retained provider transaction was
then closed only through authenticated XPC recovery as `completed/succeeded`;
its owned journal, lock, and stage were absent afterward. No elevation report
was written. Apple DTS documents this unregister/register timing behavior as
an operating-system issue and recommends yielding the main run loop or adding
a short delay before re-registration. The focused RED failed to compile five
tests because the settlement and separate registration-retry contracts were
absent. The minimal GREEN gives a stale enabled registration one main-run-loop
turn plus a bounded two-second settlement interval, and separates registration
retry from endpoint activation with at most three two-second-spaced attempts.
It still retries only `endpointUnavailable`; it never retries approval,
malformed responses, or identity mismatches, and adds no executable, argument,
provider, stage, journal, or approval authority. The five focused GREEN tests
passed 5/5; the complete isolated `MacPackagedHelperTransportTests` set passed
27/27; the Task 3 Flutter set passed 53/53; the runtime sample completed a
release Swift build; and `git diff --check` passed. The accepted `11ca63a`
artifacts are diagnostic-only after this code change; fresh exact-current-head
artifacts and both real target-host sequences remain required before checking
Step 4 or Task 4 Step 3.

- [x] **Step 4: Complete v2 elevation and verify terminal state**

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

- [x] **Step 5: Verify, review, commit, and push**

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

Final target-host execution (`verified locally`, 2026-07-20): the exact
implementation-head v1 package established and independently verified the
smoke-owned `2.7.0+270` application and `2.7.0` receipt. With the Background
Item disabled by the user, the fixed signed host returned exit 75 with only the
typed `PrivilegedHelperApprovalRequired` code and
`openMacOSBackgroundItemsSettings` remediation, retained exactly one owned
stage, left the v1 target and receipt unchanged, and launched no installer.
After the user enabled the same helper, the authenticated XPC path and fixed
installer worker installed `2.7.1+271`; the matching receipt became `2.7.1`;
the app, main executable, helper, and LaunchDaemon were `root:wheel`; the app,
main, and helper strict signatures, Team ID `UPK4SC93AN`, hardened runtime,
staple, Gatekeeper, payload code identity, and active v2 LaunchDaemon all
passed. The new ServiceManagement settlement fix also passed its real terminal
health probe without another approval cycle.

The run then exposed a smoke-harness P1 rather than a product install failure:
the harness deliberately disables relaunch but waited for the client stage to
disappear without invoking the authenticated startup recovery that a relaunched
application performs. It correctly stopped at `completed-stage-not-removed`
and wrote no premature elevation report. A read-only query reported
`commitAccepted/recoveryRequired`; the signed v2 host then requested recovery
through authenticated XPC, which returned `completed/succeeded` only after the
provider's exact live-manager guard allowed it. The owned journal, lock, and
stage were absent afterward. Independent installed-target verification was
repeated before writing the sanitized elevation report. The focused RED failed
1/1 because terminal install had no recovery-before-cleanup call. The minimal
GREEN reuses the existing signed-host recovery path after installed app/helper
and payload verification and before stage-empty success; it performs no direct
cleanup and cannot bypass the provider's PID/start-identity guard. The focused
GREEN passed 1/1, the complete smoke contract set passed 10/10, the Task 3
Flutter set passed 54/54, and the real isolated `UpdateClientTests` passed
20/20. The repository SwiftPM wrapper still could not build the unrelated
plugin test target without a local `FlutterMacOS` module, so no assertion from
that failed integration build was counted as test evidence. Focused formatting
and `git diff --check` passed. Adversarial review found no message-matching
approval fallback, automatic approval, broad cleanup, alternate executable,
caller-controlled installer arguments, premature success, or terminal-stage
retention path.

Exact-current-head acceptance (`verified locally`, 2026-07-20): exact
implementation commit `f3bf11af5f62b048b38c83d58b22d82b4b0ba635` produced
fresh v1 and v2 source apps and final PKGs. The v1 app/PKG notarization
submissions were `5d502a47-7fb4-4037-8348-b086a8d571e6` and
`267f5228-3857-444f-a386-4c6e7c849594`; its final PKG SHA-256 was
`1e1f8a5c7773f9e2330a31ae4ff94c50872d9406f3907c89bdbcb4ebd0c8bd0d`.
The v2 app/PKG submissions were
`73456311-1318-4e1f-b30a-422f753887be` and
`90378ea2-7f2e-4e15-b261-2ab7ccb7c365`; its final PKG SHA-256 was
`a697d5ff7f2e531ef0d3d10f7841574c1c4f32e492781180ef585ebff09d4a04`.
Both independent final-artifact audits passed source and extracted app, main
executable, helper, Team ID, hardened runtime, package signature, app and PKG
staples, Gatekeeper, receipt metadata, version/build, and fixed component
shape.

The exact v1 package then established and independently verified the
smoke-owned `net.monolib.updater` target at `2.7.0+270` with receipt
`net.monolib.updater.pkg` version `2.7.0`. With the Background Item disabled by
the user, the same fixed signed host returned exit 75 with typed code
`PrivilegedHelperApprovalRequired`, remediation
`openMacOSBackgroundItemsSettings`, one retained owned stage, an unchanged v1
target/receipt, and no installer launch. After the user enabled that same
helper once and left it enabled, authenticated XPC and the fixed-argv worker
installed the exact v2 package. Independent terminal checks passed the
installed app/main/helper strict signatures, Team ID `UPK4SC93AN`, hardened
runtime, app and PKG Gatekeeper/staple, active SMAppService LaunchDaemon, and
`root:wheel` ownership. The installed application and receipt both report
`2.7.1+271`/`2.7.1`; the owned journal, lock, and stage are absent after
authenticated completion recovery. The sanitized approval and elevation
reports bind the same implementation commit, v2 artifact SHA-256, and final
PKG submission ID and contain no credential, identity, environment, private
path, full command line, stdout, stderr, or helper-log field.

Final current-implementation acceptance (`verified locally`, 2026-07-20):
exact implementation commit `ac2d2dcdb737325a5751adc7a05150ffaa56c315`
and final v2 package SHA-256
`d771a55d469e030b895da3d7e8f5459c5974c6c19041a81880b101903e4de817`
with accepted package submission `2ccf4099-60d8-407b-966b-55c9861e07a7`
established the physical `2.7.0+270` baseline and matching `2.7.0` receipt.
With the user disabling the exact Background Item once, the signed host exited
75 with typed code `PrivilegedHelperApprovalRequired`, remediation
`openMacOSBackgroundItemsSettings`, an unchanged baseline, and one retained
provenance-bound stage containing the exact final v2 package. After the user
enabled that helper once, authenticated XPC and the fixed-argv worker completed
the real `2.7.0+270` to `2.7.1+271` installation. Independent terminal checks
passed the installed app, main, and helper strict signatures; Team ID
`UPK4SC93AN`; hardened runtime; app staple and Gatekeeper; matching
`net.monolib.updater.pkg` receipt version `2.7.1`; active
`system/net.monolib.updater.helper`; and `root:wheel` ownership of the app,
main, helper, and LaunchDaemon. The elevation report captured active
LaunchDaemon PID 62226. Provider completion recovery removed the journal,
target lock, protected stage, and exact client-owned stage before success.
Both sanitized reports bind the same implementation commit, final v2 hash, and
final v2 package submission and expose no private path, complete command line,
raw helper output, environment, identity name, or credential value. The Task 3
Flutter set passed 54/54, root `UpdateClientTests` passed 20/20, and
`git diff --check` passed. The adversarial review reconfirmed the single
hard-coded installer executable and argument vector, no approval bypass,
no provider shell, no alternate install executable, no premature success,
manual-action retention, completed-state cleanup, and a clean terminal
journal/lock/stage boundary. AppleScript references remain confined to older
general-purpose smoke utilities and were not invoked by this SMAppService/XPC
acceptance path.

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

Current target-host gate evidence (`blocked`, 2026-07-19): the exact-head v2
recovery artifact is now notarized, stapled, and trusted, but Task 3 cannot
produce the required verified v1 baseline while the retained provider journal
is `manualActionRequired`. Fresh `MacVerifiedInstallerTransactionTests` passed
18/18, including exact live-manager identity retention and no relaunch after
manager start; fresh `MacPersistentRecoveryTests` passed 5/5. These tests
confirm the fail-closed behavior, but the real installer-active crash sequence
remains `not run` because starting it would require a new transaction against a
target still blocked by the retained journal.

Root-only gate continuation (`verified locally`, 2026-07-20): the real
`78e83aa25db3095a669c71a959be9e23bf21dfa0` installer-active diagnostic reached
the fixed preinstall and created the expected regular `root:wheel:600` ready
marker, but exposed a P1 in the recovery harness: the unprivileged controller
then attempted to read that root-only file. The marker content is not an
authority input; the harness separately binds the unique manager PID, its
microsecond start identity, the provider transaction UUID, exact fixed argv,
and the unchanged source stage. The focused RED failed on the root-only read.
The minimal GREEN preserves the marker's restrictive ownership and mode and
uses only its fixed path, regular-node shape, and authority as readiness proof;
it neither weakens the preinstall nor exposes the marker content. The focused
test passed 1/1, all recovery contracts passed 8/8, targeted Dart analysis
reported no issues, `MacVerifiedInstallerTransactionTests` passed 18/18,
`MacInstallerWorkerTests` passed 4/4, `MacPersistentRecoveryTests` passed 5/5,
the preinstall passed `sh -n`, and `git diff --check` passed. Fresh exact-fix
target-host recovery remains required before checking Step 3.

Root-manager identity continuation (`verified locally`, 2026-07-20): a fresh
exact-`ab34f0c3d5d7994616a2c4ad789dab50f2669dc8` recovery attempt reached the
fixed root-owned preinstall gate with exactly one fixed-argv installer, but the
unprivileged harness could not read that root process through
`PROC_PIDTBSDINFO` and stopped at `installer-manager-not-found`. A direct
read-only probe confirmed that `proc_pidpath` still bound `/usr/sbin/installer`
while `proc_pidinfo` returned no start identity. The focused RED failed because
the new fixed-argv/start-identity behavior was absent. The minimal GREEN keeps
`proc_pidinfo` as the primary path and falls back to the read-only
`CTL_KERN/KERN_PROC/KERN_PROC_PID` kernel record, preserving the helper's
`macos:<seconds>:<microseconds>` identity format without reading the root-only
journal or exposing identity in evidence. It also behaviorally pins the one
allowed installer argv and rejects executable, target, extra-argument,
stage-owner, and transaction deviations. The focused GREEN passed 9/9 and a
live root installer probe returned a stable microsecond-resolution identity.
A second real attempt resolved the exact installer PID/start identity and then
failed later at `launch-daemon-kill-failed`, proving this identity blocker is
closed while leaving the separate daemon-crash injection boundary
`candidate-only`. Both gated attempts were released only after revalidating the
same PID/start identity/fixed argv and were finalized through the signed host's
authenticated XPC recovery; journal, lock, stage, and fixed markers were absent
afterward.

Daemon-crash injection continuation (`candidate-only`, 2026-07-20): the next
fresh real attempt passed exact manager PID/start-identity and fixed-argv
resolution, then failed at `launch-daemon-kill-failed` because macOS correctly
denied an unprivileged process permission to signal the root SMAppService
daemon. A service-scoped `launchctl kill` was independently denied as not
privileged, so the harness does not rely on either weak path. The focused RED
failed the new native post-reply crash-scheduling test and two recovery-smoke
contracts. The minimal GREEN adds a typed, authenticated XPC
`terminateForRecoverySmoke` operation that is authorized only when the fixed
ready marker is a regular `root:wheel:600` node, the release marker is absent,
the exact transaction is a committed `managerStarted` installer journal, and
the journal's exact manager PID/microsecond start identity remains live. Only
after the typed reply is sent does the helper signal itself with `SIGKILL`.
The signed smoke host exposes this operation only through its smoke SPI, and
the harness first revalidates launchd service PID/executable/start identity and
then proves that exact identity exited; no caller-controlled executable,
signal, service, or installer arguments were added. The focused native GREEN
passed 1/1; all `MacPrivilegeServiceTests` passed 11/11; all
`MacPersistentRecoveryTests` passed 6/6 including fail-closed behavior without
the fixed root gate; the recovery/PKG contract set passed 20/20; and the Swift
runtime adapter built successfully. The complete helper package then ran 141
tests with zero failures and one crash-worker test skipped by its intentional
harness-only guard; targeted Dart analysis and `git diff --check` were clean.
A fresh signed/notarized/stapled artifact
from the resulting commit and the complete real sequence remain required
before checking Step 3.

Transaction-query activation continuation (`verified locally`, 2026-07-20):
exact HEAD `a0be5663adfdbabb61d66f2f97a50eecfa53e5a7` produced fresh,
accepted, stapled, and independently audited v1/v2 artifacts and repeated the
typed approval and real `2.7.0+270` to `2.7.1+271` target installation. The v1
app/PKG submission IDs were `f8a1fc2a-c6b6-478f-aacb-a42c733296f1` and
`35a4c98d-a627-471c-8668-f47ad7e26ea4`; its final PKG SHA-256 was
`42f61d7c4fda989f000fd8ce4dd389adb123721f2a26e37447e47abf78434ba0`.
The v2 app/PKG submission IDs were
`d3eabc54-8db5-4ee4-a789-2a7aa4016b1c` and
`5f015c89-397a-4f42-b9d6-45edb21a69ae`; its final PKG SHA-256 was
`cb9484d4b528f7a20fba627ecaf8234d8e97b6a9da2cbfa9c0bec8f0f156ebb5`.
Both independent audits passed source/payload app, main executable, helper,
Team ID, hardened runtime, PKG signature, app and PKG staple, Gatekeeper, fixed
receipt/version/build, and component-shape checks.

The first real recovery attempt reached the fixed root gate and created one
live fixed-argv installer manager, but the evidence harness treated the first
signed-host transaction query's on-demand helper activation failure as fatal.
The LaunchDaemon was then observed not running, while a later identical
read-only signed-host query returned typed `commitAccepted/recoveryRequired`.
The gated attempt was finalized only after revalidating the exact fixed argv,
manager PID/microsecond start identity, unchanged source package, and
`root:wheel:600` ready marker; only the fixed release marker was created, and
authenticated XPC recovery converged to `completed`. Journal, lock, stage,
markers, and installer process were all absent afterward, with target and
receipt at `2.7.1+271`/`2.7.1`. This diagnostic attempt is not crash-recovery
acceptance evidence.

The focused RED failed three compile-time contracts because no bounded query
activation retry existed. The minimal GREEN retries only a nonzero process
exit from the initial read-only manager query, at most three times with two
seconds between production attempts. Typed/malformed output, identity checks,
the authenticated crash operation, recovery, and terminal queries are not
retried by this boundary. The focused GREEN passed 13/13; the widened
recovery/PKG contract set passed 23/23; targeted Dart analysis reported no
issues; focused formatting changed no files; and `git diff --check` passed. A
fresh exact-fix artifact and complete real sequence remain required before
checking Step 3.

Registered-endpoint activation correction (`verified locally`, 2026-07-20):
exact HEAD `994404174db73d54c7ba22bedde0574627af4554` produced fresh,
accepted, stapled, and independently audited v1/v2 artifacts. The v1 app/PKG
submission IDs were `544968e6-0483-4f42-b335-9769b655c99c` and
`6b4c8245-24cd-420a-b435-bf03dea10892`; its final PKG SHA-256 was
`e5508bdde11fcef80c0db69688dccd37b34a8f7753282ffdc1c9bd7a1ea250e5`.
The v2 app/PKG submission IDs were
`0524f3eb-14cf-457a-a337-e62ddec96be6` and
`76323406-1cb5-4bca-9807-0b5a2091cce7`; its final PKG SHA-256 was
`db9cace8d603e088777ce320db1202c8c7e44349c1b8be9af503209d107cf80a`.
The exact v1-to-v2 approval and privileged installation sequence was repeated
and independently verified. Two subsequent recovery diagnostics each reached
one live fixed-argv installer manager, but every external Dart-process query
retry failed before a later identical signed-host query succeeded. Each gate
was released only after revalidating the exact manager PID/start identity,
fixed argv, unchanged source package, and root-only marker; authenticated XPC
recovery then removed the journal, lock, stage, and fixed markers. Neither
diagnostic is crash-recovery acceptance evidence.

The repeated real-host result localized the P1 below the Dart harness: a fresh
transport first attempts the unprivileged one-shot recovery path, then its
already-registered authenticated XPC fallback performed only one launchd
activation probe when installation was forbidden. The focused RED ran three
registered-query tests and failed the two missing retry behaviors. The minimal
GREEN moves the bounded retry to that product boundary: it authenticates the
fixed bundled helper first, retries only `endpointUnavailable` at most three
times, never installs or registers from a read-only query, and immediately
rejects endpoint-identity mismatch and every other error. The earlier external
Dart retry and its tests were removed. Focused GREEN passed 3/3; the complete
packaged-transport suite passed 30/30; root SwiftPM passed 108/108; the
recovery/PKG contracts passed 20/20; targeted Dart analysis reported no issues;
focused formatting changed no files; and `git diff --check` passed. A fresh
signed/notarized/stapled artifact from this correction and the complete real
sequence remain required before checking Step 3.

Cold-activation budget continuation (`verified locally`, 2026-07-20): exact
HEAD `25f0be427cbdcc61585345f0f8c3a18e9308b816` produced fresh,
accepted, stapled, and independently audited v1/v2 artifacts. The v1 app/PKG
submission IDs were `3f8c4f1f-67c1-4cb0-a34a-7e7554bc4627` and
`d4c09e75-b34c-4004-9803-ff434cc3de74`; its final PKG SHA-256 was
`be554558add40fbcd9196d62fb7694b4169a3ea00fcb06a65fcc0db44d57692c`.
The v2 app/PKG submission IDs were
`eb128fda-1614-47f2-9cc3-aad4aef3be0f` and
`c7622157-70b1-42b7-b250-64a69f94f277`; its final PKG SHA-256 was
`c6dd773b711ae289c7c74b8a3fd27ff572e1bc6d67cf9f603a04b29e32705e9f`.
Both audits passed source/payload app, main executable, helper, Team ID,
hardened runtime, package signature, app/PKG staple, Gatekeeper, receipt,
version/build, and fixed component shape. The same artifacts then passed typed
approval and the real privileged `2.7.0+270` to `2.7.1+271` installation with
matching receipt, active LaunchDaemon, `root:wheel` ownership, and completed
stage cleanup.

The subsequent real crash-recovery attempt reached one live fixed-argv
installer manager but exhausted the product's old 30-by-100-ms cold endpoint
activation budget before querying `managerStarted`. A later identical signed
query succeeded immediately. The attempt was released only after revalidating
the exact manager PID/start identity, fixed argv, unchanged package hash, and
root-only gate; authenticated XPC recovery then reached `completed`, its repeat
query was idempotent, and journal, lock, stage, and markers were absent. This
attempt is not crash-recovery acceptance evidence.

The focused RED failed 1/1 because the default activation budget could not
survive 100 transient cold-launch probes. The minimal GREEN keeps the existing
100-ms delay and raises only the bounded default from 30 to 150 attempts,
providing roughly fifteen seconds for a recently replaced launchd service.
Injected short bounds remain testable; identity mismatch and all errors other
than endpoint unavailability remain fail-fast; and read-only query fallback
still cannot install or register a helper. Focused registered-query GREEN passed 4/4, the complete
packaged-transport suite passed 31/31, root SwiftPM passed 109/109, and the
recovery/PKG contracts passed 20/20. A fresh signed/notarized/stapled artifact
from this correction and the complete real sequence remain required before
checking Step 3.

Stale-signed-endpoint continuation (`verified locally`, 2026-07-20): exact
HEAD `15974725695686edde5b27cd786e29989b1baf23` produced fresh,
accepted, stapled, and independently audited v1/v2 artifacts. The v1 app/PKG
submission IDs were `cb1ea41d-8fed-45bf-a468-e6d4b06135c7` and
`93792780-0441-4714-8aca-c52a85e8ecce`; its final PKG SHA-256 was
`ac412bad5da0e34a1240553e74ba0e5b3bce97dfc983d78b56d2e3456143ae5b`.
The v2 app/PKG submission IDs were
`21cc2d87-0fbd-4ac5-b566-83bf1b88bf74` and
`d282a721-ffaf-4381-a44c-174341da8e31`; its final PKG SHA-256 was
`a2298dc0f016677cce7144f817b37d68f74b4172ab2fde1d770eb3b2dbec7c20`.
Both independent audits passed, and the exact artifacts repeated typed
approval plus the real privileged `2.7.0+270` to `2.7.1+271` installation with
matching receipt, Team ID, hardened runtime, Gatekeeper/staple, active
LaunchDaemon, `root:wheel` ownership, and completed stage cleanup.

The next real recovery attempt still failed at the first manager query. A
single timed repeat proved the entire install handoff, fixed gate, transaction
creation, and failing query returned in 6.412 seconds, so it did not exhaust
the new roughly fifteen-second endpoint-unavailable budget. The installed main
and helper hashes matched the exact v1 artifact, launchd reported the service
not running at the failure boundary, and a later identical signed query
succeeded in 126 ms. Both diagnostics were released only after exact manager
PID/start identity, fixed argv, unchanged package hash, and root-only marker
validation; authenticated XPC recovery reached idempotent `completed`, and no
journal, lock, stage, or marker remained. Neither attempt is crash-recovery
acceptance evidence.

This timing excluded the endpoint-unavailability budget. Among the remaining
fail-fast activation paths, the package/service lifecycle and later immediate
success are consistent with a valid-but-stale endpoint identity during
settlement. The focused RED failed 1/1 on the first stale signed identity.
The minimal GREEN retries only a well-formed health response whose exact helper
hash is stale, never sends the transaction operation until the expected hash
appears, never installs or registers from the read-only query path, and remains
bounded by the activation budget. An explicit malformed
`invalidReservationResponse` still fails on the first probe, while persistent
stale identity fails closed at the injected bound. The complete packaged
transport suite passed 33/33, root SwiftPM passed 111/111, and the recovery/PKG
contracts passed 20/20. A fresh signed/notarized/stapled artifact from this
correction and the complete real sequence remain required before checking
Step 3.

Authenticated-exchange settlement continuation (`verified locally`,
2026-07-20): exact HEAD `1333ea0e56700fbef6952345ed5dc138dfbf9fb1`
produced fresh, accepted, stapled, and independently audited v1/v2 artifacts.
The v1 app/PKG submission IDs were
`9adf921b-411c-453d-a20c-50b89e265861` and
`2bd0a337-f1dc-43ec-af13-02d708c2cb63`; its final PKG SHA-256 was
`8c1c4ea95ae8f468d687f451d322ce4e6e84bec929388d0b3383eb8e7ec799aa`.
The v2 app/PKG submission IDs were
`bfa30a2a-651e-4b83-ab03-26735a21d214` and
`321a70df-4873-4c1c-915b-8fe3815747fb`; its final PKG SHA-256 was
`6a220411fc856473d17ec8dfd03b4e3e027fb836ddfb816f5b57a56df2331228`.
Both independent audits passed source/payload app, main executable, helper,
Team ID, hardened runtime, package signature, app/PKG staple, Gatekeeper,
receipt, version/build, and fixed component shape. The same artifacts passed
the exact typed approval boundary and real privileged `2.7.0+270` to
`2.7.1+271` installation with the matching receipt, active LaunchDaemon,
`root:wheel` ownership, and completed stage cleanup.

The subsequent real recovery attempt again reached one live fixed-argv
installer manager but the first signed-host manager query exited nonzero. A
later identical authenticated query returned typed
`commitAccepted/recoveryRequired`. Unified logging identified the exact initial
product error as `MacInstallClientError.endpointUnavailable`: endpoint
activation and signed-identity validation had succeeded, but the transaction
exchange itself raced the remaining launchd settlement interval. The retained
attempt was released only after a fail-closed gate revalidated the exact
manager PID/start identity, fixed argv, unchanged source package hash, and
root-only ready marker. Signed-host authenticated recovery then reached
`completed/succeeded`; journal, target lock, stage, and fixed markers were all
absent, and target/receipt were `2.7.1+271`/`2.7.1`. This diagnostic attempt is
not crash-recovery acceptance evidence.

The focused RED failed 1/1 because an authenticated exchange-level
`endpointUnavailable` was not retried. The minimal GREEN reauthenticates the
existing endpoint before each bounded replay and permits replay only for the
idempotent `queryTransaction` and `recoverPendingInstall` operations. It never
installs or registers during an exchange retry, never replays the smoke-only
helper crash operation, immediately rejects malformed or identity-mismatched
responses, and remains bounded by the injected activation budget. The focused
GREEN passed 1/1; the complete packaged-transport suite passed 38/38; root
SwiftPM passed 116/116; and the recovery/PKG/runtime Dart contracts passed
31/31. A fresh signed/notarized/stapled artifact from this correction and the
complete real sequence remain required before checking Step 3.

Fresh-process transaction retry continuation (`verified locally`, 2026-07-20):
exact HEAD `60ada8d7ad1afecc81d3a9022efb6a046b8a93a2` produced fresh,
accepted, stapled, and independently audited v1/v2 artifacts. The v1 app/PKG
submission IDs were `10b0ba9a-8fe4-4966-80d3-621a39e07ee7` and
`86f0e636-cc7d-4cc4-a30b-958627c2c25f`; its final PKG SHA-256 was
`1ee27524ea6caa907969490198a9c5eb104201a97684796ce8b4e26dfb51a5e1`.
The v2 app/PKG submission IDs were
`e5871804-6df3-481d-bf72-ea588266528b` and
`f7d05ae4-1701-4325-bd95-f0a241bade93`; its final PKG SHA-256 was
`a1b2931fe985ddc82496f8dc2bc7d181d69eaf3ebfa71fa5cda756e5cb609c02`.
The typed approval gate and real `2.7.0+270` to `2.7.1+271` privileged install
both passed on that exact artifact. Two official recovery attempts reached the
live installer-manager/stage boundary but their first fresh signed status
process failed with endpoint unavailability; the same signed idempotent query
then succeeded immediately. Both diagnostic attempts were released only after
verifying the exact manager PID/start identity, fixed installer authority,
owned stage provenance/hash, and root-owned ready marker. Each reached
authenticated terminal recovery with no journal, lock, stage, or smoke marker
remaining. This validated a fresh-process transport P1 rather than Task 4
acceptance.

The focused RED failed 1/1 because the smoke adapter could not express typed
endpoint unavailability and the harness could not replay the fresh process. The
minimal GREEN emits only the three-field typed unavailable event and retries
only `queryTransaction` and `recoverPendingInstall`, at most ten attempts with
500 milliseconds between attempts. It never retries the authenticated
helper-crash operation, install, registration, malformed output, or identity
mismatch. The focused GREEN passed 1/1; the widened recovery/PKG/runtime Dart
contracts passed 38/38; the signed runtime Release build succeeded; targeted
analysis and formatting were clean; and `git diff --check` passed. A fresh
signed/notarized/stapled artifact from the resulting commit and the complete
real sequence remain required before checking Step 3.

Typed privileged-query failure continuation (`verified locally`, 2026-07-21):
exact HEAD `36845f64612612644731267ce8e4fab7735cc376` produced fresh,
accepted, stapled, and independently audited v1/v2 artifacts. The v1 app/PKG
submission IDs were `b60e9277-ffad-4078-8520-6c61cab1f205` and
`7cdbf81a-f0f1-4765-8746-ccf7733fa575`; its final PKG SHA-256 was
`f657d7c70f67f35eca90a01998a921ef17234635620b1aec381bd52f5690fc53`.
The v2 app/PKG submission IDs were
`1925e5d5-4a7c-478d-90da-b04ff5cbb78d` and
`2c039b6a-6411-42ec-bf45-2ab6709e23a3`; its final PKG SHA-256 was
`925a4c58e8ab7cc53cf61bbc041cec29a668c3bf82c5073b78589b702c951215`.
The exact typed approval boundary and real privileged `2.7.0+270` to
`2.7.1+271` installation passed on that artifact, including the matching
receipt, Team ID, hardened runtime, active LaunchDaemon, `root:wheel`
ownership, and completed stage cleanup.

The official recovery attempt reached one root-owned ready marker, one owned
stage whose PKG hash matched the v2 artifact, and exactly one fixed-argv
installer manager. Its first fresh signed query process crashed with
`swift_errorInMain` (Crash Reporter incident
`39FC0484-50C0-4868-B57E-CD17631654C4`). A subsequent read-only query from the
same signed artifact returned typed `commitAccepted/recoveryRequired`. The
diagnostic attempt was released only after revalidating that the exact manager
PID/start identity and fixed argv were unchanged and the stage hash remained
stable. Authenticated recovery then returned `completed/succeeded`; journal,
lock, stage, manager, and marker state were absent at terminal cleanup. This
safe diagnostic closure is not Task 4 acceptance evidence.

The validated P1 was in `queryTransaction`: after an arbitrary one-shot read
failure, a transient privileged fallback failure was discarded and the first
untyped Swift error was rethrown, preventing the signed adapter from emitting
typed endpoint unavailability. The focused RED failed 1/1 because the returned
error was not `MacInstallClientError.endpointUnavailable`. The minimal GREEN
preserves the privileged fallback error after the fallback is attempted. It
does not install or register a helper, submit a transaction operation, change
installer authority, mutate stage/journal state, or expand retry authority.
The focused GREEN passed 1/1; the complete packaged-transport suite passed
39/39; the widened recovery/PKG/runtime/artifact-audit Dart contracts passed
38/38; and the signed runtime Release build succeeded. Root SwiftPM remained
blocked before test execution by the intentionally absent `FlutterMacOS`
module; the full temporary isolated package was not counted because its
temporary root invalidates repo-relative fixture discovery. A fresh
signed/notarized/stapled artifact from the resulting commit and the complete
real sequence remain required before checking Step 3.

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

Current exact-head review (`blocked`, 2026-07-19): source and final-payload
app/main/helper signatures, hardened runtime, Team ID, app and PKG staples,
Gatekeeper execute/install assessments, PKG signature, fixed component and
recovery-script shape all pass for exact HEAD `464cef9b5d0e5f156cb1aaf597ac472bba1d2ed8`
and v2 final SHA-256
`26c8c7dd191677962d5ae6f427d8e9786a821e2e558aefe1e6c77eb943de049f`.
The installed smoke target also passes app/main/helper trust, staple,
Gatekeeper, ownership, and active-LaunchDaemon checks. This completion step is
still blocked because the installed receipt is `2.7.0`, the target is
`2.7.1+271`, and the retained provider journal is
`manualActionRequired/recoveryRequired`; consequently typed approval, real
elevation, terminal recovery, and completed-stage cleanup are not fresh
acceptance evidence.

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

Current continuation (`candidate-only`, 2026-07-19): fresh target-host
execution invalidated the earlier "no validated P0/P1 remains" statement by
reproducing the caller-exit P1 described in Task 3. Its separate focused
RED/GREEN fix binds the monitor to the caller's exact PID/start identity; the
complete helper suite executed 137 tests with zero failures and one intentional
skip. The finding is resolved in code but not yet accepted at the production
boundary; fresh exact-commit artifacts and the real v1-to-v2 and
installer-active recovery sequences are still required.
The literal verdict therefore remains `candidate-only / NO-GO`.

The same continuation validated a second P1 in the controlled bootstrap
boundary: the previous v1 PKG had not actually disabled Installer bundle
version checks, so it could change the receipt without replacing a newer app.
The separate focused RED/GREEN baseline-component fix is exact-identity-bound,
scripts-free, and excluded from recovery and normal publication paths. It is
`verified locally` in contract/syntax coverage but still awaits fresh artifact
and real target-host acceptance.

- [x] **Step 4: Issue verdict and close**

macOS is `production-ready` only when current-head source/payload/installed signatures, notarization/stapling/Gatekeeper, typed approval, real v1-to-v2 elevation, receipt/ownership/helper/LaunchDaemon, installer-active recovery, stage cleanup, full validation, and evidence consistency all pass with no P0/P1.

If any gate fails or is not run, record `candidate-only / NO-GO` and leave this plan active.

Final macOS verdict (`candidate-only / NO-GO`, 2026-07-19): exact-current v2
artifact trust/notarization is `verified locally`; typed target-host approval
and real 2.7.0+270 to 2.7.1+271 elevation are `not run`; installer-active daemon
crash recovery is `not run`; and four-report evidence/CI publication is
`blocked`. The retained provider journal is
`manualActionRequired/recoveryRequired`; its exact target lock is absent, its
owned stage is retained, and no installer manager remains live. The fixed
recovery authority does not relaunch an installer after manager start, so no
safe in-scope path can produce the v1 baseline without prohibited out-of-band
mutation. No accepted real crash point, terminal `completed/newTarget` result,
or completed-stage cleanup exists. The plan stays active. Windows and Linux
readiness were not changed.

- [x] **Step 5: Commit and push final status**

```sh
git add docs/exec-plans/active/2026-07-17-macos-privileged-updater-production-closure-plan.md
git commit -m "docs(macos): close privileged updater production gate"
git push origin feat/native-sdk-platform-split
```

## Completion Boundary

This plan closes only the macOS privileged updater. Windows target-host/Authenticode/UAC and installed Linux polkit/root-broker gates retain their current literal status.
