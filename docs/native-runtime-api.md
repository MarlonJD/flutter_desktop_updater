# Native Runtime Preview API

The native runtime is an opt-in `preview` for non-Flutter macOS, Windows, and
Linux applications. Flutter applications continue to use the stable Dart
`UpdateClient`. The small install/relaunch helper SDKs remain independently
usable without linking the runtime transport, contract, crypto, or archive
code.

The preview is implemented and `candidate-only`, but it is not production-ready.
Configured workflow jobs are not execution evidence; an unchecked or `not run`
lane must not be promoted by inference.

## Merge-Gate Ledger

This table describes the current remediation head, not an earlier commit or a
configured-but-unexecuted workflow.

| Lane | Status | Current evidence |
| --- | --- | --- |
| Portable contract, trust, provenance, lifecycle, redirect, package-layout, and docs suites | `verified locally` | Named focused commands and the complete local ladder are recorded in the active remediation plan |
| Current remediation head in GitHub Actions | `not run` | No CI run for the current head is claimed; therefore no lane is `verified in CI` |
| macOS SwiftPM/external consumer, exact CocoaPods fallback, Flutter builds, and normal ZIP smoke on the current head | `not run` | Jobs are configured; target-host execution is still required |
| Windows Unicode/redirect/tamper/reparse tests, Release NuGet consumer, and normal ZIP smoke on the current head | `not run` | Jobs are configured; Windows target-host execution is still required |
| Linux tamper/package/consumer tests and normal ZIP smoke on the current head | `not run` | Jobs are configured; Linux target-host execution is still required |
| Native transaction recovery journal, target lock, and crash recovery | `blocked` | Task 6's unsafe candidate was reverted; a packaged standalone-helper architecture is required |
| macOS signed/notarized DMG and PKG smokes | `not run` | Separate `workflow_dispatch` credential lane |
| Windows signed Inno smoke | `not run` | Separate `workflow_dispatch` credential lane |

Artifact status is consequently literal:

| Platform | Artifact | Evidence | Handoff |
| --- | --- | --- | --- |
| macOS | `zip` | `not run` on the current remediation head | Whole-bundle helper replacement |
| macOS | `dmg` | `not run` in the credential-gated lane | Read-only mount, app copy, helper replacement |
| macOS | `pkgInstaller` | `not run` in the credential-gated lane | Installer.app |
| Windows | `zip` | `not run` on the current remediation head | Directory helper replacement |
| Windows | `innoInstaller` | `not run` in the credential-gated lane | Authenticode-verified installer handoff |
| Linux | `zip` | `not run` on the current remediation head | Validated install-root replacement |

`verified locally` means the named behavior passed on the local host.
`verified in CI` is recorded only after the required target-host job passes.
`blocked` means a required host, dependency, approval, or credential prevented
a gate. `production-ready` requires every applicable artifact row, packaged
consumer, publisher check, and cleanup assertion to pass.

## Three-Stage Lifecycle

Every platform exposes the same stateful flow:

```text
checkForUpdate
downloadVerifyAndStage
installAndRelaunch
```

The first call fetches discovery metadata, selects an eligible release, binds
and verifies its descriptor, and returns a typed outcome. The second downloads
only an already-selected artifact, verifies its length and SHA-256, and stages
it under application-owned disposable roots. The third passes that staged
artifact to the existing platform helper. A failed or non-update result cannot
skip directly to a later stage.

### macOS Swift

`DesktopUpdaterKit` exposes the lower-camel-case API directly:

```swift
let client = UpdateClient(configuration: configuration)
let check = await client.checkForUpdate()
guard check.outcome == .updateAvailable else { return }

let staged = try await client.downloadVerifyAndStage(
    check,
    downloadDirectory: downloads,
    stagingRoot: staging,
    expectedTeamIdentifier: teamIdentifier
).get()

try client.installAndRelaunch(
    staged,
    diagnosticsLogPath: diagnosticsLogPath
)
```

Production ZIP and DMG staging rechecks the application bundle and publisher.
`allowUnsignedUpdates` exists only as an explicit debug/test opt-in. PKG trust
is never disabled by that opt-in.

### Windows .NET And C ABI

The .NET wrapper uses .NET naming while preserving the same stages:

```csharp
using var client = new DesktopUpdaterClient(configuration);
var check = client.CheckForUpdate();
if (check.Outcome != DesktopUpdaterOutcome.UpdateAvailable) return;

var staged = client.DownloadVerifyAndStage(downloads, staging);
if (staged.Outcome != DesktopUpdaterOutcome.UpdateAvailable) return;

client.InstallAndRelaunch(removedFiles, diagnosticsLogPath);
```

The versioned C equivalents are
`desktop_updater_runtime_client_check_for_update_v1`,
`desktop_updater_runtime_client_download_verify_and_stage_v1`, and
`desktop_updater_runtime_client_install_and_relaunch_v1`.

### Linux C++

Linux exposes a movable source-ABI client:

```cpp
desktop_updater::runtime::UpdateClient client(configuration);
const auto check = client.CheckForUpdate();
if (check.outcome !=
    desktop_updater::runtime::RuntimeOutcome::kUpdateAvailable) return;

const auto staged = client.DownloadVerifyAndStage(
    downloads, staging, executable_relative_path);
if (staged.outcome !=
    desktop_updater::runtime::RuntimeOutcome::kUpdateAvailable) return;

client.InstallAndRelaunch(
    install_root, executable_relative_path, removed_files, diagnostics_log);
```

