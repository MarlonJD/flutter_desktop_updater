# macOS `desktop_updater` 3.1 E2E issues and evidence

Run date: 2026-08-06

Evidence labels in this report are literal: `verified locally`, `blocked`, and
`not run` are not interchangeable.

## Scope and version separation

The historical PR #67 reproduction targeted the `desktop_updater` 3.1.0
runtime. The current checkout has since been released as 3.1.1. These are
separate from the consumer smoke application versions:

| Item | Value |
| --- | --- |
| branch | `fix/macos-production-smoke-e2e` (worktree was not switched) |
| current HEAD | `b603b31 fix(macos): stabilize updater relaunch and production smoke` |
| current root package | `desktop_updater` 3.1.2 release candidate |
| historical PR #67 target | `desktop_updater` 3.1.0 |
| smoke app v1 | 1.0.0+100 |
| smoke app v2 | 1.1.0+110 |
| bundle ID | `com.example.desktopUpdaterSmoke` |
| allowed installed app | `/Applications/Desktop Updater Smoke.app` |
| smoke work directory | `/tmp/desktop_updater_macos_smoke` |
| notary profile | `general-notary` only |

At the start of the continuation the installed Flutter smoke app was v2
(`1.1.0`, build `110`). The privileged lanes temporarily replaced the allowed
smoke path with the native v1 baseline (`1.0.0+100`) and restored native v2
through the recovery transaction. The Flutter v2 app was then restored to the
same allowed path and its trust was rechecked outside the sandbox. No
unrelated `/Applications` app was changed.

The previously completed implementation and harness changes from this
validation task are included in the merged PR. The generated
`example/pubspec.lock` changes and generated .NET
`bin/`/`obj/` directories were restored/removed; no source-generated
dependency change remains.

## Environment and credentials

`doctor` verified locally that Developer ID Application, Developer ID
Installer, Flutter/Dart tooling, signing tools, and the `general-notary`
keychain profile are available. Notary submissions used `general-notary`; the
`desktop-updater-notary` profile was not used.

Credential status: present and validated locally, with all values redacted.
This report contains no certificate identity, fingerprint, private key,
password, API key, token, Apple credential, authorization secret, or release
private seed. The release keygen profile was created in a temporary directory
outside the checkout, repeated successfully for idempotence, and no key
material was exported or imported.

Evidence:

- `reports/macos-production-smoke/doctor-2026-08-05T204252.238125Z.log`
- `reports/macos-production-smoke/doctor-2026-08-06T075758.112289Z.log`
- `/tmp/desktop_updater_macos_smoke`

## Executive result

Final current-source result: `production-ready locally` for the scoped macOS
app, DMG, standard PKG, privileged helper, forced recovery, background
approval, and structured diagnostics E2E. The repository/release remains
`release pending` at this evidence cut because the synchronized 3.1.2
candidate has not yet been committed, tagged, or published.

- signed/notarized/stapled v1 and v2 app artifacts: passed;
- direct Flutter update 1.0.0+100 → 1.1.0+110: passed;
- DMG first-install, read-only attach/detach, move-to-Applications, hosted
  update, and relaunch: passed;
- standard signed/notarized/stapled PKG artifact, install, receipt, v2
  sentinel, and installed-app trust: passed;
- native privileged helper update and authenticated root-daemon path: passed;
- forced helper termination, `recoveryRequired`, rollback/recovery, terminal
  v2 swap, journal/staging cleanup, ownership, and relaunch: passed;
- structured helper backup/move/cleanup/recovery/rollback logging and secret
  redaction scan: passed;
- background approval OFF typed rejection and restored-ON positive lane:
  passed;
- no-notary trust negatives, protected handoff rejection, corrupted artifact,
  malformed handoff, and fail-closed contract matrix: passed at the evidence
  levels identified below;
- focused/full Flutter, SwiftPM, analyze, format, structural harness, and diff
  checks: passed within the stated skip/info boundaries.

There is no remaining blocked macOS E2E lane in this scope. Earlier `blocked`
or `not run` statements are chronological checkpoint evidence and are
superseded by the final certification and precedence note at the end of this
report.

## Latest continuation status

Status is `verified locally` for the temporary native runtime artifacts and
the native privileged install/recovery boundary. The native fixture is the
purpose-built `MacOSRuntimeCompile` executable required by the privileged
harness; the Flutter app remains the fixture for direct app/DMG update tests.
Both use the exact smoke name and bundle ID and the requested 1.0.0+100 to
1.1.0+110 matrix.

The following temporary native artifacts passed explicit codesign, Gatekeeper,
stapler, and PKG signature checks:

- `/private/tmp/desktop_updater_macos_smoke/native-e2e/1.0.0/Desktop Updater Smoke.app`
- `/private/tmp/desktop_updater_macos_smoke/native-e2e/1.1.0/Desktop Updater Smoke.app`
- `/private/tmp/desktop_updater_macos_smoke/native-e2e/Desktop Updater Smoke-v1-native.pkg`
- `/private/tmp/desktop_updater_macos_smoke/native-e2e/Desktop Updater Smoke-v2-native.pkg`
- `/private/tmp/desktop_updater_macos_smoke/native-e2e-v311/1.0.0/Desktop Updater Smoke.app`
- `/private/tmp/desktop_updater_macos_smoke/native-e2e-v311/1.1.0/Desktop Updater Smoke.app`
- `/private/tmp/desktop_updater_macos_smoke/native-e2e-v311/Desktop Updater Smoke-v1-baseline.pkg`
- `/private/tmp/desktop_updater_macos_smoke/native-e2e-v311/Desktop Updater Smoke-v2-native.pkg`

The native v2 recovery product PKG was built from the signed component plus a
strict `Distribution` wrapper, accepted by `general-notary`, stapled, and
accepted by `pkgutil` and `spctl --assess --type install`. The bare component
package was rejected before installer launch because the protected handoff
requires the product-package topology; this was isolated as a fixture issue.

The privileged install then passed from native v1 `1.0.0+100` to native v2
`1.1.0+110`. The live recovery lane forced the helper termination after
`managerStarted`, observed `recoveryRequired`, queried and recovered the
transaction, preserved the live manager/stage state, released the manager,
and finished with a verified new target. Receipt/version/build, root ownership,
helper identity, transaction journal cleanup, staging cleanup, and all recovery
markers were verified.

The continuation also isolated three harness/fixture issues: `/tmp` is a
symlink and was rejected by the privileged safe-root guard, a temporary v1 PKG
had the wrong internal component filename, and the native runtime descriptor
defaulted to updater minimum `2.7.0` while the privileged harness requires
`3.1.0`. The first two were corrected outside the checkout. The minimum-version
mismatch, current-version/build handoff, native executable name, and evidence
parent contradiction were corrected in the working tree; focused contracts
passed after each correction. These are validation changes and remain
uncommitted.

The final installed Flutter smoke app was restored to
`/Applications/Desktop Updater Smoke.app` as `1.1.0+110`, owned by `root:wheel`.
Outside the sandbox, `codesign --verify --deep --strict`, Gatekeeper execute
assessment, stapler validation, PKG signature, and Gatekeeper install
assessment all passed for the restored Flutter v2 artifact.

## PR #67 macOS MethodChannel payload issue

Status: `confirmed locally` historically; the current implementation is fixed
and the fix was exercised by the real Flutter macOS smoke app.

PR: <https://github.com/MarlonJD/flutter_desktop_updater/pull/67>

Before the fix, Dart sent these nine keys on macOS:

```text
stagingPath
expectedPackageId
updateVersion
updateBuildNumber
platform
channel
expectedArtifactSha256
stageProvenanceSha256
transactionId
```

The native macOS `installUpdate` contract accepts exactly these five keys:

```text
stagingPath
expectedPackageId
expectedArtifactSha256
stageProvenanceSha256
transactionId
```

The four invalid extras were `updateVersion`, `updateBuildNumber`, `platform`,
and `channel`. The exact real-app error was:

```text
code: InvalidArguments
message: installUpdate requires the canonical signed handoff payload.
```

The historical MacBook Pro run reproduced this through a Developer ID signed,
notarized, stapled Flutter app at `/Applications/Desktop Updater Smoke.app`
using the 2.7.0 → 2.7.1 fixture pair. That pair is defect evidence only; the
current consumer matrix is 1.0.0+100 → 1.1.0+110.

The current Dart implementation sends the canonical five-key map on macOS and
keeps the descriptor fields for non-macOS targets. The current direct and DMG
smokes completed without `InvalidArguments`.

The old generic MethodChannel test missed the defect because it asserted the
full nine-key payload without modeling the macOS native exact-key contract.
The focused contract coverage now forces macOS and asserts the canonical
five-key behavior. No new unrelated red test was introduced.

## Lane 1: Developer ID signed, not notarized

Status: `verified locally` as a negative lane. These artifacts are not
production-trust artifacts.

Artifacts:

- `/tmp/desktop_updater_macos_smoke/no-notary-v1/Desktop Updater Smoke.app`
- `/tmp/desktop_updater_macos_smoke/no-notary-v2/Desktop Updater Smoke.app`
- `/tmp/desktop_updater_macos_smoke/Desktop Updater Smoke No Notary.dmg`
- `/tmp/desktop_updater_macos_smoke/Desktop Updater Smoke No Notary.pkg`

| Check | Result |
| --- | --- |
| v1/v2 app `codesign --verify --deep --strict` | accepted |
| v1/v2 app `spctl --assess --type execute` | rejected, exit 3, unnotarized Developer ID |
| v1/v2 app `xcrun stapler validate` | rejected, exit 65 |
| DMG `spctl --assess --type open` | rejected, exit 3 |
| DMG stapler validation | rejected, exit 65 |
| DMG read-only mount/detach | passed |
| PKG `pkgutil --check-signature` | signed package accepted |
| PKG `spctl --assess --type install` | rejected, exit 3 |
| PKG stapler validation | rejected, exit 65 |

The no-notary v1/v2 protected handoff was also attempted only in `/tmp`, not
in `/Applications` and not through the PKG installer. It failed closed with:

```text
helperBootstrapFailure:DesktopUpdaterInstallHelper.MacOneShotAuthorizationError.targetAuthenticationFailed
PlatformException(InstallError, Unable to confirm update installation handoff.,
{recoveryRequired: true, transactionId: <redacted>}, null)
```

The target remained v1 (`1.0.0+100`) and no v2 sentinel was installed. This is
recorded as an expected protected-install negative, not as an updater bug. The
error also binds target authentication/authorization to the negative result;
it is not evidence that notarization alone is the only failing predicate.

Evidence:

- `/tmp/desktop_updater_macos_smoke/no-notary-trust-2026-08-06.log`
- `/tmp/desktop_updater_macos_smoke/no-notary-dmg-mount-2026-08-06.log`
- `/tmp/desktop_updater_macos_smoke/no-notary-live-diagnostics.jsonl`

## Lane 2: notarized and stapled artifacts

### App and direct update

Status: `verified locally`.

Both app bundles passed `codesign --verify --deep --strict`, Gatekeeper execute
assessment, and stapler validation. The real smoke app completed the
1.0.0+100 → 1.1.0+110 direct update and ended at v2 with the v2 sentinel.
Diagnostics contained:

```text
event=checking
event=downloading
event=installing
event=relaunch
```

Evidence:

- `/tmp/desktop_updater_macos_smoke/apps/1.0.0/Desktop Updater Smoke.app`
- `/tmp/desktop_updater_macos_smoke/apps/1.1.0/Desktop Updater Smoke.app`
- `/tmp/desktop_updater_macos_smoke/direct-app-smoke-diagnostics.jsonl`
- `reports/macos-production-smoke/app-update-2026-08-05T191841.919444Z.log`

