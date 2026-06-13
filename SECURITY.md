# Security Policy

This document summarizes how `desktop_updater` handles security reports and the
security boundaries of its desktop update flow.

## Supported Versions

The actively maintained line is `2.x`. Security fixes are released on the latest
`2.x` version unless a project-specific migration note says otherwise.

The `1.x` line is legacy. Applications still on `1.x` should migrate to `2.x`
before relying on production update distribution.

## Reporting A Vulnerability

Please do not publish exploit details in a public issue first.

Preferred report path:

1. Open a private GitHub security advisory for this repository if GitHub offers
   that option to you.
2. If private advisory reporting is not available, open a minimal public issue
   asking for a private disclosure channel. Do not include exploit payloads,
   secrets, or step-by-step abuse details in that public issue.

Useful report details:

- affected `desktop_updater` version;
- operating system and architecture;
- update source shape, such as direct HTTPS, S3-compatible storage, SFTP, FTP,
  or a custom upload command;
- whether signed `release.json` descriptors are required by the app;
- a minimal reproduction or proof sketch;
- expected impact, such as rollback, metadata spoofing, path traversal, stale
  file retention, or publisher-trust bypass.

Security fixes should include regression coverage when practical and should be
verified with the narrowest relevant `flutter test --no-pub` target before
release.

## Update Security Model

`desktop_updater` 2.x uses a zip-first contract:

```text
app-archive.json -> release.json -> app.zip
```

The updater treats these files as different trust layers:

- `app-archive.json` is the small mutable index clients check first.
- Each selected index item points to one versioned `release.json`.
- `release.json` points to one zip artifact and records its expected length and
  SHA-256 digest.
- The downloaded artifact is verified before staging or installing it.
- Optional Ed25519 descriptor signatures can authenticate `release.json`
  metadata when the app pins trusted public keys.

The selected `app-archive.json` item and downloaded `release.json` must agree on
release identity: version, build number when present, platform, and channel.
Hosted validation also checks descriptor identity before accepting a published
update.

## Platform Trust

`desktop_updater` verifies update mechanics and artifact integrity. The app
publisher still owns platform trust.

- macOS production updates should be Developer ID signed, hardened-runtime
  enabled, notarized, stapled, and Gatekeeper accepted before packaging.
- Windows production updates should Authenticode-sign and timestamp signable
  `.exe` and `.dll` files when publisher trust is required.
- Linux direct zip distribution should require signed descriptors or another
  publisher-authenticity policy before being treated as production trusted.
  Native package repositories and stores can provide their own signing and
  update policies.

## Hardening Summary

Recent 2.x hardening includes:

- release selection binding between `app-archive.json` and `release.json`;
- hosted `release validate` rejection for descriptor identity mismatches;
- SHA-256 and length verification before staging;
- safe zip extraction checks;
- signed `release.json` support with app-pinned Ed25519 public keys;
- top-level staged macOS `.app` symlink rejection, with a native helper recheck;
- Windows and Linux whole-directory pruning before replacement so stale target
  files do not survive an update;
- opt-in notarized macOS `release publish` flow that signs nested Flutter
  frameworks before the outer app bundle and verifies the notarized result
  before packaging.

## Release Operation Guidance

For production releases, prefer:

- HTTPS for `app-archive.json`, `release.json`, and zip artifacts;
- short cache TTLs for `app-archive.json`;
- long, immutable cache TTLs for versioned `release.json` files and artifacts;
- signed descriptors with release private keys kept outside the repository;
- CI gates for platform signing, package generation, hosted validation, and
  post-upload `release validate --require-signature` where applicable;
- uploading versioned files first and exposing `app-archive.json` last.

Internal scan artifacts, temporary reports, credentials, signing keys, and
provider tokens should not be committed to this repository.
