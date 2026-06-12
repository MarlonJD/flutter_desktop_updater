## 2.1.1

* Hardened update selection so `app-archive.json` entries must match the downloaded `release.json` version, build number, platform, and channel.
* Hardened `release validate` to reject hosted descriptor identity mismatches before accepting a published update.
* Rejected top-level staged macOS `.app` symlinks and rechecked the staged app inside the native install helper before replacement.
* Pruned Windows and Linux whole-directory targets before copying the staged update, preventing stale files from surviving replacement.

## 2.1.0

* Added the high-level `dart run desktop_updater:release publish` flow for building, packaging, manifest generation, manual upload packages, provider upload, and hosted validation.
* Added `dart run desktop_updater:release validate` to simulate an older installed version, select an update, fetch `release.json`, download the artifact, and verify length and SHA-256.
* Added release publish upload providers for manual, S3-compatible storage, SFTP, FTP, and custom commands.
* Added ready-made update UI surfaces, manual update check result helpers, and screenshots for the stock card, sliver, dialog, and custom state-driven UI.
* Added explicit macOS notarization opt-in for `release publish --platform macos --notarize` and `macos.notarize: true`.
* Added publishing documentation for minimum setup, provider config, macOS production trust, and Windows/Linux production release options.

## 2.0.1

* Added `dart run desktop_updater:migrate` to preview and apply safe 1.x to 2.0 migration edits, plus manual findings for typed state, old CLI commands, low-level APIs, and platform publishing work.
* Documented the automated migration flow in the README and 1.x to 2.0 migration guide.

## 2.0.0

* Promoted the zip-first 2.0 release contract: `app-archive.json` points to `release.json`, and `release.json` points to one verified zip artifact.
* Added shared Dart update checks, artifact verification, safe staging, typed update state, and zip-first package/verify CLI entrypoints.
* Added native install scheduling for macOS whole-app replacement, Windows locked-file replacement, and Linux directory replacement with rollback-focused smoke coverage.
* Added macOS hosted update smoke hooks, explicit unsigned macOS release-mechanics opt-out, and documentation separating release mechanics from production-trusted publisher gates.
* Added Windows and Linux Release CI gates for build, native tests, integration tests, and update smoke.
* Made 2.0 `buildNumber` metadata optional in release indexes, release descriptors, and the zip-first package CLI.

## 2.0.0-dev.5

* Fixed version comparison so archive build metadata is not treated as newer when the installed app does not expose a build number.
* Added explicit `allowUnsignedMacOSUpdates` opt-out for owners who need unsigned macOS Release update mechanics while keeping signed, notarized, stapled updates as the default production-trusted path.
* Made 2.0 `buildNumber` metadata optional in release indexes, release descriptors, and the zip-first package CLI.

## 2.0.0-dev.4

* Added `skipInitialVersionCheck` to `DesktopUpdaterController` so apps can initialize the controller without immediately checking for updates.
* Kept `skipCheckVersion` as a deprecated alias for the same behavior.

## 2.0.0-dev.3

* Added support for Flutter versions without build metadata in update checks and release tooling.
* Kept build-number based ordering for existing archives while allowing semantic version fallback when `shortVersion` is omitted.
* Fixed Windows ProductVersion parsing so versions like `1.2.3` no longer throw, while malformed values like `1.2.3+` still fail.

## 2.0.0-dev.2

* Added macOS release manifests, content-addressed gzip payloads, and `ditto` full ZIP fallback archives for `.app` bundles.
* Added macOS staged app verification for SHA-256 hashes, file modes, symlinks, unexpected files, bundle identifiers, Team IDs, code signatures, Gatekeeper, and stapler validation.
* Changed macOS releases to publish artifact directories instead of raw `.app` trees or ZIP-only updates.
* Reworked the update pipeline around verified temporary staging directories.
* Added native macOS and Windows install helpers that wait for the app to exit before replacing files.
* Added hash/length verification for downloaded files and normalized archive paths for Windows-hosted files.
* Added support for removing files that no longer exist in the target version.

## 1.3.0
* Revert fix macOS issues, sorry for the inconvenience, do not use 1.2.0 for macOS

## 1.2.0
* Fix macOS issues (thanks to @TheFilyng)

## 1.1.1

* Fix download and skip this version localization and add colors

## 1.1.0

* Fix alert dialog skip condition

## 1.0.5

* Add alert dialog option

## 1.0.4

* Add custom direct widget for theme colors

## 1.0.3

* Fix mandotory skip issue

## 1.0.2

* Lower macOS platform requirement to 10.14
* Add DesktopUpdateSliver widget
* Update version to 1.0.2

## 1.0.1

* Add repository link to pubspec.yaml
* Add example visual to README.md

## 1.0.0

* First version of plugin
