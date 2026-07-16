# Native Helper SDKs And Standalone CLI

`desktop_updater` ships the stable Flutter/Dart update runtime, small native
helper SDK packages, and an opt-in Native Runtime Preview for non-Flutter host
applications. Helper-only consumers continue to own discovery, download,
descriptor validation, artifact verification, and staging; the helper surface
only schedules installation and relaunch of an application-owned staged
artifact. The preview adds those earlier lifecycle stages without changing the
Flutter runtime or the independently consumable helper boundary.

## Distribution Surfaces

| Surface | Integration | Contract |
| --- | --- | --- |
| Flutter | `desktop_updater` from pub.dev | Full Dart runtime with local platform helper sources |
| macOS helper | SwiftPM product `DesktopUpdaterKit` | Flutter-free Swift install and relaunch helper |
| macOS runtime preview | SwiftPM product `DesktopUpdaterKit` | Stateful Swift update client plus helper handoff |
| Windows helper | Installed CMake target `desktop_updater::native` | Static/shared C++ helper and versioned C ABI |
| Windows runtime preview | `DesktopUpdater.Native` NuGet package | Managed client, versioned runtime C ABI, native DLLs, helper, and sealed policy |
| Linux helper | Installed CMake target `desktop_updater::native` and pkg-config metadata | Source-first static C++ install helper |
| Linux runtime preview | Installed CMake target `desktop_updater::runtime` | Source-first C++ update client; no prebuilt ABI promise |
| CLI | Dart entrypoints or native-host standalone executable | Release, package, verify, and app-archive commands |

The canonical version is the root `pubspec.yaml` version. Maintainers run:

```sh
dart run tool/sync_versions.dart
dart run tool/version_check.dart
```

The sync command updates checked Dart, Swift, C/C++, CMake, pkg-config, and
NuGet version surfaces. It never changes `pubspec.yaml`, the changelog, or Git
tags.

## Install Reservation And Startup Recovery

All native helper SDKs expose the same native-first operations:

```text
prepareInstall
commitAfterExit
cancelReservation
queryTransaction
recoverPendingInstall
```

The platform spelling follows its language conventions (`prepareInstall` in
Swift, `PrepareInstall` in C++/.NET, and versioned
`desktop_updater_*_v1` functions in the Windows C ABI). Preparation returns an
owned reservation only after a helper response has a valid transaction ID,
response digest, endpoint identity, and durable journal proof. Commit is
accepted only when those values still match. Dropping a Swift reservation or
disposing a .NET safe handle sends a best-effort cancellation; the helper's
journal remains authoritative if the caller dies or cancellation cannot be
delivered.

At startup, persist only the transaction ID in application state. On Windows,
call `resolvePendingInstallAfterExit` once instead of issuing a
`queryTransaction`/`recoverPendingInstall` pair. When it returns a prepared,
recovery-required status, the authenticated helper has retained the exact
caller identity and will continue only after that process exits; the caller
must exit immediately and must not launch a second recovery request. A terminal
completed, rolled-back, or manual-action status may be handled without exiting.
The separate Windows query and recovery functions remain available as low-level
diagnostic and operator-recovery operations.

Windows filesystem recovery is durable; automatic relaunch is a separate,
verified best-effort operation with an at-most-once attempt boundary. The
protected transaction index records `launchPending`, `launchAttempting`,
`launched`, or `launchFailed`. The startup resolver reports terminal install
success only after the verified caller-token launcher returns and `launched` is
flushed. Low-level recovery results still describe the verified filesystem
outcome independently. If the helper dies after consuming the attempt claim
but before that proof is durable, the next query reports `relaunchFailure` and
does not automatically retry, because retrying could open a second app process.
The installed target or rollback result remains authoritative and the user may
start the app manually. This is deliberately not an exactly-once process-launch
guarantee.

For protected installs, the SYSTEM recovery host captures the exact
authenticated caller token before signalling readiness. It can therefore
finish recovery and make the same single verified relaunch attempt when the
normal elevated helper dies. A host that starts after reboot without that token
still recovers the filesystem transaction but records relaunch failure instead
of launching with the SYSTEM token or claiming that relaunch succeeded.