The complete compile-and-smoke sources live in
`example/native/macos-runtime`, `example/native/windows-dotnet-runtime`, and
`example/native/linux-cmake-runtime`. Those external consumers, rather than a
Flutter plugin target, are the compile authority for these examples.

## Packaging Boundaries

The native runtime is SwiftPM-only at macOS 10.15 or newer; the macOS 10.14
CocoaPods fallback intentionally excludes `Runtime/**`.
The native runtime boundary is **SwiftPM macOS 10.15+** and preserves
`import DesktopUpdaterKit`. The Flutter fallback boundary is **CocoaPods macOS
10.14** and intentionally excludes `Runtime/**`.

- macOS links the `DesktopUpdaterKit` SwiftPM product from an approved tag or a
  repository checkout. The package has no Flutter dependency.
- Windows builds the runtime with `DESKTOP_UPDATER_NATIVE_RUNTIME=ON` and
  consumes `DesktopUpdater.Native` through a NuGet feed. The package contains
  the `net8.0` and `netstandard2.0` managed assemblies plus both
  `desktop_updater_native.dll` and `desktop_updater_runtime.dll` under
  `runtimes/win-x64/native`.
- Linux builds from source with `DESKTOP_UPDATER_NATIVE_RUNTIME=ON`, installs
  the CMake package, and links `desktop_updater::runtime` plus
  `desktop_updater::native` from that installed prefix.
- Helper-only consumers keep linking only the helper target. Enabling the
  preview must not pull runtime-only networking, archive, or crypto dependencies
  into normal Flutter helper builds.

## Runtime Configuration

Every platform configuration carries the same application-owned inputs:

- `appArchiveUrl`
- `expectedPackageId`
- `currentVersion`
- `currentBuildNumber`
- `currentUpdaterVersion`
- `platform`
- `channel`
- `installationIdentity`
- `requireDescriptorSignature`
- `pinnedPublicKeysById`
- `minimumOSResolver`
- `requestHeadersProvider`
- `downloadTimeout`
- `maximumMetadataBytes`
- `maximumArchiveEntries`
- `maximumUncompressedBytes`
- `maximumSingleEntryBytes`

The defaults are 4 MiB for each index or descriptor, 100,000 archive entries,
8 GiB total uncompressed bytes, and 4 GiB for one entry. Applications may
lower them. Raising a limit is explicit. Zero or negative timeouts and limits
are rejected while configuration is constructed or validated.

The header provider is called for every requested URL. It owns authorization
policy and may return a different set of headers after a redirect. Diagnostic
output must never contain header values. The minimum-OS resolver is
application-owned because platform version policy is host-specific.

## Typed Outcomes

Each public API represents these values as an enum rather than matching error
text:

```text
noUpdate
updateAvailable
freshInstallRequired
unsupportedMinimumUpdater
unsupportedMinimumOS
rolloutIneligible
unsupportedArtifactKind
invalidDescriptor
signatureFailure
packageIdentityMismatch
downloadFailure
artifactIntegrityFailure
unsafeArchive
stagingFailure
installHandoffFailure
```

Support policy is reported separately as `supported`, `warning`, or `blocked`.
The application owns the user experience for warnings and enforced support
deadlines.

## Windows ABI Ownership

`DESKTOP_UPDATER_RUNTIME_ABI_VERSION` is `1`. Every request and result starts
with `abi_version` and `struct_size`. Callers set both fields and zero any
unknown tail bytes. The DLL catches exceptions at the C boundary.

The runtime client is an opaque owned handle released with
`desktop_updater_runtime_client_free_v1`. Result strings are owned by the DLL
and released with `desktop_updater_runtime_result_free_v1`. Callback inputs are
borrowed for the duration of the call. Header entries returned by the
application remain application-owned until its release callback runs. The .NET
wrapper owns callback delegates, header leases, native strings, result
disposal, client disposal, and the complete `removedFiles` array.

## Trust Boundary

Unsigned `app-archive.json` is discovery metadata, not release authority. The
native preview requires signed app-archive authority before selection. A
selected index item must exactly match descriptor version, integer build
number, platform, and channel. The descriptor package identity is app-owned
and must match `expectedPackageId`.

Descriptor signatures use Dart-compatible canonical JSON, Ed25519, and an
application-pinned key ID from `pinnedPublicKeysById`. Unknown key IDs, invalid
signatures, index-to-descriptor mismatches, unsupported artifacts, length or
hash mismatches, and unsafe archive paths fail before helper handoff. Platform
publisher checks remain mandatory where configured: macOS app/DMG/PKG trust
and Windows Inno Authenticode policy are not replaced by descriptor signing.

An owned stage provenance digest binds the verified stage to the helper
request. Explicit install target proof binds the request to the running app's
canonical target. Protected roots, mount and reparse rejection, symlink and
junction escapes, and install/staging overlap are fail-closed requirements.
The current implementation verifies one-shot handoff scheduling, but the
durable native transaction recovery journal is `blocked` and is not represented
by the Flutter recovery marker.

Windows keeps filesystem paths wide through its native boundary, including
Windows Unicode paths, and resolves relative redirects with a five-hop limit
without forwarding stale authority headers. Release NuGet consumption uses
the packaged Release DLLs, isolated restore/build roots, hash comparison, and
the packaged third-party notices.

## Unsupported Future Work

Delta artifacts remain descriptor metadata only; the preview does not download,
apply, or fall back from a delta payload. Linux prebuilt binary distribution
remains outside this preview until an ABI, glibc, architecture, toolchain, and
support policy is approved. Linux is source-first and makes no stable binary
ABI promise.