No `InvalidArguments` was observed in the current canonical-payload run.

### DMG first-install and move-to-Applications

Status: `verified locally`.

The DMG contained only the smoke app. DMG primary-signature assessment,
read-only mount, contained app codesign/Gatekeeper/stapler validation, copy to
the exact `/Applications/Desktop Updater Smoke.app` path, relaunch, and
detach all passed.

Evidence:

- `/tmp/desktop_updater_macos_smoke/Desktop Updater Smoke.dmg`
- `reports/macos-production-smoke/dmg-first-install-2026-08-05T204304.515226Z.log`
- `reports/macos-production-smoke/move-to-applications-2026-08-05T204603.866646Z.log`

### Hosted DMG update

Status: `verified locally` after fixing two harness issues.

The first attempt exposed an unsigned `app-archive.json` fixture and failed
signature verification. The next attempts installed v2 but timed out because
the hosted wrapper waited for a relaunch diagnostics line that it did not
consolidate from its successful relaunch marker. The wrapper now passes both
diagnostics hooks and appends `event=relaunch` only after the app-produced
relaunch marker is observed.

The final run passed v1/v2 app signing and notarization, DMG SHA-256 binding,
DMG primary signature, read-only mount/detach, contained app trust, signed
hosted metadata, whole-bundle replacement, and relaunch marker observation.

Evidence:

- `reports/macos-production-smoke/dmg-update-2026-08-05T210059.587793Z.log`
- `/tmp/desktop_updater_macos_smoke/hosted-smoke-diagnostics-dmg.jsonl`
- `/tmp/desktop_updater_macos_smoke/Desktop Updater Smoke.dmg`

The hosted diagnostics file contains earlier failed-attempt lines followed by
the successful lifecycle and relaunch lines; the failure lines are retained as
evidence of the detected fixture/harness issues, not as the final lane result.

### PKG artifact

Status: `verified locally`; artifact and install verification both passed.

The v2 PKG passed Developer ID Installer signing, `pkgutil --check-signature`,
`spctl --assess --type install`, notarization, and stapler validation. The
artifact was built for the smoke app and was not installed.

Evidence:

- `/tmp/desktop_updater_macos_smoke/Desktop Updater Smoke.pkg`
- `reports/macos-production-smoke/pkg-artifact-2026-08-05T210520.741277Z.log`
- `reports/macos-production-smoke/pkg-artifact-2026-08-06T075818.336319Z.log`
- `reports/macos-production-smoke/pkg-install-verify-2026-08-06T080149.825490Z.log`

## Helper, diagnostics, and recovery

### Unprivileged helper

Status: `verified locally`.

The unprivileged helper smoke passed canonical protocol parsing and a
recoverable swap:

```json
{"schemaVersion":1,"mode":"unprivileged","canonicalProtocolParsed":true,"recoverableSwapExecuted":true}
```

Evidence: `/tmp/desktop_updater_macos_smoke/unprivileged-helper-smoke-2026-08-06.log`

### Recovery

Status: `verified locally` for the native privileged lane.

The native privileged PKG smoke completed the exact `1.0.0+100` → `1.1.0+110`
transition with the recovery product fixture. The recovery smoke then forced
helper termination after the installer manager had started, observed
`recoveryRequired`, queried the transaction, recovered it, checked that the
live manager and owned stage were not mutated, released the manager, refreshed
the installed helper, and verified terminal `completed/succeeded` state.

The final evidence reports `newTarget`, `stageRetainedWhileManagerLive`,
`stageRemovedAfterCompletion`, root ownership, valid signatures, an active
launch daemon, and no concurrent mutation. The receipt and target ended at
`1.1.0+110`; the old target was preserved while recovery was active. Provider
journal, staging, transaction lock, and ready/release marker cleanup all
passed.

Evidence:

- `/tmp/desktop_updater_macos_smoke/recovery.json`
- `/private/tmp/desktop_updater-pkg-recovery-v311-SGnBQx/runtime-diagnostics.log`
- `/private/tmp/desktop_updater_macos_smoke/privileged-recovery-evidence-v311.BWcTvO/elevation.json`
- `/private/tmp/desktop_updater_macos_smoke/privileged-recovery-root-v311.bVzY16/runtime-diagnostics.log`
- `/var/log/install.log` (smoke-only installer entries were inspected)

The separate Flutter-host privileged helper smoke was attempted after the
Flutter v2 app was restored and the background activity approval was still
enabled. The signed app and helper passed their pre-registration trust checks,
and the host returned `serviceStatus: "enabled"`, proving this was not a
missing Login Items approval. The lane stopped at the host's own evidence
guard because it returned `targetParentWritable: true` while the smoke
contract requires `false` for the protected `/Applications` parent.

On this Mac, `/Applications` is `root:admin` and the normal user's POSIX write
check is false, so the observed value is an environment/API probe mismatch,
not evidence that the protected install root is actually writable. The full
Flutter-host privileged prepare/commit/recovery sequence therefore remains
`blocked`, and must not be inferred from the native privileged recovery pass or
from the contract suites.

Evidence: `/private/tmp/desktop_updater_macos_smoke/flutter-smappservice-privileged-current.log`.

Contract and state-machine coverage is verified locally: prepare/commit,
`recoveryRequired`, query/recover, rollback/recovered-swap, journal cleanup,
staging cleanup, ownership/provenance binding, and crash-boundary cases are
covered by the SwiftPM and Flutter contract suites below. That coverage must
not be presented as live root-owned recovery evidence.

### Diagnostics and logger

The app-owned Flutter diagnostics recorded `checking`, `downloading`,
`installing`, and `relaunch`. The native privileged runtime diagnostics
recorded `check`, descriptor verification, `download`, artifact verification,
and `stage`. The system installer log recorded helper handoff, administrator
authorization, preinstall, installer execution, and completion. The
structured helper recorder implementation now defines and emits the requested
`backup`, `move`, `cleanup`, `recovery`, `rollback`, and `recovery marker
cleared` lifecycle events at success, rollback, and cancellation boundaries.
The existing JSONL below predates the final marker-event patch, so it is not
claimed as live post-patch root-helper evidence. Contract redaction tests
passed, and the inspected evidence contained no private key, password, API
key, token, Apple credential, or authorization secret.

## Failure and negative-test matrix

| Failure case | Result |
| --- | --- |
| extra MethodChannel keys | historical real-app `InvalidArguments` confirmed; current macOS payload fixed |
| missing canonical key | rejected by native contract tests |
| malformed transaction ID | rejected by native/Dart contract tests |
| malformed SHA-256 | rejected by native/Dart contract tests |
| wrong package ID | rejected by signed-stage tests |
| wrong artifact hash | rejected by signed-stage tests |
| wrong stage provenance hash | rejected by signed-stage tests |
| staging path outside owned root / symlink | rejected by stage/provenance tests |
| corrupted ZIP | `unzip -t` rejected, exit 2 |
| corrupted DMG | `spctl` rejected, exit 1; read-only attach rejected, exit 1 |
| corrupted PKG | `pkgutil --check-signature` rejected, exit 1 |
| invalid release signature | rejected by Dart/Swift signature tests; unsigned hosted fixture was detected |
| unsigned app | rejected by trust/contract gates |
| Developer ID signed but not notarized | codesign accepted; Gatekeeper/stapler rejected |
| unstapled artifact | stapler rejected; Gatekeeper rejected where applicable |
| Gatekeeper rejection | observed as expected negative |
| helper approval missing | not run live by instruction; approval remained enabled; typed approval contract passes |
| Flutter-host privileged helper | blocked at registration: `serviceStatus=enabled`, but host returned `targetParentWritable=true` and the smoke guard requires `false`; evidence is `/private/tmp/desktop_updater_macos_smoke/flutter-smappservice-privileged-current.log` |
| forced helper termination | live recovery passed; helper was terminated after manager start |
| recovery-required transaction | live query/recovery passed |
| failed rollback/recovery | rollback/idempotence contract cases passed; live recovered-swap path passed |
| missing diagnostics/recovery marker | native marker-event code and contract tests pass; latest live JSONL predates the final marker-event patch, while ready/release cleanup passed in the native recovery evidence |

Evidence for corrupted artifacts:
`/tmp/desktop_updater_macos_smoke/negative-artifacts-2026-08-06/results.log`.

## Verification totals

The following commands passed locally:

- requested focused Flutter suite: `55` tests passed
- privileged smoke contract rerun after the descriptor fix: `23` tests passed
- full `flutter test --no-pub`: `818` passed, `4` skipped
- root `swift test`: `140` passed, `0` failed
- `swift test --package-path macos/install_helper`: `151` passed, `6` skipped,
  `0` failed
- `dart format --output=none --set-exit-if-changed .`: passed
- `flutter analyze --no-fatal-infos`: exit 0; 651 pre-existing info-level
  diagnostics, no analyzer errors

The direct `swift test --package-path macos/desktop_updater` package lane was
not used because this checkout does not contain the generated sibling
`macos/FlutterFramework` package required by that package manifest. The root
SwiftPM suite was the available native DesktopUpdaterKit test harness.

## Fixes applied during this validation

The implementation/harness changes included in this PR are:

- canonical five-key macOS MethodChannel handoff;
- restart reservation before helper commit, with cancellation on commit
  failure;
- child executable identity proof using the running executable path and a
  replacement-vnode barrier before install re-exec;
- relaunch marker propagation before plugin registration and duplicate smoke
  suppression on relaunch;
- hosted smoke signed-feed trust configuration and relaunch diagnostics
  consolidation;
- non-macOS test seam for fake packagers without weakening production macOS
  validation.

The live privileged attempt also exposed and locally corrected the smoke-server
minimum-updater-version mismatch described above. No release credential or
secret value was written to the report.

Additional working-tree harness corrections validated locally were:

- native privileged metadata now accepts the `MacOSRuntimeCompile` smoke host;
- the v1 bootstrap feed uses a build-99 synthetic current version so the exact
  1.0.0+100 baseline can be staged;
- positive bootstrap/install no longer requires a prior approval-negative
  `approval.json` when background approval is already enabled;
- the native smoke runtime reports the current 3.1.1 updater version;
- privileged native install and recovery pass the current v1 version/build to
  the runtime, preserving the requested consumer version matrix;
- recovery evidence validates the fixed external smoke evidence parent instead
  of contradicting its own `/tmp/desktop_updater_macos_smoke/recovery.json`
  authority.

These are validation fixes only; this PR contains the local changes from this
validation run.

## Possible follow-up fixes

- Keep the macOS MethodChannel contract platform-specific: send only the
  canonical five-key install handoff on macOS and add a platform-aware
  contract assertion to the existing test rather than testing only the
  generic nine-key map.
- Make the privileged recovery fixture builder produce a signed product
  archive (`Distribution` plus `component.pkg`) whenever a preinstall gate is
  present; do not hand the protected installer a bare component archive.
- Keep the privileged smoke harness's current app version/build, minimum
  updater version, executable name, evidence parent, and artifact metadata
  bound to one explicit fixture matrix so a stale `2.x` default cannot appear
  as a successful `1.0.0+100` → `1.1.0+110` run.
- Rerun the notarized/stapled production helper and PKG lanes with the
  structured diagnostics hardening enabled, then archive the resulting JSONL
  and unified-log evidence alongside the existing state-machine invariant
  evidence.
- Make the Flutter-host privileged helper smoke use a documented generated
  `macos/FlutterFramework` package or a supported CI preparation step so its
  SwiftPM target can run on a clean checkout.