The other platform SDKs retain the query-then-recover startup sequence until
they expose an equivalent atomic operation. Application or Flutter state may
drive UX but must not authorize mutation, choose rollback, or rewrite helper
state.

The compatibility method `scheduleInstallAndRelaunch` remains available. It is
implemented as prepare, reservation validation, and commit; it has no script
fallback. A missing, untrusted, or unavailable packaged endpoint fails before
mutation. The transport integration and signed/elevated retail evidence are
still **candidate-only**; this API surface is not production-ready until the
target-host gates described below pass.

Across these APIs, `diagnosticsLogPath` is a compatibility-only diagnostics
input. Standalone protocol-v1 helpers use their fixed platform-owned log and do
not write post-exit events to a caller-selected path. Use an app-owned lifecycle
diagnostics sink when the host needs its own durable file.

Each retail application must provision these policy-bound artifacts:

- macOS: `Contents/Helpers/DesktopUpdaterInstallHelper`, its plist in
  `Contents/Library/LaunchDaemons`, SMAppService registration metadata, and the
  helper's sealed policy. The same signed executable serves one-shot and root
  daemon modes; nested code is signed before the outer app.
- Windows: `desktop_updater_install_helper.exe` beside the packaged native
  DLLs for discovery, plus an installer-owned, Authenticode-verified copy in a
  protected location for UAC use. The sealed policy binds the application,
  helper signer, package identity, roots, and allowed strategies.
- Linux: `/usr/libexec/desktop-updater-helper`, its polkit action, and a sealed
  package policy in `/etc/desktop-updater/policies`. Portable packages may use
  only the unprivileged helper mode; system-owned targets require the installed
  root broker.

These are packaging contracts, not trust claims. A source scan or unsigned
local build can prove only layout. Authenticode, Apple code-signing,
installer-owned ACL/ownership, polkit elevation, and notarization require their
named target-host gates.

## macOS: DesktopUpdaterKit

Add this repository as a Swift package at an approved tag and link the
`DesktopUpdaterKit` product. For a repository checkout, a local package
dependency can point at the repository root; the package itself has no Flutter
dependency.

```swift
import DesktopUpdaterKit
import Foundation

let stageRoot = try StageProvenance.createOwnedStage(parent: stagingParent)
let stagedApp = stageRoot.appendingPathComponent(verifiedApp.lastPathComponent)
try FileManager.default.copyItem(at: verifiedApp, to: stagedApp)
let nonce = stageRoot.lastPathComponent.replacingOccurrences(
    of: updaterOwnedStagePrefix,
    with: ""
)
let provenance = try StageProvenance.write(
    stageRoot: stageRoot,
    nonce: nonce,
    packageID: "com.example.app",
    descriptorSHA256: verifiedDescriptorSHA256,
    artifactSHA256: verifiedArtifactSHA256
)
let verifiedStage = MacVerifiedStage(
    stagedPath: stagedApp,
    stageRoot: stageRoot,
    provenance: provenance,
    artifactKind: "zip"
)
let request = MacInstallRequest(
    verifiedStage: verifiedStage,
    allowUnsignedUpdates: false,
    diagnosticsLogPath: diagnosticsPath
)
try MacInstallHelper().scheduleInstallAndRelaunch(request)
```

Create an updater-owned stage only after descriptor and artifact verification,
then pass the resulting `MacVerifiedStage`. A staged request without complete
provenance is rejected synchronously before helper launch. Production signing
gates remain enabled unless `allowUnsignedUpdates` is explicitly enabled for a
controlled debug/test flow. The helper rechecks stage inventory, bundle
identity, and publisher trust before replacement. It derives the current PID
and `Bundle.main` target internally, so callers cannot select another process
or application bundle. `DesktopUpdaterVersion.string` exposes the helper
package version.

Writable targets use the packaged one-shot helper and do not register a
background item. A protected target uses the root `SMAppService` daemon on
macOS 13 or later. The application should present the stable
`PrivilegedHelperApprovalRequired` error and settings action only for first
enable or revoked consent. Enabled services are reused; a required service
refresh waits for asynchronous unregistration to complete before
re-registration so existing administrator approval is preserved.

