# macOS `desktop_updater` 3.1.0 E2E issues

Date: 2026-08-05

This report records the macOS production-smoke run on the existing checkout.
The updater package version and the consumer smoke-app version matrix are kept
separate throughout:

- updater package: `desktop_updater` 3.1.0
- smoke app v1: `1.0.0+100`
- smoke app v2: `1.1.0+110`
- smoke bundle ID: `com.example.desktopUpdaterSmoke`
- smoke installation target: `/Applications/Desktop Updater Smoke.app`
- notary profile used: `general-notary` only

The initial smoke run was performed without branch, commit, push, or GitHub
writes. After the user explicitly requested the confirmed PR #67 fix to be
published, only the PR-related production source and focused test were updated
on the contributor branch; the smoke-harness and other E2E corrections below
were not included in that PR. The final durable evidence file is this report.

## Executive status

The main notarized artifact lanes are now verified locally:

- signed/notarized/stapled app v1 and v2: passed
- signed/notarized/stapled DMG first install and move-to-Applications: passed
- signed/notarized/stapled DMG artifact trust and v1 → v2 hosted update: artifact
  and whole-bundle replacement passed; the harness timed out while waiting for
  the relaunched process
- signed/notarized/stapled PKG artifact: passed
- direct app update: v1 → v2 whole-bundle replacement passed
- no-notary app/DMG/PKG negative trust lane: passed with the expected
  Gatekeeper/stapler rejections
- no-notary protected ZIP update: correctly rejected before installation
- unprivileged helper/recoverable-swap smoke: passed

The following production lanes are not complete and must not be reported as
production-ready:

- administrator-approved PKG install/receipt verification
- privileged helper/background-service install
- live recovery transaction with forced helper termination
- live rollback/recovered swap and live native helper logger events

Those lanes were blocked by the administrator authorization handoff and by the
target app not being root-owned. The background activity setting itself is
currently enabled, but that setting does not replace administrator approval or
root-owned installation.

## Baseline, branch, and version evidence

| Check | Result |
| --- | --- |
| branch | `main` |
| HEAD | `80dab9c docs: align 3.1 controller examples (#68)` |
| root `pubspec.yaml` | `version: 3.1.0` |
| v1 consumer | `1.0.0+100` |
| v2 consumer | `1.1.0+110` |
| bundle ID | `com.example.desktopUpdaterSmoke` |
| notary profile | `general-notary` |
| smoke work directory | `/tmp/desktop_updater_macos_smoke` |

`flutter pub get` and `(cd example && flutter pub get)` completed. The example
lockfile received generated-only dependency changes during the run and was
restored. No private key, password, API key, token, Apple credential, release
private seed, certificate identity, or certificate fingerprint is included in
this report.

Developer ID Application and Developer ID Installer identities were discovered
and used without recording their values. The `general-notary` profile worked
for the successful submissions. The explicitly requested invocation including
`--keychain "$HOME/Library/Keychains/login.keychain-db"` did not find the
profile, while the profile-only invocation did; only `general-notary` was used
and `desktop-updater-notary` was never used.

Release key generation was run against a temporary directory outside the
checkout. Profile creation succeeded and a repeated invocation was idempotent.
No key material was exported or imported.

## Smoke fixture metadata

The production smoke fixture now emits the required v2 metadata:

- descriptor version/build: `1.1.0+110`
- index version/build: `1.1.0+110`
- v1/v2 build commands: `1.0.0+100` and `1.1.0+110`

The stale `2.7.1` metadata was not used as a successful result. The generic
controller test helper was given an independent non-production default so its
older `2.0.1` baseline remains meaningful; the production smoke command passes
the required `1.1.0+110` values explicitly.

## Computer Use and Background Activity

Using `node_repl` and `@oai/sky`, System Settings was opened at General → Login
Items & Extensions. The smoke background item was toggled off and then on. A
fresh accessibility-tree read after the final action reported the smoke item
as `Value: on`; a screenshot of the final state was shown to the user. No
further setting toggle was performed.

The privileged lane was not marked successful merely because this setting is
on. The final smoke app ownership was `marlonjd:staff`, not `root:wheel`, and
the administrator-approved install command remained at the OS authorization
handoff. No password was entered by the agent.

## PR #67: macOS MethodChannel payload mismatch