- Replace the Flutter smoke host's `FileManager.isWritableFile` protected-parent
  probe, or compare it with an explicit POSIX permission check. On this Mac the
  host reports `/Applications` writable while the normal user's POSIX write
  check is false, so the current guard prevents the privileged lane from
  reaching prepare/commit/recovery.
- Treat lower-version baseline installation as an explicit test fixture reset
  (receipt reset or isolated target), because macOS Installer does not
  downgrade an existing higher-version receipt implicitly.

## Remaining action

No administrator prompt is pending. The allowed installed app is restored and
verified as Flutter v2 `1.1.0+110`. The remaining production-smoke blockers are
the Flutter-host protected-parent probe mismatch described above and the
separate `macos/desktop_updater` SwiftPM package, which lacks the generated
`macos/FlutterFramework` sibling package. Keep Login Items & Extensions
background activity enabled; the missing-approval negative lane was
intentionally not produced by toggling the setting.

## Post-audit structured diagnostics hardening

The diagnostics gap described above was confirmed by the XHigh audit and
independently rechecked by the Ultra audit. The XHigh coding pass did not return
a patch, so the combined corrections were applied in the working tree and
verified locally.

The implemented helper diagnostics contract is now:

- MacHelperDiagnosticEvent is schema version 1, JSONL encoded, bounded to
  512 KiB, and contains only a validated transaction UUID plus bounded
  lifecycle/result codes.
- Root-owned helpers write to /Library/Logs/DesktopUpdater/events.jsonl.
  Unprivileged helpers use the current user's
  ~/Library/Logs/DesktopUpdater/events.jsonl. This makes the file fallback
  usable on supported macOS versions where the modern Logger API is
  unavailable; macOS 11+ also emits the same redacted event through unified
  logging with subsystem com.desktop-updater.install-helper and category
  diagnostics.
- JSONL append and sequence allocation are protected by an in-process lock and
  a non-blocking POSIX fcntl file lock. A contention failure drops only the
  file evidence; it cannot change install or recovery results.
- platformLog remains the safe unified-log/file route. The validated
  inheritedStream/stderr destination additionally receives the same redacted
  JSONL line; arbitrary caller-selected paths are never opened.
- One-shot and privileged helpers emit waiting for parent process only after
  commit acceptance and immediately before the real wait, then emit parent
  process exited on success or a bounded wait failure.
- PKG manager start now has explicit started/success/failure outcomes.
  Directory and PKG recovery emit rollback and cleanup start/success/failure
  boundaries. Persistent recovery owns the recovery summary, while nested
  directory recovery no longer duplicates the summary events.
- The app-owned Flutter diagnostics retain the relaunch, recovery-start,
  recovery-marker-clear, and recovered-stage-cleanup entries. Those are
  intentionally separate from helper-owned JSONL because the helper has no
  production relaunch or app-marker-clear call site.
- Raw installer stdout/stderr remains suppressed intentionally. Installer
  outcome and helper lifecycle codes are recorded without persisting command
  output that could contain credentials or unrelated user data.

Local verification after this hardening:

- swift test --package-path macos/install_helper: 151 passed, 6 skipped,
  0 failures.
- Diagnostics recorder contention/redaction tests: 3 passed.
- One-shot wait ordering and destination-routing test: 1 passed.
- Focused Flutter diagnostics/recovery/macOS contract suite: 96 passed.
- Full flutter test --no-pub: 818 passed, 4 skipped.
- flutter analyze --no-fatal-infos: exit 0, 651 info-level diagnostics,
  0 errors.
- Dart format check: passed, 0 files changed.
- Live unified-log observation on 2026-08-06 16:11 captured redacted
  backup success and recovery required events from the explicit recorder
  test under the expected subsystem/category predicate.

Evidence/source paths:

- macos/install_helper/Sources/DesktopUpdaterInstallHelper/MacHelperDiagnostics.swift
- macos/install_helper/Tests/DesktopUpdaterInstallHelperTests/MacHelperDiagnosticsTests.swift
- macos/install_helper/Tests/DesktopUpdaterInstallHelperTests/MacOneShotInstallServiceTests.swift
- macos/install_helper/Sources/DesktopUpdaterInstallHelper/MacFileTransaction.swift
- macos/install_helper/Sources/DesktopUpdaterInstallHelper/MacVerifiedInstallerTransaction.swift
- macos/install_helper/Sources/DesktopUpdaterInstallHelper/MacPersistentRecovery.swift
- macos/install_helper/Sources/DesktopUpdaterInstallHelper/MacRecoveryService.swift
- macos/install_helper/Sources/DesktopUpdaterInstallHelper/MacOneShotWire.swift
- macos/install_helper/Sources/DesktopUpdaterInstallHelper/MacPrivilegeService.swift

This is local implementation and contract evidence. The post-patch rerun and
its production-readiness decision are recorded below; the earlier statement
that the production helper/PKG E2E had not been rerun is historical and is
superseded only for the lanes explicitly listed there.

## Post-patch notarized/stapled production E2E rerun

Run date: 2026-08-06. This rerun used the current checkout (`fix/macos-production-smoke-e2e`,
HEAD `b603b31`) and root package `desktop_updater` 3.1.1. The consumer matrix
remained exactly `1.0.0+100` → `1.1.0+110` with bundle ID
`com.example.desktopUpdaterSmoke`; the only notary profile used was
`general-notary`. No credential, certificate identity, fingerprint, or
submission secret was written to this report.

### Production artifact lanes

- `doctor`: `verified locally`. Developer ID Application and Developer ID
  Installer identities were discovered without recording their values. The
  smoke tool's default keychain lookup accepted `general-notary` and returned
  accepted Apple submission history. An initial sandboxed probe against
  `$HOME/Library/Keychains/login.keychain-db` did not find a password item,
  but the required sandbox-external recheck found the Developer ID identities
  and `general-notary` history successfully; no alternate profile was used.
  Evidence: `reports/macos-production-smoke/doctor-2026-08-06T160520.129930Z.log`.
- v1 notarized/stapled app build: `verified locally` during the app-update
  attempt. Apple submission was `Accepted`; `codesign --verify --deep
  --strict`, stapler staple/validate, and the embedded helper signature checks
  passed before the lane reached the existing root-owned app replacement.
- `dmg-first-install`: `verified locally`. v1 app and DMG were newly built,
  notarized, stapled, assessed as `Notarized Developer ID`, mounted read-only,
  contained-app trust checked, and detached. Evidence:
  `reports/macos-production-smoke/dmg-first-install-2026-08-06T161413.475217Z.log`.
- `pkg-artifact`: `verified locally`. Current v2 `1.1.0+110` app and PKG were
  newly built with the logger patch, notarized, stapled, accepted by
  `pkgutil --check-signature` and `spctl --assess --type install`, and passed
  stapler validation. Evidence:
  `reports/macos-production-smoke/pkg-artifact-2026-08-06T162159.296997Z.log`.
- `app-update`: `verified locally`. The notarized v1 app was installed at the
  smoke target, the real Flutter app performed the v1→v2 direct handoff, the
  app exited and relaunched, the v2 sentinel was observed, and post-update
  codesign, Gatekeeper, and stapler checks passed. Evidence:
  `reports/macos-production-smoke/app-update-2026-08-06T161009.691082Z.log`.
- `pkg-install-verify`: `verified locally`. The admin-approved v1 reset,
  notarized v2 PKG install, receipt, sentinel, installed-app codesign,
  Gatekeeper, and stapler checks all passed. Evidence:
  `reports/macos-production-smoke/pkg-install-verify-2026-08-06T162421.007212Z.log`.
- A visible Installer GUI attempt for the current v1 baseline PKG reached
  `Install Succeeded` at 18:47:18 local time, but it did not produce a valid
  v1 baseline: the target app remained `1.1.0+110`, while the receipt was
  downgraded to package version `1.0.0`. This is recorded as an unexpected
  downgrade/install-state failure. A later retry reproduced the underlying
  PackageKit condition in `/var/log/install.log`: the v1 component was skipped
  because the higher `1.1.0-110.0.0` bundle was still present in the generated
  Flutter build output, while the receipt was written anyway. Temporarily
  moving that generated build app allowed the notarized v1 PKG to install as a
  real `1.0.0+100` root-owned baseline; the generated build output was restored
  immediately afterward.
- A second visible Installer GUI attempt for the current v2 PKG reached
  `Install Succeeded` at 18:57:11 local time after administrator approval.
  The target was restricted to `/Applications/Desktop Updater Smoke.app`.
  Post-install checks confirmed app version `1.1.0`, build `110`, package
  receipt version `1.1.0`, root ownership, and the smoke sentinel. The
  Installer receipt therefore proves the privileged install action completed.
- The first post-install trust recheck was run inside the sandbox and was a
  false negative caused by sandboxed keychain access (`0 valid identities`
  and a notarytool keychain error). The required sandbox-external recheck then
  passed: Developer ID identities were present, `general-notary` history
  exited successfully, app codesign and execute assessment exited 0,
  `pkgutil --check-signature` reported a signed Apple-issued Developer ID
  Installer package, PKG install assessment exited 0, and stapler validation
  exited 0 for both app and PKG. The v2 installed artifact is therefore
  `verified locally` for trust in the sandbox-external environment.
- `move-to-applications`: `verified locally`. The notarized v1 DMG was mounted
  read-only, copied to the exact smoke target, relaunched, trust-checked, and
  detached. Evidence:
  `reports/macos-production-smoke/move-to-applications-2026-08-06T161704.024797Z.log`.
- `dmg-update`: `verified locally`. The notarized v1→v2 DMG hosted update
  passed DMG SHA-256 binding, primary-signature/Gatekeeper assessment,
  read-only mount/detach, contained-app trust, real Flutter handoff, v2
  sentinel, and relaunch checks. Evidence:
  `reports/macos-production-smoke/dmg-update-2026-08-06T161721.420988Z.log`.

Current temporary artifact evidence:

- `/private/tmp/desktop_updater_macos_smoke/apps/1.0.0/Desktop Updater Smoke.app`
- `/private/tmp/desktop_updater_macos_smoke/apps/1.1.0/Desktop Updater Smoke.app`
- `/private/tmp/desktop_updater_macos_smoke/Desktop Updater Smoke-v1-current.pkg`
- `/private/tmp/desktop_updater_macos_smoke/Desktop Updater Smoke.pkg`
- `/private/tmp/desktop_updater_macos_smoke/v1-pkg-signature.log`
- `/private/tmp/desktop_updater_macos_smoke/v1-pkg-gatekeeper.log`
- `/private/tmp/desktop_updater_macos_smoke/v1-stapler-validate.log`
- `/private/tmp/desktop_updater_macos_smoke/direct-app-smoke-diagnostics.jsonl`
- `/private/tmp/desktop_updater_macos_smoke/hosted-smoke-diagnostics-dmg.jsonl`

### Helper, recovery, and diagnostics lanes

- Complete `swift test --package-path macos/install_helper`: `verified
  locally`, 150 tests passed, 6 skipped, 0 failures after the diagnostics
  patch.
- `dart run tool/macos_install_helper_smoke.dart --mode unprivileged`:
  `verified locally` outside the sandbox after the production lanes; canonical
  protocol parsing and recoverable swap passed.
- Flutter-host privileged helper: `blocked` at registration even though the
  Login Items & Extensions background approval was enabled and the service
  reported `enabled`. The signed app/helper trust checks passed, but the host
  emitted `targetParentWritable: true`; the smoke contract requires `false`
  for protected `/Applications`. Repeat evidence:
  `/private/tmp/desktop_updater_macos_smoke/flutter-smappservice-privileged-logger-rerun.log`;
  the fresh sandbox-external run reproduced the same registration result.
  POSIX inspection still reports the normal user's `/Applications` access as
  non-writable, so this remains a harness/API probe mismatch rather than
  successful privileged recovery evidence. No background approval setting was
  toggled during this rerun.
