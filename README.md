# desktop_updater

Flutter desktop updater plugin for macOS, Windows, and Linux.

The 3.1 release uses the signed schema-v3 update flow: one small signed update
index, one signed release descriptor, and one verified artifact:

```text
app-archive.json -> release.json -> app.zip / installer artifact
```

No public folder listing is required. Clients fetch exact URLs and verify the
artifact length and SHA-256 before installation.

![flutter_desktop_updater](https://github.com/user-attachments/assets/b05d9a13-0f44-4213-b3bd-58e07c18226d)

## Quick Start

Upgrading from 2.x or 3.0? Read the [2.x to 3.0 migration guide](https://github.com/MarlonJD/flutter_desktop_updater/blob/main/docs/migration/2.x-to-3.0.md) and the [3.0 to 3.1 release-key guide](https://github.com/MarlonJD/flutter_desktop_updater/blob/main/docs/migration/3.0-to-3.1.md) before changing the dependency. The 3.1 release removes direct release-key options; removed paths are not compatibility aliases.

Add the package:

```yaml
dependencies:
  desktop_updater: ^3.1.4
```

Add `desktop_updater.yaml` at your app repository root, next to
`pubspec.yaml`:

```yaml
updates:
  baseUrl: https://updates.example.com
```

Generate the feed-bound signing profile before constructing the controller:

```sh
dart run desktop_updater:release keygen
```

`keygen` prints the generated map and writes the same public metadata to
`desktop_updater.keys.json`:

```text
Public key map:
{
  "release-0123456789abcdef01234567": "base64-raw-ed25519-public-key"
}
```

Copy the complete printed map into `trustedReleasePublicKeys`; do not type a
new key ID or generate a second key. The example values above are placeholders.
`desktop_updater.keys.json` contains no private key and is safe to review and
commit. The private seed remains in protected local storage.

Back up the private signing material immediately after `keygen`:

```sh
dart run desktop_updater:release keys export \
  --output release-key.dukey \
  --passphrase-env DESKTOP_UPDATER_KEY_BUNDLE_PASSPHRASE
```

Set `DESKTOP_UPDATER_KEY_BUNDLE_PASSPHRASE` to a passphrase of at least 12
characters before running the command.

Keep `release-key.dukey` outside the repository and store its passphrase
separately in a password manager or CI secret store. CI and other computers
restore it with `release keys import`. See the
[release key management guide](https://github.com/MarlonJD/flutter_desktop_updater/blob/main/docs/release-key-management.md)
for backup/import, existing 3.0 key adoption, and two-phase rotation. Existing
3.0 feeds must use that one-time adoption flow instead of `keygen`.

Every 3.1 controller also requires the expected package identity and an
app-owned `UpdateRecoveryStore`. The package ID must exactly match the
`packageId` written into the current platform's `release.json`. The Flutter
publisher resolves its default as follows:

| Platform | Default package ID source |
| --- | --- |
| macOS | `PRODUCT_BUNDLE_IDENTIFIER` in `macos/Runner/Configs/AppInfo.xcconfig` |
| Windows | `name` in `pubspec.yaml` |
| Linux | `APPLICATION_ID` in `linux/CMakeLists.txt`; otherwise publishing requires `--package-id` |

If you publish with `--package-id`, use that exact override in the controller.
Platform identifiers may differ, so select the value at runtime when needed.

`recoveryStore` is required in 3.1. It is not an update-state value; it is a
durable storage adapter for a pending install marker. Before native install
handoff, the controller writes the marker and reads it back exactly. On the
next launch it uses the marker to verify whether the update completed. Copy or
adapt the repository's
[file-backed `JsonFileUpdateRecoveryStore`](https://github.com/MarlonJD/flutter_desktop_updater/blob/main/example/lib/json_file_update_recovery_store.dart)
and place its file in your app's persistent support directory. The complete
controller setup below uses `path_provider` to resolve that directory:

```sh
flutter pub add path_provider
```

```dart
import "dart:io";

import "package:desktop_updater/desktop_updater.dart";
import "package:path_provider/path_provider.dart";

import "json_file_update_recovery_store.dart";

// Replace this entire map with the exact "Public key map" printed by keygen.
const trustedReleasePublicKeys = <String, String>{
  "release-0123456789abcdef01234567":
      "base64-raw-ed25519-public-key",
};

String expectedPackageIdForCurrentPlatform() {
  if (Platform.isMacOS) return "com.example.app";
  if (Platform.isWindows) return "example_app";
  if (Platform.isLinux) return "com.example.app";
  throw UnsupportedError("desktop_updater requires a desktop platform.");
}

Future<JsonFileUpdateRecoveryStore> createUpdateRecoveryStore() async {
  final appSupportDirectory = await getApplicationSupportDirectory();
  final separator = Platform.pathSeparator;
  return JsonFileUpdateRecoveryStore(
    File(
      "${appSupportDirectory.path}${separator}desktop_updater"
      "${separator}pending-install-stable.json",
    ),
  );
}

Future<DesktopUpdaterController> createDesktopUpdaterController() async {
  final recoveryStore = await createUpdateRecoveryStore();

  return DesktopUpdaterController(
    appArchiveUrl: Uri.parse(
      "https://updates.example.com/app-archive.json",
    ),
    expectedPackageId: expectedPackageIdForCurrentPlatform(),
    trustedReleasePublicKeys: trustedReleasePublicKeys,
    recoveryStore: recoveryStore,
  );
}
```

Private update hosts can add runtime authentication headers for update metadata,
artifacts, and hosted release notes with `requestHeadersProvider`; see
[Runtime request headers](doc/runtime-request-headers.md).

Before the first production publish, verify the platform toolchain:

```sh
dart run desktop_updater:release doctor --platform macos
```

Then publish the platform after the generated public key is pinned in the app:

```sh
dart run desktop_updater:release publish --platform macos
```

Add `--initialize-feed` only when the hosted archive has been independently
proven absent; otherwise provide the verified existing history.

With only `updates.baseUrl`, publish creates an upload-ready package under
`dist/desktop_updater` and prints the manual upload and validate instructions.
With an upload provider configured, it uploads versioned files first, validates
them, uploads `app-archive.json` last, then validates hosted update selection.

## Native Helper SDKs And Runtime Preview

The pub.dev Flutter package remains the full update runtime. This repository
also ships Flutter-free install/relaunch helper SDKs and an opt-in native
runtime preview for native host apps:

- `DesktopUpdaterKit` through SwiftPM on macOS, including the Swift preview
  client;
- `desktop_updater::native` helper targets on Windows and Linux, plus the
  opt-in source-built `desktop_updater::runtime` target on Linux;
- `DesktopUpdater.Native` as the Windows .NET preview wrapper and NuGet package
  boundary for both native DLLs;
- a compiled `desktop-updater` CLI candidate matrix for macOS, Windows, and
  Linux.

Helper-only consumers still provide their own discovery, verification, and
staging. The preview adds the stateful `checkForUpdate`,
`downloadVerifyAndStage`, `prepareInstall`, and `commitAfterExit` flow while
reusing the same helpers and trust rules. Hosts use `queryTransaction` and
`recoverPendingInstall` after a restart. Its current merge gates require signed app-archive
authority, owned stage provenance, explicit install target proof, mount and
reparse rejection, a one-shot handoff, Windows Unicode paths and relative
redirects, and Release NuGet packages with third-party notices. Target-host
evidence is commit-bound: the audited baseline normal jobs passed, while each
3.1 release candidate must rerun the named macOS, Windows, Linux, and Windows
VM repetition gates for its exact commit. For 3.1.2, signed/notarized macOS app,
DMG, standard PKG, privileged helper, and forced-recovery target-host lanes are
`verified locally`. Windows junction/reparse, Linux mount/bind transaction
mutation, installed Linux broker, and signed Windows Inno lanes remain
separately gated. The cross-platform native runtime preview therefore remains
`candidate-only`; the macOS production updater path has separate verified
evidence.

See [Native helper SDKs and standalone CLI](https://github.com/MarlonJD/flutter_desktop_updater/blob/main/docs/native-sdk.md) for package
integration and [Native Runtime Preview API](https://github.com/MarlonJD/flutter_desktop_updater/blob/main/docs/native-runtime-api.md) for
compiling examples, current evidence, typed outcomes, and trust boundaries.

## Additional Release Files

Use `additionalFiles` when PDFs, language packs, manuals, or other app-owned
files must ship with the desktop update but are not produced by Flutter:

```yaml
additionalFiles:
  - source: release-assets/manuals/*
    destination: docs/manuals
    platforms: [windows, linux]
  - source: release-assets/manuals/*
    destination: Contents/Resources/Manuals
    platforms: [macos]
```

`release publish` copies these files after `flutter build` and before macOS
notarization, app-owned `prePackage` signing hooks, and zip packaging. That
keeps the packaged artifact consistent with platform signing and trust gates.

## Linux Zip Permissions

Linux is `preview` and direct-ZIP only for this release; it is
`candidate-only`, not `production-ready`. AppImage, deb/APT, rpm/DNF,
Flatpak/Flathub, and Snap store delivery are explicitly outside this release
scope and remain future work.

Linux update zips must keep Unix file mode metadata for executable files in the
bundle. `release publish --platform linux` creates artifacts with those modes,
and the updater restores them while staging the verified zip before the native
helper replaces the installed bundle. If you build Linux update zips with custom
tooling, make sure the app runner remains executable in the archive.

## EL10

Think of your update host as a shelf on the internet:

1. The app reads `app-archive.json`.
2. The archive says which `release.json` is newest for this platform/channel.
3. `release.json` points to one zip and records its size and hash.
4. The app downloads the zip only after the metadata says it is a valid update.
5. The app verifies the zip before staging or installing it.

Publish does the reverse: create the zip, create `release.json`, update
`app-archive.json`, upload the versioned files first, then expose the new
archive last.

## Ready-Made UI

Use the stock inline card:

```dart
DesktopUpdateWidget(
  controller: controller,
  child: const YourHomePage(),
)
```

Other built-in surfaces:

- `DesktopUpdateDirectCard`
- `DesktopUpdateSliver`
- `UpdateDialogListener`

See [Ready-made UI widgets](https://github.com/MarlonJD/flutter_desktop_updater/blob/main/docs/ui-widgets.md) for screenshots, placement
guidance, and when to choose each surface.

For custom UI, switch on `controller.state`.

## Localization And i18n

Ready-made updater UI can load bundled starter translations, app-owned JSON
assets, direct string overrides, or an app-owned resolver such as
`AppLocalizations` or `_()`. RTL locales such as Arabic and Hebrew can set or
infer `TextDirection.rtl`.

Use `DesktopUpdateLocalizationLoader.fromBundledLocale("tr_TR")` to force a
specific bundled language, or `fromPlatformLocale()` to follow the system
locale. Support-policy dates default to `YYYY-MM-DD HH:mm UTC`; pass
`DesktopUpdateLocalization(formatDateTime: ...)` when the app needs its own
date format.

See [Localization and i18n](https://github.com/MarlonJD/flutter_desktop_updater/blob/main/docs/localization.md) for the recommended setup,
JSON schema, runtime language switching, RTL behavior, and Arabic, Hebrew,
Japanese, Korean, and Cyrillic screenshots.

## Update Policy Modes

Update policy lives in `app-archive.json`, so apps can change release pressure
without rebuilding the old client:

- Optional updates are soft prompts with `Download`, optional skip persistence,
  and restart deferral.
- Mandatory updates keep prompting until installed, hide skip actions, and keep
  a `Save first` path so users can protect unsaved work before restart.
- `supportPolicy` adds a minimum supported version and enforcement deadline so
  old clients can warn first, then fail closed after the deadline.
- `freshInstall` marks releases that should send users to a fresh download
  instead of the in-app updater.

See [Update policy modes](doc/update-policy-modes.md) for JSON examples, CLI
flags, and the built-in card, sliver, and dialog behavior for each state.

## Release Notes

Use `releaseNotesLoader` when notes should depend on the selected descriptor,
platform, channel, locale, account, or environment. These examples reuse the
generated key map and recovery-store factory from Quick Start:

```dart
final recoveryStore = await createUpdateRecoveryStore();
final controller = DesktopUpdaterController(
  appArchiveUrl: Uri.parse("https://updates.example.com/app-archive.json"),
  expectedPackageId: expectedPackageIdForCurrentPlatform(),
  trustedReleasePublicKeys: trustedReleasePublicKeys,
  recoveryStore: recoveryStore,
  releaseNotesLoader: (descriptor) {
    return myNotesApi.fetch(
      version: descriptor.version,
      platform: descriptor.platform,
      channel: descriptor.channel,
    );
  },
);
```

For a simple hosted file, pass `releaseNotesUrl` instead:

```dart
final recoveryStore = await createUpdateRecoveryStore();
final controller = DesktopUpdaterController(
  appArchiveUrl: Uri.parse("https://updates.example.com/app-archive.json"),
  expectedPackageId: expectedPackageIdForCurrentPlatform(),
  trustedReleasePublicKeys: trustedReleasePublicKeys,
  recoveryStore: recoveryStore,
  releaseNotesUrl: Uri.parse("https://updates.example.com/release-notes.json"),
);
```

When `releaseNotesUrl` points at a private host, `requestHeadersProvider` is
used for the release notes request too. See
[Runtime request headers](doc/runtime-request-headers.md) for sharing one auth
token across update files and release notes, or routing different headers by
request URL.

The simple contributor-friendly JSON shape uses a `data` array:

```json
{
  "data": [
    { "type": "feat",  "message": "Add dark mode support" },
    { "type": "fix",   "message": "Fix crash on startup" },
    { "type": "other", "message": "General stability improvements" }
  ]
}
```

The richer package-owned shape supports sections, summaries, and item titles:

```json
{
  "schemaVersion": 1,
  "format": "desktop_updater.release_notes.v1",
  "summary": "Quality improvements.",
  "sections": [
    {
      "type": "features",
      "title": "New features",
      "items": [
        { "body": "Add dark mode support" }
      ]
    }
  ]
}
```

The ready-made card shows a release notes icon when the active update can load
notes. Custom UI can call `controller.loadReleaseNotes()` and render
`controller.releaseNotesState`; the controller keeps caching, retry state, and
descriptor context aligned.

Localise the bottom sheet and override section labels via
`DesktopUpdateLocalization`:

```dart
localization: const DesktopUpdateLocalization(
  releaseNotesTitleText: "What's new",
  releaseNotesButtonTooltipText: "Release notes",
  releaseNotesTypeLabels: {
    "feat": "New features",
    "fix":  "Bug fixes",
    "other": "Other changes",
  },
  releaseNotesErrorText: "Could not load release notes.",
  releaseNotesRetryText: "Retry",
  releaseNotesEmptyText: "No release notes available for this version.",
),
```

## Error Tooltip

When an update fails the error icon shows a tooltip. Supply an
`onUpdateFailedTooltip` callback to return a custom string, or set
`updateFailedTooltipText` for one static fallback:

```dart
localization: DesktopUpdateLocalization(
  updateFailedTooltipText: "Update failed. Please try again.",
  onUpdateFailedTooltip: (error) {
    if (error is SocketException) return "No internet connection.";
    if (error is TimeoutException) return "Connection timed out.";
    return null; // falls back to updateFailedTooltipText
  },
),
```

## Diagnostics And Recovery

The 3.1.4 release retains the explicit app-owned diagnostics and recovery
wiring introduced in 3.0. The Dart controller remains quiet unless the app
provides its own sink; it performs no package-owned upload or telemetry. The
privileged macOS helper additionally writes security-scoped lifecycle evidence
to its fixed root-owned JSONL log so backup, move, cleanup, rollback, recovery,
and recovery-marker handling can be audited after an administrator-approved
installation.

Use in-memory problem reports for normal support, add an app-owned diagnostics
sink for durable Dart lifecycle logs, and add an app-owned
`UpdateRecoveryStore` when support needs post-relaunch evidence. Native helper
APIs do not accept a caller-selected diagnostics path; standalone helpers use
fixed platform logs rather than app-owned diagnostics storage.

Details live in [Diagnostics and recovery](https://github.com/MarlonJD/flutter_desktop_updater/blob/main/docs/diagnostics-and-recovery.md),
[Ready-made UI widgets](https://github.com/MarlonJD/flutter_desktop_updater/blob/main/docs/ui-widgets.md#diagnostics-and-support), and
[Publishing desktop updates](https://github.com/MarlonJD/flutter_desktop_updater/blob/main/docs/publishing.md#runtime-policies).

## Production Trust

desktop_updater handles update mechanics. Your app still owns platform trust:

Pin the Ed25519 release keys embedded in your app for production metadata
authenticity. The same key map verifies both `app-archive.json` and the selected
`release.json` before policy selection or artifact download:

```dart
final recoveryStore = await createUpdateRecoveryStore();
final controller = DesktopUpdaterController(
  appArchiveUrl: Uri.parse("https://updates.example.com/app-archive.json"),
  expectedPackageId: expectedPackageIdForCurrentPlatform(),
  trustedReleasePublicKeys: trustedReleasePublicKeys,
  recoveryStore: recoveryStore,
);
```

`trustedReleasePublicKeys` is required for every 3.1 controller and low-level
update client. Each release must authenticate against one of the pinned Ed25519
keys before policy selection or artifact download. Native install handoff also
requires a signed `release.json` whose key is sealed into the native helper
policy; an unsigned descriptor fails before native handoff and leaves no pending
recovery marker. Low-level callers should keep one
`DesktopUpdater().createZipFirstUpdateSession(...)` and use that session for
both checking and downloading/staging.

- macOS production updates should be Developer ID signed, hardened-runtime
  enabled, notarized, stapled, and Gatekeeper accepted before packaging.
- Windows production updates should use Authenticode when publisher trust is
  required.
- Windows can publish direct zip artifacts or
  [Inno Setup installer artifacts](https://github.com/MarlonJD/flutter_desktop_updater/blob/main/docs/windows-inno-installer-updates.md).
- Linux direct zip distribution should add descriptor signing or another
  publisher-authenticity policy when production trust matters.

For macOS DMG first installs, DMG update artifacts, PKG installer artifacts,
and the local Apple-trust smoke harness, see
[macOS DMG and PKG installer updates](https://github.com/MarlonJD/flutter_desktop_updater/blob/main/docs/macos-dmg-pkg-installer-updates.md).

## Documentation

- [Update policy modes](doc/update-policy-modes.md): optional, mandatory,
  support-policy, and fresh-install release behavior.
- [Publishing desktop updates](https://github.com/MarlonJD/flutter_desktop_updater/blob/main/docs/publishing.md): setup, YAML config,
  additional release files, manual upload, providers, update policy modes,
  validation, CI, and platform-specific release work.
- [Native helper SDKs and standalone CLI](https://github.com/MarlonJD/flutter_desktop_updater/blob/main/docs/native-sdk.md): SwiftPM, CMake,
  C ABI, NuGet, version synchronization, CLI candidates, and release gates.
- [Native Runtime Preview API](https://github.com/MarlonJD/flutter_desktop_updater/blob/main/docs/native-runtime-api.md): non-Flutter
  discovery, verification, staging, helper handoff, evidence, and trust
  boundaries.
- [Windows and Linux production release options](https://github.com/MarlonJD/flutter_desktop_updater/blob/main/docs/windows-linux-production-release.md):
  signing choices, native package channels, and country or provider
  restrictions.
- [Windows Inno installer updates](https://github.com/MarlonJD/flutter_desktop_updater/blob/main/docs/windows-inno-installer-updates.md):
  full Inno installer mode, config, signing, and migration boundaries.
- [Ready-made UI widgets](https://github.com/MarlonJD/flutter_desktop_updater/blob/main/docs/ui-widgets.md): screenshots and guidance for
  the built-in card, sliver, dialog, and custom state-driven UI surfaces.
- [Localization and i18n](https://github.com/MarlonJD/flutter_desktop_updater/blob/main/docs/localization.md): bundled translations, custom
  JSON, resolver-based i18n, runtime locale changes, RTL behavior, and
  multi-script screenshots.
- [Diagnostics and recovery](https://github.com/MarlonJD/flutter_desktop_updater/blob/main/docs/diagnostics-and-recovery.md): where logs are
  written, how helper diagnostics work, and how to wire support collection.
- [GitHub Actions CI/CD guide](https://github.com/MarlonJD/flutter_desktop_updater/blob/main/docs/github-actions-ci-cd.md): longer CI
  skeletons and secret handling.
- [3.0 to 3.1 migration guide](https://github.com/MarlonJD/flutter_desktop_updater/blob/main/docs/migration/3.0-to-3.1.md): profile-based release
  signing, one-time key adoption, and encrypted bundle import.
- [2.x to 3.0 migration guide](https://github.com/MarlonJD/flutter_desktop_updater/blob/main/docs/migration/2.x-to-3.0.md): breaking contract,
  explicit transactions, pinned trust, and migration commands.
- [1.x to 2.0 migration guide](https://github.com/MarlonJD/flutter_desktop_updater/blob/main/docs/migration/1.x-to-2.0.md): historical migration
  commands and compatibility notes.
- [2.0 roadmap](https://github.com/MarlonJD/flutter_desktop_updater/blob/main/docs/2.0-roadmap.md)

Maintainers and agentic contributors should start with [AGENTS.md](AGENTS.md),
then use [Harness engineering](https://github.com/MarlonJD/flutter_desktop_updater/blob/main/docs/harness-engineering.md)
and the [execution plan index](https://github.com/MarlonJD/flutter_desktop_updater/blob/main/docs/exec-plans/index.md) for repo-local workflow,
validation, and plan status.

## Advanced Commands

Most apps should start with `release publish`. Use low-level commands only when
your pipeline needs to own each step:

```sh
dart run desktop_updater --help
dart run desktop_updater release publish --help
dart run desktop_updater package --help
dart run desktop_updater verify --help
dart run desktop_updater app-archive --help

# Legacy package entrypoints remain supported.
dart run desktop_updater:package --help
dart run desktop_updater:app_archive --help
dart run desktop_updater:verify --help
```

## Support

If `desktop_updater` saves you maintenance time, you can support ongoing work
through GitHub Sponsors.

Sponsorship helps fund cross-platform testing, release tooling, and maintenance
for Windows, macOS, and Linux update flows.

[Become a sponsor](https://github.com/sponsors/MarlonJD)
