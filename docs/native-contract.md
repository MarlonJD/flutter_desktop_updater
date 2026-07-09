# Native Updater Contract

This document freezes the `desktop_updater` 2.7 contract that native helper
packages and the gated native runtime preview must preserve. Flutter apps keep
using the Dart runtime and the existing MethodChannel handoff.

## Schema And Artifact Matrix

Release metadata uses schema version 3. `app-archive.json` is discovery
metadata and is not signed. Trust begins at the selected `release.json`
descriptor and remains bound to the selected index item's version, integer
build number, platform, and channel.

| Platform | Artifact kinds | Install strategies |
| --- | --- | --- |
| macOS | `zip`, `dmg`, `pkgInstaller` | `wholeBundleReplace`, `pkgInstaller` |
| Windows | `zip`, `innoInstaller` | `wholeDirectoryReplace`, `innoInstaller` |
| Linux | `zip` | `wholeDirectoryReplace` for a verified self-contained directory bundle |

Descriptors retain expected package identity, non-empty
`minimumUpdaterVersion`, optional `minimumOS`, rollout, support policy,
fresh-install metadata, lowercase SHA-256, exact artifact byte length, and
artifact-specific DMG, PKG, and Inno install metadata.

## Trust Boundaries

- Verify Ed25519 descriptor signatures over Dart-compatible canonical JSON.
- Resolve signatures only through a pinned `publicKeyId`; unknown key IDs and
  modified canonical bytes fail closed.
- Compare the descriptor package identity with the app-owned expected identity
  before installation.
- Keep DMG, PKG, and Inno publisher checks in addition to descriptor and
  artifact verification.
- Validate archive paths before extraction and reject paths that escape the
  staging root.

The discovery index is not an authenticated policy document. A signed index
would require separate schema work.

## Linux Install Target Safety

A Linux install operation is allowed only for an absolute canonical app-owned
root with a relative executable path that resolves strictly inside it. The
helper rejects symbolic-link roots, overlapping staging roots, escaping
removed-file paths, and these protected shared/system roots:

```text
/
/bin
/sbin
/usr
/usr/bin
/usr/sbin
/usr/local
/usr/local/bin
/opt
/etc
/var
/home
```

A nested self-contained bundle such as `/opt/example-app` remains valid.
Controller-owned update flows pass the verified descriptor package identity.
Legacy direct calls without enough identity or bundle evidence fail before a
script is created and must direct the app to a fresh installer.

A restart request is non-mutating: it waits for the current process and
relaunches the already resolved executable without backup, pruning, copying,
rollback, or staging cleanup.
