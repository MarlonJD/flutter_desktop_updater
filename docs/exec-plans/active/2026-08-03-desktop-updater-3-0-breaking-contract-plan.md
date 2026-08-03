# Desktop Updater 3.0 Breaking Contract Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> `superpowers:subagent-driven-development` (recommended) or
> `superpowers:executing-plans` to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a real `3.0.0` release that removes the unsafe or misleading
2.x compatibility paths, requires authenticated update authority before
download and install, migrates every native consumer to durable transactions,
and gives Flutter and helper-only consumers tested 2.x-to-3.0 instructions.

**Architecture:** Keep `DesktopUpdaterController` as the canonical Flutter
lifecycle API, but make trust configuration, package identity, and an app-owned
durable recovery store mandatory. Replace the stateless low-level facade pair
with a per-client session, and make check/stage results final, opaque,
session-bound values. The Dart handoff is misuse-resistant, not a privilege
boundary: every native adapter must independently reload retained stage
evidence, derive the running application's target proof, and reject mismatches.
The macOS in-process Swift helper derives its bundle/process/code-signing proof;
Windows and Linux standalone consumers provide target hints that are verified
against process identity and installed markers. Every consumer persists a
transaction UUID before prepare. Keep helper wire protocol 1 and frozen old
journal readers internal so interrupted 2.x transactions remain recoverable.
On Windows, use a new ABI-2 symbol family that does not reuse the already-shipped
`desktop_updater_prepare_install_v2` binary signature.

**Tech Stack:** Dart and Flutter, MethodChannel and
`plugin_platform_interface`, Ed25519 and schema-v3 release metadata, Swift and
SwiftPM, C++17 and CMake, Win32 C ABI and .NET 8/NuGet, Linux source-first CMake
and polkit, XCTest, GoogleTest, xUnit, PowerShell, shell smoke tools, and GitHub
Actions.

**Status (2026-08-03):** Independent review corrections are incorporated;
implementation has not started. The audited baseline HEAD is
`2f91208f0de95b9656b0ce2a28258e70a2920b86` in the isolated worktree
`/Users/marlonjd/.codex/worktrees/f828/flutter_desktop_updater`. The worktree is
not clean: `docs/exec-plans/index.md` is modified and this plan is untracked.
Those planning changes are user-owned and are not implementation evidence.

## Global Constraints

- Work only in
  `/Users/marlonjd/.codex/worktrees/f828/flutter_desktop_updater`; do not
  modify the primary checkout at
  `/Users/marlonjd/Developer/library/flutter_desktop_updater`.
- The intended branch is `feat/native-sdk-platform-split`, but this plan does
  not authorize creating, switching, renaming, or deleting a branch.
- This plan does not authorize commits, pushes, merges, PR edits, release
  publication, or any other Git or GitHub write. Obtain explicit authority in
  the execution thread for each requested operation.
- Keep release schema version 3. Do not invent schema 4 merely to mark the
  package major version.
- Preserve MethodChannel method names and helper wire protocol version 1 where
  they are internal implementation details. Change their required payload
  validation, not their names.
- Preserve readers for existing protocol-v1 transaction journals and recovery
  markers. Removing a public compatibility API must not make an interrupted
  2.x installation unrecoverable.
- Never weaken descriptor signatures, archive signatures, artifact hashes,
  platform code signing, archive limits, provenance, install-target proof,
  locking, rollback, or recovery to ease migration.
- Native runtime artifacts remain `preview` and `candidate-only` in 3.0.
  Normal required CI being green is not production signing, elevation,
  notarization, or installed-policy evidence.
- Bump `pubspec.yaml`, native package versions, and `CHANGELOG.md` only in
  the final release-preparation task after the contract, migrations, and
  validation lanes pass.
- Do not change `pubspec.lock` or `example/pubspec.lock` unless a separately
  approved dependency change makes a lockfile update unavoidable. This plan
  adds no dependency.
- Use conventional commits only if a later execution thread explicitly
  authorizes commits. The suggested review boundaries in this plan do not grant
  that authority.

---

## Purpose and Observable Outcome

The 3.0 release is justified by actual source, ABI, and behavior breaks, not by
documentation alone. A migrated Flutter application must provide a non-empty
map of pinned Ed25519 release keys and its expected package identity when it
creates `DesktopUpdaterController`. An update check must authenticate
`app-archive.json`, authenticate `release.json`, and compare the signed
descriptor package identity before any artifact bytes are downloaded. Native
install handoff must accept only retained stage provenance and a transaction ID
that the app persisted before prepare.

A migrated standalone host must use prepare/commit/recovery APIs. The
`scheduleInstallAndRelaunch` convenience path, generated transaction IDs,
caller-selected helper log paths, unsigned switches, and the old Windows
query-then-mutating-recover public flow must no longer compile against 3.0.
Windows retains read-only query for diagnostics but uses one atomic resolver
for startup mutation. macOS and Linux retain their query/recover pair until
those platforms have an equivalent atomic resolver.

The release is successful when old source paths are absent or intentionally
rejected, every after-migration example compiles and every safely runnable
consumer executes (the macOS command-line helper examples remain compile-only
outside a purpose-built signed `.app`), normal required CI is green for the
exact release commit, two consecutive Debug and two consecutive Release Windows
VM update smokes pass, and every credential-gated evidence gap is still labeled
literally.

## Baseline Evidence

