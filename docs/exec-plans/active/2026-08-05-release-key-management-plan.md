# Desktop Updater 3.1 Release-Key Profile Migration

Status: implementation in progress; version surfaces are synchronized, while
validation and release gates remain pending.

## Objective

Ship the 3.1 breaking CLI contract that removes direct private/public key
environment and file inputs from `release publish`, `release sign`,
`release validate`, and standalone `verify`. All normal release operations use
the feed-bound `desktop_updater.keys.json` profile or an explicit
`--key-profile` path. Existing manually managed feeds have one migration-only adoption path
that preserves their key ID, writes the profile, exports an encrypted bundle,
and never signs a release directly.

## Decisions

- The default profile is `desktop_updater.keys.json`, bound to the exact
  normalized `app-archive.json` URL and shared by macOS, Windows, and Linux.
- The four removed direct options are not compatibility aliases or deprecated
  fallbacks. Missing profiles point users to `release keygen` or the one-time
  `keys adopt` migration.
- Adoption accepts only bounded strict JSON with exactly `schemaVersion`,
  `keyId`, `privateSeed`, and `publicKeys`. The input is migration-only and
  must be deleted after encrypted bundle export; CI and other machines import
  only the encrypted bundle.
- Generated IDs are `release-` plus the first 24 lowercase hex characters of
  the raw Ed25519 public-key SHA-256 fingerprint. Adopted IDs are preserved.
- macOS/Linux use the protected local-file store (`0700`/`0600`); Windows uses
  DPAPI `CurrentUser` and never a plaintext fallback. Keychain and Secret
  Service remain out of scope.
- The public profile is not runtime trust authority. Applications continue to
  embed their pinned public-key map.

## Work sequence

- [x] Audit the 3.0 direct signing and verification surfaces.
- [x] Remove direct signing/public-key parser options and resolver branches.
- [x] Add strict adoption input, profile creation, encrypted bundle export,
      and migration-only CLI messaging.
- [x] Move publish, sign, validate, and verify fixtures to profile-backed
      inputs; add parser rejection and adoption coverage.
- [x] Update README, security, publishing, CI, migration, design, and release
      documentation.
- [x] Make ordinary CI path-selective while keeping workflow dispatch and
      version-tag runs as full release gates.
- [x] Bump `pubspec.yaml` and synchronize all generated native version
      surfaces to 3.1.0 without changing lockfiles.
- [ ] Run focused Flutter tests, formatting, analyzer, full tests, harness and
      documentation checks, and `dart pub publish --dry-run`.
- [ ] Commit the breaking change, push the current branch, open the PR, and
      monitor required CI.
- [ ] Merge only after the required checks are green, verify the merge on
      `main`, and run real `dart pub publish`.

## Verification boundary

Raw Dart formatting and analyzer checks can run from the bundled SDK. Flutter
test/analyzer commands currently attempt to write the SDK telemetry/cache
outside the allowed worktree and are blocked by the sandbox policy; record
those gates literally until they run in an authorized environment. Windows
DPAPI, provider-backed publishing, CI, merge, and pub.dev publication are
separate gates and must not be described as locally verified without evidence.