Flutter macOS hosts invoke `macos/install_helper/embed_install_helper.sh` from
their final app target after Flutter assembly. The CocoaPods fallback preserves
the tooling in its sandbox without adding helper sources to the pod's exact
five-source allowlist; a CocoaPods host invokes it from
`${PODS_ROOT}/../.symlinks/plugins/desktop_updater/macos/install_helper`.
SwiftPM hosts add the same final-app phase from the checked-out plugin source.
The example Xcode target is shared by both Flutter integration modes and shows
the invocation. Set `DESKTOP_UPDATER_HELPER_INFO_TEMPLATE` and
`DESKTOP_UPDATER_SEALED_POLICY_PATH` to consumer-owned metadata, and set
`DESKTOP_UPDATER_SEALED_POLICY_SHA256` to the digest emitted by the canonical
policy generator. The policy must
bind the actual app bundle identifier, helper service identifier, and Apple
designated requirements. The tool always builds the helper with SwiftPM's
Release configuration into DerivedData, signs it once, copies it to
`Contents/Helpers/DesktopUpdaterInstallHelper`, embeds a `BundleProgram` plist
at `Contents/Library/LaunchDaemons/<helper-service-id>.plist`, and validates the
layout before Xcode signs the outer app. Missing policy, requirement, identity,
or signing metadata fails the host build.

The Flutter plugin uses the same helper sources through SwiftPM. Its
`macos/desktop_updater.podspec` keeps CocoaPods as a separately tested fallback
for Flutter hosts that disable SwiftPM.

SwiftPM keeps the `DesktopUpdaterKit` product and import at macOS 10.15 or newer.
In merge-gate terms, the native runtime boundary is **SwiftPM macOS 10.15+**
and keeps the unchanged source spelling `import DesktopUpdaterKit`.
The CocoaPods fallback remains macOS 10.14 compatible and compiles only
`DesktopUpdaterVersion.swift`, `Diagnostics.swift`, `MacInstallHelper.swift`,
`MacInstallRequest.swift`, and `DesktopUpdaterPlugin.swift`. In merge-gate
terms, this exact Flutter fallback boundary is **CocoaPods macOS 10.14**. It
does not compile `DesktopUpdaterKit/Runtime/**`.

The same SwiftPM product now includes the preview `UpdateClient`. Its
`checkForUpdate`, `downloadVerifyAndStage`, and `installAndRelaunch` operations
are exercised by the external `example/native/macos-runtime` consumer. Linking
the helper directly does not require a Flutter engine.

## Windows: CMake, C ABI, And .NET

Build and install the native package on a Windows host:

```powershell
cmake -S windows/native -B windows/native/build \
  -DDESKTOP_UPDATER_NATIVE_BUILD_TESTS=ON \
  -DDESKTOP_UPDATER_NATIVE_RUNTIME=ON
cmake --build windows/native/build --config Release
ctest --test-dir windows/native/build -C Release --output-on-failure
cmake --install windows/native/build --config Release --prefix windows/native/install
```

An external CMake consumer requests the exact package version and links the
installed shared target:

```cmake
find_package(desktop_updater_native 2.7.0 EXACT CONFIG REQUIRED)
target_link_libraries(my_app PRIVATE desktop_updater::native)
```

Include `desktop_updater_native.h` for the C++ helper or
`desktop_updater_native_c.h` for the versioned C ABI. Set
`DESKTOP_UPDATER_NATIVE_ABI_VERSION`, `struct_size`, every staged path, and the
complete `removed_files` array before calling
`desktop_updater_schedule_install_and_relaunch_v1`. A staged C ABI request must
also include the verified provenance and artifact SHA-256 values plus complete
install-root, executable-relative-path, and package-identity target proof; an
incomplete request is rejected before scheduling. The installed header also
exposes `DESKTOP_UPDATER_NATIVE_VERSION_STRING`.

