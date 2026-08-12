## 3.1.4

* Added exclusive lease publication for FTP-hosted `app-archive.json` indexes,
  including hosted revision checks before and after the temporary upload and a
  server-side rename before validating the published bytes.
* Hardened FTP failure handling by resolving quote commands relative to the
  authenticated FTP root, failing closed instead of directly overwriting the
  live index when rename fails, and reporting stale lease cleanup failures with
  the exact recovery path.
* Added regression coverage and a required real Docker FTP end-to-end lane with
  protocol-banner readiness and native container architecture selection. Thanks
  to @Nicoeevee for the original contribution in PR #71.

## 3.1.3

* Fixed Windows direct-ZIP updates for exact per-user app roots created by
  legacy releases that do not have an installed identity marker. After signed
  descriptor, sealed-policy, and stage-provenance authorization, the portable
  helper can adopt the canonical marker uniquely bound into the verified ZIP.
* Kept invalid, malformed, mismatched, reparse-point, and otherwise unsafe
  installed markers fail-closed. Existing markers are never overwritten, and
  the protected Program Files/uninstall-record authorization path is unchanged.
* Added Windows native and source-order regression coverage for missing-marker
  adoption, matching-marker preservation, mismatches, unsafe targets, and
  provenance tampering.

## 3.1.2

* Completed the macOS privileged helper and PKG recovery path, including
  durable prepare/commit state, forced-helper-termination recovery,
  fail-closed target and staging validation, and terminal transaction cleanup.
* Fixed macOS PackageKit installs so application bundles are non-relocatable,
  strict-identifier upgrades and cannot be skipped or redirected because a
  different bundle version is discoverable elsewhere on the host.
* Added root-owned structured macOS helper diagnostics for verification,
  backup, move, cleanup, rollback, recovery, and recovery-marker lifecycle
  events without recording credentials or authorization secrets.
* Hardened the production smoke harness around authenticated installed-host
  execution, background-item approval rejection, SMAppService endpoint
  refresh, receipt checks, helper provenance, and recovery cleanup.
* Confirmed the canonical five-key macOS `installUpdate` handoff reported by
  @Nicoeevee in PR #67 through a real Flutter macOS application update.
* Validation: Developer ID signed non-notarized negative lanes and
  `general-notary` signed/notarized/stapled app, DMG, standard PKG, privileged
  PKG, background approval OFF/ON, forced recovery, and diagnostics lanes were
  exercised locally with the consumer application updating from 1.0.0+100 to
  1.1.0+110.

## 3.1.1

* Fixed the macOS `installUpdate` MethodChannel handoff to send the canonical
  five-key payload required by the native plugin. A real Flutter macOS smoke
  app update from `1.0.0+100` to `1.1.0+110` passed with signed, notarized, and
  stapled artifacts.
* Hardened macOS ZIP staging and protected install validation, and aligned the
  native helper, policy, recovery-smoke, and diagnostics contracts with the
  verified install flow.
* Validation note: notarized app update, DMG first-install/move, DMG artifact
  trust, and DMG replacement were exercised. PKG artifact trust also passed.
  Administrator-approved PKG installation, privileged helper/recovery/rollback,
  final relaunch observation, and native Logger/OSLog evidence remain in
  progress and are not claimed as complete in this release.

## 3.1.0

* **Breaking:** remove the 3.0 direct environment/file release-signing command
  path. `release publish`, `release sign`, and `release validate` now use only
  the feed-bound `desktop_updater.keys.json` profile or `--key-profile`.
* **Breaking:** make standalone `verify` profile-backed and remove its direct
  public-key environment input.
* **Breaking:** make `keys adopt` migration-only. It accepts one strict JSON
  input, preserves the existing key ID, writes a profile, and exports an
  encrypted bundle; plaintext adoption input must be deleted afterward.
* Add the [3.0 to 3.1 release-key guide](docs/migration/3.0-to-3.1.md).

* Added automatic Ed25519 release-key profiles with fingerprint-derived key IDs
  and idempotent `release keygen` setup.
* Added protected local-key storage on macOS/Linux and Windows DPAPI storage
  without plaintext Windows fallback.