| Evidence | Audited result | Consequence for this plan |
| --- | --- | --- |
| Repository source | HEAD is exactly `2f91208f0de95b9656b0ce2a28258e70a2920b86`; `pubspec.yaml` is `2.7.0`; the worktree contains the modified plan index and this untracked plan | Measure implementation from the exact commit, preserve the user-owned planning changes, and never call this worktree clean until Git proves it |
| [PR #65](https://github.com/MarlonJD/flutter_desktop_updater/pull/65) | Open draft, not merged | Do not describe PR state as release state and do not update it without authority |
| [GitHub Actions run 30763112196](https://github.com/MarlonJD/flutter_desktop_updater/actions/runs/30763112196) | Successful for Dart Package, macOS Native Consumer, Windows, Linux, both Flutter macOS integration modes, and the four standalone CLI candidate matrix entries | README and the native runtime evidence ledger must stop saying these normal target-host jobs are `not run` for this SHA |
| Normal Windows smokes in that run | Debug passed once and Release passed once | Useful exact-head CI evidence, but not the required local VM x2 repetition for the 3.0 release gate |
| Credential/manual lanes | Windows Authenticode/UAC, Linux installed polkit, macOS notarized publish, macOS SMAppService privileged helper, and signed Inno evidence remain skipped or not run | Keep these separate from normal required CI and list them as release-pending evidence |
| Dart install behavior | Unsigned checks/downloads remain possible when keys are null, but controller install handoff already rejects unsigned metadata and `allowUnsignedMacOSUpdates` | The current fail-closed install is a security behavior, not a source break; 3.0 is justified by removing the flags and unsigned check/download surface |
| Native helpers | Durable helper/runtime implementations largely predate the recent smoke fixes | Scope the release around contract removal and consumer migration; do not claim the CI harness introduced the runtime |

### Review evidence that constrains implementation

| Baseline source/symbol | Observed 2.7 behavior | Constraint carried into this plan |
| --- | --- | --- |
| `windows/native/include/desktop_updater_native_c.h` — `desktop_updater_prepare_install_v2`; `DesktopUpdaterNative.cs` — `NativePrepareInstallV2` | The `_v2` symbol already takes ABI-1 request/result/status/handle layouts and .NET marshals its result by value | New layouts use `_abi2`; the old signature is only a frozen rejecting tombstone |
| `lib/updater_controller.dart` — `_writePendingRecoveryMarker`; `lib/src/core/update_recovery.dart` — `UpdateInstallRecoveryMarker` | Store is optional, write failure is converted to `false`, the caller continues, and marker lacks package/provenance binding | Store is required; write/readback mismatch aborts before any platform call |
| `lib/updater_controller.dart` — `DesktopUpdaterController.forTesting`; `lib/src/core/release_descriptor.dart` — `buildNumber` | The callable testing constructor also makes trust/store optional, while valid non-PKG descriptors may omit build number | Apply identical constructor invariants to both entry points and preserve nullable build field-for-field |
| `lib/desktop_updater.dart` — `checkZipFirstUpdate` and `downloadZipFirstUpdate` | The facade constructs a new `UpdateClient` in each call and download accepts a raw descriptor | Replace the pair with one owner session and opaque check result |
| `lib/src/release_cli/release_publisher.dart` — manifest/post-package/sign/upload order | Manifest precedes `postPackage`; hooks are expected to sign the descriptor; publisher signs only the index | Rehash and sign both metadata files after hooks, then create/validate the manifest |
| `lib/src/release_cli/release_publish_config.dart` — default `outputDirectory`; `lib/src/release_cli/publish_command.dart` — signing/history options | Canonical publish defaults to local `dist/desktop_updater` and has no required hosted/prior-index input, so local absence cannot prove a new feed | Acquire and verify history explicitly; require proven initialization and remote-revision preconditioning |
| `lib/src/release_cli/upload/custom_command_upload_provider.dart` | Provider is unordered and signed publish rejects it | Either implement physical two-phase isolation as specified or remove the provider as an explicit 3.0 break; this plan chooses isolation |
| `lib/src/migrate/migration_tool.dart` — `_migratePubspec`; `bin/migrate.dart` usage | Tool is hard-coded as 1.x-to-2.0 and can rewrite later scalar constraints toward 2.0 | Version the migration lane before documenting 2-to-3 automation |
| `linux/native/src/desktop_updater_native.cc` — `ProveInstallTarget` | Non-legacy proof already requires exact running executable plus matching root marker | Remove only legacy proof; do not weaken the surviving rule to an either/or check |
| root `Package.swift` and `macos/desktop_updater/Package.swift` | Root tests Flutter-free kit; plugin package needs generated `FlutterFramework` | Run root Swift tests directly and cover plugin target through Flutter SwiftPM integration |
| `windows/native/CMakeLists.txt`; `linux/native/CMakeLists.txt` — `DESKTOP_UPDATER_NATIVE_RUNTIME` | Runtime build defaults to `OFF`; a tests-only configure omits runtime binaries, tests, and installed runtime targets | Every native runtime verification/install configure sets the option `ON` explicitly |
| `windows/native/src/helper/windows_protected_helper_locator.h` — `ProtectedWindowsHelperEndpointV1` | The protected endpoint is canonical schema-1 serialized authority in addition to the portable locator | Freeze its bytes and fresh-process lookup alongside the other durable-state readers |


## Decision Summary

### Required breaking changes

1. Keep `DesktopUpdaterController`, but require
   `trustedReleasePublicKeys`, `expectedPackageId`, and `recoveryStore`;
   keys and identity must be non-empty after normalization, and the store must
   durably write and read back the exact v3 marker before native prepare.
2. Require valid Ed25519 signatures on both `app-archive.json` and
   `release.json` before release selection can become downloadable. Remove
   the 2.x unsigned runtime behavior.
3. Remove `allowUnsignedMacOSUpdates` from Dart, Swift, MethodChannel,
   examples, and docs. It has no successful privileged install behavior today.
4. Remove `diagnosticsLogPath` and native equivalents. Dart diagnostics stay
   app-owned through `UpdateDiagnosticsRecorder`, callbacks, and an
   app-selected sink; privileged helpers keep fixed platform-owned sinks.
5. Remove raw staged installation from `DesktopUpdater.installUpdate` and
   staged arguments from `DesktopUpdater.restartApp`. Keep
   `DesktopUpdater.restartApp()` only as a restart utility. Controller
   `restartApp()` remains the canonical verified install action.
6. Remove the stateless `checkZipFirstUpdate`/`downloadZipFirstUpdate` pair.
   A `ZipFirstUpdateSession` owns one configured `UpdateClient`; download
   consumes only an opaque `UpdateCheckResult` issued by that same session.
   Make check/stage result constructors library-private and the classes final.
   Each check result is single-use: a later check, a null check, or any staging
   attempt invalidates it, concurrent use is rejected, and retry requires a new
   check. A stage becomes single-use when native dispatch is attempted; an
   ambiguous platform result is resolved by transaction ID, never by replaying
   the stage.
7. Replace platform-interface compatibility dispatch with one required typed
   install method plus a typed recovery capability: all implementations expose
   authenticated read-only query, macOS/Linux expose query-and-recover, and
   Windows exposes query-and-atomic-resolve. Custom `DesktopUpdaterPlatform`
   implementations must migrate; there is no legacy install fallback and no
   `runtimeType == MethodChannelDesktopUpdater` recovery shortcut. Treat the
   Dart request as misuse resistance only; the native adapter remains the
   security boundary and revalidates every field.
8. Require a caller-generated, lowercase UUID plus package/version/channel and
   stage-provenance binding to be durably persisted before helper prepare.
   A successful store write is not sufficient: read the marker back and compare
   every authoritative field, including a nullable build number, then bind that
   receipt back to the exact retained stage before constructing the platform
   request. Remove every public generated-ID prepare overload and every
   `scheduleInstallAndRelaunch` wrapper. After platform invocation, retain the
   marker on timeout, transport loss, or unauthenticated/ambiguous failure;
   clear it only on authenticated proof that no pending transaction exists or
   after terminal recovery handling.
9. Make Windows consumers use durable prepare plus atomic
   `resolvePendingInstallAfterExit` for mutation. Preserve read-only query;
   remove public mutating recover. Bump installed native and runtime ABI markers
   to 2, introduce collision-free `*_abi2` helper entry points, and reject an
   ABI-1 request after reading only its fixed prefix. Retain the exact shipped
   `desktop_updater_prepare_install_v2` ABI-1 signature only as a deterministic
   rejecting binary shim; never reinterpret it as a new layout.
10. Remove Linux's `kLegacySelfContainedBundle` target proof and generated
    transaction behavior. Require explicit install root, running executable
    proof, package identity, signed provenance, and transaction ID.
11. Require a key ID and exactly one private-key source in canonical
    `release publish`, plus `--public-keys-env` containing the trusted old/new
    rotation map. Derive the active public key from the private seed and require
    an exact map match. Do not infer a new feed from an empty output directory:
    fetch and verify the hosted prior index by default, or require an explicit
    signed `--existing-app-archive`; only `--initialize-feed` plus a verified
    hosted absence may begin without history. Freeze the verified history and
    its remote hash/ETag, then recheck that revision immediately before the
    conditional index-last write. After all packaging hooks, recompute final
    artifact bytes, rebuild and sign `release.json`, rebuild
    `app-archive.json` only from the frozen state and publisher-owned item, sign
    it, write the manifest from those final values, and perform strict local
    validation before any provider or manual handoff. The publisher, not a
    hook, owns canonical metadata signing.
12. Preserve `customCommand` only as an `OrderedUploadProvider` with physically
    isolated versioned and index roots. Lower-level package/archive/verify
    commands remain candidate tooling and must label unsigned or integrity-only
    output literally `candidate-only`.

### Recommended changes included in this release

- Introduce a single typed Dart verified-install handoff object instead of
  another expanding set of optional named parameters.
- Make the Flutter platform plugins derive install root and executable proof
  from their running process context. Do not trust caller-provided Dart paths.
- Give each native runtime a prepare/commit API that consumes its retained
  staged result and an app-persisted transaction ID; remove high-level
  scheduling wrappers.
- Add compile-tested migration consumers and negative removed-API checks so
  docs cannot silently drift from code.

### Preserved surfaces

- `DesktopUpdaterController`, `UpdateState`, ready-made widgets,
  localization, release notes, preferences, request-header callbacks,
  telemetry, problem reports, cleanup reports, app-owned diagnostics, and the
  recovery-store abstraction.
- `DesktopUpdater.restartApp()` as a restart-only utility plus current
  version, executable, macOS install-location, move-to-Applications, and
  Background Items utilities.
- Schema-v3 metadata and canonical signature encoding.
- `DesktopUpdaterKit` product/import naming, SwiftPM distribution, the macOS
  native-runtime floor, and the macOS 10.14 CocoaPods helper/plugin fallback.
- Helper protocol version 1, fixed helper diagnostics sinks, transaction state
  values, terminal rollback semantics, and old journal readers.
- Authenticated read-only query on all three platforms; macOS and Linux public
  recover because neither currently has Windows's atomic resolver. Windows
  direct recover is not preserved.
- Linux source-first CMake distribution and its explicit no-prebuilt-ABI
  policy.

## Detailed v3 Contract Matrix

| Surface | 2.x contract | 3.0 contract | Migration | Compatibility impact | Platform |
| --- | --- | --- | --- | --- | --- |
| Flutter lifecycle API | `DesktopUpdaterController` is canonical but trust inputs and the recovery store are optional, including on public `forTesting` | Preserve controller; both constructors require non-empty `trustedReleasePublicKeys`, `expectedPackageId`, and `UpdateRecoveryStore` with identical validation | Pin keys, pass the installed package ID, and provide a store whose write completes only after durable persistence | Source break at construction; earlier fail-closed configuration/persistence errors | All Flutter |
| Controller UI/state | State, widgets, localization, notes, preferences, telemetry, diagnostics recorder, and recovery-store abstraction | Preserved; v3 install markers add identity, transaction, and stage binding and must be read back before handoff | Update custom store serialization and retain its old-marker reader | Constructor/store schema source break; UI model preserved | All Flutter |
| Unsigned archive/descriptor | Null keys allow unsigned check/download; install later fails closed | Both metadata signatures are mandatory before an update is returned | Sign both files and deploy pinned keys before offering v3 | Behavior break occurs earlier, before artifact download | All |
| Package identity | Descriptor requires `packageId`, but Dart does not compare it with app-owned expected identity during check | Required expected identity is compared immediately after descriptor verification | Configure stable package ID; fix feed identity mismatches | New fail-closed check | All |
| `allowUnsignedMacOSUpdates` | Public compatibility argument exists and true is rejected before helper handoff | Removed everywhere | Delete the argument; sign/notarize/staple macOS artifacts | Source break; no successful 2.x behavior lost | Flutter/macOS/Swift |
| `diagnosticsLogPath` | Accepted across Dart/native surfaces, but versioned helpers ignore it in favor of fixed sinks | Removed; app diagnostics use recorder/callback/sink and helper logs remain platform-owned | Replace file-path argument with an app-owned diagnostics recorder or callback | Source and ABI break; helper outcome is unchanged | All |
| Facade staged install | `DesktopUpdater.installUpdate` accepts a raw path; `restartApp` can also install | Raw install method removed; facade `restartApp()` is restart-only | Use controller check/download/`restartApp()` | Source break; closes provenance bypass | Flutter |
| Low-level check/download | Facade creates a different `UpdateClient` for check and download; keys are optional and download accepts a caller descriptor | `createZipFirstUpdateSession` returns one owner session; keys/identity are required and stage accepts only that session's opaque check result | Keep the session and carry its result into `downloadVerifyAndStage` | Source break; prevents cross-client/caller-constructed handoff | Dart |
| Result construction | `UpdateCheckResult` and `UpdateStageResult` constructors are public and extensible | Classes are final, constructors are library-private, and each value carries a private owner token | Use injected transports/session factories in tests; do not construct production state | Source break for direct constructors/subclasses | Dart |
| Platform interface | Legacy `installUpdate` plus extension/runtime-type fallbacks lets released subclasses ignore verified context and recovery | Required `installVerifiedUpdate` plus `NativeInstallRecovery`; macOS/Linux return `QueryAndRecoverNativeInstallRecovery`, Windows returns `AtomicAfterExitNativeInstallRecovery`; `null` means authenticated absence only | Implement install, authenticated query, and exactly the platform-applicable typed recovery capability | Source break for custom platform implementations; Windows has no Dart direct-recover member on its capability | Flutter plugins/custom |
| MethodChannel | `installUpdate` payload contains optional unsigned, diagnostics, target, and proof values | Preserve internal method name; require transaction, package, artifact, and provenance evidence; native plugin derives target proof | Update custom native channel host in lockstep | Wire payload behavior break | Flutter plugins |
| Stage provenance | Created by normal staging, but raw public install can bypass it | Retained stage marker/digest/inventory is mandatory and rechecked at handoff | Do not move or reconstruct stages outside the library | Earlier rejection of foreign/tampered paths | All |
| Install-root/executable proof | Optional caller paths exist in Dart; native helper validation is stricter | Flutter plugins and the macOS in-process Swift helper derive process/bundle proof; Windows/Linux standalone hosts provide hints that must match process identity plus installed proof; helper rejects missing/mismatch | Remove Dart path arguments; migrate each native host to its platform proof model | Source and behavior break | All |
| Transaction identity | Controller persists a UUID; several native prepare overloads still generate one | Every consumer persists lowercase UUID before prepare and reuses it for recovery | Add durable app storage before calling prepare | Source and behavior break | All |
| `scheduleInstallAndRelaunch` | Convenience wrappers call prepare then commit | Removed | Call prepare, persist reservation locator, commit after exit, recover on startup | Source/ABI break | macOS/Windows/Linux |
| macOS prepare | Explicit-ID and generated-ID overloads | Only `prepareInstall(_:transactionID:)` | Generate and persist ID first | Swift source break | macOS |
| macOS recovery | Query and recover are public | Preserved until an atomic resolver exists | Keep query, then recover only when status requires it | No planned break | macOS |
| Windows prepare | C++ implicit prepare; installed C ABI exposes v1 layouts and an already-shipped `desktop_updater_prepare_install_v2` that still uses them; .NET has one- and two-argument overloads | Explicit-ID prepare only; ABI marker/layout 2 uses new `desktop_updater_*_abi2` symbols; the old `_v2` signature is a rejecting legacy export | Recompile C/C++/.NET consumers against 3.0; never bind the new layout to `_v2` | Source and ABI break without a signature collision | Windows |
| Windows startup recovery | Read-only query, mutating recover, and additive atomic resolver are public | Read-only query remains; atomic resolver is the only public recovery mutation; mutating recover is removed | Query for display only; persist ID and call resolver once for startup mutation; exit on active recovery acknowledgement | Source break only for mutating recover; behavior break for startup flow | Windows |
| Windows ABI-1 binaries | Public v1 exports/layouts remain usable and `_prepare_install_v2` has an ABI-1 signature | v1 declarations are absent from the 3.0 header; the frozen `_prepare_install_v2` export retains its exact ABI-1 signature and rejects; new `*_abi2` functions validate `abi_version`/`struct_size` before any later field | Rebuild against 3.0 headers/NuGet; frozen 2.7 binary harness proves deterministic rejection | Intentional ABI break with memory-safe failure | Windows |
| Windows Inno policy | Signed descriptor carries signer thumbprints/elevation, but Dart forwards mutable scalar copies | Adapter reloads the authenticated staged descriptor/provenance and derives signer thumbprints and `auto`/`always`/`never`; it compares them with sealed policy and ignores no caller override | Remove Dart Inno policy fields; package the matching sealed policy | Earlier rejection of forged/mismatched installer policy | Windows |
| Linux target proof | Non-legacy path already checks exact running executable and installed marker, but legacy self-contained fallback and optional transaction ID remain | Legacy fallback is removed; every install requires both the exact canonical running executable/root relation and matching root identity marker, plus package ID and explicit ID | Update CMake consumer request construction, marker provisioning, and startup recovery | C++ source break; existing non-legacy proof is preserved, not weakened to either/or | Linux |
| Native runtime signature flags | Swift/.NET/Linux default flags are true but callers can disable them | Disable flags removed; non-empty pinned keys always required | Delete false overrides and supply keys | Source/behavior break | Native runtime |
| Native runtime install | `InstallAndRelaunch`/equivalent can schedule directly and accepts diagnostics path | Runtime exposes explicit prepare/commit/cancel/recovery over retained staged state | Persist transaction ID and split handoff | Source/ABI break | Native runtime |
| Canonical publishing | Signing is optional; post-package hooks own descriptor signing; publisher signs only the index; validation needs `--require-signature`; a clean local output can lose hosted history | `release publish` requires key ID, one private source, and trusted old/new public-key map; acquires and verifies prior history or explicitly initializes a proven-absent feed; signs both final metadata files after hooks; validates locally; conditionally publishes index last against the frozen remote revision | Remove metadata-signing hooks, supply the active signing key plus rotation map, pin that map in apps, use `--initialize-feed` only for a proven-new feed, and migrate custom commands to two phases plus a revision precondition | CLI/config behavior break; custom-command/provider contract changes | Publisher |
| Low-level publishing | `package`, `app-archive`, and `verify` can produce or accept unsigned metadata without a durable status label | Unsigned output is always `candidate-only`; signed archive mutation fails unless atomically re-signed or explicitly invalidated for a candidate; production verify requires keys | Use canonical publish or a final sign step; pass `--candidate-only` only for fixtures | Behavior/output break | Publisher |
| Manual publishing | Manual provider prints upload instructions and skips hosted validation | Final output is signed and strictly validated locally; status remains `not uploaded`; instructions include the derived non-secret public-key map and strict hosted validation command | Upload in documented order, then run strict validation | Output/instruction change; no false published claim | Publisher |
| Metadata schema | Schema 3 with optional signature fields | Schema 3; runtime requires populated valid signatures | No schema-number migration | Parser compatibility preserved, runtime policy tightened | All |
| Helper wire/journals | Protocol v1 and existing journal formats | Preserved internally and still readable | No operator conversion | Recovery compatibility preserved | All |
| Native runtime maturity | Preview/candidate-only overall; some prose is stale about normal CI | Still preview/candidate-only; exact normal jobs marked passed, credential gates remain pending | Do not market as production-ready | Documentation correction only | Native hosts |

## Trust and Durability Timeline

| Stage | Mandatory proof in 3.0 | Required failure point |
| --- | --- | --- |
| Publisher finalization | Active private/public match proven; hosted or explicit prior index signature verified against trusted old/new map, or explicit initialization backed by hosted absence; history and remote revision frozen; hooks complete; artifact rehashed; descriptor/index rebuilt and signed; manifest matches final bytes | Before build continuation for key/history failure, and before provider/manual output for final validation |
| Ordered publication | Versioned artifact/descriptor uploaded first; hosted descriptor/artifact verified; prior hash/ETag rechecked; signed index uploaded last with the provider's revision precondition; hosted selection verified | Before the index write and before reporting publication success |
| Manual handoff | Same strict local final-output validation; explicit `not uploaded` status and exact public-key validation instructions | Before printing that the manual package is ready |
| Configuration | Absolute archive URL when a session starts, non-empty expected package ID, at least one valid 32-byte Ed25519 public key, and a durable recovery store for the controller | Constructor/session validation |
| Check | Valid signed `app-archive.json`, eligible selected item, valid signed `release.json`, descriptor/index binding, expected package identity, updater/OS/channel policy | Before returning `UpdateCheckResult` |
| Download | Library-issued check result owned by the configured client, descriptor signature re-verification, expected package identity | Before artifact request |
| Verify/stage | Exact artifact length and SHA-256, safe extraction, platform trust, signed descriptor digest, package ID, nonce, immutable entry inventory | Before returning `UpdateStageResult` |
| App persistence | Lowercase UUID plus expected version/nullable-build/package/channel and stage-provenance digest durably stored, read back, compared field-for-field, and cross-bound to the same retained stage | Before any platform install call; write/read/cross-stage error or mismatch means zero channel calls |
| Native adapter | Freshly resolved retained stage, single-use dispatch state, artifact digest, package ID, transaction ID; running install root/executable proof derived from process context; Windows Inno signer/elevation policy derived from the authenticated staged descriptor | Before crossing privilege boundary |
| Helper prepare | Sealed policy, helper identity, target proof, stage provenance, signature evidence, target lock, durable journal | Before target mutation |
| Commit/recovery | Valid reservation token and response digest; read-only query on all platforms; atomic mutating resolver on Windows; query/recover on macOS/Linux; marker retained across ambiguous transport loss | Before caller exit acknowledgement, recovery mutation, or marker clearing |
| Relaunch | Verified terminal filesystem state; at-most-once relaunch evidence remains separate from rollback success | After commit/recovery |

---

## File and Interface Map

The following is the planned change set. Each grouped entry gives the reason
for every file in that group.

### Contract, public Dart API, and publishing

- Create `docs/design-docs/2026-08-03-desktop-updater-3-0-contract.md` to
  preserve the frozen decisions, compatibility boundary, and trust timeline
  independently of this execution ledger.
- Modify `lib/desktop_updater.dart` to remove raw staged install and the two
  compatibility parameters, remove the stateless check/download pair, and add
  `createZipFirstUpdateSession` with mandatory trust and identity. Define
  `ZipFirstUpdateSession` in this same Dart library so `DesktopUpdater` can use
  its private constructor while the wrapped `UpdateClient` remains internal to
  the session.
- Modify `lib/updater_controller.dart` to require keys, package identity, and
  `UpdateRecoveryStore`; remove unsigned/diagnostics fields; retain one
  `UpdateClient`; and make write-plus-readback persistence a hard precondition
  of platform handoff. Its public `forTesting` constructor requires and
  validates the same URL, key, identity, and store inputs; only collaborator
  injection remains test-specific.
- Modify `lib/src/core/update_recovery.dart` to add a v3 marker factory with
  required transaction, package, version/nullable-build/channel, staging path,
  and stage-provenance digest while preserving decode of 2.x markers with
  missing fields. Document that `writePendingInstall` returns only after
  durable persistence.
- Create `lib/src/core/install_handoff.dart` as a package-internal home for the
  opaque persistence receipt and exact marker readback comparison. Do not
  export it from `lib/desktop_updater.dart`.
- Modify `lib/desktop_updater_platform_interface.dart` to replace legacy
  install/runtime-type fallback extensions. Co-locate the sealed request,
  its private implementation, and `dispatchVerifiedInstall` in this library so
  Dart privacy is implementable. Expose read-only query through a base recovery
  capability, macOS/Linux recover through a query-and-recover capability, and
  Windows resolve through an atomic-after-exit capability.
- Modify `lib/desktop_updater_method_channel.dart` to remove zone-based legacy
  dispatch and send only required verified evidence while retaining internal
  channel method names.
- Modify `lib/src/core/update_client.dart` to make signatures and expected
  identity mandatory, give each client a private owner token, bind download to
  that token, make final result construction private to the library, define
  the single-use check/stage state machine, and expose only an `@internal`
  `claimRetainedVerifiedStageForDispatch` function that atomically checks the
  private owner binding, marks the stage consumed before its first `await`, and
  returns a privately constructed immutable retained-stage view.
- Modify `lib/src/core/release_index.dart` so parsed item collections are
  `List.unmodifiable`; public result immutability must be deep enough that an
  owner-bound index/descriptor binding cannot be mutated between check and
  download.
- Modify `lib/src/release_cli/publish_command.dart` and
  `lib/src/release_cli/release_publisher.dart` so canonical publish rejects
  missing signing/history options before build work, parses
  `--public-keys-env`, `--existing-app-archive`, and `--initialize-feed`,
  derives and matches the active public key, acquires and verifies prior
  history, signs final descriptor and index after hooks, writes the manifest
  last, strictly validates locally, and then uses conditional ordered
  publication.
- Reuse `ReleaseDescriptorSigner` and `ReleaseIndexSigner` from
  `lib/src/release_cli/sign_command.dart` without duplicating canonical
  encoding. Modify `lib/src/release_cli/publish_manifest.dart` so its bindings
  are computed from final signed output and it produces phase-scoped
  custom-command views with an isolated `localRoot` and no disallowed local
  paths.
- Modify `lib/src/release_cli/validate_command.dart` so normal hosted
  validation removes `--require-signature`, requires `--public-keys-env`, and
  always verifies signatures. Make the generative `ReleaseValidator`
  constructor private; add `ReleaseValidator.production(publicKeys: ...)` and
  a non-CLI `ReleaseValidator.candidateOnlyForTesting()` that always emits the
  literal `candidate-only` label.
- Modify `lib/src/release_cli/release_command.dart` so help text and examples
  describe mandatory signing.
- Modify `lib/src/release_cli/doctor_command.dart` to stop recommending a
  descriptor-signing post-package hook and diagnose missing canonical signing.
- Modify `lib/src/release_cli/upload/custom_command_upload_provider.dart` so it
  implements `OrderedUploadProvider` and runs isolated `versioned` and `index`
  phases; modify
  `lib/src/release_cli/upload/manual_upload_provider.dart`,
  `lib/src/release_cli/upload/upload_provider.dart`,
  `lib/src/release_cli/upload/s3_upload_provider.dart`,
  `lib/src/release_cli/upload/ftp_upload_provider.dart`,
  `lib/src/release_cli/upload/sftp_upload_provider.dart`, and
  `lib/src/release_cli/release_publish_config.dart` for strict local validation,
  prior-index acquisition/initialization, frozen remote revision, and exact
  phase configuration. Define `RemoteIndexRevision` and `IndexPublishReceipt`
  in `upload_provider.dart`. Delete the unordered upload fallback: manual is
  the only non-uploading exception, and every automatic provider must implement
  ordered index-last publication with a revision precondition.
- Modify `lib/src/cli/desktop_updater_cli.dart`,
  `lib/src/cli/package_command.dart`, `lib/src/cli/verify_command.dart`,
  `lib/src/package/app_archive_command.dart`,
  `lib/src/package/app_archive_writer.dart`, and
  `lib/src/package/zip_release_packager.dart` so unsigned output is explicitly
  candidate-only, strict verify requires public keys, and a signed archive
  cannot be silently invalidated by upsert.
- Modify `test/desktop_updater_test.dart`,
  `test/updater_controller_test.dart`,
  `test/update_recovery_test.dart`,
  `test/desktop_updater_method_channel_test.dart`, and
  `test/update_client_security_test.dart` to prove the new API, request
  owner binding, atomic single-use dispatch claim, durable marker readback,
  early signature rejection, package mismatch rejection, and minimal target
  payload. Assert Dart sends no
  `removedFiles`, signer-thumbprint, elevation-policy, install-root, or
  executable override. Invert the current test that
  permits native handoff after recovery-store failure: store write/read failure
  or mismatch must produce zero channel calls.
- Replace `test/compat/flutter_220_public_api_test.dart` with
  `test/compat/flutter_300_public_api_test.dart`, and replace
  `test/compat/flutter_220_channel_controller_contract_test.dart` with
  `test/compat/flutter_300_channel_controller_contract_test.dart`, because the
  old tests explicitly require the compatibility surface being removed.
- Replace `test/compat/diagnostics_recovery_220_contract_test.dart` with
  `test/compat/diagnostics_recovery_300_contract_test.dart` and
  `test/compat/cli_220_contract_test.dart` with
  `test/compat/cli_300_contract_test.dart`.
- Create `test/v3_removed_api_contract_test.dart` to assert removed Dart,
  Swift, C++, C ABI, and .NET names stay absent and to exercise negative
  analyzer fixtures.
- Create the real expected-failure consumers under
  `test/fixtures/v3_removed_api/dart/`, `swift/`, `windows-c/`,
  `windows-cpp/`, `windows-dotnet/`, and `linux-cmake/`; each platform lane
  compiles its own fixtures rather than relying on source scans.
- Modify `test/release_index_signature_verifier_test.dart`,
  `test/release_signature_verifier_test.dart`, and
  `test/staged_update_provenance_test.dart` to cover the mandatory trust
  chain.
- Modify `test/release_cli/release_publish_config_test.dart`,
  `test/release_cli/release_publisher_build_test.dart`,
  `test/release_cli/publish_manifest_test.dart`,
  `test/release_cli/release_sign_command_test.dart`,
  `test/release_cli/release_validate_test.dart`, and
  `test/release_cli/release_doctor_test.dart` to reject unsigned canonical
  publication, an invalid/unknown-key prior index, active-key/map mismatch,
  clean-output history loss, implicit initialization, concurrent remote-index
  change, and unordered providers. Cover valid old-to-new key rotation,
  explicit proven-new initialization, and explicitly signed prior-index input
  while retaining labeled fixture/candidate mechanics.
- Modify `test/desktop_updater_cli_test.dart`,
  `test/release_cli/release_command_test.dart`,
  `test/app_archive_command_test.dart`, `test/app_archive_writer_test.dart`,
  `test/zip_release_packager_test.dart`, and create
  `test/verify_command_signature_policy_test.dart` to cover strict production
  verification, explicit candidate mode, and signed-archive invalidation.
- Modify `test/release_cli/upload/custom_command_upload_provider_test.dart`,
  `test/release_cli/upload/manual_upload_provider_test.dart`,
  `test/release_cli/upload/s3_upload_provider_test.dart`,
  `test/release_cli/upload/ftp_upload_provider_test.dart`, and
  `test/release_cli/upload/sftp_upload_provider_test.dart` to prove ordered
  upload, physical phase isolation, remote-revision recheck/preconditioning,
  and deterministic refusal rather than lost updates on concurrent index
  publication.
- Modify `test/fixtures/release_publish_project.dart`,
  `test/fixtures/release_fixture_builder.dart` (the shared builder emits a
  deterministic signed index and signed descriptor by default; its only
  unsigned mode is an explicit `candidateOnly: true` fixture),
  `test/e2e/release_publish_e2e_helpers.dart`,
  `test/e2e/release_publish_manual_e2e_test.dart`,
  `test/e2e/release_publish_custom_command_e2e_test.dart`,
  `test/e2e/release_publish_s3_e2e_test.dart`,
  `test/e2e/release_publish_ftp_e2e_test.dart`,
  `test/e2e/release_publish_sftp_e2e_test.dart`,
  `test/e2e/fixtures/upload_commands/copy_updates.dart`,
  `example/tool/release_publish_smoke.dart`, and
  `test/release_publish_smoke_tool_test.dart` so no-hook signed publish succeeds
  and post-package artifact mutation, wrong-key, descriptor/index tampering,
  and early-index publication fail.

### Flutter platform adapters and host smoke

- Modify `macos/desktop_updater/Sources/desktop_updater/DesktopUpdaterPlugin.swift`,
  `windows/desktop_updater_plugin.cpp`, and
  `linux/desktop_updater_plugin.cc` to derive target proof from the running
  host, reload the retained stage marker, and reject incomplete verified
  payloads. The Windows adapter derives Inno Authenticode thumbprints and
  elevation policy from the authenticated staged descriptor rather than Dart
  scalar fields.
- Modify `macos/desktop_updater/Tests/desktop_updaterTests/DesktopUpdaterSwiftPMTests.swift`,
  `windows/test/desktop_updater_plugin_test.cpp`, and
  `linux/test/desktop_updater_plugin_test.cc` to prove missing proof and old
  payloads fail and the new payload succeeds.
- Modify `example/lib/app.dart`,
  `example/macos/Runner/AppDelegate.swift`,
  `example/tool/updater_smoke.dart`, and
  `example/tool/hosted_update_smoke.dart` to configure pinned keys/package
  identity, use app-owned diagnostics, and persist transaction IDs.
- Modify `tool/windows_direct_flutter_smoke.ps1`,
  `tool/macos_production_smoke.dart`,
  `tool/macos_privileged_pkg_smoke.dart`, and
  `tool/macos_privileged_pkg_recovery_smoke.dart` to stop passing a helper log
  path and to collect app-owned diagnostics plus fixed platform evidence.
- Preserve the existing signed schema-v3 metadata and deterministic public-key
  output in `tool/native_runtime_smoke_server.dart`; modify only its v3
  prepare/commit/diagnostics consumer contract. Keep
  `--allow-unsigned-artifact` only for an explicit negative platform-artifact
  trust fixture; it must not disable either metadata signature.
- Modify `test/example_hosted_smoke_config_test.dart`,
  `test/windows_release_smoke_config_test.dart`,
  `test/macos_release_smoke_config_test.dart`, and
  `test/linux_release_smoke_config_test.dart` to guard the signed fixture and
  app-owned evidence flow.
- Modify `test/native_helper_script_test.dart` to assert every helper-smoke
  invocation uses explicit transaction state and no removed diagnostics or
  scheduling option.
- Modify `test/e2e/zip_first_update_flow_test.dart`,
  `test/native_runtime_resource_limits_test.dart`,
  `test/updater_controller_release_notes_test.dart`, and
  `test/update_dialog_listener_test.dart` for the required session/controller
  collaborators without weakening their original behavioral assertions.

### macOS helper and SwiftPM runtime

- Modify
  `macos/desktop_updater/Sources/DesktopUpdaterKit/MacInstallRequest.swift`
  to keep only a verified-stage initializer and remove unsigned and diagnostics
  fields.
- Modify
  `macos/desktop_updater/Sources/DesktopUpdaterKit/MacInstallHelper.swift` to
  remove scheduling and generated-ID prepare while retaining explicit prepare,
  commit, cancel, query, and recover.
- Modify `macos/install_helper/Sources/DesktopUpdaterInstallHelper/TransactionJournal.swift`,
  `macos/install_helper/Sources/DesktopUpdaterInstallHelper/MacPersistentRecovery.swift`,
  and
  `macos/install_helper/Sources/DesktopUpdaterInstallHelper/MacVerifiedInstallerTransaction.swift`
  only to keep the frozen schema-1/schema-2 readers reachable from the new
  public flow; do not bump writer schemas or rewrite on read.
- Modify
  `macos/desktop_updater/Sources/DesktopUpdaterKit/Runtime/RuntimeError.swift`
  to remove signature-disable configuration fields and require non-empty keys.
- Modify
  `macos/desktop_updater/Sources/DesktopUpdaterKit/Runtime/ArtifactStager.swift`
  and
  `macos/desktop_updater/Sources/DesktopUpdaterKit/Runtime/UpdateClient.swift`
  to replace `installAndRelaunch` with explicit staged prepare/commit APIs.
- Modify
  `macos/desktop_updater/Tests/DesktopUpdaterKitTests/MacInstallHelperTests.swift`,
  `MacPackagedHelperTransportTests.swift`,
  `DesktopUpdaterKitPublicAPITests.swift`,
  `RuntimeAPITests.swift`, and `UpdateClientTests.swift` in the same test
  directory to prove removed overloads, explicit IDs, required signatures,
  recovery, and the successful new path.
- Modify
  `macos/install_helper/Tests/DesktopUpdaterInstallHelperTests/MacPersistentRecoveryTests.swift`,
  `MacVerifiedInstallerTransactionTests.swift`, and
  `MacCrashRecoveryTests.swift` in that directory for frozen bytes and
  fresh-process recovery.
- Use the common frozen 2.7 macOS journal fixtures from Task 1 and test that 3.0
  reads them without rewriting bytes until an explicit recovery mutation.
- Modify `example/native/macos/Sources/DesktopUpdaterConsumer/main.swift` and
  `example/native/macos-runtime/Sources/MacOSRuntimeCompile/main.swift` as the
  compile-tested helper-only and runtime migrations.
- Modify `test/macos_swift_package_test.dart`,
  `test/native_sdk_consumer_package_test.dart`, and
  `test/macos_privileged_helper_smoke_contract_test.dart` to guard SwiftPM
  product/import stability and the new transaction surface.
- Modify
  `macos/install_helper/Sources/DesktopUpdaterInstallHelper/HelperVersion.swift`,
  `macos/install_helper/Configuration/Helper-Info.plist`,
  `macos/install_helper/Tests/DesktopUpdaterInstallHelperTests/HelperVersionTests.swift`,
  `test/macos_native_helper_layout_test.dart`, and
  `test/macos_notarized_publish_smoke_config_test.dart` so the helper package
  version is generated and notarized candidate evidence remains separately
  labeled.

### Windows C++, C ABI, .NET, and runtime

- Modify `windows/native/include/desktop_updater_native.h` and
  `windows/native/src/desktop_updater_native.cpp` to remove diagnostics,
  schedule, implicit prepare, and public mutating recover; retain read-only
  query and make explicit-ID prepare plus atomic resolver canonical.
- Modify
  `windows/native/src/helper/windows_recovery_pipe_server.cpp` and its
  persistent/crash-recovery tests so the app-facing protocol-1 dispatcher
  rejects direct `recoverPendingInstall` without disabling helper-internal
  autonomous recovery.
- Modify `windows/native/src/helper/windows_install_authorizer.cpp`,
  `windows/native/src/helper/helper_policy_windows.h`,
  `windows/native/src/helper/helper_policy_windows.cpp`, and
  `windows/native/test/helper/windows_install_authorizer_test.cpp` so sealed
  release-root keys and the authenticated staged descriptor, not Dart/C ABI
  policy scalars, determine Inno signer and elevation policy.
- Modify `windows/native/include/desktop_updater_native_c.h`,
  `windows/native/src/desktop_updater_native_c.cpp`, and
  `windows/native/src/desktop_updater_native_c_internal.h` to define ABI-2
  request/status/handle contracts under collision-free `*_abi2` entry points,
  omit public v1 declarations, and reject old versions before reading
  version-dependent layout. Keep the exported
  `desktop_updater_prepare_install_v2` function with its exact frozen 2.7
  ABI-1 signature as a deterministic rejecting shim; do not declare it in the
  3.0 header and do not route it through ABI-2 structs.
- Modify `windows/native/src/helper/windows_transaction_journal.cpp`,
  `windows/native/src/helper/windows_persistent_recovery.cpp`,
  `windows/native/src/helper/windows_portable_transaction_index.cpp`, and
  `windows/native/src/helper/windows_protected_helper_locator.cpp` only to
  route frozen 2.7 state into
  query/resolver without bumping schemas or rewriting on read.
- Modify `windows/native/include/desktop_updater_version.h` to set native ABI
  marker 2 and later synchronize package version 3.0.0.
- Modify `windows/native/include/desktop_updater_runtime_c.h` and
  `windows/native/src/runtime/desktop_updater_runtime_c.cpp` to expose runtime
  ABI 2 with mandatory pinned keys and explicit
  prepare/commit/cancel/read-only-query/resolver.
- Modify `windows/native/src/runtime/artifact_stager_windows.h` and
  `artifact_stager_windows.cpp` to return verified staged handoff state
  instead of scheduling directly.
- Modify `native_runtime/cpp/update_client_core.h` and
  `native_runtime/cpp/update_client_core.cc` to remove signature-disable
  switches and require key-backed signed index/descriptor validation.
- Modify `windows/native/dotnet/DesktopUpdater.Native/DesktopUpdaterNative.cs`
  to P/Invoke the new `*_abi2` family and expose only explicit prepare, commit,
  cancel, read-only query, and resolver.
- Modify `windows/native/dotnet/DesktopUpdater.Native/DesktopUpdaterClient.cs`
  to remove signature flags, diagnostics, scheduling, one-argument prepare,
  and mutating recover overloads; retain read-only query and add retained-stage
  explicit prepare.
- Modify `windows/native/dotnet/DesktopUpdater.Native/README.md` for the exact
  NuGet migration and protected-helper provisioning requirements.
- Modify
  `windows/native/test/desktop_updater_native_c_test.cpp`,
  `windows/native/test/runtime/runtime_c_api_compile_test.cpp`,
  `native_runtime/cpp/contract_fixture_tests.cc`, and
  `native_runtime/cpp/update_client_core_fixture_tests.cc` to prove ABI-1
  rejection, ABI-2 success, signature enforcement, resolver behavior, and
  unchanged journal recovery. Test `auto`, `always`, and `never` Inno elevation,
  signer mismatch, staged-descriptor tampering, truncated ABI-2 prefixes, and
  ABI-1 values with guard pages/ASan so no later field is read.
- Modify
  `windows/native/test/helper/windows_persistent_recovery_test.cpp`,
  `windows_portable_transaction_index_test.cpp`,
  `windows_protected_helper_locator_test.cpp`,
  `windows_crash_recovery_test.cpp`, and
  `windows_recovery_host_test.cpp` in the corresponding helper test directory
  for frozen-reader, read-only-query, rejected direct-recover, resolver-race,
  and internal autonomous-recovery coverage.
- Modify
  `windows/native/dotnet/DesktopUpdater.Native.Tests/DesktopUpdaterNativeTests.cs`
  and `DesktopUpdaterClientTests.cs` to use reflection/compilation assertions
  for removed overloads plus real DLL P/Invoke for the new path.
- Modify `example/native/windows-cmake/main.cpp`,
  `example/native/windows-dotnet/Program.cs`, and
  `example/native/windows-dotnet-runtime/Program.cs` as compile-tested C ABI,
  helper-only .NET, and runtime migrations.
- Compile the common frozen 2.7 C and .NET probes only against their frozen
  header/PInvoke declarations, then execute them against the 3.0 DLL. Use the
  common frozen Windows transaction/record/claim/locator fixtures to prove
  read-only query and atomic resolver do not eagerly rewrite old state.
- Modify `tool/verify_windows_nuget_consumer.ps1` and
  `.github/workflows/desktop-updater-ci.yml` to verify the ABI-2 DLL, package
  inventory, signed metadata fixture, frozen probes, real removed-API compile
  fixtures, signed no-hook/custom publication, installed consumers, and
  required normal jobs on their owning hosts.
- Modify `windows/native/CMakeLists.txt`,
  `tool/windows_install_helper_smoke.ps1`,
  `tool/windows_inno_smoke.ps1`, `test/native_package_retail_contract_test.dart`,
  and `test/native_runtime_merge_gate_contract_test.dart` to distinguish NuGet
  discovery assets from installer-owned protected helper authority. The NuGet
  verifier hashes the helper, sealed policy, helper DLL, and runtime DLL;
  protected provisioning installs the exact signed helper and required sealed
  policy as an immutable pair. CMake/NuGet installation is explicitly a
  compile-time locator/discovery mechanism and never claims to provision that
  protected authority.

### Linux helper, CMake, and runtime

- Modify `linux/native/include/desktop_updater_native.h` and
  `linux/native/src/desktop_updater_native.cc` to remove schedule,
  diagnostics, legacy self-contained proof, and generated IDs; keep
  explicit-ID prepare/commit/cancel/query/recover. Preserve the stronger
  non-legacy rule that the canonical running executable must match the exact
  root/relative path and the root must contain a matching installed identity
  marker; neither proof is sufficient alone.
- Modify `linux/native/include/desktop_updater_runtime.h`,
  `linux/native/src/runtime/runtime_configuration.cc`,
  `linux/native/src/runtime/update_client_linux.cc`,
  `linux/native/src/runtime/artifact_stager_linux.h`, and
  `linux/native/src/runtime/artifact_stager_linux.cc` to require signatures
  and expose retained-stage explicit prepare.
- Modify `linux/native/src/helper/linux_transaction_journal.cc`,
  `linux/native/src/helper/linux_transaction_registry.cc`, and
  `linux/native/src/helper/linux_provider_journal.cc` only to keep
  frozen schema readers reachable from explicit-ID query/recover; do not bump
  writer schemas or rewrite on read.
- Modify `linux/native/include/desktop_updater_version.h` to set API marker 2
  and later synchronize package version 3.0.0.
- Modify `linux/native/test/desktop_updater_native_test.cc`,
  `linux/native/test/runtime/client_lifecycle_test.cc`,
  `linux/native/test/runtime/contract_conformance_test.cc`,
  `linux/native/test/linux_commit_caller_fixture.cc`, and
  `linux/native/test/linux_polkit_e2e_fixture.cc` to cover the explicit
  transaction, target proof, successful new path, legacy rejection, and
  installed-polkit boundary.
- Modify `linux/native/test/helper/linux_transaction_registry_test.cc` and
  `linux_crash_recovery_test.cc` in that directory for frozen transaction,
  registry, provider-journal, and fresh-process recovery coverage.
- Modify `example/native/linux-cmake/main.cpp` and
  `example/native/linux-cmake-runtime/main.cpp` as compile-tested helper-only
  and runtime migrations.
- Modify `linux/native/README.md`, whose 2.x example advertises
  `InstallAndRelaunch`, to show installed source-first prepare/commit/recovery
  and the required identity-marker provisioning.
- Modify `test/linux_native_sdk_layout_test.dart`,
  `test/native_runtime_api_contract_test.dart`,
  `test/native_runtime_staging_contract_test.dart`, and
  `test/native_runtime_conformance_contract_test.dart` to guard source-first
  API marker 2, absent legacy names, mandatory trust, and fixture parity.
- Modify `test/windows_native_sdk_layout_test.dart`,
  `test/native_runtime_contract_matrix_test.dart`,
  `test/native_runtime_diagnostics_contract_test.dart`, and
  `test/native_runtime_smoke_contract_test.dart` to guard ABI-2 package
  inventory, the cross-platform explicit transaction surface, app-owned
  diagnostics, and signed smoke configuration.
- Modify `tool/linux_install_helper_smoke.sh` only to supply the explicit
  transaction and app-owned evidence; keep fixed helper syslog/events sinks and
  sealed polkit policy unchanged.
- Create frozen 2.7 Linux transaction/registry/provider fixtures in the common
  durable-state compatibility fixture set and prove a fresh 3.0 process reads
  them without eager reserialization before recovery.

### Documentation and migration

- Create `docs/migration/2.x-to-3.0.md` with the outline in this plan.
- Modify `lib/src/migrate/migration_tool.dart`, `bin/migrate.dart`, and
  `test/migration_tool_test.dart` to version the existing migrator. Add
  a required `--from 1|2`: lane 1 transforms supported simple 1.x constraints,
  treats only its exact tool-owned `^2.0.0` output as an idempotent no-op, and
  rejects other 2.x or all 3.x scalars as source-major mismatch. Lane 2
  transforms supported simple 2.x constraints, treats simple 3.x as a no-op,
  and rejects 1.x as source-major mismatch. Mismatch is a nonzero no-write;
  path/git/SDK/nested/ambiguous constraints are report-only no-writes. Never
  invent keys, package identity, durable storage, target proof, or native ABI
  edits.
- Modify `README.md`, `ARCHITECTURE.md`, and `docs/index.md` so the
  canonical controller, trust boundary, migration route, and current evidence
  are discoverable.
- Modify `docs/native-sdk.md`, `docs/native-runtime-api.md`,
  `docs/native-contract.md`, and `docs/native-install-helper-protocol.md` to
  remove compatibility claims, correct signed-index authority, document
  per-platform recovery, and keep preview maturity literal.
- Modify `doc/runtime-request-headers.md`, `linux/native/README.md`, and
  `docs/macos-dmg-pkg-installer-updates.md` so low-level session ownership,
  Linux source-first migration, and Ed25519-versus-Apple signing boundaries do
  not retain 2.x examples.
- Modify `docs/diagnostics-and-recovery.md` to delete the compatibility-path
  example and document only app-owned diagnostics plus fixed helper sinks.
- Modify `docs/publishing.md` to require signed archive/descriptor publishing,
  explain the trusted old/new rotation map, hosted versus explicit signed
  history, `--initialize-feed`, concurrent-publisher preconditions, and app key
  pin rollout, and distinguish Ed25519 metadata trust from Authenticode, Apple
  signing/notarization, and Linux package trust.
- Modify `docs/ui-widgets.md`, `docs/localization.md`, and `docs/i18n.md`
  so every controller example includes required keys, package identity, and a
  durable recovery store.
- Modify `docs/windows-inno-installer-updates.md`,
  `docs/windows-linux-production-release.md`, and
  `docs/github-actions-ci-cd.md` for ABI-2 provisioning, source-first Linux,
  signed fixtures, normal-CI evidence, and separate credential gates.
- Modify `docs/migration/1.x-to-2.0.md` only by adding a historical-version
  banner, the explicit `--from 1` invocation, and a link to the 2.x-to-3.0
  guide; do not rewrite what 2.x did.
- Modify active overlapping ledgers
  `docs/exec-plans/active/2026-07-10-native-runtime-merge-blocker-remediation-plan.md`
  and
  `docs/exec-plans/active/2026-07-21-windows-linux-production-readiness.md`
  with a dated cross-reference where 3.0 supersedes their compatibility or
  evidence wording. Do not mechanically rewrite completed plans or historical
  design documents.
- Modify `test/native_sdk_docs_test.dart`,
  `test/native_runtime_merge_gate_docs_test.dart`,
  `test/native_helper_diagnostics_docs_test.dart`, and
  `test/harness_engineering_docs_test.dart` to keep documentation claims and
  links executable. Update `test/release_index_test.dart` to require deeply
  unmodifiable parsed index items and `test/native_helper_script_test.dart` to
  guard changed helper invocations.

### Version and release preparation

- Modify `pubspec.yaml` to `3.0.0` and add the 3.0 breaking section to
  `CHANGELOG.md` only after all earlier tasks pass.
- Modify and then run `tool/sync_versions.dart`, which intentionally owns and
  updates
  `lib/src/package_version.dart`,
  `macos/desktop_updater/Sources/DesktopUpdaterKit/DesktopUpdaterVersion.swift`,
  `macos/install_helper/Sources/DesktopUpdaterInstallHelper/HelperVersion.swift`,
  both version keys in
  `macos/install_helper/Configuration/Helper-Info.plist`,
  `windows/native/include/desktop_updater_version.h`,
  `linux/native/include/desktop_updater_version.h`,
  `windows/native/CMakeLists.txt`, `linux/native/CMakeLists.txt`,
  `windows/native/dotnet/DesktopUpdater.Native/DesktopUpdater.Native.csproj`,
  `example/native/windows-cmake/CMakeLists.txt`,
  `example/native/windows-dotnet-runtime/DesktopUpdater.RuntimeCompile.csproj`,
  `linux/native/cmake/desktop_updater_native.pc.in`,
  `example/native/linux-cmake/CMakeLists.txt`, and
  `example/native/linux-cmake-runtime/CMakeLists.txt`. Update
  `tool/version_check.dart`,
  create `test/version_sync_test.dart`, and update
  `macos/install_helper/Tests/DesktopUpdaterInstallHelperTests/HelperVersionTests.swift`,
  `test/macos_native_helper_layout_test.dart`, and `test/native_sdk_docs_test.dart`
  to enforce the expanded generated surface.
- Keep `example/native/macos/Package.swift` and
  `example/native/macos-runtime/Package.swift` as local path dependencies so
  they compile-test the current worktree; change only public dependency
  snippets that resolve a tagged 3.0.0 package. Classify the Flutter local-pod
  `macos/desktop_updater.podspec` version `0.0.1` explicitly as non-canonical if
  it remains unchanged.
- Classify every remaining literal `2.7.0` before changing it. Package
  dependency/version assertions become 3.0.0. A fixture that represents the
  installed 2.x side of a migration remains 2.7.0. A
  `minimumUpdaterVersion: 2.7.0` value may intentionally remain so a signed
  bridge app can install the first v3 application release.

---

### Task 1: Freeze the Contract in Executable Tests

**Files:** Create the v3 design document and removed/public API tests listed
above; modify no production API in the first red-test step.

**Interfaces:**

- Produces the exact Dart constructor:

~~~dart
DesktopUpdaterController({
  required Uri? appArchiveUrl,
  required String expectedPackageId,
  required Map<String, String> trustedReleasePublicKeys,
  required UpdateRecoveryStore recoveryStore,
  // Preserved lifecycle, UI, diagnostics-recorder, and policy inputs.
});
~~~

- A non-null constructor URL must be absolute and is validated immediately;
  `null` preserves delayed `init(Uri)`, and `init` applies the same validation
  before any request. `DesktopUpdaterController.forTesting` has the same four
  required trust/durability parameters and identical validation; it adds only
  the existing non-authority seams such as platform selection and release-notes
  loading. It must not accept a preconstructed check, stage, verified request,
  or persistence receipt.

- New writes use this factory; the legacy decoder may create an internal
  representation with nullable v3-only getters:

~~~dart
UpdateInstallRecoveryMarker.pendingV3({
  required DateTime createdAt,
  required String packageVersion,
  required String platform,
  required String channel,
  required String updateVersion,
  required int? updateBuildNumber,
  required String expectedPackageId,
  required String stagingPath,
  required String stageProvenanceSha256,
  required String transactionId,
  String? appVersion,
  String? diagnosticsText,
});
~~~

- Produces opaque persisted-install and platform-handoff capabilities:

~~~dart
final class PersistedInstallTransaction {
  const PersistedInstallTransaction._(this.marker);

  final UpdateInstallRecoveryMarker marker;
  String get transactionId => marker.transactionId!;
}

@internal
Future<PersistedInstallTransaction> persistInstallTransaction({
  required UpdateRecoveryStore store,
  required UpdateInstallRecoveryMarker marker,
});

sealed class VerifiedNativeInstallRequest {
  const VerifiedNativeInstallRequest._();

  String get stagingPath;
  String get expectedPackageId;
  String get expectedArtifactSha256;
  String get stageProvenanceSha256;
  String get transactionId;
}

typedef NativeInstallStatusOperation =
    Future<NativeInstallTransactionStatus?> Function(String id);

sealed class NativeInstallRecovery {
  const NativeInstallRecovery._();
  Future<NativeInstallTransactionStatus?> queryInstallTransaction(String id);
}

final class QueryAndRecoverNativeInstallRecovery
    extends NativeInstallRecovery {
  QueryAndRecoverNativeInstallRecovery({
    required NativeInstallStatusOperation query,
    required NativeInstallStatusOperation recover,
  })  : _query = query,
        _recover = recover,
        super._();

  final NativeInstallStatusOperation _query;
  final NativeInstallStatusOperation _recover;

  @override
  Future<NativeInstallTransactionStatus?> queryInstallTransaction(String id) =>
      _query(id);
  Future<NativeInstallTransactionStatus?> recoverPendingInstallTransaction(
    String id,
  ) => _recover(id);
}

final class AtomicAfterExitNativeInstallRecovery
    extends NativeInstallRecovery {
  AtomicAfterExitNativeInstallRecovery({
    required NativeInstallStatusOperation query,
    required NativeInstallStatusOperation resolveAfterExit,
  })  : _query = query,
        _resolveAfterExit = resolveAfterExit,
        super._();

  final NativeInstallStatusOperation _query;
  final NativeInstallStatusOperation _resolveAfterExit;

  @override
  Future<NativeInstallTransactionStatus?> queryInstallTransaction(String id) =>
      _query(id);
  Future<NativeInstallTransactionStatus?>
      resolvePendingInstallTransactionAfterExit(String id) =>
          _resolveAfterExit(id);
}

abstract class DesktopUpdaterPlatform extends PlatformInterface {
  Future<void> installVerifiedUpdate(VerifiedNativeInstallRequest request);
  NativeInstallRecovery get nativeInstallRecovery;
}

// This function, _VerifiedNativeInstallRequest, and the sealed request above
// live in desktop_updater_platform_interface.dart.
@internal
Future<void> dispatchVerifiedInstall({
  required UpdateStageResult stageResult,
  required PersistedInstallTransaction persistedTransaction,
});
~~~

- The request's private implementation is constructed only by the dispatcher
  in the same Dart library. The dispatcher accepts a final library-issued
  `UpdateStageResult` and a `PersistedInstallTransaction`, calls
  `claimRetainedVerifiedStageForDispatch`, requires the marker's updater-package
  version to equal the running package, and compares platform, staging path,
  expected package ID, update version/nullable-build/channel, and provenance
  digest against the freshly claimed stage. It separately requires one canonical
  lowercase UUID to be identical in the receipt, marker, and constructed
  request before constructing that request.
  macOS/Linux return `QueryAndRecoverNativeInstallRecovery`; Windows returns
  `AtomicAfterExitNativeInstallRecovery`. `null` from query means an
  authenticated, well-formed helper response proving the transaction absent;
  unsupported platforms, transport loss, endpoint authentication failure, and
  parse/protocol failure throw. No `runtimeType` check or fallback returns null
  silently. Because the base is sealed and both variants are final, an external
  custom platform constructs exactly one provided callback-backed variant; it
  cannot return a base-only or hybrid recovery model.

- Produces a per-client low-level contract:

  `UpdateCheckResult`, `UpdateStageResult`, `RetainedVerifiedStage`, and its
  resolver live in `lib/src/core/update_client.dart`.
  `ZipFirstUpdateSession` and `DesktopUpdater` live together in
  `lib/desktop_updater.dart`; this co-location is required for the session's
  private constructor.

~~~dart
final class UpdateCheckResult {
  const UpdateCheckResult._({
    required this.index,
    required this.item,
    required this.descriptor,
    required Object ownerToken,
    required String descriptorBindingSha256,
  })  : _ownerToken = ownerToken,
        _descriptorBindingSha256 = descriptorBindingSha256;

  final ReleaseIndex index;
  final ReleaseIndexItem item;
  final ReleaseDescriptor descriptor;
  final Object _ownerToken;
  final String _descriptorBindingSha256;
}

final class UpdateStageResult {
  const UpdateStageResult._({
    required this.descriptor,
    required this.stagingPath,
    required this.stageProvenanceSha256,
    required this.stageProvenance,
    required Object ownerToken,
    required String descriptorBindingSha256,
  })  : _ownerToken = ownerToken,
        _descriptorBindingSha256 = descriptorBindingSha256;

  final ReleaseDescriptor descriptor;
  final String stagingPath;
  final String stageProvenanceSha256;
  final StagedUpdateProvenance stageProvenance;
  final Object _ownerToken;
  final String _descriptorBindingSha256;
}

final class RetainedVerifiedStage {
  const RetainedVerifiedStage._({
    required this.stageRoot,
    required this.stagingPath,
    required this.platform,
    required this.expectedPackageId,
    required this.updateVersion,
    required this.updateBuildNumber,
    required this.channel,
    required this.expectedArtifactSha256,
    required this.stageProvenanceSha256,
  });

  final String stageRoot;
  final String stagingPath;
  final String platform;
  final String expectedPackageId;
  final String updateVersion;
  final int? updateBuildNumber;
  final String channel;
  final String expectedArtifactSha256;
  final String stageProvenanceSha256;
}

@internal
Future<RetainedVerifiedStage> claimRetainedVerifiedStageForDispatch(
  UpdateStageResult stageResult,
);

final class ZipFirstUpdateSession {
  const ZipFirstUpdateSession._(this._client);

  final UpdateClient _client;

  Future<UpdateCheckResult?> checkForUpdate() => _client.checkForUpdate();
  Future<UpdateStageResult> downloadVerifyAndStage({
    required UpdateCheckResult checkResult,
    void Function(int receivedBytes, int? totalBytes)? onProgress,
  }) => _client.downloadVerifyAndStage(
    checkResult: checkResult,
    onProgress: onProgress,
  );
}

class DesktopUpdater {
  ZipFirstUpdateSession createZipFirstUpdateSession({
    required Uri appArchiveUrl,
    required DesktopVersionInfo currentVersion,
    required String expectedPackageId,
    required Map<String, String> trustedReleasePublicKeys,
    String channel = "stable",
    String? installationIdentity,
    UpdateRequestHeadersProvider? requestHeadersProvider,
    MinimumOSSupportChecker? isMinimumOSSupported,
    DesktopUpdaterTelemetry? telemetry,
  }) => ZipFirstUpdateSession._(
    UpdateClient(
      appArchiveUrl: appArchiveUrl,
      currentVersion: currentVersion,
      expectedPackageId: expectedPackageId,
      trustedReleasePublicKeys: trustedReleasePublicKeys,
      channel: channel,
      installationIdentity: installationIdentity,
      requestHeadersProvider: requestHeadersProvider,
      isMinimumOSSupported: isMinimumOSSupported,
      telemetry: telemetry,
    ),
  );
}
~~~

  `UpdateCheckResult` and `UpdateStageResult` are final with library-private
  constructors. Each `UpdateClient` owns a private token; check captures a
  canonical index/descriptor binding, and download checks token identity,
  recomputes the binding, re-verifies signature/package identity, and only then
  requests artifact bytes. Each successful check replaces the session's active
  result; a null check invalidates it. Staging acquires a single-use lease, so a
  concurrent attempt is rejected and success or failure consumes the result;
  retry requires a new check. Successful staging replaces the active stage.
  Dispatch atomically claims the private owner and binding before the claim
  function's first `await`, rejects a foreign, stale, or already-dispatched
  stage, and leaves the stage consumed even if later validation or the platform
  call fails. Thus two concurrent dispatches cannot both obtain a view or call
  the platform; an ambiguous call is recovered by transaction ID rather than
  replayed. Parsed index item collections become deeply unmodifiable. The old
  stateless facade methods and raw descriptor download are removed.

- [ ] **Step 1: Add failing positive and negative Dart contract tests**

  Write tests that compile the preserved controller/state/widget surface,
  require the new constructor arguments, inspect the MethodChannel's required
  verified payload, and assert the legacy named arguments/method names are
  absent from public sources. The analyzer fixture separately omits each
  required argument from both the primary and `forTesting` constructors. Add
  analyzer fixtures proving callers cannot construct or implement the final
  result, persistence receipt, retained-stage view, or sealed install request
  types, and that a Windows atomic capability has no direct-recover member.

- [ ] **Step 2: Freeze binary and durable-state compatibility inputs**

  Before editing production serializers or headers, create these baseline- or
  explicitly pinned predecessor-generated fixtures and record their SHA-256
  values:

  ~~~text
  test/fixtures/compat/windows-native-abi/2.7.0/
    desktop_updater_native_c.h
    prepare-v2-probe.c
    dotnet-probe/
    SHA256SUMS
  test/fixtures/compat/native-durable-state/2.7.0/
    README.md
    macos/directory-journal-schema1.json
    macos/verified-installer-journal-schema1.json
    macos/verified-installer-journal-schema2.json
    windows/transaction-journal-schema2.json
    windows/persistent-record-schema3.json
    windows/resolver-claim-schema1.json
    windows/portable-locator-schema1.json
    windows/protected-helper-endpoint-schema1.json
    linux/transaction-journal-schema2.json
    linux/transaction-registry-schema2.json
    linux/provider-journal-schema1.json
    SHA256SUMS
  ~~~

  Except for one named predecessor case, "old journals" means exactly the
  formats emitted by baseline 2.7.0. Baseline 2.7 writes macOS verified-
  installer schema 2; preserve schema 1 from writer commit
  `73aa730efbf1384eef9b74d7eb87ee655d81c0b5`, before schema 2 landed in
  `96cc4ecbb009d5be5a50adcbeeedf8fae2dedfa4`, and record that provenance in the
  fixture README. This does not revive pre-payload-seal Windows transaction
  schema 1. Add byte-golden decode/re-encode tests plus frozen baseline and
  predecessor writer subprocesses at prepared crash boundaries; a fresh v3
  process must query and resolve/recover without first rewriting through a v3
  encoder. The protected-helper endpoint fixture must also support fresh
  authenticated locator lookup without rewrite. Reuse existing schema-3
  release and protocol-1 wire fixtures; do not treat the abstract
  `journal-transitions.json` model as serialized platform state.

- [ ] **Step 3: Prove the tests fail against 2.7.0**

  Run:

  ~~~sh
  flutter test --no-pub test/compat/flutter_300_public_api_test.dart
  flutter test --no-pub test/compat/flutter_300_channel_controller_contract_test.dart
  flutter test --no-pub test/v3_removed_api_contract_test.dart
  ~~~

  Expected: failures name the optional trust configuration, raw descriptor
  download, platform fallback, schedule methods, diagnostics path, and unsigned
  flag that still exist.

- [ ] **Step 4: Write the durable contract design**

  Copy the decisions and trust timeline from this plan into the design document
  and link it from `docs/index.md`. State explicitly that fail-closed security
  behavior is distinct from source/ABI breakage.

- [ ] **Step 5: Review gate**

  Have an independent reviewer compare the design and failing tests with the
  exact baseline. Resolve every high/medium finding before changing production
  code.

**Acceptance:** Every breaking decision has a failing executable assertion or
an exact native compile/API assertion. No break is justified only by prose.

### Task 2: Enforce Dart Trust, Durable Handoff, and Signed Publishing

**Files:** Modify the Dart public/core/platform/publishing files and Dart tests
listed in the file map.

**Interfaces:**

- `UpdateClient` requires `expectedPackageId` and a non-empty trusted key
  map, stores an unmodifiable normalized copy, and exposes no production
  verifier/signature-bypass knobs.
- `checkForUpdate()` verifies signed index, signed descriptor, index binding,
  and expected identity before returning.
- `downloadVerifyAndStage(checkResult: ...)` accepts only a result created by
  the library and revalidates ownership/trust.
- `DesktopUpdaterController.restartApp()` creates a v3 marker requiring a
  lowercase UUID, non-empty expected version/package/channel, exact staging
  path, nullable build number copied field-for-field, and lowercase
  64-character provenance digest. The legacy representation keeps v3-only
  fields nullable only so old markers decode.
- `UpdateRecoveryStore.writePendingInstall` is documented to complete only
  after durable replacement. The package helper awaits write, reads the same
  channel, compares every serialized field including UTC creation time,
  updater-package version, platform, channel, nullable app/update/build values,
  expected package ID, path, provenance, diagnostics, and transaction, and
  issues `PersistedInstallTransaction` only on an exact match. Dispatcher
  separately checks the stage-bound subset against retained verified state.
  Readback detects loss/corruption but cannot prove `fsync` semantics when an
  app-provided store violates its contract; that limitation is documented and
  covered by the release risk ledger.

- [ ] **Step 1: Add focused security failures**

  Add fake-transport counters proving unsigned index, unsigned descriptor,
  unknown key ID, invalid signature, empty keys, empty expected identity, and
  descriptor package mismatch all fail before the artifact URL is requested.
  Reject malformed Base64, non-32-byte keys, blank IDs, and post-trim duplicate
  IDs at configuration. Add same-session success plus foreign-client,
  different-config, concurrent-result, mutated-binding, stale-result, and
  post-success replay failures; assert any staging attempt consumes its check
  result and any native-dispatch attempt consumes its stage. The analyzer
  fixture proves omitted trust/store arguments on both controller constructors
  no longer compile. Controller tests prove throwing write, null readback,
  every authoritative readback mismatch, and a valid receipt from stage A
  paired with stage B produce zero platform calls. Race two dispatches for the
  same stage and receipt and prove exactly one reaches the platform while the
  other receives an already-claimed failure. Add
  timeout/transport-loss tests proving the persisted marker remains until an
  authenticated query/recovery result proves the transaction absent or
  terminal. Add a Flutter binary-messenger test that dispatches a real
  library-issued `VerifiedNativeInstallRequest` through
  `MethodChannelDesktopUpdater`, asserts the preserved `installUpdate` method
  name and the exact five-entry serialized map (`stagingPath`,
  `expectedPackageId`, `expectedArtifactSha256`, `stageProvenanceSha256`, and
  `transactionId`), and proves no legacy payload key is present. This runtime
  proof belongs here because Task 1 cannot construct the opaque request before
  the Task 2 authority path exists. Add
  platform-host tests proving a raw forged MethodChannel payload still fails
  native stage/descriptor/target validation.

- [ ] **Step 2: Run the focused tests red**

  ~~~sh
  flutter test --no-pub test/update_client_security_test.dart
  flutter test --no-pub test/updater_controller_test.dart
  flutter test --no-pub test/update_recovery_test.dart
  flutter test --no-pub test/desktop_updater_test.dart
  ~~~

- [ ] **Step 3: Implement the minimal public/core break**

  Remove compatibility fields, raw install, and stateless low-level methods;
  add the owner session; make results final/library-constructed; make the store
  required; and replace install/recovery fallbacks with the sealed request and
  typed recovery capabilities. The controller retains `_activeCheckResult` and
  `_activeStageResult` instead of rebuilding authority from descriptor/path
  scalars. `update_client.dart` removes public path-only retained-stage lookup;
  its internal owner-aware atomic claim is the only Dart path to retained state.
  The same-library platform dispatcher cross-binds that state to the persisted
  receipt before the MethodChannel sends the minimal stage/transaction binding;
  native code reloads provenance and descriptor. Preserve state transitions,
  callbacks, UI integration, and app-owned diagnostics.

- [ ] **Step 4: Make canonical publishing signed**

  Change the ordered-provider boundary to carry the concurrency precondition:

  ~~~dart
  final class RemoteIndexRevision {
    const RemoteIndexRevision.present({
      required this.sha256,
      required this.etag,
    }) : absent = false;
    const RemoteIndexRevision.absent()
        : absent = true,
          sha256 = null,
          etag = null;

    final bool absent;
    final String? sha256;
    final String? etag;
  }

  final class IndexPublishReceipt {
    const IndexPublishReceipt({
      required this.observedPriorRevision,
      required this.publishedSha256,
      required this.mechanism,
      required this.leaseEvidenceSha256,
    });

    final RemoteIndexRevision observedPriorRevision;
    final String publishedSha256;
    final IndexPublishMechanism mechanism;
    final String? leaseEvidenceSha256;
  }

  enum IndexPublishMechanism { conditionalWrite, exclusiveLease }

  abstract interface class OrderedUploadProvider implements UploadProvider {
    Future<void> uploadVersionedFiles({
      required Directory localRoot,
      required PublishManifest manifest,
      required UploadConfig config,
      required StringSink output,
    });
    Future<IndexPublishReceipt> uploadAppArchive({
      required Directory localRoot,
      required PublishManifest manifest,
      required UploadConfig config,
      required StringSink output,
      required RemoteIndexRevision expectedRevision,
    });
  }
  ~~~

  `IndexPublishReceipt.observedPriorRevision` must equal the frozen expected
  revision and `publishedSha256` must equal the final signed local index. The
  provider obtains that guarantee with an atomic conditional write or a tested
  exclusive backend lease; `leaseEvidenceSha256` is null for
  `conditionalWrite` and a lowercase 64-hex digest of provider-specific lock
  evidence for `exclusiveLease`. A preflight GET followed by an unconditional
  PUT is not sufficient.

  Implement this order exactly:

  1. Require `--public-key-id`, exactly one private-key source, and
     `--public-keys-env`. The named environment variable contains the same
     JSON `{keyId: base64PublicKey}` map used by strict validation. Derive the
     active public key and require it to match the normalized map entry before
     build/package work.
  2. Resolve history before build work. By default, bounded-fetch the hosted
     `app-archive.json` under `baseUrl`, require HTTP success, and verify its
     signature against the trusted old/new map. `--existing-app-archive` uses
     an explicit signed local input but must also match the hosted canonical
     bytes when the hosted index exists. Only `--initialize-feed` permits a
     verified hosted 404/nonexistence; it may be combined with an explicit
     signed local input only to extend an in-progress, not-yet-hosted new-feed
     batch. An empty output directory alone never initializes a feed. Parse the
     selected history once into an immutable publisher-owned snapshot, and
     retain its canonical SHA-256 plus hosted ETag/absence revision. Unsigned,
     invalid, unknown-key, stale-explicit, or mode-conflicting input fails.
     Hooks never source this state.
  3. Run `prePackage`, package the artifact/initial unsigned metadata, then run
     `postPackage`.
  4. Recompute final artifact length and SHA-256 after hooks.
  5. Rebuild the descriptor from the publisher's frozen package/release inputs
     plus final artifact values; do not accept hook-authored metadata fields.
     Sign final `release.json` with `ReleaseDescriptorSigner` and the required
     key.
  6. Rebuild/upsert `app-archive.json` only from the frozen pre-hook snapshot
     and the publisher-owned new item, then sign it with the same active key.
     Reject or overwrite any hook mutation; never re-read it as authority.
  7. Write `.desktop_updater_publish.json` from the final signed files and
     final artifact values.
  8. Strictly validate local index signature, selection/descriptor binding,
     descriptor signature, manifest binding, and artifact bytes.
  9. Re-fetch the hosted index and require the frozen hash/ETag or continued
     initialized-feed absence. Reject concurrent change before handoff. Every
     non-manual provider must implement `OrderedUploadProvider`: upload
     versioned files, validate them remotely, then conditionally write the index
     against the frozen remote revision and validate hosted selection. Delete
     the unordered provider fallback. A backend without conditional write must
     hold a tested exclusive publication lease across recheck and index rename,
     or its automatic provider is rejected.
  10. Manual mode performs the same revision recheck, then prints
     `not uploaded yet`, the frozen expected revision, the derived non-secret
     public-key map, exact versioned-then-index upload instructions, and an
     exact strict hosted-validation command only after local validation.

  Metadata-signing hooks are neither required nor authoritative. Make
  `CustomCommandUploadProvider` ordered: the first invocation has
  `DESKTOP_UPDATER_UPLOAD_PHASE=versioned` and a temporary local root that
  physically omits `app-archive.json`; the second has phase `index` and a root
  containing only `app-archive.json`. In both phases,
  `DESKTOP_UPDATER_PUBLISH_MANIFEST` points to a new phase-scoped manifest whose
  `localRoot` is the isolated root and whose allowed-file list contains only
  that phase's payload. It contains no canonical build-root or disallowed local
  path; the versioned view cannot reveal the local index path. The index phase
  receives the frozen revision through
  `DESKTOP_UPDATER_EXPECTED_REMOTE_INDEX_SHA256`,
  `DESKTOP_UPDATER_EXPECTED_REMOTE_INDEX_ETAG`, and
  `DESKTOP_UPDATER_EXPECTED_REMOTE_INDEX_ABSENT`, but no canonical build-root
  path. `DESKTOP_UPDATER_INDEX_PUBLISH_RECEIPT` names a file in a separate
  publisher-owned temporary control directory outside both upload roots and
  outside the read-only phase manifest. The command writes the prior revision
  it observed and the published SHA-256 there; missing, malformed, mismatched,
  replaced/symlinked, or wrong-control-root receipts fail publication. The
  receipt is never listed in either phase manifest and cannot be reached by a
  recursive uploader rooted at either payload directory. The backend command
  must use a conditional write or tested exclusive lease, not merely echo the
  expected values.

  Freeze the custom-command receipt as strict UTF-8 JSON, maximum 16 KiB, with
  no BOM, duplicate keys, or unknown keys:

  ~~~json
  {
    "schemaVersion": 1,
    "observedPriorRevision": {
      "absent": false,
      "sha256": "64-lowercase-hex",
      "etag": null
    },
    "publishedSha256": "64-lowercase-hex",
    "mechanism": "conditionalWrite",
    "leaseEvidenceSha256": null
  }
  ~~~

  `absent: true` requires both nested `sha256` and `etag` to be null;
  `absent: false` requires the SHA-256 and permits a nullable ETag.
  `mechanism` is exactly `conditionalWrite` or `exclusiveLease`; the latter
  requires a lowercase 64-hex `leaseEvidenceSha256`, while the former requires
  null. The `...ABSENT` environment value is always literal `true` or `false`.
  The SHA and ETag variables are omitted from the environment when null, never
  encoded as empty strings. Add strict parser tests for unknown schema/key,
  duplicate key, wrong type, oversize/BOM input, invalid digest, contradictory
  absent/hash/ETag, and mechanism/evidence mismatch.
  Hosted versioned validation must finish between invocations. Add no-hook
  success, valid old-key-history/new-key rotation, explicit initialization,
  clean-output established-feed preservation, and failures for unsigned or
  invalid prior history, active-key/map mismatch, stale explicit history,
  concurrent remote change, unordered providers, post-hook artifact/index
  mutation, wrong-key signing, tamper, manifest mismatch, canonical-root
  disclosure, receipt upload/listing, and phase leakage.

  Make production validation strict-only. `package` and `app-archive` print
  `candidate-only`; signed archive upsert fails unless it atomically re-signs
  or the caller passes `--invalidate-signature-for-candidate`;
  `verify` requires public keys unless an explicit `--candidate-only` integrity
  mode is selected.

- [ ] **Step 5: Run focused Dart/API and CLI tests green**

  ~~~sh
  flutter test --no-pub test/desktop_updater_test.dart
  flutter test --no-pub test/desktop_updater_method_channel_test.dart
  flutter test --no-pub test/updater_controller_test.dart
  flutter test --no-pub test/update_recovery_test.dart
  flutter test --no-pub test/update_client_security_test.dart
  flutter test --no-pub test/release_index_signature_verifier_test.dart
  flutter test --no-pub test/release_signature_verifier_test.dart
  flutter test --no-pub test/staged_update_provenance_test.dart
  flutter test --no-pub test/release_cli/release_publisher_build_test.dart
  flutter test --no-pub test/release_cli/release_publish_config_test.dart
  flutter test --no-pub test/release_cli/release_command_test.dart
  flutter test --no-pub test/release_cli/release_sign_command_test.dart
  flutter test --no-pub test/release_cli/release_validate_test.dart
  flutter test --no-pub test/release_cli/release_doctor_test.dart
  flutter test --no-pub test/compat/cli_300_contract_test.dart
  flutter test --no-pub test/desktop_updater_cli_test.dart
  flutter test --no-pub test/zip_release_packager_test.dart
  flutter test --no-pub test/app_archive_command_test.dart
  flutter test --no-pub test/app_archive_writer_test.dart
  flutter test --no-pub test/verify_command_signature_policy_test.dart
  flutter test --no-pub test/release_cli/upload
  flutter test --no-pub test/release_publish_smoke_tool_test.dart
  flutter test --no-pub test/e2e/release_publish_manual_e2e_test.dart
  flutter test --no-pub test/e2e/release_publish_custom_command_e2e_test.dart
  ~~~

  Run the S3/FTP/SFTP E2E cases only with their explicit provider fixtures or
  provisioned endpoints; they use the same deterministic signed metadata and
  cannot substitute for the required manual/custom local contract cases.

**Acceptance:** An install-capable Dart path cannot be configured without keys
expected identity, and durable storage; cannot download unsigned/unbound
metadata; cannot hand a foreign stage to native code; and cannot reach a
platform call after persistence or cross-stage binding failure. Canonical
publish cannot emit or hand off unsigned/mismatched final bytes, discard prior
signed history from a clean output, initialize a feed implicitly, or overwrite
a changed remote revision; valid old/new key rotation succeeds. Every unsigned
lower-level path is literally candidate-only.

### Task 3: Remove macOS Compatibility Scheduling and Migrate SwiftPM

**Files:** Modify the macOS helper/runtime/plugin/examples/tests listed above.

**Interfaces:**

~~~swift
public static func loadAndVerify(
    stagedPath: URL,
    stageRoot: URL,
    expectedPackageID: String,
    trustedReleasePublicKeys: [String: Data]
) throws -> MacVerifiedStage

public init(verifiedStage: MacVerifiedStage)

public func prepareInstall(
    _ request: MacInstallRequest,
    transactionID: String
) throws -> MacInstallReservation

public func commitAfterExit(
    _ reservation: MacInstallReservation
) throws -> InstallTransactionStatus
~~~

`queryTransaction` and `recoverPendingInstall` remain public. There is no
`scheduleInstallAndRelaunch`, generated-ID prepare, unsigned flag, or
diagnostics path. The runtime prepares its retained `RuntimeStagedUpdate`
with an explicit transaction ID rather than scheduling it. `MacInstallHelper`
accepts no caller-selected install target: it derives PID, bundle URL,
executable, bundle identifier, code-signing designated requirement, and target
class from the current process. The command-line Swift example is compile-only
unless run inside a purpose-built signed `.app` fixture.
`MacVerifiedStage` has no public memberwise/raw initializer; the public loader
re-reads signed descriptor and provenance and returns the value only after key,
package, artifact, and stage binding succeed. The privileged helper still
repeats verification against sealed policy roots.

- [ ] **Step 1: Change XCTest/public API assertions first**

  Assert raw `MacVerifiedStage`/`MacInstallRequest` initializers and old
  overloads are absent, empty/malformed transaction IDs fail, the signed-stage
  loader plus explicit prepare succeeds, and a persisted transaction can be
  queried/recovered by a fresh helper instance.

- [ ] **Step 2: Run the Swift tests red**

  ~~~sh
  swift test --package-path .
  swift test --package-path macos/install_helper
  ~~~

  Do not run `swift test --package-path macos/desktop_updater` in a clean
  checkout: that package imports generated `macos/FlutterFramework`. Its plugin
  target is exercised by the Flutter SwiftPM build in Step 5.

- [ ] **Step 3: Implement the explicit Swift transaction surface**

  Remove compatibility constructors/wrappers, make signatures unconditional,
  and split runtime prepare from commit. Keep `DesktopUpdaterKit`, helper
  protocol 1, existing journal decoding, and macOS query/recover. Run the frozen
  schema-1/schema-2 readers in a fresh helper process and prove query is
  byte-preserving until explicit recovery.

- [ ] **Step 4: Migrate and compile external consumers**

  Update both macOS native examples, then run:

  ~~~sh
  swift build --package-path example/native/macos
  swift build --package-path example/native/macos-runtime
  flutter test --no-pub test/macos_swift_package_test.dart
  flutter test --no-pub test/native_sdk_consumer_package_test.dart
  ~~~

- [ ] **Step 5: Verify Flutter integration modes**

  Run both modes from a clean example build:

  ~~~sh
  flutter config --enable-macos-desktop
  flutter config --enable-swift-package-manager
  (cd example && flutter clean && flutter pub get && flutter build macos --debug && flutter test integration_test -d macos)
  flutter config --no-enable-swift-package-manager
  (cd example && flutter clean && flutter pub get && flutter build macos --debug && flutter test integration_test -d macos)
  ~~~

  Then run the exact macOS 10.14 fallback typecheck:

  ~~~sh
  xcrun swiftc -typecheck -target x86_64-apple-macosx10.14 -swift-version 5 -module-cache-path "${TMPDIR}/desktop-updater-swift-module-cache" -F "${FLUTTER_ROOT}/bin/cache/artifacts/engine/darwin-x64/FlutterMacOS.xcframework/macos-arm64_x86_64" macos/desktop_updater/Sources/DesktopUpdaterKit/DesktopUpdaterVersion.swift macos/desktop_updater/Sources/DesktopUpdaterKit/Diagnostics.swift macos/desktop_updater/Sources/DesktopUpdaterKit/MacApplicationRestarter.swift macos/desktop_updater/Sources/DesktopUpdaterKit/MacInstallHelper.swift macos/desktop_updater/Sources/DesktopUpdaterKit/MacInstallRequest.swift macos/desktop_updater/Sources/desktop_updater/DesktopUpdaterPlugin.swift
  ~~~

  The CocoaPods fallback must remain macOS 10.14-compatible and must not compile
  runtime-only sources.

**Acceptance:** Old Swift source no longer compiles, the explicit prepare path
passes, fresh-process recovery still reads old journals, and both native
SwiftPM and Flutter integration modes build.

### Task 4: Make Windows ABI 2 and Atomic Recovery Mandatory

**Files:** Modify the Windows/native-runtime/.NET/examples/tests/tool files
listed above.

**Interfaces:**

- C++ exposes `PrepareInstall(request, transactionId)`, `CommitAfterExit`,
  `CancelReservation`, read-only `QueryTransaction`, and
  `ResolvePendingInstallAfterExit`. Implicit prepare, schedule, and public
  `RecoverPendingInstall` are absent.
- Installed C types are `desktop_updater_install_request_abi2`,
  `desktop_updater_result_abi2`,
  `desktop_updater_transaction_status_abi2`, and
  `desktop_updater_reservation_handle_abi2`. Every complete input/output struct
  begins with `uint32_t abi_version; size_t struct_size;`, with static offset
  assertions.
- Installed C entry points are
  `desktop_updater_native_abi_version_abi2`,
  `desktop_updater_prepare_install_abi2`,
  `desktop_updater_commit_after_exit_abi2`,
  `desktop_updater_cancel_reservation_abi2`,
  `desktop_updater_query_transaction_abi2`,
  `desktop_updater_resolve_pending_install_after_exit_abi2`,
  `desktop_updater_transaction_status_free_abi2`,
  `desktop_updater_reservation_release_abi2`, and
  `desktop_updater_result_free_abi2`. There is no ABI-2 schedule or direct
  recover entry point.
- `desktop_updater_prepare_install_v2` remains exported but absent from the 3.0
  header. It retains the exact 2.7 ABI-1 request/result/status/handle signature,
  always returns an ABI-1-shaped removed-API error, sets reservation null and
  outcome rejected, initializes a non-null full-size ABI-1 status to canonical
  empty/rejected values with null-owned strings, and never dispatches into ABI
  2. Binary-only ABI-1 result, status, and reservation cleanup exports remain
  because released .NET code calls them after rejection.
- ABI-2 parsers copy/check only the prefix before later fields and leave output
  handles/status untouched on prefix rejection.
- Runtime C ABI uses the same collision-free convention:
  `desktop_updater_runtime_abi_version_abi2`,
  `desktop_updater_runtime_result_size_abi2`,
  `desktop_updater_runtime_client_create_abi2`,
  `desktop_updater_runtime_client_check_for_update_abi2`,
  `desktop_updater_runtime_client_download_verify_and_stage_abi2`,
  `desktop_updater_runtime_client_prepare_install_abi2`,
  `desktop_updater_runtime_client_commit_after_exit_abi2`,
  `desktop_updater_runtime_client_cancel_reservation_abi2`,
  `desktop_updater_runtime_client_query_transaction_abi2`,
  `desktop_updater_runtime_client_resolve_pending_install_after_exit_abi2`,
  `desktop_updater_runtime_client_free_abi2`, and
  `desktop_updater_runtime_result_free_abi2`. The runtime has no shipped `_v2`
  collision, but one convention avoids repeating this ambiguity.
- .NET helper-only API keeps explicit-ID prepare, commit, cancel, read-only
  query, and resolver.
- .NET runtime API prepares retained staged state with a transaction ID; it
  does not expose signature-disable flags or `InstallAndRelaunch`.
- ABI-2 install-root/executable values are hints, never authority. Flutter and
  in-process SDK adapters derive the running executable; standalone calls must
  match that process identity plus the installed identity marker or registry
  proof and sealed helper policy before prepare succeeds.

- [ ] **Step 1: Add ABI/API failures**

  Compile the frozen 2.7 C and .NET probes against only their frozen
  declarations, then run them against the 3.0 DLL. The old
  `_prepare_install_v2` call must return the exact removed-API error, leave
  reservation null, initialize status to the documented ABI-1 rejected value,
  and permit all released cleanup calls. Put a readable ABI prefix at the end
  of a guard page followed by `PAGE_NOACCESS`; separately prove `_abi2`
  rejects ABI 1 and truncated sizes before a later read and succeeds with ABI
  2. Add xUnit reflection/build assertions that old overloads are absent.

  Prove repeated query modifies no journal, registry, resolver claim, or
  relaunch state; query racing resolver yields a valid authenticated pre/post
  snapshot without creating authority; app-facing direct recover rejects
  without mutation; and internal autonomous crash recovery still functions.
  Add install-root/executable hint mismatch, sibling/symlink, registry/marker
  mismatch, caller identity, and sealed-policy failures before prepare.

- [ ] **Step 2: Run focused Windows tests red on Windows**

  ~~~powershell
  cmake -S windows/native -B windows/native/build -DDESKTOP_UPDATER_NATIVE_BUILD_TESTS=ON -DDESKTOP_UPDATER_NATIVE_RUNTIME=ON
  cmake --build windows/native/build --config Debug
  ctest --test-dir windows/native/build -C Debug --output-on-failure
  dotnet test windows/native/dotnet/DesktopUpdater.Native.Tests/DesktopUpdater.Native.Tests.csproj --configuration Debug --verbosity minimal
  ~~~

- [ ] **Step 3: Implement ABI 2 without unsafe old-layout reads**

  Remove public v1 declarations and compatibility overloads, add `_abi2`
  layouts, and update DLL exports/P/Invoke together without changing the old
  `_v2` calling convention. Audit every prefix check and export definition.
  Remove signer/elevation fields from ABI-2 and Flutter requests. The Windows
  adapter reloads canonical staged provenance plus `release.json`, binds
  descriptor/package/artifact digests, verifies Ed25519 against sealed policy
  keys, and derives Inno strategy, `requiresElevation`, and Authenticode
  thumbprints. The helper repeats descriptor/provenance verification and checks
  the actual installer signature immediately before execution. Signed `never`
  rejects a protected target, `always` selects elevation, and `auto` uses the
  existing target rule; missing/tampered/mismatched policy fails before launch.

- [ ] **Step 4: Migrate native, CMake, NuGet, and runtime consumers**

  Update all three Windows example consumers and the NuGet verifier. The host
  must persist the UUID before prepare, provision the fixed helper and sealed
  policy, exit after commit/recovery acknowledgement, use query only for
  display, and call only the atomic resolver for startup mutation. NuGet
  side-by-side helper/policy files are discovery assets, not protected
  authority; protected installs require an installer-owned immutable signed
  helper/policy generation. CMake is compile-time locator/discovery only and
  must not describe its install prefix as a protected provisioner.

- [ ] **Step 5: Run Debug and Release native/.NET verification**

  ~~~powershell
  cmake --build windows/native/build --config Debug
  ctest --test-dir windows/native/build -C Debug --output-on-failure
  cmake --build windows/native/build --config Release
  ctest --test-dir windows/native/build -C Release --output-on-failure
  dotnet test windows/native/dotnet/DesktopUpdater.Native.Tests/DesktopUpdater.Native.Tests.csproj --configuration Debug --verbosity minimal
  dotnet test windows/native/dotnet/DesktopUpdater.Native.Tests/DesktopUpdater.Native.Tests.csproj --configuration Release --verbosity minimal
  ~~~

  Install and compile the CMake consumer against the installed package, not
  the source tree:

  ~~~powershell
  cmake --install windows/native/build --config Release --prefix windows/native/install
  cmake -S example/native/windows-cmake -B example/native/windows-cmake/build "-DCMAKE_PREFIX_PATH=$PWD/windows/native/install"
  cmake --build example/native/windows-cmake/build --config Release
  ctest --test-dir example/native/windows-cmake/build -C Release --output-on-failure --no-tests=error
  ~~~

  Create the Release NuGet package from the just-built ABI-2 helper/runtime
  outputs, then run its two isolated consumers. Every native command is
  followed by an explicit exit-code check so a later success cannot mask an
  earlier failure:

  ~~~powershell
  $version = (Select-String -Path pubspec.yaml -Pattern '^version:\s*(\S+)\s*$').Matches[0].Groups[1].Value
  $nativeDll = (Resolve-Path windows/native/build/Release/desktop_updater_native.dll).Path
  $runtimeDll = (Resolve-Path windows/native/build/Release/desktop_updater_runtime.dll).Path
  $installHelper = (Resolve-Path windows/native/build/Release/desktop_updater_install_helper.exe).Path
  $fixture = Get-Content -Raw fixtures/compat/native-install-helper/v1/policy-cases.json | ConvertFrom-Json
  $validPolicy = $fixture.cases | Where-Object { $_.expectedValid -eq $true } | Select-Object -First 1
  if ($null -eq $validPolicy -or [string]::IsNullOrWhiteSpace($validPolicy.canonicalJson)) {
    throw "No canonical helper policy fixture is available for NuGet packing."
  }
  $packLane = Join-Path $env:TEMP ("desktop-updater-v3-nuget-pack-" + [guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Path $packLane -Force | Out-Null
  $helperPolicy = Join-Path $packLane "desktop_updater_helper_policy.json"
  [IO.File]::WriteAllText($helperPolicy, $validPolicy.canonicalJson, [Text.UTF8Encoding]::new($false))
  dotnet pack windows/native/dotnet/DesktopUpdater.Native/DesktopUpdater.Native.csproj --configuration Release --output windows/native/artifacts "-p:PackageVersion=$version" "-p:NativeDllPath=$nativeDll" "-p:RuntimeDllPath=$runtimeDll" "-p:InstallHelperPath=$installHelper" "-p:HelperPolicyPath=$helperPolicy"
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  $packageSource = (Resolve-Path windows/native/artifacts).Path
  $package = (Resolve-Path "windows/native/artifacts/DesktopUpdater.Native.$version.nupkg").Path
  $helperLane = Join-Path $env:TEMP ("desktop-updater-v3-nuget-helper-" + [guid]::NewGuid().ToString("N"))
  $runtimeLane = Join-Path $env:TEMP ("desktop-updater-v3-nuget-runtime-" + [guid]::NewGuid().ToString("N"))
  & tool/verify_windows_nuget_consumer.ps1 -PackagePath $package -PackageSource $packageSource -ProjectPath example/native/windows-dotnet/DesktopUpdater.Consumer.csproj -LaneRoot $helperLane -OutputPath (Join-Path $helperLane "build") -PackageVersion $version
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  dotnet (Join-Path $helperLane "build/DesktopUpdater.Consumer.dll")
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  & tool/verify_windows_nuget_consumer.ps1 -PackagePath $package -PackageSource $packageSource -ProjectPath example/native/windows-dotnet-runtime/DesktopUpdater.RuntimeCompile.csproj -LaneRoot $runtimeLane -OutputPath (Join-Path $runtimeLane "build") -PackageVersion $version
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  dotnet (Join-Path $runtimeLane "build/DesktopUpdater.RuntimeCompile.dll")
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  ~~~

  The verifier must compare hashes for the packaged helper, sealed policy,
  helper DLL, and runtime DLL in both the NuGet cache and consumer output, not
  merely discover the two libraries. Its focused tests must fail for a missing
  or byte-mismatched `desktop_updater_install_helper.exe` or
  `desktop_updater_helper_policy.json`. Until the
  credentialed helper smoke performs an actual protected-root mutation and
  recovery, its Authenticode plus interactive `--version` result remains
  `release pending` rather than protected-install evidence.

**Acceptance:** New consumers compile and execute against ABI 2; old public
names are absent except documented binary tombstones; a frozen 2.7 binary
calling shipped `_prepare_install_v2` receives an ABI-1-shaped deterministic
rejection through the exact legacy convention; an ABI-1 prefix passed to
`_abi2` is rejected before any layout-dependent read; read-only query remains;
and the atomic resolver is the sole app-triggered recovery mutation.

### Task 5: Require Explicit Linux Proof and Transaction Identity

**Files:** Modify the Linux helper/runtime/plugin/examples/tests/smoke files
listed above.

**Interfaces:**

~~~cpp
InstallResult PrepareInstall(
    const InstallRequest& request,
    const std::string& transaction_id,
    InstallReservation* reservation);
~~~

`InstallRequest` has no diagnostics path, legacy proof source, or optional
transaction member. `QueryTransaction` and `RecoverPendingInstall` remain.
The runtime always requires pinned keys and exposes explicit prepare/commit.

- [ ] **Step 1: Add failing C++ contract tests**

  Cover missing/invalid transaction IDs, legacy self-contained bundle
  rejection, exact canonical parent plus `/proc/self/exe` relative-path proof,
  mandatory matching root identity marker, unmarked/sibling/symlink targets,
  wrong owner/mode, package mismatch, tampered stage provenance, query/recover
  after crash, and app-owned/fixed diagnostics separation. Neither executable
  context nor marker alone may pass.

- [ ] **Step 2: Run Linux native tests red**

  ~~~sh
  cmake -S linux/native -B linux/native/build -DDESKTOP_UPDATER_NATIVE_BUILD_TESTS=ON -DDESKTOP_UPDATER_NATIVE_RUNTIME=ON
  cmake --build linux/native/build
  ctest --test-dir linux/native/build --output-on-failure
  ~~~

- [ ] **Step 3: Implement API marker 2 and explicit proof**

  Remove the legacy enum/branches and schedule wrapper, require the transaction
  argument, and keep query/recover plus protocol-v1 journal decoding. The
  Flutter plugin derives `/proc/self/exe` and the exact root/relative executable
  context and ignores Dart paths. Standalone hosts provide root/executable/
  package hints, but prepare verifies them against the calling process and the
  matching installed marker.

- [ ] **Step 4: Install first, then compile source-first consumers**

  Both examples use `find_package(... EXACT)` and cannot configure against a
  clean uninstalled checkout. Use isolated directories in this order:

  ~~~sh
  linux_build="$(mktemp -d)"
  linux_prefix="$(mktemp -d)"
  linux_consumer_build="$(mktemp -d)"
  linux_runtime_build="$(mktemp -d)"
  cmake -S linux/native -B "$linux_build" -DDESKTOP_UPDATER_NATIVE_BUILD_TESTS=ON -DDESKTOP_UPDATER_NATIVE_RUNTIME=ON
  cmake --build "$linux_build"
  ctest --test-dir "$linux_build" --output-on-failure --no-tests=error
  cmake --install "$linux_build" --prefix "$linux_prefix"
  PKG_CONFIG_PATH="$linux_prefix/lib/pkgconfig" pkg-config --modversion desktop_updater_native
  cmake -S example/native/linux-cmake -B "$linux_consumer_build" -DCMAKE_PREFIX_PATH="$linux_prefix"
  cmake --build "$linux_consumer_build"
  ctest --test-dir "$linux_consumer_build" --output-on-failure --no-tests=error
  cmake -S example/native/linux-cmake-runtime -B "$linux_runtime_build" -DCMAKE_PREFIX_PATH="$linux_prefix"
  cmake --build "$linux_runtime_build"
  ctest --test-dir "$linux_runtime_build" --output-on-failure --no-tests=error
  ~~~

  These contract builds resolve 2.7.0 until Task 8 synchronizes versions; rerun
  the same installed-consumer sequence after the bump to prove 3.0.0 exact
  lookup. The install tree must export `desktop_updater::native`,
  `desktop_updater::runtime`, and the existing
  `desktop_updater_native_HELPER_EXECUTABLE` locator variable; there is no
  invented `desktop_updater::helper` target. The runtime consumer must fail
  configuration if it falls back to the source tree or if runtime was not
  built/installed.

- [ ] **Step 5: Run helper and installed-polkit gates**

  Run `./tool/linux_install_helper_smoke.sh` for the unprivileged explicit-ID
  flow. Run the installed-polkit self-hosted lane only on its provisioned host,
  using an installed root-owned helper/policy pair, matching identity marker,
  non-root caller, interactive agent, protected mutation, forced-crash
  recovery, and package-channel signature verification. Otherwise record
  literal `not run` with the missing host, credentials, or approval named.

**Acceptance:** Legacy Linux proof cannot compile or pass validation; the new
source-first consumers compile and execute from the isolated installed
`desktop_updater::native`/`desktop_updater::runtime` package and resolve the
helper through `desktop_updater_native_HELPER_EXECUTABLE`; unprivileged recovery
passes; and protected installation remains gated on real polkit evidence.

### Task 6: Write and Compile-Test the Migration Guide

**Files:** Create/update the documentation and migration files listed above.

- [ ] **Step 1: Write the 2.x-to-3.0 guide with these sections**

  1. Why 3.0 is a real breaking release.
  2. Preflight: inventory keys, package ID, currently shipped unsigned feeds,
     diagnostics ownership, helper packaging, transaction storage, and native
     ABI consumers.
  3. Flutter before/after constructor and controller flow.
  4. Low-level Dart before/after per-client `ZipFirstUpdateSession` and
     check-result-bound download.
  5. Standalone macOS SwiftPM before/after prepare/commit/query/recover.
  6. Standalone Windows C ABI and .NET before/after `_abi2` prepare, read-only
     query, and atomic resolver, including the `_prepare_install_v2` tombstone.
  7. Windows protected helper generation, sealed policy, Authenticode/UAC, and
     Inno provisioning.
  8. macOS Developer ID signing, notarization, stapling, helper embedding, and
     SMAppService approval.
  9. Linux helper-only source-first CMake, install marker, polkit broker, and
     packaging boundaries.
  10. Signed archive/descriptor trust, key rotation, expected package identity,
      stage provenance, install-root/executable proof, and failure timing.
  11. App-owned diagnostics and fixed helper sinks.
  12. Transaction persistence, commit, startup recovery, rollback, and
      relaunch-failure semantics.
  13. Unsigned-app migration: ship a final 2.x bridge with pinned keys through a
      trusted full installer/store channel before switching the feed; server
      metadata alone cannot safely retrofit trust.
  14. Verification checklist and credential-gated evidence.

- [ ] **Step 2: Update every canonical example**

  Use one deterministic test key ID and placeholder public key in prose, never a
  private key. Every Flutter controller example supplies keys and package ID.
  Every controller example supplies a durable store. Every helper example
  persists its transaction ID before prepare.

- [ ] **Step 3: Version and test the migration CLI**

  Require `--from 1|2`; never guess the source major. Use this complete matrix:

  | Requested lane | Observed simple constraint | Result |
  | --- | --- | --- |
  | `--from 1` | supported 1.x | Rewrite to `^2.0.0` |
  | `--from 1` | exact `^2.0.0` | Idempotent no-op |
  | `--from 1` | other 2.x or any 3.x | Source-major mismatch; nonzero and no write |
  | `--from 2` | any 1.x | Source-major mismatch; nonzero and no write |
  | `--from 2` | supported 2.x | Rewrite to `^3.0.0` |
  | `--from 2` | simple 3.x | Idempotent no-op |
  | either | nested, git, path, SDK, or ambiguous | Manual finding and no write |

  The 2-to-3 lane only reports manual findings for trust/store inputs, removed
  Dart arguments and constructors, custom platform implementations, and native
  schedule/generated-ID/ABI calls. Test missing/invalid `--from`, every matrix
  cell, dry-run/apply/check, repeated invocation, exact locations, nonzero
  mismatch semantics, and absence of generated secrets or identities.

- [ ] **Step 4: Compile the after examples**

  Dart migration snippets live in executable tests; Swift/C++/.NET examples are
  the external consumers named in Tasks 3-5. Run all their focused build/test
  commands.

- [ ] **Step 5: Prove the before examples are rejected**

  Do not use source-name scans as the sole proof. Add expected-failure fixtures
  under `test/fixtures/v3_removed_api/`: a Dart analyzer package; a Swift
  consumer package compiled on macOS; Windows C and C++ `try_compile` inputs;
  a .NET project built by the Windows lane; and a Linux CMake `try_compile`
  consumer. Each harness must require nonzero compilation for the intended
  missing symbol/signature and fail if compilation succeeds for any other
  reason. Cover unsigned/diagnostics arguments, raw install, public result
  construction/implementation, schedule, generated-ID prepare, Windows direct
  recover (not read-only query), ABI-1 header declarations, and Linux legacy
  proof. The frozen 2.7 Windows probes separately prove bounded binary
  rejection.

- [ ] **Step 6: Correct evidence without overclaiming**

  Record run `30763112196` as passed normal exact-head evidence for SHA
  `2f91208f...`. Keep Authenticode/UAC, installed polkit, notarized DMG/PKG,
  SMAppService privileged helper, and signed Inno lanes separate and
  `not run` or `release pending`. Keep the native runtime
  `preview/candidate-only`.

**Acceptance:** The guide can be followed without reading this plan; every
after example compiles/tests, every before path is intentionally rejected, and
no normal CI result is presented as credentialed production evidence.

### Task 7: Run the Validation and Evidence Ladder

**Focused Dart/API contract tests:**

~~~sh
flutter test --no-pub test/compat/flutter_300_public_api_test.dart
flutter test --no-pub test/compat/flutter_300_channel_controller_contract_test.dart
flutter test --no-pub test/compat/diagnostics_recovery_300_contract_test.dart
flutter test --no-pub test/compat/cli_300_contract_test.dart
flutter test --no-pub test/v3_removed_api_contract_test.dart
flutter test --no-pub test/desktop_updater_test.dart
flutter test --no-pub test/desktop_updater_method_channel_test.dart
flutter test --no-pub test/updater_controller_test.dart
flutter test --no-pub test/update_recovery_test.dart
flutter test --no-pub test/update_client_security_test.dart
flutter test --no-pub test/release_index_test.dart
flutter test --no-pub test/release_index_signature_verifier_test.dart
flutter test --no-pub test/release_signature_verifier_test.dart
flutter test --no-pub test/staged_update_provenance_test.dart
flutter test --no-pub test/e2e/zip_first_update_flow_test.dart
flutter test --no-pub test/native_runtime_resource_limits_test.dart
flutter test --no-pub test/migration_tool_test.dart
flutter test --no-pub test/updater_controller_release_notes_test.dart
flutter test --no-pub test/update_dialog_listener_test.dart
flutter test --no-pub test/release_cli
flutter test --no-pub test/release_cli/upload
flutter test --no-pub test/app_archive_command_test.dart
flutter test --no-pub test/app_archive_writer_test.dart
flutter test --no-pub test/zip_release_packager_test.dart
flutter test --no-pub test/verify_command_signature_policy_test.dart
flutter test --no-pub test/release_publish_smoke_tool_test.dart
flutter test --no-pub test/e2e/release_publish_manual_e2e_test.dart
flutter test --no-pub test/e2e/release_publish_custom_command_e2e_test.dart
flutter test --no-pub test/native_sdk_docs_test.dart
flutter test --no-pub test/native_runtime_merge_gate_docs_test.dart
flutter test --no-pub test/native_helper_diagnostics_docs_test.dart
flutter test --no-pub test/harness_engineering_docs_test.dart
~~~

**Native helper/API tests:** Run root `swift test`, the install-helper package,
Windows Debug/Release CTest and xUnit, the frozen 2.7 C/.NET probes, Linux
CTest, every installed external consumer, the native runtime contract suites,
and the per-platform expected-compile-failure fixtures from Tasks 1 and 3-6.
Zero discovered tests, an expected-failure fixture failing for an unrelated
environment reason, or a legacy fixture regenerated by v3 code is a failure.

**Windows VM repetition gate:** On the provisioned Windows VM, use four fresh
smoke roots and evidence paths. Run in this order:

~~~powershell
./tool/windows_direct_flutter_smoke.ps1 -Configuration Debug -EvidencePath reports/windows-v3-debug-run-1
./tool/windows_direct_flutter_smoke.ps1 -Configuration Debug -EvidencePath reports/windows-v3-debug-run-2
./tool/windows_direct_flutter_smoke.ps1 -Configuration Release -EvidencePath reports/windows-v3-release-run-1
./tool/windows_direct_flutter_smoke.ps1 -Configuration Release -EvidencePath reports/windows-v3-release-run-2
~~~

The script interface must no longer accept a caller-selected helper diagnostics
path. Each run must prove signed check, download, provenance, persisted
transaction, prepare, exit, install, relaunch, cleanup, and terminal recovery.
Do not reuse a stage or transaction ID across runs.

**Local validation ladder:**

~~~sh
dart run tool/harness_gate.dart --structural
dart run tool/version_check.dart
dart format --output=none --set-exit-if-changed .
flutter analyze --no-fatal-infos
flutter test --no-pub
dart pub publish --dry-run
git diff --check
~~~

Run the structural harness gate because helper/docs/CI contracts change. It is
not a source/attestation-bound `harness-ready` claim.

**Required GitHub Actions jobs for the exact pre-bump implementation HEAD:**

- `Dart Package`
- four `Standalone CLI candidate (...)` matrix entries
- `macOS Native Consumer`
- `macOS Flutter (swiftpm)`
- `macOS Flutter (cocoapods)`
- `Windows`, including native CTest, NuGet isolated consumer, integration,
  signed-fixture Debug smoke, and signed-fixture Release smoke
- `Linux`, including helper/recovery CTest, installed CMake/pkg-config
  consumers, integration, privileged mount-namespace rejection where the
  normal job provisions it, and signed-fixture update smoke

**Manual/credential-gated evidence before production claims:**

- Windows fixed Release helper and DLL Authenticode verification plus
  interactive UAC protected-root mutation/recovery.
- Signed Inno package/install/update/uninstall evidence when Inno is a shipped
  channel.
- macOS signed/notarized/stapled DMG and PKG publication evidence.
- macOS approved bundled SMAppService helper and real protected install/recovery
  evidence.
- Linux installed root-owned broker, sealed policy bytes, interactive polkit,
  non-root protected mutation, forced-crash recovery, and package-channel
  signing evidence.

**Acceptance:** Focused, full, native, external-consumer, Windows x2/x2, and
exact pre-bump implementation-HEAD CI gates pass. This is not yet the exact
3.0.0 release-commit evidence; Task 8 reruns the same ladder after version
synchronization. Missing manual evidence remains named and does not silently
become `production-ready`.

### Task 8: Synchronize 3.0.0 and Prepare the Release

**Files:** Modify only the version/changelog/generated surfaces listed in the
file map after Tasks 1-7 pass.

- [ ] **Step 1: Bump the canonical package and changelog**

  Set root version to `3.0.0`. The changelog must name every removed Dart,
  Swift, C++, C ABI, .NET, diagnostics, unsigned, and transaction/recovery
  surface and link the migration guide.

- [ ] **Step 2: Synchronize generated version surfaces**

  ~~~sh
  dart run tool/sync_versions.dart
  dart run tool/version_check.dart
  flutter test --no-pub test/version_sync_test.dart
  swift test --package-path macos/install_helper --filter HelperVersionTests
  ~~~

  Review the emitted file list against the version file map. No lockfile may
  appear.

- [ ] **Step 3: Audit version literals semantically**

  ~~~sh
  rg -n "2\.7\.0|3\.0\.0" README.md docs example macos windows linux .github test
  ~~~

  Change dependency/package claims to 3.0.0. Keep intentional 2.7.0 migration
  baselines and minimum-updater bridge fixtures with an explanatory test or
  comment.

- [ ] **Step 4: Re-run the complete validation ladder and exact-head CI**

  Run every Task 7 job again for the version-synchronized 3.0.0 HEAD; only this
  post-bump run may be called exact release-commit CI evidence. Freeze all
  tracked release files before triggering it. Store the run URL, job
  conclusions, commit SHA, and manual-gate ledger in the external handoff
  packet (and in GitHub's commit-bound run), not by editing README, this plan,
  or another tracked evidence file before release approval. Any commit that
  changes the candidate SHA requires the exact-head CI ladder again. A later
  ExecPlan retrospective is a separate post-release documentation change and
  is never described as the tested/tagged release SHA.

  Do not tag, publish, merge, or mark PR #65 ready from this plan. Present the
  scoped implementation diff, literal `git status --short`, test evidence, CI
  URL, manual-gate ledger, and external review findings to the user for
  explicit release authority. Do not describe the worktree as clean unless Git
  reports no tracked or untracked changes.

**Acceptance:** All public package/native/doc version surfaces say 3.0.0 where
they describe the release, intentional 2.7.0 bridge fixtures are explained,
`CHANGELOG.md` and migration guide agree, dry-run packaging succeeds, and
lockfiles are unchanged. The external evidence packet names the exact tested
SHA and CI URL, and no later commit is substituted as the release candidate
without rerunning the ladder.

---

## Risks and Recovery Plan

| Risk | Prevention/detection | Recovery |
| --- | --- | --- |
| Existing applications stop receiving updates | Migration guide requires a final trusted 2.x bridge and adoption check before feed cutover | Restore the previous signed `app-archive.json` bytes atomically; direct remaining users to a trusted full installer/store release |
| Unsigned-release applications cannot establish trust remotely | Fail the migration preflight if no pinned-key bridge is deployed; never pretend a server-only flag can fix it | Ship a signed-capable 2.x bridge through an already trusted distribution channel, then re-enable automatic v3 rollout |
| Helper packaging or protected paths fail after API migration | Compile external consumers and run unprivileged plus credential-gated installed-helper lanes | Roll the application feed back; keep old helper/journal readers; repair packaging in 3.0.1 rather than reintroducing unverified paths |
| Native ABI consumers load incompatible DLLs or call the shipped `_prepare_install_v2` with its old signature | New `_abi2` symbols, exact ABI-1-shaped tombstone, guard-page probes, export checks, installed package checks, isolated CMake/NuGet consumers | Consumers pin 2.7.0 until rebuilt; publish a corrected 3.0.1 native package if release bytes are wrong; never repurpose the tombstone |
| App-provided recovery storage acknowledges a lossy write | Required store contract, exact write/readback comparison, failure-before-channel tests | Abort handoff and report configuration/storage failure; require the app owner to repair the durable store |
| Transaction is prepared but app exits/crashes at a boundary | Persist/read back UUID and stage binding first, durable helper journal, target lock, resolver/query-recover tests, frozen old-state fixtures, x2 smokes | Fresh app/helper process resolves the existing transaction; never generate a replacement ID for the same pending install |
| Dart capability is bypassed by code already executing in the app | Final/private result/request types prevent accidental assembly; native plugin/helper independently reload and validate stage, descriptor, policy, and process-derived target | Reject at the native boundary and record redacted evidence; never describe Dart library privacy as authorization |
| Post-package hooks mutate bytes after metadata was computed | Rehash artifact and rebuild/sign both metadata files after hooks; strict local manifest/index/descriptor/artifact validation | Stop before provider invocation; fix the hook and regenerate all final metadata |
| A clean output or concurrent publisher drops signed release history | Default to verified hosted history, require explicit proven-new initialization, freeze hash/ETag, recheck, and use a conditional index write or tested exclusive provider lease | Abort before index write; refetch current signed history and rebuild/re-sign rather than merging stale output |
| Custom upload publishes the index early or discovers the canonical root through its manifest | Physically isolated ordered roots, phase-scoped manifests with rebound roots, remote versioned validation between phases, disclosure/leak tests | Stop publication; restore the prior signed index atomically and repair the command contract |
| A v3 reader silently rewrites incompatible 2.7 durable state | Frozen byte-golden and crash-boundary writer fixtures for exact emitted schemas | Block release; repair the reader without reviving intentionally rejected pre-seal formats |
| Release evidence is incomplete | Separate normal required CI from signing/elevation/notarization/polkit lanes | Keep artifacts candidate-only and release pending; do not promote docs or runtime maturity |
| Docs drift from code again | Compile-tested examples, removed-name contract test, docs tests, version check, and commit-bound external evidence packet | Block release/dry-run until the failing contract test and canonical docs agree |
| A late issue appears after 3.0 publication | Version bump last, atomic feed publication, retained 2.x documentation and journal readers | Stop feed rollout, restore previous signed index, publish 3.0.1; do not republish mutable bytes under an existing version |

## Rollback Boundaries During Implementation

- Each task is an independent review boundary. If it fails before release,
  revert only that task's authorized changes; do not reset the worktree or
  discard unrelated user work.
- Never roll back by weakening signature/provenance/target checks or by
  restoring `allowUnsignedMacOSUpdates`.
- If platform migrations cannot converge together, do not publish a partial
  3.0 contract. Keep the package at 2.7.0 and the plan active until all three
  platform surfaces and docs agree.
- Existing protocol-v1 journals and recovery markers remain readable throughout
  rollback and forward migration.

## Final Acceptance Criteria

- [ ] `3.0.0` is supported by real source/ABI/behavior breaks named in the
  contract matrix, not only documentation changes.
- [ ] Every planned old compatibility surface is absent, safely rejected, or
  explicitly preserved with a platform-specific rationale.
- [ ] `allowUnsignedMacOSUpdates`, `diagnosticsLogPath`, raw Dart staged
  install, stateless low-level check/download, schedule wrappers, generated-ID
  prepare overloads, Windows public app-triggered recover, ABI-1 public header
  declarations, and Linux legacy proof are gone. Windows authenticated
  read-only query remains.
- [ ] `DesktopUpdaterController`, widgets/state/localization, app-owned
  diagnostics, the recovery-store abstraction, schema 3, internal protocol 1,
  exact 2.7 journal readers plus the named predecessor macOS schema-1 reader,
  macOS/Linux query/recover, and Windows read-only query are preserved.
- [ ] Pinned keys, expected package identity, and durable recovery storage are
  required; archive/descriptor signatures and identity are enforced before
  artifact download; exact marker write/readback happens before any platform
  call and is cross-bound to the same single-use retained stage; provenance,
  signed installer policy, and process-derived target proof are enforced before
  helper mutation.
- [ ] Windows prepare/query/resolver `_abi2` flow is mandatory for Flutter,
  C++, C ABI, .NET, NuGet, and runtime consumers. The frozen 2.7
  `_prepare_install_v2` probe gets a deterministic ABI-1-shaped rejection and
  ABI-1 prefixes never trigger layout-dependent `_abi2` reads.
- [ ] Canonical publish signs both final metadata files after hooks, validates
  final bytes before handoff, preserves verified prior history even from a
  clean output directory, rejects implicit feed initialization and stale/
  concurrently changed history, and conditionally publishes the index last.
  Custom-command phases are physically isolated; unordered automatic providers
  are rejected; all lower-level unsigned output is labeled `candidate-only`.
- [ ] macOS SwiftPM migration consumers compile; the Flutter SwiftPM integration
  and any purpose-built signed `.app` fixture execute. Windows C ABI/.NET and
  Linux source-first CMake migration consumers compile and execute.
- [ ] The migration guide's after examples compile/test and its before examples
  fail in real Dart, Swift, C, C++, .NET, and Linux CMake compile fixtures for
  the intended removed symbol/signature. The versioned migrator preserves the
  1-to-2 lane, migrates simple 2.x constraints, leaves 3.x alone, and invents no
  secrets or native edits.
- [ ] Focused Dart, full Dart, native helper, native runtime, external consumer,
  local validation, Windows Debug x2, Windows Release x2, and required exact-head
  GitHub Actions gates pass.
- [ ] README/native runtime evidence says baseline normal target-host CI passed
  for audited SHA `2f91208f...`; the external release handoff, not a
  self-invalidating tracked edit, records the exact v3 release SHA/run results.
  Credential-gated lanes remain separate and literal.
- [ ] Native runtime remains `preview/candidate-only`; production-ready is not
  inferred.
- [ ] `pubspec.yaml`, generated Dart/Swift/helper-plist/CMake/NuGet/pkg-config
  versions, both runtime consumers, README/docs dependency examples, and
  `CHANGELOG.md` are synchronized at 3.0.0; local-path Swift packages remain
  local and intentional 2.7.0 bridge/frozen fixtures are documented.
- [ ] Neither lockfile changed.
- [ ] Required manual Authenticode/UAC, signed Inno, notarized DMG/PKG,
  SMAppService, and installed-polkit evidence is named before any production
  release claim.

## Progress

- [x] (2026-08-03) Read repository instructions, architecture, documentation
  maps, harness policy, native contracts, public APIs, platform helpers, tests,
  and current CI evidence.
- [x] (2026-08-03) Distinguished existing fail-closed install behavior from
  actual 3.0 source/ABI/behavior breaks.
- [x] (2026-08-03) Froze the proposed controller, trust, diagnostics,
  transaction, recovery, native ABI, migration, maturity, and release decisions
  in this plan.
- [x] (2026-08-03) Committed the initial Task 1 red-contract snapshot,
  frozen 2.7 Windows ABI probe, macOS prepared-journal fixtures, and permanent
  target-host durable-state emitters in `33bf921` and `745447d`; no production
  API changed.
- [x] (2026-08-03) Verified the Linux target-host durable-state artifact from
  baseline serializer `2f91208` and emitter `745447d` locally by SHA-256. Its
  three bytes remain outside the fixture tree until matching Windows bytes are
  available.
- [ ] Complete Task 1 contract tests and durable design review. The exact-head
  Windows fixture-emitter job failed before upload because the emitter omitted
  the header declaring `WindowsHelperSha256Hex`; the narrow test-only include
  correction is awaiting a controller-pushed target-host retry and matching
  artifact collection.
- [ ] Complete Task 2 Dart/API/publishing migration.
- [ ] Complete Task 3 macOS helper and SwiftPM migration.
- [ ] Complete Task 4 Windows C ABI/.NET/helper/runtime migration.
- [ ] Complete Task 5 Linux CMake/helper/runtime migration.
- [ ] Complete Task 6 documentation and compile-tested migration guide.
- [ ] Complete Task 7 local, VM, native, and pre-bump implementation-HEAD CI.
- [ ] Complete Task 8 version/changelog synchronization and exact release-HEAD
  validation.

## Surprises & Discoveries

- The 2.x controller already rejects unsigned metadata at native install
  handoff, even though check/download APIs still permit unsigned metadata. The
  3.0 break is therefore removal and earlier mandatory authentication, not a
  claim that 2.x privileged install was open.
- Schema 3 already supports signed `app-archive.json` and signed
  `release.json`; mandatory trust does not require a schema bump.
- The current Windows durable path already has an additive explicit-ID prepare
  and atomic resolver, but old overloads and ABI-1 layouts remain public. Its
  explicit-ID C export is already named `desktop_updater_prepare_install_v2`
  while still using ABI-1 structs, so that name cannot carry the new layout.
- The controller currently ignores the boolean result of recovery-marker
  persistence and the marker omits package/provenance identity. Making the
  store required is insufficient without exact readback before channel use.
- Canonical publishing currently writes the manifest before `postPackage`,
  expects hooks to sign `release.json`, signs only the index, and rejects signed
  `customCommand`; 3.0 must reorder ownership rather than merely require CLI
  flags.
- Canonical publish defaults to a local output directory and has no required
  hosted-history acquisition. Treating a missing local index as first release
  would silently drop an established feed, and signing the truncated result
  would make that loss authentic. History acquisition, explicit initialization,
  and remote-revision concurrency control are therefore part of correctness.
- The shipped migrator is a 1-to-2 tool and can rewrite later scalar
  constraints toward 2.0. It must be version-aware before recommending it in a
  3.0 migration guide.
- macOS and Linux do not have the Windows atomic resolver. Removing their
  query/recover APIs would reduce recovery capability rather than remove only
  compatibility debt.
- The normal target-host jobs are green for the audited SHA, while several
  canonical docs still say they are not run. Credential-gated lanes remain
  genuinely unproven and must not be conflated with that correction.
- Several `2.7.0` literals are migration/smoke inputs rather than package
  version claims. A mechanical replacement could make the first signed v3
  bridge impossible to test.
- The first Linux fixture-emitter CI attempt failed because the provider
  journal output path was relative; `745447d` canonicalized it before writing.
  The Linux retry emitted a SHA-verified artifact.
- Exact-head Windows job `91617757650` in Actions run `30792147066` failed
  before fixture upload with MSVC `C3861` at
  `native_durable_state_fixture_emitter.cpp:76`: the emitter called
  `WindowsHelperSha256Hex` without including `windows_helper_bootstrap.h`.
  `desktop_updater_install_helper_support` already compiles
  `windows_helper_bootstrap.cpp` and is already linked by the emitter target;
  adding that source a second time would risk duplicate definitions.

## Decision Log

- **2026-08-03 — Keep `DesktopUpdaterController` canonical.** Replacing it
  would break the mature state/widget/localization surface without closing a
  trust gap. Required configuration and result binding close the gap.
- **2026-08-03 — Remove unsigned metadata compatibility.** Both metadata
  signatures and expected package identity become mandatory before artifact
  download.
- **2026-08-03 — Remove `allowUnsignedMacOSUpdates`.** It is misleading
  source compatibility because the sealed privileged path already rejects it.
- **2026-08-03 — Remove caller-selected helper diagnostics paths.** App-owned
  diagnostics and platform-owned helper sinks have distinct owners and remain.
- **2026-08-03 — Remove raw staged install.** Only retained library-issued stage
  proof can reach supported Dart handoff, and native code independently
  revalidates it because Dart privacy is not a privilege boundary.
- **2026-08-03 — Replace stateless low-level facade with a session.** A check
  result must retain the same client/configuration owner through staging.
- **2026-08-03 — Require durable marker readback before prepare.** Generated IDs
  and best-effort writes cannot support reliable recovery after a prepare
  boundary crash.
- **2026-08-03 — Require Windows atomic resolver for mutation.** Preserve
  authenticated query as a read-only snapshot; remove direct app-triggered
  recover because it duplicates mutation authority and races startup.
- **2026-08-03 — Preserve macOS/Linux query-recover.** They remain the
  authoritative recovery flow until an atomic replacement exists.
- **2026-08-03 — Break Windows native/runtime ABI to 2 under `_abi2`.** The
  shipped `_prepare_install_v2` already has an ABI-1 signature, so it remains a
  rejecting tombstone and is never repurposed. Removing diagnostics and old
  operations cannot be represented honestly by ABI-1 layouts.
- **2026-08-03 — Make the publisher own both final signatures.** Hooks may
  mutate package bytes but cannot be canonical metadata-signing authority;
  signing, manifest creation, strict validation, and ordered upload occur after
  hooks.
- **2026-08-03 — Never infer a new feed from local absence.** Canonical publish
  verifies hosted or explicit signed history, requires explicit initialization
  backed by remote absence, and conditionally writes the index against the
  frozen remote revision so clean builds and concurrent publishers cannot drop
  releases.
- **2026-08-03 — Version the existing migrator.** Preserve explicit 1-to-2
  behavior, add safe 2-to-3 analysis, and never synthesize trust or native
  authority.
- **2026-08-03 — Preserve schema 3, wire protocol 1, and old journal readers.**
  Package major version, public API version, wire protocol, and durable storage
  schema solve different compatibility problems.
- **2026-08-03 — Keep Native Runtime Preview candidate-only.** Required normal
  CI is necessary evidence but does not replace signing, privilege, packaging,
  or production attestation.
- **2026-08-03 — Reuse the baseline Windows bootstrap SHA-256 helper in the
  fixture emitter.** Include its declaring header rather than duplicate a hash
  implementation or alter the serializer/CMake source ownership. Keep the
  existing `desktop_updater_install_helper_support` link edge, which supplies
  the baseline implementation and public helper include directory.
- **2026-08-03 — Do not integrate a single-platform durable artifact.** The
  verified Linux bytes are retained as an external CI artifact until the
  matching Windows artifact carries its own target-host provenance and hashes.

## Outcomes & Retrospective

Task 1 is in progress. The repository now has red 3.0 contracts, frozen ABI
inputs, macOS baseline journals, and permanent target-host emitters. The
baseline ABI probe and macOS emitter/reader checks pass locally; the 3.0
contracts are deliberately red on baseline 2.7. Linux durable-state bytes are
authentic and SHA-verified but intentionally not integrated alone. The Windows
CI compile failure is corrected only by a test-emitter declaration include;
actual Windows compilation and fixture upload remain a required next CI result.
No production implementation, release state, VM, or live artifact was changed.
On completion, record the final diff, versions, focused/full/native/VM/CI
evidence, external review findings, unresolved manual gates, release decision,
and any contract deviation here. A deviation requires a dated Decision Log
entry and updated tests/docs before the plan can move to `completed/`.

## Dependencies and External Authority

- Application owners must supply stable package identity and Ed25519 key
  material; the repository must never persist private production keys.
- Windows protected production evidence needs an Authenticode certificate,
  timestamp service, provisioned UAC host, and optionally signed Inno channel.
- macOS production evidence needs Developer ID Application/Installer
  identities, notary credentials, stapling, an approved SMAppService host, and
  real DMG/PKG artifacts.
- Linux protected evidence needs a provisioned root-owned broker, sealed policy,
  interactive polkit agent, and distribution/package signing authority.
- GitHub branch, PR, merge, tag, release, and workflow-dispatch writes require
  explicit user authorization outside this plan.

## Revision History

- **2026-08-03:** Incorporated independent API/SDK/release/updater-security
  review corrections: required recovery-store readback, per-client Dart
  sessions and single-use sealed misuse-resistant handoff, typed per-platform
  recovery capabilities, nullable build binding, collision-free Windows
  `_abi2` plus the frozen `_prepare_install_v2` tombstone, retained Windows
  read-only query, signed Inno policy derivation, verified history acquisition,
  final-byte publisher-owned signatures, conditional ordered custom-command
  phases, candidate-only lower-level tools, complete migrator source-major
  matrix, frozen durable-state fixtures with explicit writer provenance, real
  negative compile consumers, runtime-enabled installed-package build order,
  complete NuGet packing/execution, expanded version surfaces, and credential-
  evidence boundaries. No production implementation changed.
- **2026-08-03:** Initial ExecPlan created from the
  `2f91208f0de95b9656b0ce2a28258e70a2920b86` repository audit and successful
  normal CI run `30763112196`. No implementation or release changes were made
  while authoring the plan.
