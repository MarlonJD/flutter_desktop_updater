# Native Helper SDKs And Standalone CLI

`desktop_updater` ships the stable Flutter/Dart update runtime, small native
helper SDK packages, and an opt-in Native Runtime Preview for non-Flutter host
applications. Helper-only consumers continue to own discovery, download,
descriptor validation, artifact verification, and staging; the helper surface
owns only the explicit prepare/commit/cancel/query transaction over an
application-owned verified stage. The preview adds the earlier lifecycle
stages without changing the Flutter runtime or the independently consumable
helper boundary.

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
resolvePendingInstallAfterExit (Windows)
recoverPendingInstall (macOS/Linux)
```

The platform spelling follows its language conventions (`prepareInstall` in
Swift, `PrepareInstall` in C++/.NET, and versioned
`desktop_updater_*_abi2` functions in the Windows C ABI). Preparation returns an
owned reservation only after a helper response has a valid transaction ID,
response digest, endpoint identity, and durable journal proof. Commit is
accepted only when those values still match. Dropping a Swift reservation or
disposing a .NET safe handle sends a best-effort cancellation; the helper's
journal remains authoritative if the caller dies or cancellation cannot be
delivered.

At startup, persist the transaction ID in app-owned state. On Windows, call
`resolvePendingInstallAfterExit` once for the mutating startup path; use
`queryTransaction` only for read-only display. When the resolver returns a
prepared, recovery-required status, the authenticated helper has retained the
exact caller identity and will continue only after that process exits. The
caller must exit immediately and must not launch a second recovery request.
macOS and Linux retain their authenticated query-then-recover capability.

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

Application or Flutter state may drive UX but must not authorize mutation,
choose rollback, or rewrite helper state.

There is no compatibility scheduling wrapper in 3.0. Every host must persist
its caller-generated transaction ID, call explicit prepare, and commit only
after the caller has exited. A missing, untrusted, or unavailable packaged
endpoint fails before mutation. The transport integration and signed/elevated
retail evidence are still **candidate-only**; this API surface is not
production-ready until the target-host gates described below pass.

Native helpers do not accept a caller-selected diagnostics path. Use an
app-owned lifecycle diagnostics sink before handoff; platform helpers retain
their fixed platform-owned logs.

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

// `staged` is returned by UpdateClient after signed metadata and artifact
// verification; do not construct a stage or provenance marker at the call site.
let verifiedStage = try MacVerifiedStage.loadAndVerify(
    stagedPath: staged.stagedPath,
    stageRoot: staged.stageRoot,
    expectedPackageID: "com.example.app",
    trustedReleasePublicKeys: trustedReleasePublicKeys
)
let transactionID = UUID().uuidString.lowercased()
let reservation = try MacInstallHelper().prepareInstall(
    MacInstallRequest(verifiedStage: verifiedStage),
    transactionID: transactionID
)
try MacInstallHelper().commitAfterExit(reservation)
```

Create an updater-owned stage only after descriptor and artifact verification,
then pass the resulting `MacVerifiedStage`. A staged request without complete
provenance is rejected synchronously before helper launch. The helper rechecks
stage inventory, bundle identity, and publisher trust before replacement. It
derives the current PID and `Bundle.main` target internally, so callers cannot
select another process or application bundle. `DesktopUpdaterVersion.string`
exposes the helper package version.

Writable directory-replacement targets use the packaged one-shot helper and do
not register a background item. A protected directory target uses the root
`SMAppService` daemon on macOS 13 or later. macOS PKG
`macosInstaller` + `verifiedInstallerHandoff` always uses that daemon because
the fixed `/usr/sbin/installer` operation requires root, even when the app
bundle's parent directory is writable. The application should present the stable
`PrivilegedHelperApprovalRequired` error and settings action only for first
enable or revoked consent. Enabled services are reused; a required service
refresh waits for asynchronous unregistration to complete before
re-registration so existing administrator approval is preserved.
The Swift runtime exposes this as `RuntimeError.diagnostic` with
`RuntimeDiagnosticCode.privilegedHelperApprovalRequired` and
`RuntimeRemediationAction.openMacOSBackgroundItemsSettings`. Custom UI must
switch on those typed values instead of matching the diagnostic message.

Flutter macOS hosts invoke `macos/install_helper/embed_install_helper.sh` from
their final app target after Flutter assembly. The CocoaPods fallback preserves
the tooling in its sandbox without adding helper sources to the pod's exact
six-source allowlist; a CocoaPods host invokes it from
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
`checkForUpdate`, `downloadVerifyAndStage`, and explicit
`prepareInstall`/`commitAfterExit` operations are exercised by the external
`example/native/macos-runtime` consumer. Linking the helper directly does not
require a Flutter engine.

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
find_package(desktop_updater_native 3.0.0 EXACT CONFIG REQUIRED)
target_link_libraries(my_app PRIVATE desktop_updater::native)
```

Include `desktop_updater_native.h` for the C++ helper or
`desktop_updater_native_c.h` for the installed C ABI. The public C ABI2
surface contains only explicit prepare, commit-after-exit, cancel, query, and
resolve-after-exit operations. Every request, result, and status begins with
`abi_version` and `struct_size`; truncated prefixes are rejected before later
fields are read. The old `desktop_updater_prepare_install_v2` export is a
binary-only ABI1 rejecting tombstone and is absent from the 3.0 header.

Persist a canonical lowercase UUIDv4 before prepare and release owned ABI2
result/status strings with the ABI2 free functions. The .NET wrapper exposes
`PrepareInstall`, `CommitAfterExit`, `CancelReservation`, `QueryTransaction`,
and `ResolvePendingInstallAfterExit` with matching ABI2 P/Invoke entry points.
It does not expose a scheduler, mutating direct recover, caller-selected
diagnostics path, signer allowlist, or elevation override. The C++, C, .NET,
Flutter plugin, and Dart status surfaces preserve `relaunchFailure` as a
distinct terminal result.

`DesktopUpdater.Native` packages the `net8.0` and `netstandard2.0` managed
wrappers, `buildTransitive` copy target, both native runtime DLLs,
`desktop_updater_install_helper.exe`, and the consumer-specific sealed policy.
The helper and policy are discovery assets; the installer remains the
protected authority. Repository CI packs the package to a local feed and runs
external consumers against the real DLLs. It is not a public NuGet release
until an approved release workflow publishes that exact verified package.

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
paths. For this release, Linux is a direct-ZIP `preview` only; AppImage,
deb/APT, rpm/DNF, Flatpak/Flathub, and Snap store packaging remain out of
scope and `candidate-only`.

Use the installed CMake package:

```cmake
find_package(desktop_updater_native 3.0.0 EXACT CONFIG REQUIRED)
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
prepareInstall(transactionID)
commitAfterExit(reservation)
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

The exact implementation head passed the normal, secretless target-host matrix
in [GitHub Actions run #709](https://github.com/MarlonJD/flutter_desktop_updater/actions/runs/30952030992):
Dart package checks, macOS SwiftPM/CocoaPods integrations, native consumer
checks, Windows/Linux target-host tests, and normal ZIP smokes all passed.
Credential-gated Authenticode/UAC, installed-polkit, signed SMAppService, DMG,
PKG, and Inno lanes remain `not run` without their explicit credentials and
hosts. The API remains `preview` and `candidate-only`, not
`production-ready`. See
[Native Runtime Preview API](native-runtime-api.md) for the literal ledger,
compiling examples, packaging boundaries, and trust rules.