* Added encrypted key export/import, public-only export, existing 3.0 key
  adoption, and two-phase pending-key rotation.
* Added profile-backed publish, sign, and validate flows; the direct
  environment/file signing contract from 3.0 was removed in 3.1.0.

## 3.0.0

* **Breaking:** require signed release metadata, pinned public keys, expected
  package identity, and an app-owned durable recovery store.
* **Breaking:** replace implicit native scheduling and generated transaction
  IDs with explicit prepare, commit-after-exit, cancel, query, and recovery
  operations.
* **Breaking:** publish the ABI2 Windows native and runtime surfaces, remove
  caller-controlled diagnostics/target policy inputs, and keep the old ABI1
  prepare export only as a rejecting tombstone.
* **Breaking:** remove Linux legacy target proof and require source-first
  explicit transaction requests bound to the running executable and identity
  marker.
* Add the [2.x to 3.0 migration guide](docs/migration/2.x-to-3.0.md) and a
  version-aware `desktop_updater:migrate --from 1|2` command.

## 2.7.0

* Added production macOS DMG and PKG artifact publishing, validation, and local
  smoke evidence flows while preserving direct `.app.zip` whole-bundle update
  behavior.
* Added a macOS move-to-Applications prompt for apps launched from disk images.
* Added DMG update staging that mounts a verified DMG, copies the contained
  `.app`, and hands off to the existing whole-bundle replacement helper.
* Added PKG update staging that verifies signed, notarized installer packages
  and hands them to Installer.app without silent privileged installation.
* Added full Windows Inno installer update mode, including installer
  descriptors, installer staging without zip extraction, Windows helper
  execution, Authenticode policy checks, release CLI publish support, and
  documentation for generated and custom Inno scripts.
* Fixed Windows Inno release publishing so custom installer output names stay
  consistent across the generated script, local artifact, release descriptor,
  publish manifest, hooks, upload, and validation.
* Documented macOS DMG first-install, DMG update, PKG installer update, and
  Windows Inno installer support boundaries.

## 2.4.5

* Preserved Inno Setup uninstall artifacts named `unins###.exe`,
  `unins###.dat`, and `unins###.msg` during Windows direct zip
  `wholeDirectoryReplace` updates.
* Retried Windows staging cleanup after a successful payload copy without
  rolling back the already-installed update when cleanup still fails.
* Added conservative Dart cleanup for old `desktop_updater_stage_*` directories
  before creating a new staging directory.
* Documented the Inno-compatible direct zip update boundary and clarified that
  the updater still does not download or execute Inno `.exe` installers.

## 2.4.4

* Fixed macOS `release publish` metadata so `release.json` preserves the
  top-level `.app` bundle name while generated artifact zip filenames keep the
  existing extension-stripped format.
* Added regression coverage for macOS bundle-name staging metadata and
  cross-platform zip packaging behavior.

## 2.4.3

* Previewed a Windows protected-directory install fix that treats
  `C:\Program Files` and `C:\Program Files (x86)` app directories as requiring
  UAC elevation when the app is launched by a non-admin user, even if a simple
  write probe can create a temporary file there.
* Documented the updated Windows UAC decision path for protected install roots,
  writable per-user installs, and helper diagnostics.
* Updated the pub.dev description and topics to better position
  `desktop_updater` as a Sparkle-style updater for Flutter desktop apps.

## 2.4.2

* Extended `requestHeadersProvider` to hosted release notes loaded through
  `releaseNotesUrl`, so private update hosts can use the same runtime-owned
  headers for update metadata, artifacts, and release notes.

## 2.4.1

* Added customizable support-policy date formatting for localized ready-made
  UI, with a default `YYYY-MM-DD HH:mm UTC` display.
* Documented explicit locale loading such as `tr_TR`, including bundled locale
  fallback and app-owned date formatting overrides.
* Removed the default macOS CI runner from push/PR checks while keeping the
  notarized macOS publish smoke as an opt-in workflow.

## 2.4.0

