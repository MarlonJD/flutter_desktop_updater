# Cross-Platform Privileged Install Helper Design

**Date:** 2026-07-11

**Status:** Approved for implementation planning

**Related blocker:** Task 6 in
`docs/exec-plans/active/2026-07-10-native-runtime-merge-blocker-remediation-plan.md`

## Purpose

Replace the generated macOS shell, Windows PowerShell, and Linux shell install
helpers with packaged native helper products that can safely own an install
transaction after the application exits. The design covers Flutter consumers
and Flutter-free Swift, C++, and .NET consumers through the same native helper
protocols.

The helper system must provide pre-handoff ownership, cross-process exclusion,
durable recovery, target and staging validation, elevation, and deterministic
failure behavior without weakening the repository's existing trust or
compatibility boundaries.

## Current Problem

The current platform helpers are generated scripts. The rejected Task 6
candidate demonstrated that adding a journal around those scripts is not
sufficient. The production paths remained vulnerable to one or more of:

- mutation after path-based validation;
- unsafe recovery concurrency;
- injected journal sibling paths;
- torn journal writes;
- backup deletion without proven activation;
- helper startup success before lock and recovery ownership existed;
- cleanup of paths not authorized by a durable transaction.

The unsafe candidate was reverted. This design is the architecture required to
remove that blocker rather than patching the rejected scripts.

## Goals

- Build and package native standalone helpers for macOS, Windows, and Linux.
- Support unprivileged writable installs and fully supported elevated installs.
- Authenticate both the calling application and the helper endpoint.
- Reserve and lock the target before the application reports handoff success.
- Persist an idempotent, crash-safe transaction journal.
- Keep destructive mutation fd-relative or handle-relative.
- Share a versioned wire contract, canonical serialization rules, fixtures,
  diagnostics, and conformance expectations across platforms.
- Keep platform mutation implementations independent so each can use its native
  filesystem, signing, IPC, and package-manager security primitives.
- Support Flutter and Flutter-free consumers without requiring the Flutter
  engine or Dart runtime in a helper.
- Preserve the released Flutter API and MethodChannel surface.
- Preserve `DesktopUpdaterKit`, SwiftPM macOS 10.15+, and the CocoaPods macOS
  10.14 exact six-source fallback.
- Provide helper-side strategies that a later Linux distribution-artifact plan
  can consume for AppImage, deb, rpm, Flatpak, and Snap updates.

## Non-Goals

This design does not produce or publish Linux distribution artifacts. A later
Linux Distribution Artifacts design and implementation plan will own:

- AppImage construction and publishing;
- deb and rpm packagers;
- Flatpak repository, `.flatpakref`, and `.flatpakrepo` generation;
- Snap public-store or Brand Store publishing;
- new public Linux artifact kinds and release CLI configuration;
- repository hosting and release upload workflows.

This design does not permit arbitrary elevated commands, caller-selected trust
roots, shell-script fallback, or silent privilege escalation.

## Selected Architecture

The three helpers share contracts, not a destructive mutation engine.

Shared assets are:

- the versioned request, result, reservation, and journal schemas;
- canonical JSON and digest rules;
- state-machine definitions;
- stable error and diagnostic event names;
- Dart-generated valid and adversarial fixtures;
- cross-language conformance expectations;
- compatibility and capability negotiation rules.

Platform implementations are independent:

- macOS uses Swift and native Apple security, XPC, and filesystem APIs;
- Windows uses C++ and wide Win32 handle, Authenticode, UAC, and named-pipe
  APIs;
- Linux uses C++ and fd-relative POSIX/Linux, polkit, Unix-socket, and package
  manager APIs.

There is no shared recursive copy, delete, rollback, elevation, or recovery
implementation. Windows and Linux may reuse existing non-destructive common
parsers and generated fixtures, but their mutation code remains platform-owned.

## Component Model

### Common contract artifacts

The repository will contain a normative helper protocol specification, a
machine-readable schema, and generated fixtures. The initial protocol version
is `1`; unknown major versions fail closed.