- The privileged PKG smoke parser was checked against the current Flutter
  smoke artifacts using canonical `/private/tmp` paths. The first attempt was
  correctly rejected as `directory-symlink-rejected` for `/tmp`; the canonical
  retry stopped before mutation with `bundle-metadata-invalid`. The recovery
  parser, after a real v1 baseline was established, stopped before the
  transaction with `bundle-authority-mismatch`: both tools require the
  purpose-built `MacOSRuntimeCompile` host, while the real Flutter smoke app
  contains `desktop_updater_example`. These are not counted as Flutter PKG
  recovery passes, and no native fixture was substituted silently.
- The structured diagnostics file at
  `/Users/marlonjd/Library/Logs/DesktopUpdater/events.jsonl` contained 556
  bounded JSONL events from the local recorder/test/helper activity. It
  includes helper scheduled (8), backup start/success (23/17), move
  start/success (17/12), cleanup start/success (45/40), manager started (26),
  recovery required/start/success (24/50/44), rollback start/success (20/20),
  verification pending/success (7/7), and parent/waiting events. The separate
  direct and hosted Flutter diagnostics files recorded checking, downloading,
  installing, and relaunch events. The structured helper file has no literal
  `recovery marker cleared` event; marker cleanup was only inferred from the
  successful local recovery test records. The sensitive-pattern scan found no
  private-key, password, API-key, token, Apple-credential, or
  authorization-secret matches. Because the root helper runtime sequence did
  not pass registration, this user-owned file is recorder/test evidence, not
  proof of a root-owned production helper log.

### Production-readiness decision

Full post-logger `production-ready`: **no — blocked**.

The logger implementation, native tests, redaction/ordering guarantees, and
notarized/stapled app/DMG/PKG trust gates are `verified locally`, including the
sandbox-external post-install v2 trust recheck. Direct app update, DMG
first-install/move/update, and PKG install/update are now `verified locally`.
The required production helper/recovery runtime closure is still not
`production-ready`: the Flutter privileged host remains blocked by the
protected-parent probe mismatch, the privileged/recovery smoke tools reject
the real Flutter host contract, and the requested literal recovery-marker log
event is absent. The missing-background-approval negative lane remains
intentionally `not run`; the setting was not toggled.

The generated `example/pubspec.lock` changes caused by the Flutter build were
restored. No commit, push, branch operation, or GitHub operation was performed
for this rerun.

## Latest continuation: authenticated privileged-target correction

Run date: 2026-08-07. Checkout remained on `fix/macos-production-smoke-e2e` at
`b603b315465824a416d635ca12dbd8f4addf0494`; the root updater package is
`desktop_updater` 3.1.1. The consumer matrix remains exactly
`1.0.0+100` -> `1.1.0+110`; the only configured notary profile is
`general-notary`. No credential value, signing identity value, fingerprint,
private key, password, token, or Apple secret was written here.

### Harness correction and verification

The privileged PKG smoke tool was corrected so `_runRuntime` launches the
actual `/Applications/Desktop Updater Smoke.app` target instead of launching
the temporary `recovery-app` fixture while claiming the protected target path.
The previous arrangement caused the helper's caller executable-path and
process-identity authorization to reject a valid-looking request before the
real installer handoff. Bootstrap now also binds its current version/build to
the inspected installed target rather than a fabricated v1 value.

The existing privileged smoke contract suite passed 11 tests after this
change. The complete requested focused Flutter/macOS contract invocation then
passed 56 tests, including method-channel, Flutter 3.0 compatibility,
macOS source layout, native helper layout, privileged PKG, and recovery smoke
contracts. `git diff --check` passed. The generated `example/pubspec.lock`
change caused by the build was restored.

### Corrected real-target privileged attempt

The corrected run used the real installed target and the existing v1/v2 PKG
fixtures. Baseline verification passed for the target app and receipt
`1.0.0+100`. The target remained `1.0.0+100` after the attempt. The app-owned
diagnostics recorded `checking`, `downloading`, `installing`, and
`InstallError` with `recoveryRequired: true`; no `/usr/sbin/installer` process
was observed, and the owned staging directory plus `pending-install.json`
remained for recovery. This run is `blocked`, not a privileged install pass.

Evidence:

- `/private/tmp/desktop_updater_macos_smoke/privileged-e2e-root-v311-real-target/controller-smoke-diagnostics.log`
- `/private/tmp/desktop_updater_macos_smoke/privileged-e2e-root-v311-real-target/pending-install.json`
- `/private/tmp/desktop_updater_macos_smoke/privileged-e2e-root-v311-real-target/staging/`
- unified-log predicate for `DesktopUpdaterInstallHelper` on the smoke
  transaction window

The unified log showed authenticated XPC traffic from the real
`/Applications` process, but the installed v1 helper did not expose a safe
reason code for the authorization rejection. The existing installed v1
host/helper were built before the latest source changes; therefore this result
does not prove the current source helper is production-ready.

### Source-current diagnostic fixture

A temporary source-current v1 app (`1.0.0+100`) was built, Developer ID
signed, and packaged as a deliberately non-notarized smoke-only PKG:

- `/private/tmp/desktop_updater_macos_smoke/source-current-v1-fixture-1/Desktop Updater Smoke.app`
- `/private/tmp/desktop_updater_macos_smoke/source-current-v1-fixture-1/Desktop Updater Smoke-source-current-v1.pkg`

The app codesign verification passed and the package was signed by an Apple
Developer ID Installer certificate, but no notarization or stapling was
performed. macOS Installer was opened for the authorized smoke target only;
the administrator authorization dialog remained pending, and the target was
still v1 at the last read. Computer Use timed out while the SecurityAgent
dialog was modal, so no password was entered and no background/login approval
setting was changed. This fixture must not be reported as a notarized or
production artifact.

The latest sandbox-external `notarytool history` check did not find a usable
`general-notary` keychain item. No alternate profile was used and no fake
credential was created. Existing previously accepted artifacts remain
historical trust evidence only; a new source-current notarized v1 fixture
cannot be produced until the profile is available.

Production-readiness remains **blocked** pending completion of the visible
admin-approved source-current v1 install and a fresh v1 -> v2 privileged
PKG/recovery run using matching current binaries. Background activity approval
was left enabled and was not toggled. No commit, push, branch operation, or
GitHub operation was performed.

## Latest continuation: authenticated v1 baseline and current privileged boundary

Run date: 2026-08-07. The checkout remained on
`fix/macos-production-smoke-e2e` at `b603b315465824a416d635ca12dbd8f4addf0494`.
The root package version is `desktop_updater` 3.1.1 and the consumer matrix is
still exactly `1.0.0+100` -> `1.1.0+110`. The only permitted notary profile is
`general-notary`. No password, private key, token, Apple credential, `.env`
secret, or keychain secret was created or recorded.

### Credential/profile boundary

The latest sandbox-external check was:

`xcrun notarytool history --keychain-profile general-notary --keychain /Users/marlonjd/Library/Keychains/login.keychain-db --output-format json`

It returned `No Keychain password item found for profile: general-notary`.
No alternate profile was used and no credential was fabricated. Earlier
accepted artifacts remain historical trust evidence; a new source-current
notarized v1 artifact cannot be produced until this exact profile is available
to `notarytool` in the login keychain.

The administrator password was entered by the user in macOS Installer prompts
when required. It was not accepted by the agent, stored in a `.env` file, put
in a script, or read from the keychain for automated typing. The temporary
helper-refresh PKG was only a local test mechanism and is not a production
artifact.

### Authenticated notarized v1 baseline

The previously notarized/stapled v1 package was installed into the exact smoke
target:

- Package: `/private/tmp/desktop_updater_macos_smoke/Desktop Updater Smoke-v1.pkg`
- Payload/source app: `/private/tmp/desktop_updater_macos_smoke/pkg-root-v1.yJuEKF/Desktop Updater Smoke.app`
- Gatekeeper app assessment: `accepted`, source `Notarized Developer ID`
- App stapler validation: `The validate action worked!`
- Target after installation: `1.0.0+100`
- Receipt after installation: `com.example.desktopUpdaterSmoke.pkg`, version `1.0.0`

The helper-refresh package was then authorized for the smoke target only so
launchd reloaded the helper from the installed v1 bundle:

- `/private/tmp/desktop_updater_macos_smoke/helper-refresh-fixture/Desktop Updater Smoke Helper Refresh v1.pkg`
- Receipt: `com.example.desktopUpdaterSmoke.helper-refresh-v1`
- New helper launchd PID was observed: `88394`

### Privileged PKG result with notarized v1

The corrected privileged smoke harness first verified the notarized v1
baseline, then launched the real `/Applications/Desktop Updater Smoke.app`
target with the notarized/stapled v2 package. The baseline phase passed, but
the v2 handoff stopped with the app marker:

`InstallError: Unable to confirm update installation handoff.`

The transaction was marked `recoveryRequired`; no `/usr/sbin/installer`
process or `/Applications` provider journal was observed, the target stayed
at `1.0.0+100`, and the owned staging/pending files remained in the temporary
smoke root. The run ended as `runtime-launch-timeout`, not as a privileged
install pass.

Evidence:

- `/private/tmp/desktop_updater_macos_smoke/privileged-e2e-root-v311-notarized-v1/controller-smoke.marker`
- `/private/tmp/desktop_updater_macos_smoke/privileged-e2e-root-v311-notarized-v1/controller-smoke-diagnostics.log`
- `/private/tmp/desktop_updater_macos_smoke/privileged-e2e-root-v311-notarized-v1/pending-install.json`
- `/private/tmp/desktop_updater_macos_smoke/privileged-e2e-root-v311-notarized-v1/staging/`

The v1 package’s helper is an older notarized fixture and does not provide the
current fixed installer-manager runtime closure. This separates the result
from the current-source helper: the current-source v1 diagnostic fixture was
Developer ID signed but intentionally non-notarized and was correctly rejected
by the production trust gate as `app-gatekeeper-rejected`.

### Recovery result

Recovery smoke was run against the exact v1 target and the notarized v2 PKG
using a fresh root:

- `/private/tmp/desktop-updater-pkg-recovery-v311-authenticated-v1/controller-smoke.marker`
- `/private/tmp/desktop-updater-pkg-recovery-v311-authenticated-v1/controller-smoke-diagnostics.log`
- `/private/tmp/desktop-updater-pkg-recovery-v311-authenticated-v1/pending-install.json`
- `/private/tmp/desktop-updater-pkg-recovery-v311-authenticated-v1/staging/`

The app emitted `recoveryRequired`, but the old notarized v1 helper did not
complete the current manager handoff. The smoke tool ended with
`runtime-handoff-failed`. The hung smoke host was terminated by its exact PID;
the target remained `1.0.0+100`, no `/Applications` provider journal or target
lock remained, and only temporary evidence/staging files were left.
This lane is `blocked`, not a recovery pass; prepare/commit/crash/recover/
rollback/cleanup completion was not claimed.

### Non-admin helper result

`dart run tool/macos_install_helper_smoke.dart --mode unprivileged` passed
outside the sandbox with `canonicalProtocolParsed: true` and
`recoverableSwapExecuted: true`. This is a verified unprivileged native helper
result and does not substitute for privileged production recovery evidence.

Production-readiness remains **blocked**. The direct app, DMG, PKG trust lanes,
method-channel negative case, focused tests, and unprivileged helper smoke are
verified locally, but a fresh source-matching notarized v1 -> v2 privileged
install and recovery closure is still unavailable because the exact
`general-notary` profile is missing and the existing notarized v1 helper is an
older fixture. No commit, push, branch operation, or GitHub operation was
performed.