Durable Windows consumers should generate and persist a canonical lowercase
UUIDv4 before privileged preparation, then use
`desktop_updater_prepare_install_v2`. Its prepare outcome distinguishes a
definite rejection from an ambiguous handoff that requires authoritative
recovery by that same transaction ID. Startup recovery uses
`desktop_updater_resolve_pending_install_after_exit_v1`; an active recovery ACK
requires the caller to exit immediately. The original prepare, query, and
recover entry points remain ABI-compatible for existing consumers.
The .NET status exposes `AwaitsCallerExit` for that exact
`prepared`/`recoveryRequired` combination; `manualActionRequired` must remain
visible to the operator and must not be treated as an exit acknowledgement.
The C++, C, .NET, Flutter plugin, and Dart status surfaces preserve
`relaunchFailure` as a distinct additive result code. It means the install
reached a verified terminal state but the single best-effort relaunch was not
durably confirmed; it is neither success nor a request to retry recovery.

`DesktopUpdater.Native` packages the `net8.0` and `netstandard2.0` managed
wrappers, `buildTransitive` copy target, both
`runtimes/win-x64/native/desktop_updater_native.dll` and
`runtimes/win-x64/native/desktop_updater_runtime.dll`,
`desktop_updater_install_helper.exe`, and the consumer-specific
`desktop_updater_helper_policy.json`. Pack requires explicit
`InstallHelperPath` and `HelperPolicyPath` inputs and fails when either is
missing. The `buildTransitive`
copy target accepts an explicit `RuntimeIdentifier` only when it is `win-x64`
and fails before copying assets for any other explicit RID. Framework-dependent
consumers that omit `RuntimeIdentifier` retain the existing copy behavior. The
preview wrapper exposes `CheckForUpdate`, `DownloadVerifyAndStage`, and
`InstallAndRelaunch`;
helper-only consumers use `DesktopUpdaterInstallRequest` so the managed wrapper
marshals the retained provenance, artifact digest, signer allowlist, and target
proof. Its `DesktopUpdaterElevationPolicy` carries the signed Inno
`requiresElevation` value as `Auto`, `Always`, or `Never`; the native helper
rejects policy drift from the provenance-protected release manifest before
installer execution. The old managed overload remains source-compatible for
restart-only calls and rejects staged requests lacking that trust context. The
lower-level C ABI uses the corresponding versioned `_v1` functions.
Repository CI packs the package to a local feed and runs external consumers
against the real DLLs. It is not a public NuGet release until an approved
release workflow publishes that exact verified package.

The NuGet or Flutter copy beside the runtime DLLs is a discovery artifact. It
does not become an elevation authority merely by being present. A machine-wide
installer must copy the exact signed helper and sealed policy into an absolute,
installer-owned immutable
`C:\Program Files\DesktopUpdaterHelperGenerationV1--<package-id>--<release-version>`
generation leaf, directly beneath trusted Program Files, and pass that directory as
`DESKTOP_UPDATER_PROTECTED_HELPER_INSTALL_DIR`. The elevated path verifies
Authenticode publisher, helper digest, final path, and directory writability
before UAC launch. Endpoint records are keyed by package and exact helper path;
an upgrade never replaces the endpoint or files retained by an older pending
transaction. The legacy nested `DesktopUpdater\Helpers` layout is not a trusted
provisioning parent; a user-writable package copy is rejected for elevation.

## Linux: Source-First CMake Package

Build, test, and install the Linux helper from source on the target host:

The helper-only target supports CMake 3.10+, while the opt-in preview runtime
requires CMake 3.12+ for its imported libcurl target. The build-and-test command
below requires CMake 3.14+ because it also enables the native test suite.

```sh
cmake -S linux/native -B linux/native/build \
  -DDESKTOP_UPDATER_NATIVE_BUILD_TESTS=ON \
  -DDESKTOP_UPDATER_NATIVE_RUNTIME=ON
cmake --build linux/native/build
ctest --test-dir linux/native/build --output-on-failure
cmake --install linux/native/build --prefix linux/native/install
```

The installed CMake and pkg-config metadata resolves paths relative to the
installation tree, so the install-time `--prefix` above remains authoritative.
That default install is portable and unprivileged. The helper may run beside a
Flutter bundle or under the chosen prefix, but its root mode rejects every path
except `/usr/libexec/desktop-updater-helper`.

