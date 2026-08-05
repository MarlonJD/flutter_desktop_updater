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
| branch | `main` |
| current HEAD | `1402ef7 chore: remove internal superpowers artifacts` |
| current root package | `desktop_updater` 3.1.1 |
| historical PR #67 target | `desktop_updater` 3.1.0 |
| smoke app v1 | 1.0.0+100 |
| smoke app v2 | 1.1.0+110 |
| bundle ID | `com.example.desktopUpdaterSmoke` |
| allowed installed app | `/Applications/Desktop Updater Smoke.app` |
| smoke work directory | `/tmp/desktop_updater_macos_smoke` |
| notary profile | `general-notary` only |

The final installed smoke app is v2 (`1.1.0`, build `110`) and contains the
expected v2 sentinel. No unrelated `/Applications` app was changed.

The implementation and harness changes from this validation task are included
in this PR. The generated `example/pubspec.lock` changes and generated .NET
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
- `/tmp/desktop_updater_macos_smoke`

## Executive result

The non-administrator portion is complete and verified locally:

- signed/notarized/stapled app artifacts: passed
- direct app update 1.0.0+100 → 1.1.0+110: passed
- DMG first-install and read-only mount/detach: passed
- move-to-Applications using only the smoke app: passed
- hosted notarized DMG update and relaunch marker: passed
- signed/notarized/stapled PKG artifact: passed
- unprivileged helper and recoverable-swap smoke: passed
- no-notary trust negatives and protected handoff rejection: passed
- corrupted ZIP/DMG/PKG rejection checks: passed
- focused/full Flutter and SwiftPM contract suites: passed

The following are deliberately `blocked`/`not run` because they require direct
administrator authorization, root-owned `/Applications` state, or forced
privileged-helper termination:

- PKG install/update/receipt verification
- privileged helper/background-service live install
- live recovery after forced helper termination
- live rollback/recovered swap against a root-owned target
- live privileged helper logger events

The Login Items & Extensions background activity approval was already enabled.
It was not toggled during this run. Enabled background activity does not remove
the administrator/root-owned install requirement.

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

Status: `verified locally`; installation intentionally not attempted.

The v2 PKG passed Developer ID Installer signing, `pkgutil --check-signature`,
`spctl --assess --type install`, notarization, and stapler validation. The
artifact was built for the smoke app and was not installed.

Evidence:

- `/tmp/desktop_updater_macos_smoke/Desktop Updater Smoke.pkg`
- `reports/macos-production-smoke/pkg-artifact-2026-08-05T210520.741277Z.log`

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

Live privileged recovery is `blocked`, not successful. The following were not
run because they require administrator authorization, root-owned target state,
or forced termination of the privileged helper:

- `pkg-install-verify`
- `dart run tool/macos_install_helper_smoke.dart --mode privileged`
- `dart run tool/macos_privileged_pkg_smoke.dart ...`
- `dart run tool/macos_privileged_pkg_recovery_smoke.dart ...`
- root-owned `/Applications` setup and forced helper termination

Contract and state-machine coverage is verified locally: prepare/commit,
`recoveryRequired`, query/recover, rollback/recovered-swap, journal cleanup,
staging cleanup, ownership/provenance binding, and crash-boundary cases are
covered by the SwiftPM and Flutter contract suites below. That coverage must
not be presented as live root-owned recovery evidence.

### Diagnostics and logger

The app-owned smoke diagnostics recorded `checking`, `downloading`,
`installing`, and `relaunch`. Native helper recovery/logger events were not
claimed live because the privileged lane was blocked. Contract redaction tests
passed; no private key, password, API key, token, Apple credential, or
authorization secret appeared in the evidence files.

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
| helper approval missing | live privileged lane blocked; typed approval contract passes |
| forced helper termination | live lane blocked; crash/recovery contracts pass |
| recovery-required transaction | live lane blocked; query/recovery contracts pass |
| failed rollback/recovery | live lane blocked; rollback/idempotence contracts pass |
| missing diagnostics/recovery marker | harness fixed; app relaunch marker observed |

Evidence for corrupted artifacts:
`/tmp/desktop_updater_macos_smoke/negative-artifacts-2026-08-06/results.log`.

## Verification totals

The following commands passed locally:

- requested focused Flutter suite: `55` tests passed
- full `flutter test --no-pub`: `818` passed, `4` skipped
- root `swift test`: `140` passed, `0` failed
- `swift test --package-path macos/install_helper`: `147` passed, `6` skipped,
  `0` failed
- `dart format --output=none --set-exit-if-changed .`: passed
- `flutter analyze --no-fatal-infos`: exit 0; 649 pre-existing info-level
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

These are validation fixes only; this PR contains the local changes from this
validation run.

## Remaining action

To close the remaining lanes, an authorized operator must run the PKG install
and privileged/recovery smoke with a root-owned smoke target, complete any
System Settings background-item approval if macOS requests it, and capture the
receipt, ownership, helper identity/provenance, recovery journal cleanup, and
native logger evidence. No administrator password was entered or requested in
this run.