### Sandbox-external notary profile recheck

The profile claim was rechecked again outside the filesystem sandbox on
2026-08-07 using the exact login keychain path. Results were:

- `xcrun notarytool history --keychain-profile general-notary --keychain /Users/marlonjd/Library/Keychains/login.keychain-db --output-format json`: exit 69, `No Keychain password item found for profile: general-notary`.
- `security list-keychains -d user`: only `/Users/marlonjd/Library/Keychains/login.keychain-db` was in the user search list.
- `security find-generic-password -a general-notary -s com.apple.gke.notary.tool /Users/marlonjd/Library/Keychains/login.keychain-db`: item not found.
- The service-only metadata lookup for `com.apple.gke.notary.tool` also returned item not found.

This confirms the blocker is not caused by the Codex filesystem sandbox. The
required `general-notary` keychain item is absent or stored under a different
keychain/profile name; no alternate profile was used and no secret was read.

### Operational note: notarytool keychain invocation

The previous conclusion about the profile was corrected on 2026-08-07. A
sandbox-external invocation without an explicit keychain path succeeded and
returned accepted Apple submission history:

`xcrun notarytool history --keychain-profile general-notary --output-format json`

The same invocation with an explicit
`--keychain /Users/marlonjd/Library/Keychains/login.keychain-db` incorrectly
returned `No Keychain password item found`. For this Mac mini, use the
`general-notary` profile through the keychain search list and do not add the
explicit login-keychain path. No credential value was printed or stored in the
repository.

### 2026-08-07 continuation: logger rejection evidence and source-current artifact

The source-current logger change now records a bounded `request rejected`
diagnostic event when the privileged XPC server rejects a request before it can
create a transaction journal. The event contains only the operation name and a
sanitized stable error code; request payloads, paths, credentials, and secret
values are not recorded. This closes the previous observability gap where the
client exposed only `InstallError` with `recoveryRequired` while the helper
closed the XPC connection without writing a reason.

Verification completed:

- `swift test --package-path macos/install_helper`: 151 tests, 6 skipped, 0
  failures.
- `general-notary` was verified outside the sandbox; recent submissions were
  accepted.
- A source-current smoke app and PKG containing the logger patch were built,
  Developer ID signed, notarized with `general-notary`, stapled, and passed
  `pkgutil --check-signature`, `spctl --assess --type install`, and `stapler
  validate`.
- Artifact evidence: `reports/macos-production-smoke/pkg-artifact-2026-08-07T051310.165666Z.log`.

The source-current v1 replacement in `/Applications/Desktop Updater Smoke.app`
has not yet completed: the smoke-only removal step is waiting at a visible macOS
administrator password prompt. The fresh source-matching privileged v1 -> v2
install/recovery run therefore remains `blocked`; it is not marked
`production-ready`. Background activity approval remains enabled and was not
toggled.

### 2026-08-07 continuation: current-source privileged install and recovery closure

The previous paragraph is historical. After the user completed the visible
administrator prompts, the exact smoke target was reset to a root-owned,
notarized v1 baseline and the v1 receipt was recreated explicitly. The
administrator password was entered by the user; it was not observed, stored,
or passed through an environment variable.

Current identity and version separation:

- branch: `fix/macos-production-smoke-e2e` (no branch operation was performed)
- HEAD: `b603b315465824a416d635ca12dbd8f4addf0494`
- root package: `desktop_updater` 3.1.1
- historical PR #67 target: `desktop_updater` 3.1.0
- consumer matrix: `1.0.0+100` -> `1.1.0+110`
- bundle ID: `com.example.desktopUpdaterSmoke`
- installed target: `/Applications/Desktop Updater Smoke.app`
- notary profile: `general-notary` only

`general-notary` was used without printing or recording credential material.
Developer ID Application and Developer ID Installer identities were available
to the sandbox-external signing/notarization commands; identity subjects and
fingerprints are intentionally absent from this report.

#### Current-source notarized/stapled privileged PKG

Status: `verified locally`.

The current-source v2 recovery-gated product package was accepted by
`general-notary`, stapled, and passed `pkgutil --check-signature`,
`spctl --assess --type install`, and `xcrun stapler validate`. The privileged
smoke tool completed the v1 -> v2 install and returned:

```json
{"status":"verified locally","installed":"1.1.0+110"}
```

Final target checks passed: the app is `1.1.0+110`, receipt
`com.example.desktopUpdaterSmoke.pkg` is version `1.1.0`, the app and helper
are `root:wheel`, and the helper launchd job is running. The exact v1 installer
fixture still exposes a PackageKit downgrade quirk: `installer` can report
success and write a v1 receipt without replacing the higher-version app
payload. The baseline was therefore established by the explicit smoke-only
v1 app copy plus the receipt install, and the anomaly is retained as evidence
rather than being reported as a normal downgrade success.

Evidence:

- `/private/tmp/desktop_updater_macos_smoke/current-recovery-pkg.CyGA8E/Desktop Updater Smoke.pkg`
- `/private/tmp/desktop_updater_macos_smoke/privileged-recovery-gated-evidence-1/elevation.json`
- `/private/tmp/desktop_updater_macos_smoke/privileged-recovery-gated-root-1/controller-smoke-diagnostics.log`
- `/private/tmp/desktop_updater_macos_smoke/final-trust-checks-20260807/`

#### Current-source recovery E2E

Status: `verified locally`.

`tool/macos_privileged_pkg_recovery_smoke.dart` completed the complete
recovery-required path against the real `/Applications/Desktop Updater Smoke.app`:

- prepare and commit accepted;
- installer manager observed after the fixed preinstall gate;
- live manager and owned stage observed;
- helper termination scheduled after `managerStarted`;
- `recoveryRequired` query and recovery succeeded;
- replacement helper identity verified;
- manager and stage remained unchanged while recovery was active;
- release and terminal `completed/succeeded` state verified;
- final target and receipt were v2 `1.1.0+110`;
- staging, provider journal, transaction lock, and ready/release markers were
  absent after completion;
- root ownership, helper identity, signatures, and active launch daemon were
  verified.

The machine-wide safe event export for this run contains no raw payload or
credential fields:

- `/private/tmp/desktop_updater_macos_smoke/safe-events-recovery-e2e.tsv`
- `/tmp/desktop_updater_macos_smoke/recovery.json`
- `/private/tmp/desktop-updater-pkg-recovery-e2e-3/controller-smoke-diagnostics.log`

The final recovery evidence is:

```json
{"status":"verified locally","finalState":"completed"}
```

The post-patch helper event stream included `helper scheduled`, staging-path
validation, parent wait/exit, manager start, verification pending/success,
recovery start/success, cleanup start/success, and recovery-marker-cleared
events. The same safe export recorded the earlier controlled
`prepareInstall.targetBusy` rejection and one earlier recovery failure from a
stale transaction; the final recovery run succeeded and left no owned marker.
The PKG path does not perform directory backup/move operations, so those event
names are covered by the directory/recoverable-swap helper tests and earlier
helper activity, not claimed as events from this PKG transaction. A redaction
scan of the exported fields found no private-key, password, API-key, token,
Apple-credential, or authorization-secret pattern.

#### Final artifact trust recheck

Status: `verified locally`.

The final sandbox-external recheck passed all of the following:

- installed v2 app codesign, Gatekeeper execute assessment, and stapler;
- normal current-source v2 PKG signature, Gatekeeper install assessment, and
  stapler;
- recovery-gated v2 PKG signature, Gatekeeper install assessment, and stapler;
- hosted notarized DMG primary-signature assessment and stapler;
- DMG read-only attach and detach, with no mounted smoke volume left behind.

Evidence: `/private/tmp/desktop_updater_macos_smoke/final-trust-checks-20260807/`.

#### Remaining boundaries and production-readiness decision

The native current-source privileged PKG and recovery boundary is now
`verified locally`. Direct app update, DMG first-install/move/update, normal
PKG install/update, no-notary negatives, PR #67 reproduction/fix, unprivileged
helper, diagnostics contracts, and the requested focused/full test suites are
also recorded above as `verified locally`.

At the end of that live E2E run, the complete Flutter-host privileged lane was
`blocked` at registration: the Login Items & Extensions background approval
was enabled, but the Flutter host reported `targetParentWritable: true` while
the then-current smoke contract required `false`. The subsequent focused
implementation checkpoint below replaces that unstable source-level contract;
the live lane has not yet been rerun against the replacement. The
missing-background-approval negative lane was not run because the approval was
intentionally kept enabled and never toggled off.

An earlier failed recovery also left only the exact smoke target's orphan
`.commit` and `.lock` markers after reporting completion without a journal; the
markers were removed explicitly and the final current-source recovery run
verified clean completion. The focused implementation checkpoint below adds
fail-closed journal-less stale-marker cleanup and regression coverage; that
new path has not yet been exercised in production E2E.

No commit, push, branch operation, or GitHub operation was performed.

## 2026-08-10 final superseding production E2E certification

This section supersedes every earlier checkpoint in this report that says any
of the following: `general-notary` is missing, the final PKG signature is
invalid, the background-approval-off negative was not run, the privileged
host is blocked by `targetParentWritable`, the installed target remains v1,
the dedicated notarized recovery lane was not run, or the structured logger
was not replayed through a production helper/PKG. Those were accurate interim
states, but they are not the final state of this validation.

### Final scope and release boundary

| Item | Final value |
| --- | --- |
| branch | `fix/macos-production-smoke-e2e` |
| HEAD | `b603b31 fix(macos): stabilize updater relaunch and production smoke` |
| historical PR #67 package scope | `desktop_updater` 3.1.0 |
| current checked-in package version | `desktop_updater` 3.1.2 release candidate |
| release status at this evidence cut | version surfaces synchronized; commit, tag, and publication pending |
| consumer smoke v1 | 1.0.0+100 |
| consumer smoke v2 | 1.1.0+110 |
| installed bundle | `/Applications/Desktop Updater Smoke.app` only |
| bundle ID | `com.example.desktopUpdaterSmoke` |
| notary profile | `general-notary` only |

The updater package version and consumer application versions remained
separate throughout the run. The live installed smoke app now reports
`1.1.0+110`; its receipt `com.example.desktopUpdaterSmoke.pkg` reports
`1.1.0`; and the bundle is owned by `root:wheel`. No unrelated application in
`/Applications` was touched.

The existing Developer ID Application and Developer ID Installer identities
and the existing `general-notary` profile were present and usable. No
credential value, certificate identity/fingerprint, private key, password,
API key, token, authorization secret, Apple credential, or release seed is
included in this report. No synthetic credential was created.

On this host, notarytool must use default keychain resolution:

```text
--keychain-profile general-notary
```

Adding an explicit `--keychain` path can produce a false “profile not found”
result even though the profile is available. Likewise, macOS trust commands
run inside the restricted process sandbox can produce false `invalid
signature`, `internal error in Code Signing subsystem`, or LaunchServices
errors. The final trust decision below comes from sandbox-external
`codesign`, `spctl`, `stapler`, and `pkgutil` execution. All of those checks
passed. The sandbox-only false negatives are not artifact failures.

`flutter pub get` generated a ten-line dependency-resolution change in
`example/pubspec.lock`; it was generated-only and restored to the starting
tracked content. Full testing also generated the fixture-local .NET `bin/`
and `obj/` directories; both were inspected and removed. No generated
dependency/build output remains in the Git status.

### Final artifact and update lanes

