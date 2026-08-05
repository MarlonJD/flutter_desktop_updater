# Desktop Updater 3.1 Release Key Management

Status: implementation complete; commit, push, CI, merge, and pub.dev release
gates remain pending.

## Objective

Add a safe local release-signing workflow without changing the runtime trust
contract. The normal flow is `release keygen` followed by profile-backed
`release publish`. Existing explicit environment/file signing remains the
advanced CI path.

## Decisions

- One profile is bound to the exact normalized `app-archive.json` URL and is
  shared by macOS, Windows, and Linux.
- Generated IDs are `release-` plus the first 24 lowercase hex characters of
  the raw Ed25519 public-key SHA-256 fingerprint.
- macOS/Linux use an explicit protected local-file store (`0700`/`0600`);
  Windows uses DPAPI `CurrentUser` and never plaintext fallback. Keychain and
  Secret Service are out of scope.
- Encrypted bundles use the installed `cryptography_plus` Argon2id and
  XChaCha20-Poly1305 APIs, bounded parameters, authenticated headers, and no
  passphrase CLI argument.
- Existing feeds use `keys adopt`; rotation prepares a pending key and
  `keys activate` changes active state only after client adoption.
- The public profile is not a runtime trust authority. Applications continue
  to embed their pinned public-key map.

## Work sequence

- [x] Add strict duplicate-key JSON parsing.
- [x] Add profile schema, fingerprint IDs, atomic profile writes, and stores.
- [x] Add encrypted/public-only export and import.
- [x] Add keygen, adoption, show, rotation, and activation commands.
- [x] Integrate profile resolution with publish, sign, and validate.
- [x] Add focused key-management tests.
- [x] Update user, security, CI, migration, and release documentation.
- [x] Bump and synchronize package version surfaces to 3.1.0.
- [x] Run focused, documentation, structural-harness, analyzer, version, full
      test, and package dry-run validation. The full suite's remaining failures
      are host-signing fixtures and a temporary clone Swift package-name
      mismatch; the affected Swift contract passes from the repository-name
      checkout, and the native compatibility test passes in isolation.
- [ ] Commit only on a safe target branch; do not push main or detached HEAD.

## Verification boundary

Focused key-management tests run on macOS. Windows DPAPI target-host evidence,
provider-backed publishing, CI, merge, and pub.dev publication are separate
gates. A failed or unavailable target-host command must remain explicitly
`not run` or `blocked`.