The common operations are:

```text
prepareInstall(request) -> reservation
commitAfterExit(reservation)
cancelReservation(reservation)
queryTransaction(policyId, transactionId) -> transactionStatus
recoverPendingInstall(policyId, targetIdentity) -> recoveryResult
```

The platform SDKs expose platform-idiomatic spellings while preserving these
wire semantics.

### Native SDK clients

- `DesktopUpdaterKit` calls the macOS XPC/helper client directly.
- The Windows C ABI and `DesktopUpdater.Native` call the named-pipe helper
  client directly.
- The installed Linux C++ SDK calls the Unix-socket helper client directly.
- Flutter platform adapters call those same native SDK clients. Flutter does
  not own the authoritative journal or recovery decision.

### Standalone helpers

Each helper owns:

- caller and policy authentication;
- target and stage validation;
- cross-process locking;
- journal persistence and recovery;
- strategy-specific mutation or package-manager delegation;
- post-activation identity and trust verification;
- bounded cleanup;
- redacted diagnostics and relaunch.

## Build-Time Privileged Helper Policy

An elevated helper must not trust package identity, update keys, allowed roots,
or allowed strategies supplied by an unprivileged caller. Every application
therefore has a sealed `HelperPolicyV1` created during build or installation.

The policy contains:

```text
policyVersion
applicationPackageId
helperServiceId
allowedApplicationSigner
allowedHelperSigner
allowedTargetClasses
allowedInstallRoots
releaseRootPublicKeys
allowedStrategies
minimumHelperProtocolVersion
```

The request references `policyId`; it cannot replace policy fields.

Platform storage is:

- macOS: a sealed, signed app/helper resource bound to Team ID, bundle ID, and
  designated requirements;
- Windows: installer-owned protected policy bound to the Authenticode identities
  of the app and helper;
- Linux: `/etc/desktop-updater/policies/<package-id>.json`, root-owned and
  installed with the helper/broker;
- portable user-writable installs: an embedded policy that authorizes only
  same-user writable targets and never grants elevation authority.

Release root-key rotation requires either a signed application/helper package
update or a policy transition signed by an already trusted root key. Unknown
keys, rollback to an older policy version, caller-supplied root keys, and
policy/target identity mismatches fail closed.

## Request and Reservation Model

`NativeInstallTransactionRequestV1` contains untrusted hints plus cryptographic
and ownership evidence. It includes:

- schema and protocol versions;
- a lowercase canonical UUID transaction ID;
- policy ID and package ID;
- strategy and target class;
- target path hint and executable-relative-path proof;
- current and desired version/build identity;
- stage path hint, ownership nonce, provenance digest, artifact digest, and
  artifact length;
- signed release descriptor and its binding evidence;
- caller process identity and a request nonce;
- optional redacted diagnostics destination.

Paths in a request are not mutation authority. The helper canonicalizes and
opens the target and stage independently, validates them against policy, and
retains pinned descriptors or handles before accepting a reservation.

`prepareInstall` returns a reservation only after the helper has:

1. authenticated caller, helper, and policy;
2. verified the signed release and stage provenance;
3. proven the target identity and allowed root;
4. rejected links, reparse points, mount boundaries, or unsupported layouts;
5. acquired the target's exclusive cross-process lock;
6. created and durably persisted the initial journal;
7. established a process-lifetime monitor for the caller.

The response includes a high-entropy `readyToken`, transaction ID, journal
digest, and helper endpoint identity. The application reports handoff success
only after validating this response.

The helper receives the commit token and waits for the exact caller process to
exit. macOS uses an audit-token-bound process monitor, Windows uses a retained
process handle, and Linux uses pidfd where available with a validated
PID/start-time fallback. If the caller does not exit before the bounded timeout,
the helper cancels without mutation.

## Journal Model

The journal envelope contains a strict schema version, transaction UUID,
policy/package identity, strategy, relative sibling names, provenance and
artifact digests, owner generation, state, and state-specific evidence.