Status: confirmed locally from the prior MacBook Pro real-app run, fixed in the
working tree for the subsequent smoke runs, and merged through PR #67.

PR publication evidence:

- contributor head: `Nicoeevee:main`
- original contributor fix commit retained: `eae93d0`
- maintainer follow-up commit: `41e849a`
- merged PR: https://github.com/MarlonJD/flutter_desktop_updater/pull/67
- merge commit: `503ff86`
- contributor comment: https://github.com/MarlonJD/flutter_desktop_updater/pull/67#issuecomment-5196021877

The local checkout was returned to `main` at `80dab9c`; the unrelated
uncommitted smoke/E2E work was restored and was not pushed as part of PR #67.

The pre-fix Dart handoff sent nine keys on macOS:

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

The native macOS `installUpdate` contract accepts exactly five:

```text
stagingPath
expectedPackageId
expectedArtifactSha256
stageProvenanceSha256
transactionId
```

The four invalid extras were `updateVersion`, `updateBuildNumber`, `platform`,
and `channel`. The exact observed native error was:

```text
code: InvalidArguments
message: installUpdate requires the canonical signed handoff payload.
```

The prior MacBook Pro run produced this error through the real signed,
notarized, stapled Flutter macOS app at the smoke path during a 2.7.0 → 2.7.1
handoff. That version pair is historical defect evidence only; the requested
consumer matrix for this run is 1.0.0+100 → 1.1.0+110.

The current Dart MethodChannel implementation sends the exact five-key map on
macOS and retains the full descriptor map for other platforms. The focused
channel test now forces the macOS target platform and asserts the canonical
five-key set. No new PR-specific red test was added.

Existing tests missed the issue because the generic MethodChannel test asserted
the full nine-key payload and the controller contract test did not model the
macOS native exact-key set. A real macOS integration assertion should remain a
future maintenance recommendation.

## Lane 1: Developer ID signed, not notarized

Status: verified locally as a negative lane.

Evidence artifacts:

- `/tmp/desktop_updater_macos_smoke/no-notary-v1/Desktop Updater Smoke.app`
- `/tmp/desktop_updater_macos_smoke/no-notary-v2/Desktop Updater Smoke.app`
- `/tmp/desktop_updater_macos_smoke/Desktop Updater Smoke No Notary.dmg`
- `/tmp/desktop_updater_macos_smoke/Desktop Updater Smoke No Notary.pkg`

Observed controls:

| Artifact/control | Result |
| --- | --- |
| no-notary v1/v2 `codesign --verify --deep --strict` | passed |
| no-notary v1/v2 `spctl --assess --type execute` | rejected, exit 3; unnotarized Developer ID |
| no-notary v1/v2 `xcrun stapler validate` | failed, exit 65 |
| no-notary DMG `spctl --assess --type open` | rejected, exit 3 |
| no-notary DMG stapler validation | failed, exit 65 |
| no-notary DMG readonly attach/detach | passed after resolving the actual mounted volume name |
| no-notary PKG `pkgutil --check-signature` | passed; package is signed |
| no-notary PKG `spctl --assess --type install` | rejected, exit 3 |
| no-notary PKG stapler validation | failed, exit 65 |

The no-notary protected ZIP update was run with a clean v1 smoke app and a
no-notary v2 staged app. The new macOS ZIP trust gate rejected the staged app
at Gatekeeper assessment with `source=Unnotarized Developer ID`; the v1 app
remained installed and the v2 sentinel was not installed.

Evidence:

- `/tmp/desktop_updater_macos_smoke/no-notary-protected-update-dartfix.log`
- `/tmp/desktop_updater_macos_smoke/no-notary-protected-diagnostics-dartfix.jsonl`

This is the expected protected-install rejection, not an updater regression.
No-notary DMG/PKG privileged installation or recovery was claimed as a live
success; those require the blocked administrator lane.

## Lane 2: notarized and stapled

### App artifact and direct app update

`doctor` passed the macOS host, both required Developer ID identity classes, and
the `general-notary` profile. The production app-update lane produced and
verified v1 and v2. Both app bundles passed codesign, Gatekeeper execute
assessment, and stapler validation.

Evidence:

