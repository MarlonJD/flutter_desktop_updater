# desktop_updater

Flutter desktop updater plugin for macOS, Windows, and Linux.

2.x uses one small update index, one release descriptor, and one verified zip:

```text
app-archive.json -> release.json -> app.zip
```

No public folder listing is required. Clients fetch exact URLs and verify the
zip length and SHA-256 before installation.

![flutter_desktop_updater](https://github.com/user-attachments/assets/b05d9a13-0f44-4213-b3bd-58e07c18226d)

## Quick Start

Add the package:

```yaml
dependencies:
  desktop_updater: ^2.3.2
```

Point your app at the hosted archive:

```dart
final controller = DesktopUpdaterController(
  appArchiveUrl: Uri.parse("https://updates.example.com/app-archive.json"),
);
```

Add `desktop_updater.yaml` at your app repository root, next to
`pubspec.yaml`:

```yaml
updates:
  baseUrl: https://updates.example.com
```

Publish one platform:

```sh
dart run desktop_updater:release publish --platform macos
```

Before your first production release, run:

```sh
dart run desktop_updater:release doctor --platform macos
```

With only `updates.baseUrl`, publish creates an upload-ready package under
`dist/desktop_updater` and prints the manual upload and validate instructions.
With an upload provider configured, it uploads versioned files first, validates
them, uploads `app-archive.json` last, then validates hosted update selection.

## Linux Zip Permissions

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

See [Ready-made UI widgets](docs/ui-widgets.md) for screenshots, placement
guidance, and when to choose each surface.

For custom UI, switch on `controller.state`.

## Release Notes

Use `releaseNotesLoader` when notes should depend on the selected descriptor,
platform, channel, locale, account, or environment:

```dart
final controller = DesktopUpdaterController(
  appArchiveUrl: Uri.parse("https://updates.example.com/app-archive.json"),
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
final controller = DesktopUpdaterController(
  appArchiveUrl: Uri.parse("https://updates.example.com/app-archive.json"),
  releaseNotesUrl: Uri.parse("https://updates.example.com/release-notes.json"),
);
```

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

2.2.0 adds opt-in diagnostics and recovery for support flows. The default stays
quiet: no package-owned files, uploads, telemetry, or storage.

Use in-memory problem reports for normal support, add an app-owned diagnostics
sink for durable Dart lifecycle logs, and add `diagnosticsLogPath` plus an
app-owned `UpdateRecoveryStore` only when support needs post-exit native helper
evidence.

Details live in [Diagnostics and recovery](docs/diagnostics-and-recovery.md),
[Ready-made UI widgets](docs/ui-widgets.md#diagnostics-and-support), and
[Publishing desktop updates](docs/publishing.md#runtime-policies).

## Production Trust

desktop_updater handles update mechanics. Your app still owns platform trust:

- macOS production updates should be Developer ID signed, hardened-runtime
  enabled, notarized, stapled, and Gatekeeper accepted before packaging.
- Windows production updates should use Authenticode when publisher trust is
  required.
- Linux direct zip distribution should add descriptor signing or another
  publisher-authenticity policy when production trust matters.

## Documentation

- [Publishing desktop updates](docs/publishing.md): setup, YAML config,
  manual upload, providers, validation, CI, and platform-specific release work.
- [Windows and Linux production release options](docs/windows-linux-production-release.md):
  signing choices, native package channels, and country or provider
  restrictions.
- [Ready-made UI widgets](docs/ui-widgets.md): screenshots and guidance for
  the built-in card, sliver, dialog, and custom state-driven UI surfaces.
- [Diagnostics and recovery](docs/diagnostics-and-recovery.md): where logs are
  written, how helper diagnostics work, and how to wire support collection.
- [GitHub Actions CI/CD guide](docs/github-actions-ci-cd.md): longer CI
  skeletons and secret handling.
- [1.x to 2.0 migration guide](docs/migration/1.x-to-2.0.md): migration
  commands and compatibility notes.
- [2.0 roadmap](docs/2.0-roadmap.md)

## Advanced Commands

Most apps should start with `release publish`. Use low-level commands only when
your pipeline needs to own each step:

```sh
dart run desktop_updater:package --help
dart run desktop_updater:app_archive --help
dart run desktop_updater:verify --help
```