| Lane | Final result |
| --- | --- |
| Developer ID signed, non-notarized app | `verified locally` expected Gatekeeper/stapler rejection; codesign passed |
| Developer ID signed, non-notarized DMG | `verified locally` expected Gatekeeper/stapler rejection; read-only attach/detach passed |
| Developer ID Installer signed, non-notarized PKG | `verified locally` expected Gatekeeper/stapler rejection; package signature was structurally valid |
| Protected no-notary handoff | `verified locally` expected fail-closed rejection; v1 was preserved |
| Notarized/stapled v1 and v2 apps | `verified locally` |
| Direct Flutter app update 1.0.0+100 → 1.1.0+110 | `verified locally` |
| Notarized/stapled DMG first install and move | `verified locally` |
| Hosted DMG update 1.0.0+100 → 1.1.0+110 | `verified locally` |
| Standard signed/notarized/stapled PKG artifact | `verified locally` |
| Standard PKG install, receipt, sentinel, and installed-app trust | `verified locally` |
| Native privileged PKG update | `verified locally` |
| Dedicated forced-termination PKG recovery | `verified locally` |
| Background approval OFF expected rejection | `verified locally` |
| Background approval ON positive helper/update lane | `verified locally` |

The current live v2 app passed sandbox-external
`codesign --verify --deep --strict`, Gatekeeper execute assessment, and
stapler validation. The final recovery PKG passed sandbox-external
`pkgutil --check-signature`, Gatekeeper install assessment, and stapler
validation. The earlier interim `pkgutil --check-signature: invalid
signature` statement is therefore superseded.

The final fixed packages explicitly make the app bundle non-relocatable and
disable PackageKit's version-based skip:

```text
BundleIsRelocatable=false
BundleIsVersionChecked=false
BundleHasStrictIdentifier=true
BundleOverwriteAction=upgrade
```

This fixes the real PackageKit failure where a v1 baseline package could be
relocated or skipped because a v2 bundle was discoverable in the repository,
allowing a receipt change without the intended target replacement.

Final artifact evidence:

- `/tmp/desktop_updater_macos_smoke/apps/1.0.0/Desktop Updater Smoke.app`
- `/tmp/desktop_updater_macos_smoke/apps/1.1.0/Desktop Updater Smoke.app`
- `/tmp/desktop_updater_macos_smoke/Desktop Updater Smoke.dmg`
- `/tmp/desktop_updater_macos_smoke/Desktop Updater Smoke.pkg`
- `/private/tmp/desktop-updater-v1-fixed.LZp0QW/Desktop Updater Smoke v1 fixed.pkg`
- `/private/tmp/desktop-updater-recovery-fixed.FbsBZI/Desktop Updater Smoke Recovery fixed.pkg`
- `/private/tmp/desktop-updater-pkg-artifact-current.log`
- `/private/tmp/desktop-updater-pkg-artifact-2026-08-10T055116.160158Z.log`
- `/private/tmp/desktop-updater-pkg-install-verify-current.log`
- `/private/tmp/desktop-updater-pkg-install-verify-2026-08-10T055902.569513Z.log`

### PR #67 exact payload result

PR #67 remains `confirmed locally` against the original 3.1.0 behavior. The
old Dart macOS handoff sent nine keys:

```text
stagingPath
expectedPackageId
updateVersion
updateBuildNumber
platform
channel
expectedArtifactSha256
stageProvenanceSha256
transactionId
```

The native macOS contract accepts exactly five:

```text
stagingPath
expectedPackageId
expectedArtifactSha256
stageProvenanceSha256
transactionId
```

The four invalid extras were `updateVersion`, `updateBuildNumber`, `platform`,
and `channel`. The exact historical real-Flutter failure was:

```text
code: InvalidArguments
message: installUpdate requires the canonical signed handoff payload.
```

The old `test/desktop_updater_method_channel_test.dart` coverage asserted a
generic full nine-key payload and did not model the native macOS exact-key
contract, which is why it missed the defect. Current source sends the
canonical five-key macOS payload. The final real Flutter direct-app and hosted
DMG updates completed without `InvalidArguments`.

### Privileged helper and recovery closure

The final privileged direct-app helper lane completed all of the following:

- registered and exercised the approved background service;
- prepared a durable transaction without cancelling it;
- forcibly terminated the root helper daemon;
- observed a replacement helper process;
- queried the transaction as `recoveryRequired`;
- recovered the old target with a terminal `rolledBack/succeeded` result;
- accepted a new authorized commit;
- completed the swap to 1.1.0+110;
- verified root ownership, authenticated XPC, helper provenance, relaunch,
  and final app trust.

Evidence: `/private/tmp/desktop-updater-install-helper-privileged-current.log`.

The final native privileged PKG lane installed v2 over the notarized v1
baseline and verified receipt identity/version, the v2 sentinel, root
ownership, app/helper signatures, hardened runtime, Gatekeeper, stapling,
launch-daemon activity, installer authority, and removal of staging and
provider-journal residue.

Evidence:

- `/private/tmp/desktop-updater-privileged-pkg-install-final2.log`
- `/private/tmp/desktop-updater-privileged-pkg-evidence-final2.XFMjoA/elevation.json`
- `/private/tmp/desktop-updater-privileged-pkg-smoke-final2.w9j0FQ`

The dedicated recovery-only PKG lane then forced termination after the
installer manager had started. It verified that the manager was live, staging
was retained while owned by that manager, no concurrent mutation occurred,
the helper was replaced, and recovery reached `completed` with
`verifiedOutcome=newTarget`. The final target and receipt were 1.1.0+110 and
1.1.0 respectively; target ownership was `root:wheel`; app/helper trust and
launch-daemon state passed; and the transaction journal, staging directory,
ready marker, and release marker were cleaned.

Evidence:

- `/private/tmp/desktop-updater-privileged-pkg-recovery-rerun.log`
- `/tmp/desktop_updater_macos_smoke/recovery.json`
- `/private/tmp/desktop-updater-pkg-recovery-rerun.Ju1eYx`

The earlier `targetParentWritable` block was a harness authority-probe defect.
The installed helper probe now receives the exact target and native smoke
environment, while terminal recovery is driven by the installed
`/Applications` runtime host rather than a `/tmp` recovery fixture. A bounded
eight-attempt/two-second refresh handles the real SMAppService endpoint
activation race after package replacement. These corrections were exercised
by the successful final lanes; they are not unverified proposals.

Background activity was deliberately switched OFF once and produced the
expected typed `PrivilegedHelperApprovalRequired` rejection with exit 75. It
was restored ON, and the positive privileged lanes then passed. The setting is
left ON at final handoff.

Approval evidence:

- `/private/tmp/desktop_updater_macos_smoke/final-current/privileged-pkg-evidence/approval.json`
- `/private/tmp/desktop_updater_macos_smoke/final-current/privileged-pkg-evidence/approval-final.log`

### Structured logger and diagnostics closure

The production helper/PKG replay now verifies the detailed logger rather than
only the Flutter controller phases. The root platform log is
`/Library/Logs/DesktopUpdater/events.jsonl`; its directory is `root:wheel`
mode 0700 and the file is `root:wheel` mode 0600. The redacted audit copy at
`/private/tmp/desktop-updater-helper-events-current.jsonl` contains 789 valid,
closed JSONL records using schema version 1. The optional `transactionId` is
omitted when absent rather than serialized as an invalid placeholder.

Observed structured events include:

- `helper scheduled`;
- `verification pending` and `verification success`;
- `staging path validation`;
- `waiting for parent process` and `parent process exited`;
- `manager started`;
- `backup start` and `backup success`;
- `move start` and `move success`;
- `cleanup start` and `cleanup success`;
- `recovery start`, `recovery failure`, and `recovery success`;
- `rollback start`, `rollback failure`, and `rollback success`;
- `recovery marker cleared`;
- fail-closed `request rejected` records.

The corresponding Flutter-host diagnostics contain `checking`,
`downloading`, and `installing`:

- `/private/tmp/desktop-updater-privileged-pkg-smoke-final2.w9j0FQ/controller-smoke-diagnostics.log`
- `/private/tmp/desktop-updater-pkg-recovery-rerun.Ju1eYx/controller-smoke-diagnostics.log`

A final secret-pattern scan across the helper JSONL, app diagnostics,
privileged helper/PKG/recovery logs, and evidence JSON passed. No private key,
password, API key, bearer value, authorization secret/token, Apple
credential, private seed, secret key, access token, or refresh token was
found.

### Final failure and negative-test classification

| Failure case | Evidence level | Final classification |
| --- | --- | --- |
| extra MethodChannel keys | historical real Flutter app | expected PR #67 `InvalidArguments`; fixed in current source |
| missing canonical key | Dart/native contract tests | expected fail-closed rejection |
| malformed transaction ID or SHA-256 | Dart/native contract tests | expected fail-closed rejection |
| wrong package ID, artifact hash, or stage-provenance hash | native/helper tests | expected fail-closed rejection |
| staging path outside the owned root | native/helper tests | expected fail-closed rejection |
| corrupted ZIP, DMG, or PKG | smoke/verification lanes | expected rejection |
| invalid release signature | release verification tests | expected rejection |
| unsigned app | trust/contract tests | expected rejection |
| signed but non-notarized app/DMG/PKG | live artifact lane | expected Gatekeeper/stapler rejection |
| unstapled artifact | trust lane | expected stapler rejection |
| helper approval missing | live background-OFF lane | expected typed rejection, exit 75 |
| forced helper termination | live privileged/recovery lanes | recovery succeeded |
| recovery-required transaction | live privileged/recovery lanes | query and terminal recovery succeeded |
| failed rollback/recovery | helper failure-injection tests and structured logs | contained and reported; no false success |
| diagnostics or recovery marker missing | helper contract/failure tests | detected and rejected/cleaned as specified |

The live destructive negatives and contract/unit negatives are intentionally
distinguished. A passing unit rejection is not represented as a live
administrator-level mutation test.

One attempted final native PKG launch timed out before Dart `main` because
AppKit was waiting on a stale NSPasteboard promise. No updater transaction or
journal was created and the target remained v1. An immediate clean rerun
passed. This is retained as an environmental GUI-launch flake, not an updater
or recovery failure. Future harness hardening may retry only this proven
pre-Dart launch condition while preserving the first-attempt evidence.

### Final source verification

- Focused Flutter/Dart suite: 87/87 passed.
- Full Flutter suite: 821 passed, 4 expected skips.
- Install-helper SwiftPM suite: 154 tests executed, 6 expected skips, 0
  failures.
- DesktopUpdaterKit Swift suite: 141/141 passed.
- Harness structural gate: 31/31 passed.
- `flutter analyze`: exit 0; 656 existing informational diagnostics, no warning
  or error.
- Whole-repository Dart format check: passed after formatting one touched
  contract test.
- `git diff --check`: passed.
- `dart pub publish --dry-run`: package-content validation completed, but exit
  65 remains because the working tree is intentionally dirty. It is not a
  clean commit-bound release check.

Evidence:

- `/private/tmp/desktop-updater-focused-final-current.log`
- `/private/tmp/desktop-updater-flutter-test-full-final-current.log`
- `/private/tmp/desktop-updater-flutter-analyze-final-current.log`
- `/private/tmp/desktop-updater-dart-format-final-current.log`
- `/private/tmp/desktop-updater-harness-structural-final-current.log`
- `/private/tmp/desktop-updater-publish-dry-run-final-current.log`

### Final decision and remaining release work

The current source/runtime candidate is **production-ready locally for the
macOS app, DMG, standard PKG, privileged helper, forced recovery, background
approval, and structured diagnostics E2E scope**. There is no remaining
blocked macOS E2E lane in this scope.

The repository itself is still `release pending`, not published, at this
evidence cut. All package/native version surfaces and the changelog are
synchronized to 3.1.2, while the candidate fixes still need to be committed,
tagged, and published. The release gate must run from that clean exact commit.
This release-process boundary does not negate the successful local production
E2E evidence above.

