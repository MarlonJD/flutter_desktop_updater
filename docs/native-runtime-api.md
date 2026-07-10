# Native Runtime Preview API

The native runtime is a preview contract for non-Flutter macOS, Windows, and
Linux applications. Flutter applications continue to use the Dart
`UpdateClient`. The helper SDKs remain usable independently of this runtime.

## Implementation status

| Platform | Artifact | Status | Planned handoff |
| --- | --- | --- | --- |
| macOS | `zip` | `not implemented` | Whole-bundle helper replacement |
| macOS | `dmg` | `not implemented` | Read-only mount, app copy, helper replacement |
| macOS | `pkgInstaller` | `not implemented` | Installer.app |
| Windows | `zip` | `not implemented` | Directory helper replacement |
| Windows | `innoInstaller` | `not implemented` | Versioned helper C ABI |
| Linux | `zip` | `not implemented` | Validated install-root replacement |

The macOS contract is a Swift API. Windows exposes a versioned C ABI with a
.NET wrapper. Linux exposes a C++ source ABI only; it does not promise a stable
binary ABI or a generic prebuilt shared library.

## Runtime configuration

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

## Typed outcomes

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

The configuration types and outcome enums compile today so applications can
evaluate the preview surface. Discovery, download, staging, and install entry
points remain unavailable until their platform implementation and external
consumer smoke pass.

## Windows ABI ownership

`DESKTOP_UPDATER_RUNTIME_ABI_VERSION` is `1`. Every request and result starts
with `abi_version` and `struct_size`. Callers set both fields and zero any
unknown tail bytes. The DLL catches exceptions at the C boundary.

The runtime client is an opaque owned handle released with
`desktop_updater_runtime_client_free_v1`. Result messages are owned by the DLL
and released with `desktop_updater_runtime_result_free_v1`. Callback inputs are
borrowed for the duration of the call. Header entries returned by the
application remain application-owned until its release callback runs.

## Trust boundary

`app-archive.json` is discovery metadata. A selected index item must exactly
match descriptor version, integer build number, platform, and channel. The
descriptor package ID must match `expectedPackageId`. Descriptor signatures
use Dart-compatible canonical JSON, Ed25519, and an application-pinned key ID.
Platform publisher checks remain mandatory for DMG, PKG, and Inno artifacts
when configured. Unsupported artifact kinds fail before artifact download.