- `/tmp/desktop_updater_macos_smoke/apps/1.0.0/Desktop Updater Smoke.app`
- `/tmp/desktop_updater_macos_smoke/apps/1.1.0/Desktop Updater Smoke.app`
- `reports/macos-production-smoke/app-update-2026-08-05T175431.864968Z.log`
- `/tmp/desktop_updater_macos_smoke/direct-app-smoke-diagnostics.jsonl`

Direct app update result:

- real Flutter macOS app at `/Applications/Desktop Updater Smoke.app`
- v1 installed successfully
- v1 → v2 whole-bundle replacement passed
- v2 version/build and sentinel were observed
- no `InvalidArguments` occurred after the canonical five-key fix
- the production tool did not emit a separate successful relaunch marker in
  the direct-app log, so relaunch evidence is recorded as incomplete rather
  than assumed

The direct diagnostics file contains the app-owned lifecycle events
`checking`, `downloading`, and `installing`.

### DMG first install and move-to-Applications

Both lanes passed with a DMG containing only the smoke app.

Evidence:

- `reports/macos-production-smoke/dmg-first-install-2026-08-05T175906.610415Z.log`
- `reports/macos-production-smoke/move-to-applications-2026-08-05T180145.294738Z.log`
- `/tmp/desktop_updater_macos_smoke/Desktop Updater Smoke.dmg`

The DMG primary signature, readonly mount, contained app Gatekeeper trust,
stapler validation, copy to the exact smoke path, relaunch of the copied app,
and detach all passed. No unrelated `/Applications` application was changed.

### DMG update

The first hosted attempt correctly exposed an unsigned `app-archive.json`
fixture problem and failed signature verification. The hosted smoke harness was
then corrected to serve a signed release index/descriptor and to pass the
matching public trust configuration into the child Flutter app process.

The rerun passed DMG artifact SHA-256, DMG primary signature, readonly mount,
contained app trust, hosted signed metadata, and whole-bundle v1 → v2
replacement. The command ended with a timeout waiting for the relaunched app
process after replacement; that observation is recorded separately from the
successful update operation.

Evidence:

- `reports/macos-production-smoke/dmg-update-2026-08-05T181707.881522Z.log`
- `/tmp/desktop_updater_macos_smoke/hosted-smoke-diagnostics-dmg.jsonl`
- `/tmp/desktop_updater_macos_smoke/Desktop Updater Smoke.dmg`

The diagnostics file retains the two earlier unsigned-feed failures followed
by the successful `checking`, `downloading`, and `installing` sequence. It was
scanned for private-key, password, API-key, token, authorization-secret, and
Apple-credential material and was clean.

### PKG artifact

The notarized/stapled PKG artifact lane passed:

- Developer ID Installer signing
- notarization with `general-notary`
- stapling and stapler validation
- `pkgutil --check-signature`
- `spctl --assess --type install`
- receipt-ready package construction

Evidence:

- `/tmp/desktop_updater_macos_smoke/Desktop Updater Smoke.pkg`
- `reports/macos-production-smoke/pkg-artifact-2026-08-05T182244.193016Z.log`

The artifact command intentionally did not perform the administrator install;
that is a separate lane.

### PKG install/receipt lane

Status: blocked, not successful.

`pkg-install-verify` built and notarized the v1 preparation app, then reached
the administrator-approved replacement command. The `osascript` authorization
handoff waited for administrator approval; no password was entered by the
agent, and the lane was stopped. A noninteractive admin check was also
negative. No PKG receipt was present after the interrupted handoff.

Evidence:

- `reports/macos-production-smoke/pkg-install-verify-2026-08-05T182543.926129Z.log`
- `/tmp/desktop_updater_macos_smoke/Desktop Updater Smoke.pkg`

The current `/Applications/Desktop Updater Smoke.app` is v2 with the v2
sentinel and Apple trust, but that state came from the DMG update lane, not a
successful PKG install. Its current ownership is `marlonjd:staff`; it is not
evidence of the root-owned privileged installer lane.

## Helper, privileged, and recovery lanes

### Unprivileged helper

Passed:

```text
dart run tool/macos_install_helper_smoke.dart --mode unprivileged
```

The command verified the unprivileged file transaction, canonical helper
protocol parsing, and recoverable swap behavior.

### Privileged helper and PKG smoke

