# Release Key Management

Desktop Updater 3.1 uses a profile-based release-signing workflow. The
application still embeds the public key map in `trustedReleasePublicKeys`, and
the updater never treats this mutable project profile as runtime trust.

## First local setup

From the application project that contains `desktop_updater.yaml`:

```sh
dart run desktop_updater:release keygen
dart run desktop_updater:release publish --platform macos
dart run desktop_updater:release publish --platform windows
dart run desktop_updater:release publish --platform linux
```

`keygen` resolves the exact `updates.baseUrl/app-archive.json` feed, generates
one Ed25519 key, and writes the public profile to
`desktop_updater.keys.json`. The key ID is generated from the first 24
hexadecimal characters of the SHA-256 fingerprint of the raw public key:

```text
release-<24 lowercase hexadecimal fingerprint characters>
```

The same feed profile is shared by macOS, Windows, and Linux. Running `keygen`
again is idempotent. It never replaces an existing identity and refuses to
repair a missing private secret by silently generating a new key.

The profile is safe to review and commit. It contains no private seed,
passphrase, secret-store path, or environment value.

Use `--config`, `--base-url`, or `--key-profile` when the project uses a
non-default location.

## Private-key storage

On macOS and Linux, the private seed is stored outside the repository in a
per-user directory with a `0700` directory and `0600` file policy. This is
filesystem-permission protection and is not equivalent to Keychain or Secret
Service storage. On Windows, the profile store uses DPAPI `CurrentUser` and
stores only DPAPI ciphertext; it never falls back to a plaintext Windows key
file. Windows DPAPI evidence must come from a Windows host or CI lane.

No command edits `.zshrc`, `.bashrc`, PowerShell profiles, `setx`, registry
environment variables, or the parent process environment. A child CLI cannot
reliably update its caller's environment; the profile is the persistent local
configuration instead.

## Moving to another computer

Create an encrypted backup. The passphrase is read from a hidden prompt or an
environment variable; there is deliberately no `--passphrase` argument.

```sh
dart run desktop_updater:release keys export \
  --output release-key.dukey \
  --passphrase-env DESKTOP_UPDATER_KEY_BUNDLE_PASSPHRASE
```

The bundle is versioned JSON encrypted with Argon2id and XChaCha20-Poly1305.
The implementation bounds the envelope and KDF parameters, authenticates the
header as associated data, rejects wrong passphrases and tampering with the
same generic authentication error, and never exports plaintext private keys.

On the destination computer:

```sh
dart run desktop_updater:release keys import \
  --input release-key.dukey \
  --passphrase-env DESKTOP_UPDATER_KEY_BUNDLE_PASSPHRASE
```

For application review or trust-map preparation, export public metadata only:

```sh
dart run desktop_updater:release keys export \
  --public-only \
  --output release-public-keys.json
```

Public-only export does not open the private-key store. Output files refuse to
overwrite an existing file unless `--force` is supplied.

## Existing 3.0 feeds

Do not run `keygen` for a feed that is already signed with a manually chosen
ID such as `stable-2026`; that would create a new identity. Adopt the existing
key once instead:

```sh
dart run desktop_updater:release keys adopt \
  --input legacy-adoption.json \
  --output release-key.dukey \
  --passphrase-env DESKTOP_UPDATER_KEY_BUNDLE_PASSPHRASE
```

`keys adopt` accepts one strict JSON input containing the existing key ID,
private seed, and complete public map. It preserves the key ID, verifies the
private seed against the map, writes the profile, and exports an encrypted
bundle. It is migration-only and never signs a release directly. Delete the
plaintext input after successful export. CI and other machines must use only
encrypted bundle import; raw private-key environment variables and files are
not supported.

## Rotation

Rotation is deliberately two-phase so an unadopted client cannot be locked
out:

```sh
dart run desktop_updater:release keys rotate
```

This prepares a pending key and leaves the current active key unchanged.
Embed both old and pending public keys in the application and release that
client first. After the required adoption window:

```sh
dart run desktop_updater:release keys activate
```

Activation changes the active key and retains the old public and private key
material. Old keys are never removed automatically. Remove an old key only as
a separately managed client-trust migration.

## Low-level commands

```sh
dart run desktop_updater:release keys show
dart run desktop_updater:release sign --key-profile desktop_updater.keys.json \
  --config desktop_updater.yaml --release dist/desktop_updater/releases/.../release.json
dart run desktop_updater:release validate --key-profile desktop_updater.keys.json \
  --manifest dist/desktop_updater/.desktop_updater_publish.json
```

Profile-backed `publish` and `sign` bind the profile to the exact configured
`app-archive.json` URL. Profile-backed `validate` binds it to the feed URL in
the publish manifest. Standalone `verify` reads the same public profile and
does not accept a direct public-key environment input.

Metadata signing is separate from platform signing. This workflow does not
replace Apple Developer ID/notarization, Windows Authenticode, or Linux
distribution signing.