The journal never treats caller-provided absolute child paths as authority.
Prepared and backup sibling names are derived from the validated target parent
and transaction UUID. Unknown fields, duplicate keys, invalid UUIDs, invalid
state transitions, policy mismatches, and unsupported versions fail closed.

Every state transition uses:

```text
write a new sibling journal file
flush the new file
atomically replace the current journal
flush the containing directory
perform the state mutation
verify the resulting filesystem/package state
```

Swap strategies use:

```text
prepared
backupCreated
targetActivated
completed
```

Package-manager strategies use:

```text
prepared
managerStarted
verificationPending
completed
manualActionRequired
```

Package-manager operations do not claim that a file backup was restored. They
query the authoritative package manager and report its actual state.

## Strategy Model

### `directoryReplace`

Used by existing ZIP directory and bundle updates. The helper constructs a
complete verified sibling tree before replacing the target. Removed-file
semantics are represented by the complete prepared tree rather than destructive
pruning of the live target.

### `singleFileReplace`

Provides the helper-side primitive for a later AppImage artifact plan. The
helper verifies a complete sibling file, mode, owner, digest, package identity,
and architecture before an atomic file replacement. User-writable AppImages use
unprivileged mode. Root-owned AppImages require the installed Linux broker.
The AppImage mount or extracted contents are never the mutation target.

### `verifiedInstallerHandoff`

Used by existing macOS PKG and Windows Inno flows. The helper verifies the
installer and platform trust policy, launches only the fixed platform installer
entry point, and verifies resulting package/application identity. It never
accepts an arbitrary executable or argument vector.

### `systemPackageTransaction`

Provides helper-side allowlisted providers for future deb and rpm integration.
Provider, package ID, version, architecture, and source artifact are structured
fields. The helper constructs fixed apt/dpkg/dnf/rpm operations and rejects
caller-supplied commands or flags. Recovery queries the package database and
returns its real state.

### `externalManagedRefresh`

Provides helper-side delegation and status semantics for future Flatpak and
Snap integration. Flatpak supports Flathub or a signed self-hosted remote. Snap
supports the public Snap Store or a private Brand Store. Storeless dangerous
Snap sideloading is debug-only and never a production update strategy. The
helper does not mutate Flatpak or Snap mounted revisions directly.

The later Linux Distribution Artifacts plan will create artifacts, add public
descriptor kinds, publish repositories/stores, and map those kinds to these
helper strategies.

## Platform Design

### macOS

The build produces a macOS 10.14-compatible
`DesktopUpdaterInstallHelper` executable separately from the pod target.

- SwiftPM product/module/import remains `DesktopUpdaterKit` and macOS 10.15+.
- The CocoaPods target remains macOS 10.14 with the exact four helper sources
  plus `DesktopUpdaterPlugin.swift`; helper sources are not added to that
  allowlist.
- The helper is embedded under `Contents/Helpers`, signed before the outer app,
  and verified as nested code.
- Writable targets use a signed unprivileged one-shot mode.
- Privileged targets use the same bundled helper through
  `SMAppService.daemon(plistName:)` and a package-unique Mach service/XPC
  endpoint on macOS 13 and later.
- The client and helper validate audit tokens, Team ID, bundle ID, designated
  requirements, helper policy, protocol version, and transaction nonce.
- Release acceptance requires hardened runtime, helper/app signing,
  notarization, admin approval, and actual root-daemon execution.

### Windows

CMake produces `desktop_updater_install_helper.exe` as a Release native target.
CMake install, Flutter builds, and NuGet package the helper beside the runtime
DLLs.

- Protected installations place the helper through the trusted installer.
- Elevation uses `ShellExecuteExW` with `runas`; PowerShell is not used.
- The client validates Authenticode chain, expected publisher, helper policy,
  and exact file digest before launch.
- The helper validates its own signer and protected location after elevation.
- IPC uses a nonce-named named pipe with an explicit DACL limited to the caller,
  elevated helper, and SYSTEM.
- Both sides validate peer PID/token, package identity, protocol version, and
  request digest.
