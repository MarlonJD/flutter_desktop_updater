# Release Key Profile Contract

## Status and scope

This document freezes the durable release-key profile and backup contract
introduced by Desktop Updater 3.1. It supplements the [release key management
guide](../release-key-management.md); it does not change the runtime trust
contract. Applications continue to embed their own trusted public-key map and
the updater never treats a mutable project profile as runtime trust.

## Feed-bound profile

The default public profile is `desktop_updater.keys.json` at the application
project root. `--key-profile` may select another path, resolved relative to the
project root when it is not absolute. The profile is shared by macOS, Windows,
and Linux releases for one exact normalized `app-archive.json` URL.

Schema version 1 is:

```json
{
  "schemaVersion": 1,
  "profileId": "0123456789abcdef0123456789abcdef",
  "feedUrl": "https://updates.example.com/app-archive.json",
  "activeKeyId": "release-0123456789abcdef01234567",
  "pendingKeyId": "release-fedcba9876543210fedcba98",
  "publicKeys": {
    "release-0123456789abcdef01234567": "base64-raw-32-byte-public-key",
    "release-fedcba9876543210fedcba98": "base64-raw-32-byte-public-key"
  }
}
```

`pendingKeyId` is optional. `profileId` is 16 random bytes encoded as lower-case
hex. Generated IDs are `release-` plus the first 24 lower-case hexadecimal
characters of SHA-256 over the raw 32-byte Ed25519 public key. Existing labels
such as `stable-2026` remain valid for adoption and direct CI signing.

Readers reject unknown or duplicate fields, unsupported schema versions, BOMs,
invalid UTF-8, unsafe IDs, invalid public-key bytes, missing active/pending
references, and profiles larger than 64 KiB. The profile contains no private
seed, passphrase, secret-store path, or environment value. Writes are
same-directory temporary-file writes followed by an atomic rename; callers
must not infer power-loss durability or elimination of every same-user TOCTOU
race from this operation.

## Private-key storage

macOS and Linux use a per-user protected local-file store outside the project:
parent directories are `0700` and files are `0600`, symlinks are rejected, and
profile operations use an exclusive lock. This is filesystem-permission
protection, not Keychain or Secret Service protection.

Windows uses DPAPI `CurrentUser` and stores only ciphertext. If DPAPI is
unavailable, the CLI fails with direct-signing guidance; it never silently
falls back to a plaintext Windows key file. No command modifies shell profiles,
`setx`, registry environment variables, or the parent process environment.

## Portable encrypted bundle

`keys export` writes a versioned JSON envelope using Argon2id with the fixed
3.1 parameters (64 MiB memory, three iterations, one lane, 32-byte output) and
XChaCha20-Poly1305 with a 24-byte nonce. The envelope header is authenticated
as associated data. Bundles are bounded to 1 MiB, passphrases must contain at
least 12 Unicode scalar values, and wrong passphrases/tampering produce one
generic authentication error. Plaintext private-key export is not supported.

The encrypted payload contains the validated public profile and available
private seeds indexed by key ID. Active and pending seeds are required on
import; retired private seeds may be absent. Import is idempotent for identical
state and refuses feed/profile/public-map conflicts without merging. Public-only
export never opens the private-key store.

## Adoption and rotation

`keys adopt` imports an existing direct-signing key and complete public map,
preserving IDs such as `stable-2026`; it never generates a replacement key.

Rotation is two-phase. `keys rotate` stores a new seed and adds its public key
as `pendingKeyId` while leaving `activeKeyId` unchanged. Clients must embed both
keys before `keys activate` changes the active key. Activation retains old
public/private material and removes nothing automatically. Old trust entries
are removed only through a separately managed client migration.

## Release boundary

The feature is a backward-compatible CLI addition and targets 3.1.0. Direct
environment/file signing remains supported for CI and advanced pipelines.
Version bump, commit/push, CI/merge, and pub.dev publication are separate
release gates; a publish dry-run is not publication evidence. Host-specific
Windows DPAPI evidence requires a Windows host or CI lane.