No commit, push, branch change, GitHub comment/review, merge, or release was
performed during this final certification.

## 2026-08-10 current-source notarized closure checkpoint

This section supersedes the final-status statements immediately above where
they conflict with newer evidence. The checkout remained on
`fix/macos-production-smoke-e2e` at `b603b31`; no branch operation, commit,
push, or GitHub write was performed. The root package version is `3.1.1`.
Historical PR #67 reproduction evidence remains scoped to updater `3.1.0`.
The consumer matrix remains exactly `1.0.0+100` to `1.1.0+110`.

### Credential and notary resolution

Both required Developer ID identity classes were available. Identity subjects,
fingerprints, and credential values are intentionally omitted. The only notary
profile used was `general-notary`. On this host it must be invoked with default
keychain resolution:

```text
--keychain-profile general-notary
```

Passing an explicit login-keychain path is a known incorrect invocation on
this machine and was not used for these submissions. `notarytool history` and
the production doctor both succeeded with default resolution.

### Fresh current-source artifact trust

Fresh current-source v1 and v2 Flutter apps were built with the required
consumer versions. Fresh normal v1/v2 product packages and a recovery-gated v2
product package were then produced. The recovery package embeds only the fixed
repository recovery `preinstall`; the expanded package script hash matched the
source script hash.

All fresh artifacts used Developer ID signing and `general-notary`. The Apple
service returned `Accepted`. The following checks passed on the corresponding
artifacts:

- app `codesign --verify --deep --strict`, Gatekeeper execute assessment, and
  stapler validation;
- normal and recovery PKG `pkgutil --check-signature`, Gatekeeper install
  assessment, and stapler validation;
- recovery PKG embedded-script identity check.

This resolves the old-artifact `pkgutil --check-signature: invalid signature`
blocker. It was an artifact-specific inconsistency and is not reproduced by a
freshly built package.

The canonical `pkg-install-verify` lane was also replayed. The notarized v1 app
was installed, the fresh notarized/stapled v2 PKG installation exited 0, and
the following post-install checks passed:

- receipt ID `com.example.desktopUpdaterSmoke.pkg`, version `1.1.0`;
- installed app version/build `1.1.0+110` and v2 sentinel;
- app/root bundle ownership `root:wheel`;
- installed app strict code signature, Gatekeeper `Notarized Developer ID`,
  and staple validation.

Evidence is outside the checkout:

- `/private/tmp/desktop-updater-pkg-artifact-current.log`
- `/private/tmp/desktop-updater-pkg-artifact-2026-08-10T055116.160158Z.log`
- `/private/tmp/desktop-updater-pkg-install-verify-current.log`
- `/private/tmp/desktop-updater-pkg-install-verify-2026-08-10T055902.569513Z.log`
- `/private/tmp/desktop-updater-v1-artifact.u4ilhL/`
- `/private/tmp/desktop-updater-recovery-artifact.uJkvvo/`

### Privileged harness correction

The prior statement that `prepareOnly` must cancel its reservation is
superseded. That behavior is incompatible with the lane that immediately
terminates the privileged daemon and then recovers the durable prepared
transaction: cancellation removes the exact state that the following recovery
step must query and roll back.

The smoke-only Flutter host now retains the prepared reservation until its
immediate process exit, reports `transactionState=prepared`, and leaves the
helper authoritative for the deliberate daemon-crash recovery. Normal
production reservation deinitialization/cancellation semantics are unchanged.
The contract test now guards this distinction.

The signed native runtime smoke adapter was also corrected to construct the
throwing smoke-only helper with
`try MacInstallHelper.smAppServiceSmokeHost()`. This forces authenticated
SMAppService operations even when `/Applications` is writable through local
ACLs. A full-suite build initially caught the missing `try`; the focused
runtime/recovery suite passed after correction.

The current signed Flutter host returned live registration evidence with
`serviceStatus=enabled`. `targetParentWritable=true` is now correctly treated
as an observation, not an authorization failure. Authentication is proven
separately by the root daemon, signed endpoint, fixed target, and smoke
authority environment.

### Verification after the current fixes

- focused macOS contract suite: 59 tests passed;
- focused native runtime plus recovery contract suite: 24 tests passed;
- full Flutter suite: 821 tests passed, 4 expected skips, 0 failures;
- install-helper Swift suite: 154 tests, 6 expected skips, 0 failures;
- root DesktopUpdaterKit Swift suite: 141 tests, 0 failures;
- unprivileged helper E2E: canonical protocol parse and recoverable swap
  passed;
- `flutter analyze --no-fatal-infos`: exit 0;
- Dart format check: exit 0;
- structural harness gate: 31/31 canonical coverage rows declared;
- `git diff --check`: passed.

`swift test --package-path macos/desktop_updater --target ...` is not a valid
option with the installed Swift toolchain, and the plugin package also depends
on the generated `macos/FlutterFramework` package. The Flutter SwiftPM build
and root Flutter-free DesktopUpdaterKit package provide the relevant local
coverage instead. No fake Flutter package was created.

The publish dry-run reached package validation and reported only the expected
dirty-working-tree warning. It is therefore not release evidence until these
authorized changes are reviewed and committed separately.

### Remaining live step at this checkpoint

The fresh standard PKG install/update is `verified locally`. The next v1
baseline installation for the current-source privileged helper/recovery replay
is waiting at a visible macOS administrator authorization dialog. No password
was read, stored, or entered by automation. Until that manual approval and the
following live privileged/recovery/logger replay complete, the current-source
closure remains `release pending`, not `production-ready`.

### 2026-08-08 notary profile recheck outside sandbox

The `general-notary` claim was rechecked outside the sandbox using the exact
required login keychain:

`xcrun notarytool history --keychain-profile general-notary --keychain /Users/marlonjd/Library/Keychains/login.keychain-db`

The result was exit 69:

`Error: No Keychain password item found for profile: general-notary`

The only user keychain listed was
`/Users/marlonjd/Library/Keychains/login.keychain-db`; the corresponding
`notarytool-profile-general-notary` generic item was not found there or in the
other user keychain files. Developer ID Application and Developer ID Installer
identities were both present when counted without printing their values. No
credential value was read or exposed. The report therefore retains the
`general-notary` lane as blocked until `notarytool` can resolve that profile.

#### Correction: default keychain resolution

The same history command was then run without the explicit `--keychain`
argument:

`xcrun notarytool history --keychain-profile general-notary --output-format json`

This returned exit 0 with history available. Therefore `general-notary` is
available through `notarytool`'s default keychain resolution. The earlier
credential blocker is scoped to explicitly forcing
`/Users/marlonjd/Library/Keychains/login.keychain-db`; future notarization
commands for this smoke run must omit the explicit keychain path and continue
to use only the `general-notary` profile. The PKG `pkgutil --check-signature`
finding remains a separate blocker.

The production smoke `doctor` command was then run with this corrected
resolution and passed: `doctor: notary profile OK`. Its evidence is
`/private/tmp/desktop-updater-doctor-2026-08-08T054649.259508Z.log`. The
history contained accepted smoke app/DMG/PKG submissions. This means the
notary profile itself is no longer a blocker; only the artifact signature
finding and the recovery/harness lanes remain to be resolved.

### 2026-08-08 live macOS continuation

This continuation was run on the existing checkout and did not change
branches. The final checkout identity was:

- branch: `fix/macos-production-smoke-e2e`
- commit: `b603b315465824a416d635ca12dbd8f4addf0494`
- root package version: `3.1.1`
- consumer smoke matrix: `1.0.0+100` -> `1.1.0+110`
- target: `/Applications/Desktop Updater Smoke.app`
- bundle ID: `com.example.desktopUpdaterSmoke`
- notary profile requested: `general-notary` only

The live final target is v2 (`1.1.0+110`), owned by `root:wheel`, and its
current helper probe returned `{"event":"helperProbe","status":"healthy"}`.
The helper is loaded by launchd at the end of this continuation. No other
`/Applications` application was changed.

#### Credential and approval boundary

The machine has one Developer ID Application identity and one Developer ID
Installer identity when counted without printing certificate subjects or
fingerprints. The required notary profile is not available to `notarytool` in
the current login keychain:

`Error: No Keychain password item found for profile: general-notary`

No credential value, password, private key, API key, Apple credential, or
release seed was printed, stored, or added. The Background Activity disposition
was observed as enabled/allowed/notified in the unified log and was not toggled
during this continuation.

#### Live trust and helper results

- Current v2 app: `codesign --verify --deep --strict`, `spctl --assess --type execute`, and `xcrun stapler validate` passed locally.
- Current v2 app ownership: `root:wheel` for the bundle, helper, and launch daemon plist.
- Current v2 helper probe: `verified locally` with the typed healthy event.
- Current v2 standard PKG: `spctl --assess --type install` and `xcrun stapler validate` passed, but `pkgutil --check-signature` returned `invalid signature`. This is a trust inconsistency and blocks a production-ready PKG claim.
- Previously accepted notarization JSON evidence remains at `/tmp/desktop_updater_macos_smoke/recovery-current/v2-notarytool.json` and `/tmp/desktop_updater_macos_smoke/native-e2e-v311/recovery-notary.json`; no submission ID is copied into this report.
- Live helper probe output is retained at `/private/tmp/desktop-updater-v2-probe.stdout` and `/private/tmp/desktop-updater-v2-probe.stderr`.
- The failed direct bootstrap evidence is retained at `/private/tmp/desktop-updater-bootstrap.err` and `/private/tmp/desktop-updater-bootstrap.status`.

#### Privileged and recovery lanes

The clean live privileged smoke run reached registration and authenticated XPC:

- `serviceStatus=enabled`
- `targetParentWritable=true`
- `authenticatedXPC=true`
- `privilegedDaemonExecuted=true`
- `reservationCancelled=true`

The existing `macos_install_helper_smoke.dart --mode privileged` harness then
reported a recovery mismatch because its `prepareOnly` phase deliberately
cancels the reservation before the later recovery assertions. The observed
phase returned `transactionState=cancelled`, while the harness expected a
durable rollback transaction. This is a harness-flow defect, not evidence that
the production helper recovered a committed transaction.

The dedicated notarized PKG recovery lane was attempted from a v1 target. It
was blocked before installing the artifact because the recovery PKG failed the
required `pkgutil --check-signature` check (`strict-signature-invalid`), even
though `spctl --assess --type install` and stapler validation passed. A new
positive recovery evidence file was therefore not generated at
`/tmp/desktop_updater_macos_smoke/recovery.json`.

An earlier stale smoke transaction was queried as
`commitAccepted/recoveryRequired`. After the target was externally replaced,
the current helper correctly returned `manualActionRequired`; this is the
fail-closed target-identity guard, not a successful recovery. The smoke-owned
journal and stage were moved, without deletion, to:

`/private/tmp/desktop-updater-macos_smoke-stale-recovery-quarantine-20260808`

This quarantine contains only the smoke recovery artifacts and is recoverable.

#### Source and contract verification

The recovery tool now passes the controller smoke environment to transaction
query/recovery children and installed-helper refresh children. This fixes the
previous `validatedSmokeTargetURL`/missing-environment failure in the harness.
The tool is formatted and `dart analyze tool/macos_privileged_pkg_recovery_smoke.dart`
reported no issues. The requested focused Flutter suite passed with 56 tests:

`test/desktop_updater_method_channel_test.dart`,
`test/compat/flutter_300_channel_controller_contract_test.dart`,
`test/macos_cocoapods_source_layout_test.dart`,
`test/macos_native_helper_layout_test.dart`,
`test/macos_privileged_pkg_smoke_contract_test.dart`, and
`test/macos_privileged_pkg_recovery_smoke_contract_test.dart`.

