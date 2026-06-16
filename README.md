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
  desktop_updater: ^2.2.0
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

## Diagnostics And Recovery

2.2.0 adds opt-in diagnostics for support flows without writing files or
uploading logs by default:

1. **In-memory problem reports**: `UpdateFailed(report)` carries a bounded,
   redacted report that ready-made UI can copy after a check, download,
   verification, staging, or install-handoff failure.
2. **App-owned Dart lifecycle logs**: pass
   `UpdateDiagnosticsRecorder(sink: ...)` when your app wants a durable log at a
   path, retention policy, and upload flow it controls.
3. **Native helper diagnostics plus recovery**: pass `diagnosticsLogPath` and
   an app-owned `UpdateRecoveryStore` when support needs post-exit install,
   rollback, cleanup, relaunch, or post-relaunch failure evidence.

The native helper log path is always explicit and app-owned. Helper logging
failures are ignored so support logging cannot block install or rollback.

```dart
final controller = DesktopUpdaterController(
  appArchiveUrl: archiveUrl,
  diagnosticsRecorder: UpdateDiagnosticsRecorder(
    sink: AppUpdateLogSink(appOwnedLifecycleLog),
  ),
  diagnosticsLogPath: appOwnedHelperLog.path,
  recoveryStore: AppUpdateRecoveryStore(),
);
```

See [Ready-made UI widgets](docs/ui-widgets.md#diagnostics-and-support),
[Publishing desktop updates](docs/publishing.md#runtime-policies), and the
[native helper diagnostics plan](docs/plans/2026-06-13-native-helper-diagnostics-recovery-plan.md)
for the complete app-owned support model.

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
- [Native helper diagnostics and recovery](docs/plans/2026-06-13-native-helper-diagnostics-recovery-plan.md):
  opt-in support logs, recovery markers, platform helper evidence, and
  verification notes.
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
