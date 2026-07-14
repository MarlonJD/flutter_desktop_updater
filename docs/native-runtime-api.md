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
| Task 10 complete local ladder | `verified locally` | Historical pre-helper ladder remains recorded in the remediation plan; current helper evidence is listed separately below |
| macOS root SwiftPM tests | `verified locally` | Root `swift test` passed 62 tests on this macOS host after the helper integration |
| macOS exact CocoaPods 10.14 five-source typecheck | `verified locally` | The exact fallback source allowlist typechecked for `x86_64-apple-macosx10.14` |
| macOS external SwiftPM consumer | `verified locally` | `swift run --package-path example/native/macos` built and executed the external consumer |
| Flutter macOS SwiftPM build and integration | `not run` | The current helper head has not run in GitHub Actions |
| Flutter macOS CocoaPods build and integration | `not run` | The current helper head has not run in GitHub Actions |
| macOS normal ZIP smoke | `not run` | The current helper head has not run in GitHub Actions |
| Windows Unicode and relative redirect CTest | `not run` | Requires the Windows target-host job for the current helper head |
| Windows provenance, lifecycle, and C ABI CTest | `not run` | Requires the Windows target-host job for the current helper head |
| Windows source-contract target and reparse validation | `verified locally` | Dart source-contract tests verified the fail-closed target/reparse checks; this is not junction execution evidence |
| Windows junction/reparse transaction mutation and recovery | `not run` | The standalone helper implementation exists; mandatory Windows target-host execution is absent |
| Windows Release NuGet isolated P/Invoke consumer | `not run` | The current package, embedded helper, and sealed policy inventory have not run on Windows CI |
| Windows normal ZIP smoke | `not run` | Requires the Windows target-host job for the current helper head |
| Linux native tamper CTest | `verified locally` | The local Linux container lane passed its native suite |
| Linux installed CMake consumer | `verified locally` | The local Linux container installed and consumed the CMake package |
| Linux standard and multiarch pkg-config consumers | `verified locally` | The local Linux container consumed the installed pkg-config metadata |
| Linux mount/bind transaction mutation and recovery | `not run` | The local container suite had one explicit mount-namespace skip; the required privileged target-host lane has not run |
| Cross-platform/macOS packaged signed helper ownership transfer, cross-process target lock, durable journal, and crash recovery | `blocked` | Local macOS helper tests passed 38 tests and root SwiftPM passed 62 tests, but signed/elevated combined-boundary evidence is absent; local signing inspection found 0 valid code-signing identities |
| Linux normal ZIP smoke | `not run` | Requires the Linux target-host job for the current helper head |
| Portable native helper fixture/state-machine CI | `not run` | The mandatory job is configured but has not executed for the current helper head |
| macOS unprivileged helper crash-recovery CI | `not run` | The mandatory job is configured but has not executed for the current helper head |
| Windows helper trust/reparse/crash-recovery CI | `not run` | The mandatory job is configured but has not executed for the current helper head |
| Linux helper and privileged mount-namespace CI | `not run` | The mandatory job is configured but has not executed for the current helper head |
| macOS signed nested helper/SMJobBless/XPC CI | `not run` | Manual credential-gated lane; hardened-runtime and trust boundary not executed |
| Windows Authenticode/UAC helper CI | `not run` | Manual self-hosted credential-gated lane |
| Linux installed polkit broker CI | `not run` | Manual self-hosted policy/privilege lane |
| Current remediation head in GitHub Actions | `not run` | The current helper head has not run in GitHub Actions; older run `29291937840` does not prove these helper changes |
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
evidence. The packaged standalone helpers now use a durable native transaction
journal, cross-process target locks, and platform-specific reparse or mount
checks. Local source and macOS/Linux execution are candidate evidence only:
mandatory Windows and privileged Linux target-host lanes remain `not run`, and
the signed/elevated combined boundary remains `blocked`. The Flutter recovery
marker is a separate app-owned relaunch expectation and is not a substitute
for the native transaction journal.

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