- User-writable portable installs can update writable targets without
  elevation; they cannot elevate a helper from a user-writable path.

### Linux

CMake builds one helper codebase with unprivileged one-shot and root-broker
modes. CMake install provides:

```text
/usr/libexec/desktop-updater-helper
/usr/share/polkit-1/actions/<package-policy>.policy
/etc/desktop-updater/policies/<package-id>.json
```

- The broker and policy must be root-owned and non-writable by the caller.
- `pkexec` receives only a socket locator and nonce, never target paths or
  commands.
- The request travels over a Unix socket and is authenticated using
  `SO_PEERCRED`, binary inode/owner/mode, policy, package identity, and nonce.
- Mutation uses pinned directory descriptors with `openat`, `O_NOFOLLOW`,
  `fstatat`, `renameat`/`renameat2`, `unlinkat`, device checks, mountinfo checks,
  and directory fsync.
- Writable bundle/AppImage targets use unprivileged mode.
- Root-owned targets and system package transactions require the installed
  broker. Missing broker or polkit produces a fail-closed result; there is no
  sudo or shell fallback.

## Recovery Rules

- Caller exits before `readyToken`: reservation is cancelled; target is
  unchanged.
- Caller does not exit after commit: bounded timeout; target is unchanged.
- Helper dies in `prepared`: target remains authoritative; only the strictly
  journal-bound prepared sibling may be removed after revalidation.
- Helper dies in `backupCreated`: recovery restores the verified backup.
- Helper dies in `targetActivated`: recovery verifies the new target. It
  completes only if identity, signature, provenance, and package policy pass;
  otherwise it restores the verified backup.
- Journal is missing, torn, corrupt, ambiguous, or unknown-version: no
  destructive cleanup; result is `manualActionRequired`.
- Package-manager operation is interrupted: query actual provider state and
  report `completed`, `verificationPending`, or `manualActionRequired` without
  inventing file rollback.
- Recovery ownership is acquired atomically before inspecting or mutating a
  dead transaction. A live owner is never recovered by a second helper.
- Cleanup may delete only names derived from a valid journal under the pinned
  parent, after link/mount/reparse and identity checks.
- Recovery is idempotent; repeating it produces the same verified state.

## Diagnostics and Result Model

Shared diagnostic events include:

```text
helper authenticated
target lock acquired
transaction journal persisted
caller exit observed
recovery detected
backup restored
activation verified
package manager state verified
manual action required
transaction completed
```

Canonical user paths and secrets are redacted using the existing diagnostics
policy. The helper retains enough transaction ID, state, package identity, and
reason information for support without logging trust keys, tokens, headers, or
full personal paths.

Native detailed results include:

```text
helperUnavailable
helperTrustFailure
authorizationDenied
targetValidationFailure
stageProvenanceFailure
transactionBusy
journalCorrupt
recoveryRequired
rolledBack
externalManagerPending
manualActionRequired
packageManagerFailure
relaunchFailure
completed
```

Existing Flutter calls and MethodChannel names remain unchanged. New native
detail maps to the existing compatible Flutter error/result shapes, with
additional redacted diagnostic fields rather than breaking public APIs.

## Flutter-Free Consumers

The helper system is native-first.

- A Swift application imports `DesktopUpdaterKit` and uses the native helper
  client directly.
- A Windows C++ application uses the versioned C ABI; a .NET application uses
  `DesktopUpdater.Native` and the same installed helper EXE.
- A Linux C++ application links the installed CMake/pkg-config client and uses
  the same helper/broker.

Native applications call `queryTransaction` during startup before scheduling a
new update. They do not use Dart `UpdateRecoveryStore`. External consumer tests
must build, package, launch, and recover using installed artifacts rather than
source-tree shortcuts.

## Flutter Integration

Flutter adapters remain thin consumers of the native SDK clients. They:

- translate existing MethodChannel requests into native helper requests;
- wait for a validated reservation before returning handoff success;
- keep `UpdateRecoveryStore` as optional UX evidence only;
- map native recovery status into existing compatible result/error surfaces;
- never perform privileged filesystem mutation in Dart;
- never fall back to generated shell or PowerShell helpers.