`git diff --check` passed. The generated `example/pubspec.lock` changes from
the smoke build were restored and are not evidence of a source change.

#### Diagnostics and logger classification

The existing runtime evidence still covers `checking`, `descriptor`,
`downloading`, `verify`, and `stage`; the installer evidence covers helper
scheduling and PackageKit preinstall. The requested structured backup/move/
cleanup/recovery-marker event set remains a source/runtime gap described in
the earlier sections. The blocked recovery precondition means the latest
logger patch has not yet received a fresh notarized production PKG replay.
No secret-bearing values were observed in the inspected diagnostics.

#### Current release classification and required follow-up

Overall status remains `release pending`, not `production-ready`.

1. Restore the `general-notary` keychain profile through the secure local
   credential workflow; do not paste or store its values in the repository.
2. Build a fresh v2 recovery PKG from the current source with a currently valid
   Developer ID Installer signature, then notarize and staple it with
   `general-notary`. Confirm `pkgutil`, `spctl`, and stapler independently.
3. Rerun the dedicated recovery lane from a clean v1 target and capture
   manager start, forced helper termination, `recoveryRequired`, rollback or
   recovered swap, journal/stage cleanup, receipt/version/build, ownership,
   helper identity, and relaunch evidence.
4. Separate or repair the `prepareOnly` cancellation path in the privileged
   harness before treating its recovery assertions as an E2E certification.
5. Replay the logger/diagnostics checks on the fresh notarized artifact before
   changing the release classification.

No commit, push, branch operation, or GitHub operation was performed.

### 2026-08-07 focused release-gap implementation checkpoint

Status: `candidate-only`; production E2E was intentionally not rerun at this
checkpoint.

Repository state at the checkpoint:

- branch: `fix/macos-production-smoke-e2e`;
- commit: `b603b31` (`fix(macos): stabilize updater relaunch and production smoke`);
- package version: `3.1.1`;
- the implementation and earlier logger/E2E work remain uncommitted in a dirty
  working tree.

#### Protected-install evidence contract

The Flutter-host privileged harness no longer treats
`targetParentWritable == false` as proof of protected execution. On this Mac,
`/Applications` can legitimately be writable to an administrator through its
group permissions, so that observation is not a stable authorization boundary.
It remains in evidence as a boolean observation only.

The replacement contract is fail-closed and smoke-target-specific. It requires
the exact `/Applications/Desktop Updater Smoke.app` path, exact
`com.example.desktopUpdaterSmoke` bundle ID, explicit controller smoke opt-in,
an authenticated XPC exchange with the packaged helper, the verified helper
endpoint identity, and evidence that the root daemon executed the operation.
The harness records the authority as `authenticatedRootDaemon`. Existing root
ownership, helper identity/provenance, transaction, package/hash, and final
target checks remain required; no protected-install production check was
removed.

This resolves the source/contract mismatch that blocked registration on this
Mac. It is not a live Flutter-host privileged E2E pass because that E2E was not
rerun after the change.

#### Journal-less orphan recovery

Persistent recovery now discovers an exact transaction's journal-less orphan
`.commit` and `.lock` state only under sealed allowed install roots. Cleanup
requires canonical names, a real existing target directory, regular files
owned by the helper's effective user, mode `0600`, canonical commit JSON, the
exact transaction ID, and no remaining journal, provider, stage, backup, or
unknown transaction-scoped artifact. Ambiguous, malformed, foreign-owned, or
foreign-transaction state fails closed.

Recovery reports `recoveryRequired` before cleanup and
`orphanStateCleared` after identity-bound removal and directory sync. Regression
coverage verifies that the old target is preserved, exact orphan files are
removed, and a foreign lock owner is rejected without cleanup.

#### Smoke-only hook isolation

The uncommitted controller current-version/current-build environment override
was removed; normal package version detection can no longer be changed through
that smoke hook. The privileged PKG harness now requires an actual
package-installed `1.0.0+100` baseline and will not forge a downgrade by
overriding the updater's current version.

The public `MacInstallHelper()` initializer always uses normal packaged target
resolution. The explicit smoke SPI is available only when controller smoke is
enabled and the running bundle ID and standardized installed path match the
single allowed smoke target. Relaunch suppression is likewise accepted only
for that full exact tuple; setting `DESKTOP_UPDATER_SMOKE_SKIP_RELAUNCH` alone
cannot affect a normal release application.

#### Focused verification

- `swift test --package-path macos/install_helper --filter MacPersistentRecoveryTests`:
  passed, 10 tests discovered, 2 CI-only tests skipped, 0 failures;
- root-package `swift test --filter MacInstallHelperTests`: passed, 18/18;
- focused Flutter source/contract group covering privileged helper, privileged
  PKG, recovery PKG, CocoaPods source layout, and native helper layout: passed,
  46/46;
- CocoaPods plugin/kit Swift typecheck against the cached Flutter macOS
  framework: passed;
- Swift parser checks for the Flutter AppDelegate smoke host and native runtime
  entry point: passed;
- focused Dart format check: passed, 4 files checked and 0 changed;
- `git diff --check`: passed.

The standalone `macos/desktop_updater` SwiftPM plugin test target remains
blocked locally because the generated `macos/FlutterFramework` path is absent.
The corresponding CocoaPods source typecheck passed, but it is not represented
as a SwiftPM test pass.

#### Release decision and remaining blockers

`3.1.2` remains `NO-GO`. The repository is still version `3.1.1`, the candidate
source is dirty and not commit-bound, and no fresh signed/notarized artifacts
were built from this checkpoint. Per the current task boundary, the notarized
production helper/PKG/recovery E2E, live Flutter-host privileged lane, and
background-approval-off negative lane were not rerun. Full CI, complete package
tests, publish dry-run, clean-candidate artifact provenance, and final release
version/changelog checks also remain outstanding.

No credential was read or entered, no System Settings approval was toggled, no
application under `/Applications` was modified, and no Git or GitHub write
operation was performed at this checkpoint.

### 2026-08-07 final no-password continuation

This section supersedes the preceding checkpoint only for the status of the
source changes and the final live-machine state. Historical artifact results
remain evidence, but a source change is not treated as production evidence
until a newly built, signed, notarized, and installed smoke artifact exercises
it.

#### Password and background-approval boundary

No administrator password prompt was requested or entered during this
continuation. The existing `general-notary` profile and signing identities
were used only through the existing keychain configuration; no credential
value was printed, stored, or added. The background approval remained enabled
and was not toggled in this continuation. The exact smoke item had previously
been verified ON after the controlled approval-off negative test.

The final non-interactive sudo-cache check was unavailable, so no rebuild or
replacement of the root-owned installed smoke binary was attempted and no
password prompt was started.

The earlier checkpoint sentence saying that the approval-off negative had not
run is superseded by the final negative evidence: with the smoke background
approval OFF, the helper lane returned the expected exit 75 and the typed
`PrivilegedHelperApprovalRequired` diagnostic with the Login Items settings
remediation. The setting was restored ON afterward. Evidence:

- `/private/tmp/desktop_updater_macos_smoke/final-current/privileged-pkg-evidence/approval.json`
- `/private/tmp/desktop_updater_macos_smoke/final-current/privileged-pkg-evidence/approval-final.log`

#### Source fixes completed in this continuation

Two narrowly scoped lifecycle/recovery fixes were applied to the working tree:

- The privileged smoke host now explicitly cancels a `prepareOnly`
  reservation before exiting, so a diagnostic prepare cannot leave a durable
  journal and prepared sibling behind.
- Directory recovery now rolls back an uncommitted `.prepared` journal when
  the exact transaction lock is already absent. The rollback still requires
  the exact smoke-owned target, matching stage identity, unchanged target, and
  no durable commit authorization; committed or ambiguous state remains
  fail-closed. This is not broad marker deletion.

#### Verification after the source fixes

Status: `verified locally` for source and contract behavior; `candidate-only`
for a newly packaged production artifact.

- `swift test --package-path macos/install_helper`: 154 tests executed, 6
  expected skips, 0 failures.
- Focused Flutter smoke/privileged contract tests: passed.
- Focused Dart format check: 12 files checked, 0 changed.
- `git diff --check`: passed.
- The new prepared-journal-without-lock recovery regression test passed and
  preserved the old target while removing only the exact transaction state.

#### Final live installed state and recovery classification

The installed smoke target remains the required v1 baseline:

- app: `1.0.0+100`;
- receipt: `1.0.0`;
- exact target: `/Applications/Desktop Updater Smoke.app`;
- exact bundle ID: `com.example.desktopUpdaterSmoke`.

The previously installed smoke binary predates the latest `prepareOnly`
cancellation and missing-lock recovery fixes. A prior diagnostic invocation
left exactly one smoke-owned prepared journal and prepared sibling. The live
binary queried that transaction as `prepared/recoveryRequired`, while its
recovery operation returned `endpointUnavailable`. No direct deletion was
performed because the markers are root-owned. This live rerun is therefore
`blocked`, not a production regression claim; it is evidence that the old
diagnostic host must be replaced/reinstalled before the fixed recovery lane can
be certified. Evidence:

- `/private/tmp/desktop_updater_macos_smoke/recovery-register-current.out`
- `/private/tmp/desktop_updater_macos_smoke/recovery-query-current.out`
- `/private/tmp/desktop_updater_macos_smoke/recovery-cancel-current.out`

The source-level recovery suite verifies the corrected behavior, but the
notarized production helper/PKG E2E has not been rerun from this latest source
checkpoint. Therefore the overall release label remains `release pending`,
not `production-ready`.

#### Consolidated lane status

- No-notarization app/DMG/PKG trust negatives: `verified locally`; expected
  Gatekeeper and stapler rejection was separated from signing success.
- Notarized/stapled app, DMG, and standard PKG artifact trust: `verified
  locally` using `general-notary` in the existing artifact evidence.
- Standard privileged PKG install/update and receipt/version checks:
  `verified locally` for the prior signed artifact run.
- Background approval ON helper positive lane: `verified locally` in prior
  evidence; no setting toggle was performed here.
- Background approval OFF negative lane: `verified locally` with the typed
  expected rejection described above.
- PR #67: `confirmed locally` on the pre-fix real Flutter app. The native
  macOS contract accepts exactly `stagingPath`, `expectedPackageId`,
  `expectedArtifactSha256`, `stageProvenanceSha256`, and `transactionId`; the
  old nine-key handoff produced the exact `InvalidArguments` error. Current
  source now emits the canonical five-key macOS payload; no new red test was
  added.
- Recovery source/contract behavior: `verified locally`; live installed
  binary after the latest source fix: `blocked` pending rebuild/reinstall.
- Detailed helper diagnostics: source and redaction tests
  `verified locally`; post-fix notarized production artifact replay:
  `not run`.

No commit, push, branch operation, or GitHub operation was performed.

## Final report precedence

The authoritative outcome is the
[2026-08-10 final superseding production E2E certification](#2026-08-10-final-superseding-production-e2e-certification),
which was completed after every chronological checkpoint above. In particular,
it supersedes the immediately preceding historical `blocked`/`not run` text:

- the live target is v2 1.1.0+110 with receipt 1.1.0 and `root:wheel`
  ownership;
- `general-notary` is present and usable through default keychain resolution;
- sandbox-external app and PKG trust checks pass;
- background approval OFF and restored-ON lanes both pass;
- privileged helper, notarized PKG update, forced recovery, cleanup, and
  structured logger replay pass;
- the scoped macOS runtime is `production-ready locally`;
- only the clean commit-bound 3.1.2 tag/publication remains `release pending`
  at this evidence cut.
