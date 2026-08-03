# Desktop Updater 3.0 Contract

## Status and scope

This is the durable contract record for the breaking 3.0 migration. It freezes
the decisions in the active [3.0 ExecPlan](../exec-plans/active/2026-08-03-desktop-updater-3-0-breaking-contract-plan.md).
It does not itself change a runtime API.

The baseline is `2f91208f0de95b9656b0ce2a28258e70a2920b86` (`2.7.0`). Existing
protocol-v1 helper readers and durable native transaction readers remain
internal compatibility obligations. Public source and Windows ABI compatibility
are intentionally broken where documented below.

## Frozen public contract

`DesktopUpdaterController` and `DesktopUpdaterController.forTesting` require
the same `Uri? appArchiveUrl`, `String expectedPackageId`,
`Map<String, String> trustedReleasePublicKeys`, and `UpdateRecoveryStore`
inputs. A non-null URL is absolute at construction time; `null` retains delayed
`init(Uri)`, where the identical validation occurs before any request. Testing
adds only non-authority collaborators.

New recovery writes use `UpdateInstallRecoveryMarker.pendingV3` with package,
channel, update version/nullable build number, expected package ID, staging
path, stage-provenance SHA-256, and a canonical lowercase UUID. A legacy
decoder may represent missing v3 fields as nullable, but no new write may omit
them.

The low-level facade becomes `createZipFirstUpdateSession`. A session owns one
client; its final, library-constructed `UpdateCheckResult` and
`UpdateStageResult` are single-use and owner-bound. Raw descriptor download,
stateless check/download, and raw staged installation are removed.

`PersistedInstallTransaction`, `RetainedVerifiedStage`, and
`VerifiedNativeInstallRequest` are opaque. Only the library may create them.
Dispatch claims a retained stage before its first await, compares every
durable/staged binding, and consumes the stage even if a later platform call
fails. A transaction is recovered by ID rather than replaying staging.

Platform implementations expose `installVerifiedUpdate` and one sealed,
callback-backed recovery capability. macOS and Linux use
`QueryAndRecoverNativeInstallRecovery`; Windows uses
`AtomicAfterExitNativeInstallRecovery` and has no direct-recover member.
Unauthenticated absence, transport failure, malformed responses, unsupported
platforms, and endpoint-authentication failure throw; only an authenticated
well-formed absence yields `null`.

The channel keeps its internal method names but receives only verified required
evidence: staging path, expected package ID, expected artifact SHA-256, stage
provenance SHA-256, and transaction ID. It does not accept caller-selected
removed files, unsigned mode, diagnostics path, install root, executable path,
or Windows signer/elevation policy.

## Native and durable compatibility

Windows introduces an ABI-2 symbol family and never reuses the shipped
`desktop_updater_prepare_install_v2` binary signature. The 2.7 header and a
compile probe are frozen under `test/fixtures/compat/windows-native-abi/2.7.0`.
The old export remains only as a deterministic rejecting tombstone.

The durable fixture set under `test/fixtures/compat/native-durable-state/2.7.0`
is byte-addressed by SHA-256. It represents prepared crash boundaries from the
2.7 writers, except macOS verified-installer schema 1, which is pinned to
writer commit `73aa730efbf1384eef9b74d7eb87ee655d81c0b5`, before schema 2 landed
in `96cc4ecbb009d5be5a50adcbeeedf8fae2dedfa4`. Windows transaction schema 1 is
not revived. New readers must decode and re-encode the frozen bytes, and a
fresh process must query and recover/resolve without rewrite; protected helper
endpoint lookup has the same no-rewrite requirement.

## Trust and durability timeline

| Stage | Required proof | Failure boundary |
| --- | --- | --- |
| Configuration | Absolute URL, package ID, pinned non-empty Ed25519 key map, recovery store | Constructor/session |
| Check | Signed index, selected item, signed descriptor, index/descriptor binding, package/channel/OS policy | Before returning a check result |
| Download | Same-client check, recomputed binding, signature and package identity | Before artifact request |
| Verify and stage | Length, SHA-256, safe extraction, platform trust, signed descriptor and immutable provenance | Before stage result |
| App persistence | Lowercase UUID and all update/stage bindings written, read back, and compared | Before every platform call |
| Native adapter | Fresh retained stage, single-use claim, target process proof, sealed Windows policy | Before privilege boundary |
| Helper prepare | Helper identity, target proof, provenance, sealed policy, lock, durable journal | Before target mutation |
| Commit and recovery | Reservation/response binding; query everywhere; atomic Windows resolver | Before mutation or marker clearing |
| Relaunch | Verified terminal filesystem state | After recovery |

## Security policy versus compatibility break

Fail-closed behavior and a source/ABI break are separate claims. Requiring
signatures, package identity, provenance, and authenticated helper responses
changes the security failure point. Removing optional constructor inputs,
unsigned flags, raw descriptor/staging paths, schedule helpers, diagnostics
paths, and ABI-1 declarations is a source or ABI break. Neither claim is used
as evidence for the other.

## Executable enforcement

`flutter_300_public_api_test.dart`,
`flutter_300_channel_controller_contract_test.dart`, and
`v3_removed_api_contract_test.dart` run compiler/analyzer consumers rather
than name-only source scans. They retain the 2.7 red evidence until the later
production implementation tasks turn them green.
