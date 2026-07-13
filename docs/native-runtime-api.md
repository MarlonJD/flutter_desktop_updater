# Native Runtime Preview API

The native runtime is an opt-in `preview` for non-Flutter macOS, Windows, and
Linux applications. Flutter applications continue to use the stable Dart
`UpdateClient`. The small install/relaunch helper SDKs remain independently
usable without linking the runtime transport, contract, crypto, or archive
code.

The preview is implemented and `candidate-only`, but it is not production-ready.
Configured workflow jobs are not execution evidence; an unchecked or `not run`
lane must not be promoted by inference.

## Current-Head Merge-Gate Ledger

This table describes the current remediation head, not an earlier commit or a
configured-but-unexecuted workflow.

| Lane | Status | Current evidence |
| --- | --- | --- |
| Portable contract, trust, provenance, lifecycle, redirect, and package-layout suites | `verified locally` | Named focused commands are recorded in the active remediation plan |
| Task 10 complete local ladder | `verified locally` | Fixtures, format, analysis, full Flutter with 660 passes and 3 explicit skips, pub dry-run with 0 warnings and 1 hint, 52 SwiftPM tests, exact 10.14 typecheck, external consumer, and diff check exited 0 |
| macOS root SwiftPM tests | `verified locally` | Root `swift test` passed 52 tests on this macOS host |
| macOS exact CocoaPods 10.14 five-source typecheck | `verified locally` | The exact fallback source allowlist typechecked for `x86_64-apple-macosx10.14` |
| macOS external SwiftPM consumer | `verified locally` | `swift run --package-path example/native/macos` built and executed the external consumer |
| Flutter macOS SwiftPM build and integration | `verified in CI` | Build and integration passed in push run `29291937840` |
| Flutter macOS CocoaPods build and integration | `verified in CI` | Build and integration passed in push run `29291937840` with the exact fallback boundary unchanged |
| macOS normal ZIP smoke | `verified in CI` | Native consumer ZIP smoke passed in push run `29291937840` |
| Windows Unicode and relative redirect CTest | `verified in CI` | The named target-host CTest gate passed in push run `29291937840` |
| Windows provenance, lifecycle, and C ABI CTest | `verified in CI` | Standalone CTest and real-DLL managed tests passed in push run `29291937840` |
| Windows source-contract target and reparse validation | `verified locally` | Dart source-contract tests verified the fail-closed target/reparse checks; this is not junction execution evidence |
| Windows junction/reparse transaction mutation and recovery | `blocked` | Task 6's unsafe candidate was reverted; safe handle-relative transaction mutation is not implemented |
| Windows Release NuGet isolated P/Invoke consumer | `verified in CI` | Isolated restore, candidate DLL hash proof, and P/Invoke execution passed in push run `29291937840` |
| Windows normal ZIP smoke | `verified in CI` | The packaged .NET runtime used the real DLL/helper and completed install, cleanup, and diagnostics in push run `29291937840` |
| Linux native tamper CTest | `verified in CI` | The named target-host native tamper gate passed in push run `29291937840` |
| Linux installed CMake consumer | `verified in CI` | Configure, build, and execution from the installed prefix passed in push run `29291937840` |
| Linux standard and multiarch pkg-config consumers | `verified in CI` | Both installed-prefix compile/link/run consumers exited 0 in push run `29291937840` |
| Linux mount/bind transaction mutation and recovery | `blocked` | Task 6's unsafe candidate was reverted; fd-relative mount/bind transaction mutation is not implemented |
| Cross-platform/macOS packaged signed helper ownership transfer, cross-process target lock, durable journal, and crash recovery | `blocked` | The standalone-helper design is approved, but Task 6 implementation and target-host recovery evidence are pending |
| Linux normal ZIP smoke | `verified in CI` | Native runtime ZIP smoke passed in push run `29291937840` |
| Current remediation head in GitHub Actions | `verified in CI` | Push run `29291937840` completed successfully for commit `87a2adf`; the credential-gated notarized publish job was skipped |
| macOS signed/notarized DMG smoke | `not run` | Separate credential-gated `workflow_dispatch` lane |
| macOS signed/notarized PKG smoke | `not run` | Separate credential-gated `workflow_dispatch` lane |
| Windows signed Inno smoke | `not run` | Separate credential-gated `workflow_dispatch` lane |

`verified locally` means the named behavior passed on the local host.
`verified in CI` is recorded only after the required target-host job passes.
`blocked` means a required implementation, host, dependency, approval, or
credential prevented a gate. `production-ready` requires every applicable
artifact row, packaged consumer, publisher check, and cleanup assertion to pass.

## Artifact Capability Matrix

This matrix describes implemented handoff shapes only. Evidence belongs solely
to the current-head ledger above.

| Platform | Artifact | Handoff |
| --- | --- | --- |
| macOS | `zip` | Whole-bundle helper replacement |
| macOS | `dmg` | Read-only mount, app copy, helper replacement |
| macOS | `pkgInstaller` | Installer.app handoff |
| Windows | `zip` | Directory helper replacement |
| Windows | `innoInstaller` | Authenticode-verified installer handoff |
| Linux | `zip` | Validated install-root replacement |

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
- `requireIndexSignature`
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

The version-1 result is returned by value and its layout is frozen. C and .NET
consumers call the scalar ABI-version and exact-result-size probes before any
by-value runtime call. Any future result layout change requires a new result
type and new versioned entry points.

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
canonical target. Local source-contract tests verify the current fail-closed
Windows target/reparse checks, but they are not target-host junction execution
evidence. Windows junction/reparse transaction mutation, Linux mount/bind
transaction mutation, and durable native transaction recovery are `blocked`
by Task 6. The current implementation separately verifies one-shot handoff
scheduling; the Flutter recovery marker does not satisfy the blocked native
transaction gate.

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