Both Flutter integration modes must embed the same signed macOS helper artifact.
The CocoaPods source allowlist and SwiftPM module name remain unchanged.

## Migration and Rollout

Implementation is staged behind internal candidate-only wiring until each
platform's native helper passes its host gates.

1. Add schemas, fixtures, parsers, and conformance tests without mutation.
2. Build and package helpers with no production routing.
3. Implement reservation, authentication, and no-mutation cancellation.
4. Implement journal and strategy mutation behind test-only activation.
5. Run crash, concurrency, link/mount/reparse, trust, and elevation suites.
6. Route native SDK clients to the packaged helpers.
7. Route Flutter adapters to the same native clients.
8. Remove script generation only after the replacement path is independently
   verified on that platform.

There is no runtime fallback to the old scripts. If a required helper, policy,
signature, broker, or privilege mechanism is unavailable, the operation fails
before mutation.

## Verification Matrix

Every platform must test:

- two helpers racing for the same canonical target;
- caller and helper death at every journal state;
- disk-full, short write, torn journal, and directory-flush failures;
- stage provenance and artifact mutation;
- target, prepared, backup, and journal replacement attacks;
- wrong package ID, policy, signer, and protocol version;
- protected-root, link, junction, reparse, mount, bind-mount, and device
  boundaries as applicable;
- permission and ownership changes between reservation and mutation;
- relaunch only from a verified activated target;
- repeated recovery idempotence;
- nonzero test discovery.

Elevation tests include:

- macOS wrong Team ID, invalid blessing, XPC spoof, unsigned nested helper, and
  authorization cancellation;
- Windows wrong signer, pipe spoof, UAC cancellation, portable elevation
  rejection, and helper replacement attempts;
- Linux wrong owner/mode, fake broker, peer-credential mismatch, polkit
  cancellation, mount injection, and missing broker for a root-owned AppImage.

Consumer gates include:

- Flutter CocoaPods macOS 10.14 host build and launch;
- Flutter SwiftPM macOS 10.15+ host build and launch;
- external Swift application;
- external Windows C++ and isolated NuGet/.NET applications;
- external Linux CMake and pkg-config applications;
- Release artifacts containing the expected helper, policy, and ownership or
  signature metadata.

Signed/elevated/notarized lanes require real credentials and target hosts.
Source contracts, fake package managers, or unsigned debug runs cannot satisfy
those gates.

## Completion Criteria

The helper architecture is complete only when:

- no caller-provided parent or arbitrary command can become mutation authority;
- successful handoff implies an authenticated helper owns the lock and durable
  journal;
- every crash state converges to a verified old target, verified new target, or
  non-destructive `manualActionRequired` state;
- no mutation or cleanup crosses a link, junction, reparse, mount, bind-mount,
  device, policy, or package-identity boundary;
- Flutter and Flutter-free consumers use packaged helpers;
- public Flutter/MethodChannel and `DesktopUpdaterKit` compatibility remains
  intact;
- macOS 10.14 CocoaPods and macOS 10.15+ SwiftPM boundaries are proven;
- target-host test discovery is nonzero and all mandatory secretless lanes pass;
- signed/elevated/notarized smokes are recorded literally;
- an independent adversarial review has no validated P0/P1 finding.

Until those criteria are met, the native runtime remains `candidate-only` and
the existing Task 6 blocker remains open.

## Follow-On Linux Distribution Artifacts Design

The next design must consume, not redefine, this helper contract. It will map:

- AppImage to `singleFileReplace`;
- deb/rpm to `systemPackageTransaction`;
- Flatpak self-hosted or Flathub remotes to `externalManagedRefresh`;
- Snap public or Brand Stores to `externalManagedRefresh`.

That design must add artifact generation, public descriptor kinds, repository
or store signing, publishing, and end-to-end artifact smokes. Production Snap
`--dangerous` sideload remains prohibited; offline local Snap files are
debug/test-only.