Distribution packagers that need the system broker configure a separate staged
install with `DESKTOP_UPDATER_INSTALL_SYSTEM_BROKER=ON` and provide the exact
package ID, broker SHA-256, canonical policy JSON, and canonical policy digest.
Configuration fails when those values are missing or left at placeholders. The
system-broker install uses the fixed paths `/usr/libexec/desktop-updater-helper`,
`/usr/share/polkit-1/actions/com.desktopupdater.install.policy`, and
`/etc/desktop-updater/policies/<package-id>.json`; use the packaging system's
staging mechanism such as `DESTDIR` rather than relocating those absolute
paths. This repository does not add AppImage, deb, rpm, Flatpak, or Snap
packagers in this task.

Use the installed CMake package:

```cmake
find_package(desktop_updater_native 2.7.0 EXACT CONFIG REQUIRED)
target_link_libraries(my_app PRIVATE desktop_updater::native)
```

Runtime consumers also link the source-built preview target:

```cmake
target_link_libraries(my_app
  PRIVATE desktop_updater::runtime desktop_updater::native)
```

The install tree also generates `desktop_updater_native.pc` with the canonical
package version. The helper requires an explicit application-owned
`install_root` and canonical `executable_relative_path`. It rejects `/`, shared
system prefixes, traversal, symlink escapes, and destructive work outside that
root before it opens a helper transaction.

## Standalone CLI

The package entrypoints remain available everywhere Dart is installed:

```sh
dart run desktop_updater --help
dart run desktop_updater release publish --help
dart run desktop_updater package --help
dart run desktop_updater verify --help
dart run desktop_updater app-archive --help
```

`package` keeps the existing `--input` flag. Native publish adapters use
`--project-type`, `--artifact-root`, the explicit Xcode flags, and the explicit
CMake source/build/target flags documented in
[Publishing desktop updates](publishing.md).

Native-host CI builds these candidate names and generates a `SHA256SUMS` file
beside each binary:

```text
desktop-updater-macos-arm64
desktop-updater-macos-x64
desktop-updater-windows-x64.exe
desktop-updater-linux-x64
```

Those CI artifacts are `candidate-only`. Production distribution would require
an approved workflow that produces signed standalone release assets: macOS
assets must be signed/notarized as required by policy, Windows assets must pass
the approved signing gate, and every published checksum must match the final
bytes. This plan does not publish those production CLI assets. An unsigned
candidate is not a production release.

## Verification And Evidence Labels

Native packages are released only after their target-host tests and external
consumers pass. The repository uses literal evidence labels:

- `verified locally` or `verified in CI` means the named command passed on the
  required host;
- `candidate-only` means an unsigned/non-production artifact was built and
  checked;
- `not run` means the target host or gate was not exercised;
- `blocked` means a required external dependency or credential prevented the
  gate;
- `production-ready` requires every applicable target-host, signing, package,
  checksum, and consumer gate.

The Windows/Linux release and update smoke lanes remain mandatory. The macOS
Developer ID/notary smoke stays separately gated by explicit credentials and
approved workflow dispatch.

## Native Runtime Preview

The opt-in preview implements the same three-stage lifecycle on every platform:

```text
checkForUpdate
downloadVerifyAndStage
installAndRelaunch
```

It covers HTTP transport, rollout and fresh-install selection, support policy,
index-to-descriptor binding, canonical descriptor signature verification,
artifact integrity, bounded safe staging, diagnostics, and existing helper
handoff. Applications still own configuration, pinned keys, package identity,
minimum-OS policy, request headers, UI, and release approval.

The current safety boundary requires signed app-archive authority before
selection, owned stage provenance through helper handoff, and explicit install
target proof. The native helpers persist transaction journals, reconcile
interrupted swaps, and expose prepare/commit recovery semantics. Local tests
cover the macOS journal and swap paths and the fail-closed Windows and Linux
target checks. Real Windows junction/reparse mutation and installed privileged
Linux mount/bind mutation remain `not run` until their target-host lanes run.
Windows transport must preserve Unicode paths and resolve relative redirects;
Windows retail consumption must use the Release NuGet payload and installed
third-party notices.

The current remediation head's target-host jobs are configured but `not run`;
no `verified in CI` result is claimed for it. Signed DMG, PKG, and Inno lanes
are also `not run` without explicit credentials. The API remains `preview` and
`candidate-only`, not `production-ready`. See
[Native Runtime Preview API](native-runtime-api.md) for the literal ledger,
compiling examples, packaging boundaries, and trust rules.