The source parser was checked for the required fields: mode, v1-app,
recovery-app, v1-pkg, v2-pkg, git-commit, artifact-sha256,
notarization-submission-id, evidence-dir, smoke-root, and optional open-settings.

The live lane was not completed because:

- `/Applications/Desktop Updater Smoke.app` was not root-owned (`root:wheel`)
- the staged smoke app was user-owned as expected for a source stage, but no
  administrator authorization was available to establish the protected target
- the `osascript with administrator privileges` handoff remained waiting

### Recovery smoke

The recovery parser was checked for app, pkg, receipt-id, expected-version,
expected-build, git-commit, artifact-sha256, notarization-submission-id,
evidence, and smoke-root. The live recovery sequence was not run because its
preconditions require the completed privileged baseline and root-owned target.

Therefore the following are **not** live verified in this run:

- prepare/commit against the installed privileged helper
- forced helper/app termination in a production transaction
- `recoveryRequired` query and recover transaction
- rollback or recovered swap against `/Applications`
- old-target preservation during live recovery
- transaction-journal and staging cleanup after live recovery
- live receipt/version/build and relaunch after recovery
- live helper identity/provenance and root ownership evidence

The recovery contract tests and native Swift recovery tests passed; they are
contract evidence, not a substitute for this blocked privileged lane.

## Logger and diagnostics

Verified app-owned diagnostics:

- direct app: `checking`, `downloading`, `installing`
- hosted DMG: failed unsigned-feed attempts followed by successful
  `checking`, `downloading`, `installing`
- no sensitive values found in the JSONL diagnostics files

The macOS native source defines the helper event vocabulary and accepts a
platform-log diagnostics destination, but no actual named OSLog/Logger emission
was observed for the requested helper events. The following native events are
therefore **not** claimed as live verified:

```text
helper scheduled
backup start
backup success
move start
move success
cleanup start
cleanup success
recovery
rollback
recovery marker cleared
```

Native diagnostics/redaction contract tests passed, including checks that
private-key and token material is removed from exported diagnostics.

## Negative/failure matrix

| Failure case | Result |
| --- | --- |
| extra MethodChannel keys | confirmed locally; exact `InvalidArguments` reproduced in the prior real-app run |
| missing canonical key | expected rejection covered by helper/native contract tests |
| malformed transaction ID | expected rejection covered by helper/native contract tests |
| malformed SHA-256 | expected rejection covered by helper/native contract tests |
| wrong package ID | expected rejection covered by descriptor/helper contract tests |
| wrong artifact hash | expected rejection covered by artifact/native contract tests |
| wrong stage provenance hash | expected rejection covered by staged-provenance/native contract tests |
| staging path outside owned root | expected rejection covered by native helper contract tests |
| corrupted/truncated ZIP and ZIP metadata | expected rejection covered by resource-limit/adversarial tests |
| corrupted DMG/PKG byte mutation | not run as a live production artifact mutation |
| invalid release signature | expected rejection covered by signature verifier tests; unsigned hosted feed failed live before harness correction |
| unsigned app | expected rejection covered by Gatekeeper/native negative controls |
| Developer ID signed but not notarized app | live no-notary Gatekeeper rejection passed |
| unstapled app/DMG/PKG | live stapler failures passed as expected |
| Gatekeeper rejection | live no-notary app/DMG/PKG rejection passed |
| helper approval missing | live privileged handoff blocked at administrator authorization; no false success claimed |
| forced helper termination | contract/native recovery tests only; live privileged lane blocked |
| recovery-required transaction | contract/native recovery tests only; live privileged lane blocked |
| failed rollback/recovery | contract/native recovery tests only; live privileged lane blocked |
| diagnostics/recovery marker missing | contract coverage passed; no live privileged marker sequence claimed |

## Test results

Passed locally:

- focused Flutter macOS/channel/layout/helper/privileged contract and ZIP E2E
  set: 64 passed
- isolated negative/signature/artifact/helper/PKG audit set: 63 passed
- full Flutter suite: 816 passed, 4 skipped
- root Swift package: 139 passed, 0 failed
- `macos/install_helper` Swift package: 147 passed, 6 skipped, 0 failed
- `dart format` on changed Dart files
- `git diff --check`

The full Flutter suite retains two failures in
`test/release_cli/release_publisher_build_test.dart`:

- macOS publish uses DMG packager when configured
- macOS publish uses PKG packager when configured