* Added ready-made updater UI localization loading from bundled package JSON,
  app-owned JSON assets, direct string overrides, and app-owned resolver
  callbacks.
* Added bundled starter translations, automatic locale fallback, runtime
  localization switching, and RTL text direction support for locales such as
  Arabic and Hebrew.
* Documented i18n setup with JSON schema guidance and screenshots for Arabic,
  Hebrew, Japanese, Korean, and Cyrillic examples.

## 2.3.7

* Added `release publish` `additionalFiles` support for packaging app-owned
  manuals, language packs, and other external files before platform signing,
  notarization, pre-package hooks, and zip descriptor generation.
* Added a packaged update policy guide and README summary for optional,
  mandatory, support-policy, and fresh-install update modes.

## 2.3.6

* Exported `DesktopUpdaterController` and core public update result/version
  types from `package:desktop_updater/desktop_updater.dart` so README quick
  start examples work with a single package import.

## 2.3.5

* Added `requestHeadersProvider` so apps can attach runtime-owned HTTP headers
  to private update host requests for `app-archive.json`, `release.json`, and
  update artifact downloads.
* Documented private update host authentication with a short README pointer and
  detailed publishing guide coverage.

## 2.3.4

* Added `MandatoryReadyToInstallBehavior` for dialog-based mandatory update
  flows so apps can choose the default `Save first` prompt or restart without an
  extra confirmation.
* Fixed `UpdateDialogListener` mandatory `Save first` handling so it dismisses
  the modal update flow and lets the user return to the app to save work.

## 2.3.3

* Added mandatory ready-to-install UX that preserves mandatory state after staging and shows `Save first` plus `Restart`.
* Added `supportPolicy` for minimum supported app versions with warning-before-deadline and blocking-after-deadline ready-made UI.
* Added `freshInstall` metadata, ready-made fresh-install UI, external download launching, and release publish flags.
* Added `release publish` help and validation for support-policy and fresh-install flags.

## 2.3.2

* Fixed Linux zip staging so Unix permission bits are restored from the update
  archive, preserving executable bundle files before native relaunch.
* Added a Linux native helper fallback that restores the target executable bit
  after replacement and rolls back if relaunch would be impossible.
* Documented Linux zip permission expectations for apps that produce update
  artifacts outside `release publish`.

## 2.3.1

* Added `release publish --dart-define` support so build-time Dart environment
  values are forwarded to `flutter build`.

## 2.3.0

* Added optional release notes support for update UIs through `releaseNotesUrl`, `releaseNotesLoader`, `releaseNotesState`, and `loadReleaseNotes()`.
* Added public release notes models that keep the simple `{ "data": [{ "type", "message" }] }` format supported while allowing richer sections, summaries, and item metadata.
* Added a built-in Material release notes bottom sheet and wired the ready-made update card to show a release notes action when notes are available.
* Added example custom release notes UIs for inline panels, side sheets, and changelog pages.
* Fixed the release notes bottom sheet so its first load starts after the route has built, avoiding build-time listener notifications.

## 2.2.0

* Added opt-in update diagnostics sinks with redacted log formatting for app-owned lifecycle logs.
* Added app-owned install recovery markers and post-relaunch failure reports for native install handoff.
* Added explicit native helper diagnostics log paths for macOS, Windows, and Linux helper events.
* Added Windows and Linux CI smoke diagnostics artifacts for failed or explicitly requested diagnostics runs.
* Documented the native helper diagnostics and recovery support flow in the README and product docs.

## 2.1.4

* Added `release publish --mandatory` so generated `app-archive.json` items can mark updates as mandatory while keeping the default optional.
* Fixed Windows staged updates to refresh the uninstall display version metadata after installation.

## 2.1.3

* Fixed Windows `release publish` builds so the CLI invokes `flutter build windows --release` through shell-aware process resolution.

## 2.1.2

* Fixed notarized macOS `release publish` so nested Flutter frameworks are signed before the outer `.app`, then verified through notary, stapler, and Gatekeeper before packaging.
* Added user-facing `release publish` smoke coverage for Windows, Linux, and opt-in notarized macOS CI so release smoke tests exercise the same publish command users run.

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
