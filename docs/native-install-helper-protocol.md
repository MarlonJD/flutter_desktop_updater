# Native Install Helper Protocol V1

This document is the normative wire-contract reference for the packaged native
install helpers. It implements the common contract in the
[approved privileged-helper design](design-docs/2026-07-11-cross-platform-privileged-install-helper-design.md).
The machine-readable request schema is
[`schemas/native-install-helper-v1.schema.json`](../schemas/native-install-helper-v1.schema.json),
and the generated cross-language fixtures are under
`fixtures/compat/native-install-helper/v1/`.

Linux AppImage, deb, rpm, Flatpak, and Snap artifact production and publishing
are out of scope for protocol v1 implementation. Those formats may consume the
strategy contract only after their separate execution plan's prerequisite is
satisfied.

## Encoding and framing

Every message is one UTF-8 JSON value. An implementation must reject malformed
UTF-8, duplicate object keys, unknown fields in authority-bearing objects,
unsupported major versions, unknown enum values, and non-canonical lowercase
UUIDs. Integer fields remain integers; implementations must not round them
through an IEEE-754 representation.

Canonical JSON is compact UTF-8 JSON with no insignificant whitespace. Object
keys are sorted by ascending Unicode scalar value, which is equivalent to
lexicographic UTF-8 byte order for valid Unicode. Array order is preserved.
Strings use JSON escaping, and integer values retain their exact decimal value.
Duplicate object keys are rejected before canonicalization.

The request has `schemaVersion: 1` and `protocolVersion: 1`. The initial
reservation, status, recovery, journal, and diagnostic shapes are defined in
the schema `$defs`. A digest described as SHA-256 is exactly 64 lowercase hex
characters. A `readyToken` or request nonce represents 32 bytes as 43-character
unpadded base64url.

## Operations

The five protocol operations are:

```text
prepareInstall(request) -> reservation
commitAfterExit(reservation)
cancelReservation(reservation)
queryTransaction(policyId, transactionId) -> transactionStatus
recoverPendingInstall(policyId, targetIdentity) -> recoveryResult
```

`prepareInstall` returns success only after the authenticated helper owns the
exclusive target lock, has durably persisted the initial journal, and monitors
the exact caller process. A reservation contains the transaction ID, an opaque
high-entropy `readyToken`, the journal digest, the authenticated helper endpoint
identity digest, and an absolute expiry instant.

`commitAfterExit` binds the transaction ID, token, journal digest, helper
identity, and caller lifetime. It authorizes work only after the exact caller
exits. `cancelReservation` can remove only a still-`prepared` transaction after
the same bindings and strictly derived sibling names are revalidated.
`queryTransaction` is read-only. `recoverPendingInstall` must acquire recovery
ownership atomically and cannot recover a live owner.

## Request fields and authority

`NativeInstallTransactionRequestV1` binds:

- schema and protocol versions and a lowercase transaction UUID;
- a `policyId` reference and application `packageId`;
- one strategy, a named provider, and a target class;
- target and staging path hints plus an executable-relative proof;
- current and desired version, build, and package identities;
- the staging ownership nonce, provenance digest, artifact digest, and exact
  artifact length;
- the canonical signed-descriptor digest, Ed25519 key ID, and signature;
- caller process, start identity, executable digest, package identity, and
  signer identity;
- a request nonce and an optional platform-log or inherited-stderr diagnostic
  destination.

All paths are untrusted hints, never mutation authority. The helper derives
prepared, backup, journal, lock, and cleanup names beneath an independently
opened and pinned target parent. A caller cannot supply release roots, allowed
install roots, trusted signers, arbitrary commands, sibling paths, or elevated
capabilities. The sealed `HelperPolicyV1` remains authoritative for every
provider, target, signer, release key, and privileged strategy.

The fixed strategy/provider families are:

| Strategy | V1 provider family |
| --- | --- |
| `directoryReplace` | `platformDirectory` |
| `singleFileReplace` | `platformFile` |
| `verifiedInstallerHandoff` | `macosInstaller` or `windowsInno` |
| `systemPackageTransaction` | `apt` or `dnf` |
| `externalManagedRefresh` | `flatpak` or `snap` |

Capability negotiation never silently substitutes a strategy or provider.
Production Snap dangerous sideloading, caller command lines, direct Flatpak or
Snap revision mutation, and shell, PowerShell, or sudo fallback are not protocol
capabilities.

## Journal states and transitions

File and directory swaps use this durable path:

```text
prepared -> backupCreated -> targetActivated -> completed
```

Provider-managed transactions use this durable path:

```text
prepared -> managerStarted -> verificationPending -> completed
```

`rolledBack` and `manualActionRequired` are terminal alternatives. A provider
transaction never claims a file rollback; it records and queries the actual
provider transaction identity. An unknown, corrupt, torn, or ambiguous journal
cannot authorize cleanup and yields `manualActionRequired`.

Before each state change, the helper writes a new sibling journal, flushes the
file, atomically replaces the current journal, and flushes the containing
directory. It then performs the bounded mutation and verifies the observed
filesystem or provider state. Terminal states cannot transition back to an
active state.

## Results and diagnostics

The stable result codes are:

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

The stable diagnostic event names are:

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

Diagnostics retain the transaction ID, journal state, package ID, stable event
name, and stable detail code. They never emit ready tokens, request nonces,
release keys, signatures, authorization material, headers, credentials, or full
personal paths. A user path is reduced to its target class and safe basename.
Existing Flutter calls receive compatible error/result shapes plus redacted
detail; they do not expose this protocol as a new breaking API.

## Negotiation, timeouts, and compatibility

Peers send the highest major protocol version they implement. V1 accepts only
major version `1`; an unknown major version fails before mutation. Additive
minor capabilities, when introduced, must be explicitly advertised and ignored
only when they do not alter authority or required safety checks. Unknown
authority fields, enum values, strategies, providers, result codes, and journal
states always fail closed.

Reservation expiry and caller-exit waiting are bounded by the sealed helper
policy. Expiry before commit cancels a still-prepared reservation. If the exact
caller does not exit before the post-commit deadline, the helper returns a
pre-mutation timeout result and cancels the reservation. A timeout never
authorizes a second helper to recover a live owner.

Protocol v1 does not change the released Flutter API, the `desktop_updater`
MethodChannel methods, or the `DesktopUpdaterKit` product/module/import. Native
SDK clients may add platform-idiomatic wrappers while preserving these exact
wire semantics.
