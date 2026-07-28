# Native Runtime Preview API

The native runtime is an opt-in `preview` for non-Flutter macOS, Windows, and
Linux applications. Flutter applications continue to use the stable Dart
`UpdateClient`. The small install/relaunch helper SDKs remain independently
usable without linking the runtime transport, contract, crypto, or archive
code.

The preview is implemented. Its macOS scope is `production-ready` based on the
accepted local macOS target-host and signed/notarized release evidence. Windows
and Linux remain `candidate-only / external evidence pending`, so the overall
cross-platform preview is still `candidate-only`.

Hosted macOS CI is optional duplication rather than a macOS readiness gate.
Configured Windows or Linux workflow jobs are not execution evidence; an
unchecked or `not run` required lane must not be promoted by inference.

## Linux Scope For This Release

Linux is preview-only in this release and is not production-ready. The supported
release shape is the source-first native SDK with a direct-ZIP update bundle.
That direct-ZIP preview still requires signed release authority, stable package
identity, and the documented helper trust checks; preview does not weaken those
boundaries.

AppImage, deb/APT, rpm/DNF, Flatpak/Flathub, and Snap/Snap Store/Brand Store
distribution are out of scope for this release. Those channels remain
`candidate-only` and `not run` under the separate Linux distribution plan. A
green Docker or hosted Linux job verifies portable mechanics only; it is not
store approval, repository publication, or installed-polkit target-host
evidence.

## Current-Head Merge-Gate Ledger

This table describes the current remediation head, not an earlier commit or a
configured-but-unexecuted workflow.

| Lane | Status | Current evidence |
| --- | --- | --- |
| Portable contract, trust, provenance, lifecycle, redirect, and package-layout suites | `verified locally` | Named focused commands are recorded in the active remediation plan |
| Task 10 complete local ladder | `verified locally` | Historical pre-helper ladder remains recorded in the remediation plan; current helper evidence is listed separately below |
| macOS root SwiftPM tests | `verified locally` | Root `swift test` completed 96/96 tests on this macOS host for the current integration head |
| macOS exact CocoaPods 10.14 six-source typecheck | `verified locally` | The exact fallback source allowlist typechecked for `x86_64-apple-macosx10.14` |
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
| Linux mount/bind transaction mutation and recovery | `not run` | The unprivileged container suite had one explicit mount-namespace skip. A separate privileged throwaway container passed the exact bind-mount rejection test 1/1, but installed-polkit transaction mutation and recovery have not run |
| macOS packaged signed helper ownership transfer, cross-process target lock, durable journal, and crash recovery | `verified locally` | The helper suite passed 134/134 and DesktopUpdaterKit passed 96/96; earlier administrator-approved notarized root-daemon evidence covered XPC prepare, forced-kill rollback recovery, v1-to-v2 replacement, ownership normalization, and fresh-process completed query, while the new PKG provider still requires fresh target-host evidence |
| macOS local Developer ID/notarized SMAppService target-host smoke | `verified locally` | Final universal v1/v2 apps were accepted by Apple notarization, stapled, and Gatekeeper accepted with `source=Notarized Developer ID`; the protected root-owned target updated with daemon PIDs `27851` → `28621` → `29512` and endpoint identities `525c…` → `308d…` |
| Linux normal ZIP smoke | `not run` | Requires the Linux target-host job for the current helper head |
| Portable native helper fixture/state-machine CI | `not run` | The mandatory job is configured but has not executed for the current helper head |
| macOS unprivileged helper crash-recovery CI | `not run` | The mandatory job is configured but has not executed for the current helper head |
| Windows helper trust/reparse/crash-recovery CI | `not run` | The mandatory job is configured but has not executed for the current helper head |
| Linux helper and privileged mount-namespace CI | `not run` | The mandatory job is configured but has not executed for the current helper head |
| macOS signed bundled SMAppService daemon/XPC CI | `not run` | Optional CI duplication; the equivalent target-host boundary is verified locally and accepted for the macOS `production-ready` verdict |
| Windows Authenticode/UAC helper CI | `not run` | Manual self-hosted credential-gated lane |
| Linux installed polkit broker CI | `not run` | Manual self-hosted lane is configured for separate fixed-byte/policy audit plus real non-root public-API → pkexec mutation, durable query, after-backup death, and fresh-broker recovery; it has not run for this head |
| Current remediation head in GitHub Actions | `not run` | The current helper head has not run in GitHub Actions; older run `29291937840` does not prove these helper changes |
| macOS signed/notarized DMG smoke | `not run` | Separate credential-gated `workflow_dispatch` lane |
| macOS signed/notarized hosted PKG approval-required smoke | `not run` | Separate credential-gated `workflow_dispatch` lane; approval-boundary evidence is not install success |
| macOS signed/notarized self-hosted PKG install and receipt smoke | `not run` | Separate preapproved target-host lane for real `/Applications` mutation, receipt, installed helper identity, and stage cleanup |
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
| macOS | `pkgInstaller` | Bundled `SMAppService` root daemon executes the fixed `/usr/sbin/installer` handoff |
| Windows | `zip` | Directory helper replacement |
| Windows | `innoInstaller` | Authenticode-verified installer handoff |
| Linux | `zip` | Preview direct-ZIP install-root replacement |

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

The optional `diagnosticsLogPath` argument is a compatibility-only diagnostics
input. Standalone protocol-v1 helpers use their fixed platform-owned log and do
not write post-exit events to a caller-selected path. Hosts that need their own
durable file should persist app-owned lifecycle diagnostics before handoff.

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
`allowUnsignedUpdates` can relax staging-only checks for a controlled test, but
privileged installation rejects it. The install handoff requires signed
descriptor authority and signed application code; PKG trust is never disabled.

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

Swift installation failures that need a user action use
`RuntimeError.diagnostic` rather than message matching. A pending macOS
background-item approval has diagnostic code
`PrivilegedHelperApprovalRequired` and remediation action
`openMacOSBackgroundItemsSettings`; custom clients may localize the diagnostic
message while switching on those stable typed values.

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
support policy is approved. AppImage, deb/APT, rpm/DNF, Flatpak/Flathub, and
Snap store delivery remain future work under the separate distribution plan.
Linux is source-first and makes no stable binary ABI promise.