Both fake packagers create placeholder text artifacts, while the production
publisher verifier correctly invokes real Gatekeeper/pkgutil checks. The DMG
placeholder is rejected as having no usable signature and the PKG placeholder
cannot be parsed as a package. This is a test-fixture/verifier integration
issue, not evidence that the real notarized smoke artifacts failed. It remains
unfixed because relaxing the production verifier would be the wrong fix.

The separate SwiftPM plugin package test remains blocked by the repository's
missing generated ignored `macos/FlutterFramework` package. The root Swift
package and install-helper package were run successfully instead.

## Evidence paths

Retained machine evidence under `/tmp`:

- `/tmp/desktop_updater_macos_smoke/apps/1.0.0/Desktop Updater Smoke.app`
- `/tmp/desktop_updater_macos_smoke/apps/1.1.0/Desktop Updater Smoke.app`
- `/tmp/desktop_updater_macos_smoke/no-notary-v1/Desktop Updater Smoke.app`
- `/tmp/desktop_updater_macos_smoke/no-notary-v2/Desktop Updater Smoke.app`
- `/tmp/desktop_updater_macos_smoke/Desktop Updater Smoke.dmg`
- `/tmp/desktop_updater_macos_smoke/Desktop Updater Smoke No Notary.dmg`
- `/tmp/desktop_updater_macos_smoke/Desktop Updater Smoke.pkg`
- `/tmp/desktop_updater_macos_smoke/Desktop Updater Smoke No Notary.pkg`
- `/tmp/desktop_updater_macos_smoke/direct-app-smoke-diagnostics.jsonl`
- `/tmp/desktop_updater_macos_smoke/hosted-smoke-diagnostics-dmg.jsonl`
- `/tmp/desktop_updater_macos_smoke/no-notary-protected-update-dartfix.log`
- `/tmp/desktop_updater_macos_smoke/no-notary-protected-diagnostics-dartfix.jsonl`

Transient production command log names captured before cleanup:

- `app-update-2026-08-05T175431.864968Z.log`
- `dmg-first-install-2026-08-05T175906.610415Z.log`
- `move-to-applications-2026-08-05T180145.294738Z.log`
- `dmg-update-2026-08-05T181707.881522Z.log`
- `pkg-artifact-2026-08-05T182244.193016Z.log`
- `pkg-install-verify-2026-08-05T182543.926129Z.log`

Per the user’s durable-evidence rule, transient files under
`reports/macos-production-smoke/` other than this report are removed during
final cleanup. The `/tmp` artifact and diagnostics paths above are not copied
into the repository.

## Implemented corrections during this run

The following corrections were required to obtain meaningful E2E evidence:

1. macOS MethodChannel `installUpdate` now sends the native canonical five-key
   payload.
2. macOS ZIP staging preserves symlinks and validates staged app codesign,
   Gatekeeper, stapler, bundle ID, and team identity before protected staging.
3. The smoke app identifiers and fixture metadata are bound to the requested
   smoke app and `1.0.0+100 → 1.1.0+110` matrix.
4. Hosted production smoke metadata is signed and the matching trusted public
   configuration is forwarded to the child smoke app process.
5. Temporary helper debugging was removed so helper errors do not expose raw
   error objects or credential-adjacent data.

## Remaining recommendations

- Complete the administrator-approved PKG install once the user performs the
  macOS authorization handoff; verify receipt, root ownership, helper
  identity, and installed v2 trust before calling the lane complete.
- Run the privileged recovery smoke with a notarized v1/v2 PKG pair and record
  every recovery marker, journal, stage, ownership, and relaunch assertion.
- Fix the DMG/PKG publisher test fakes by injecting a verifier process or using
  valid test artifacts; do not weaken production Gatekeeper/pkgutil checks.
- Make the production smoke relaunch observer use a durable marker or a robust
  exact-bundle process check so a successful replacement is not followed by a
  false timeout.
- If platform-log helper diagnostics are a release requirement, implement and
  verify actual macOS Logger/OSLog emission for the event vocabulary above.
- Add a real macOS integration assertion for the exact five-key MethodChannel
  handoff in a later user-owned test plan.
- Store the `general-notary` keychain profile where both the profile-only and
  explicitly selected login-keychain invocations resolve consistently.
