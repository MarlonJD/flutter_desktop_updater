# desktop_updater

Flutter desktop updater plugin for macOS, Windows, and Linux.

The 2.0 line uses a zip-first release contract:

```text
app-archive.json -> release.json -> one verified zip artifact
```

This avoids public folder listing, works with signed URLs and private buckets,
and lets the updater verify the exact artifact length and SHA-256 before
extraction or installation.

![flutter_desktop_updater](https://github.com/user-attachments/assets/b05d9a13-0f44-4213-b3bd-58e07c18226d)

## Documentation

- [Publishing desktop updates](docs/publishing.md)
- [GitHub Actions CI/CD guide](docs/github-actions-ci-cd.md)
- [1.x to 2.0 migration guide](docs/migration/1.x-to-2.0.md)
- [2.0 roadmap](docs/2.0-roadmap.md)
- [Agent migration prompt](docs/migration/agent-prompt.md)

## Version Lines

- `1.x`: stable maintenance line for the legacy folder-based update contract.
- `2.x`: current stable line for the zip-first release contract.

Apps already shipping with 1.x should keep their existing release contract until
their app code and publishing pipeline have both migrated to 2.0.

## Install

```yaml
dependencies:
  desktop_updater: ^2.0.0
```

Install the CLI:

```sh
dart pub global activate desktop_updater
```

## Publish TL;DR, EL10

Think of your update host as one shelf on the internet.

1. Your app opens `app-archive.json` and asks: is there a newer update for my
   platform and channel?
2. `app-archive.json` points to a versioned `release.json`.
3. `release.json` points to exactly one zip and records its length and SHA-256.
4. `release publish` builds the selected platform, creates those files, and
   puts the upload-ready package under `dist/desktop_updater`.
5. If an upload provider is configured, it uploads the versioned files first,
   validates them, uploads `app-archive.json` last, then validates update
   selection like an older installed app would.

Minimum config:

```yaml
# desktop_updater.yaml
updates:
  baseUrl: https://updates.example.com
```

Publish one platform:

```sh
dart run desktop_updater:release publish --platform macos
```

With only `updates.baseUrl`, the command stops after creating a manual upload
package and prints the validate command. The full setup guide, provider
examples, and platform-specific release steps live in
[Publishing desktop updates](docs/publishing.md).

## Runtime Usage

Create a controller with your hosted `app-archive.json` URL:

```dart
import "package:desktop_updater/desktop_updater.dart";
import "package:desktop_updater/updater_controller.dart";

late final DesktopUpdaterController controller;

@override
void initState() {
  super.initState();
  controller = DesktopUpdaterController(
    appArchiveUrl: Uri.parse("https://updates.example.com/app-archive.json"),
    skipInitialVersionCheck: true,
  );
}
```

Use one of the ready-made update surfaces, or build your own from the same
controller state.

Inline card above your content:

```dart
DesktopUpdateWidget(
  controller: controller,
  child: const YourHomePage(),
)
```

Card-only placement:

```dart
Column(
  children: [
    DesktopUpdateDirectCard(controller: controller),
    const Expanded(child: YourHomePage()),
  ],
)
```

Sliver placement:

```dart
CustomScrollView(
  slivers: [
    DesktopUpdateSliver(controller: controller),
    const SliverToBoxAdapter(child: YourHomePage()),
  ],
)
```

Dialog listener:

```dart
Stack(
  children: [
    const YourHomePage(),
    UpdateDialogListener(controller: controller),
  ],
);
```

For custom UI, switch on the typed state:

```dart
return switch (controller.state) {
  UpdateAvailable(:final descriptor, :final mandatory) => ListTile(
      leading: const Icon(Icons.system_update),
      title: Text(mandatory ? "Required update" : "Update available"),
      subtitle: Text(descriptor.version),
      trailing: FilledButton(
        onPressed: controller.downloadUpdate,
        child: const Text("Download"),
      ),
    ),
  UpdateDownloading(:final receivedBytes, :final totalBytes) =>
    LinearProgressIndicator(
      value: totalBytes <= 0 ? null : receivedBytes / totalBytes,
    ),
  UpdateReadyToInstall() => FilledButton(
      onPressed: controller.restartApp,
      child: const Text("Restart"),
    ),
  UpdateFailed(:final error) => Text("Update failed: $error"),
  _ => const SizedBox.shrink(),
};
```

Run a quiet manual check:

```dart
await controller.checkVersion();
```

## Manual Check Feedback

Automatic startup checks stay quiet when no update is available. For a
user-triggered menu item or button, call `checkForUpdates()` and decide how your
app should present the result:

```dart
final result = await controller.checkForUpdates();

switch (result) {
  case ManualUpdateCheckAvailable():
    break;
  case ManualUpdateCheckUpToDate():
    // Show a snackbar, settings-row message, native dialog, or custom widget.
    break;
  case ManualUpdateCheckFailed(:final error):
    // Log the error and show retry guidance.
    break;
}
```

The package also provides `showManualUpdateCheckResultDialog()` for stock
Material feedback when your manual check action owns the whole presentation.

## Release Contract

`app-archive.json` is the small index clients fetch first. It selects the best
release for the current platform, channel, and installed version.

`release.json` describes one zip artifact and its install strategy. The updater
downloads that zip, verifies length and SHA-256, stages it, then installs it
with the platform helper.

Supported install strategies:

- `wholeBundleReplace`: macOS `.app` bundle replacement.
- `wholeDirectoryReplace`: Windows and Linux app directory replacement.

The full JSON shape and low-level commands are documented in
[Publishing desktop updates](docs/publishing.md).

## Platform Trust

desktop_updater separates update mechanics from platform publisher trust:

- macOS production updates should be Developer ID signed, hardened-runtime
  enabled, notarized, stapled, and Gatekeeper accepted before packaging.
- Windows production updates should sign `.exe` and `.dll` files with
  Authenticode when publisher trust is required.
- Linux has no single OS-level Developer ID equivalent; use descriptor signing,
  repository packages, Flatpak, Snap, or another authenticity policy when
  production trust matters.

Unsigned Windows and Linux Release builds can still be release-mechanics ready.
Unsigned macOS updates require the explicit `allowUnsignedMacOSUpdates: true`
opt-out and are not production-trusted.

## Migration

Preview the 1.x to 2.0 migration:

```sh
dart run desktop_updater:migrate --path .
```

Apply safe edits:

```sh
dart run desktop_updater:migrate --path . --apply
```

The migrator updates simple source changes, such as `skipCheckVersion` to
`skipInitialVersionCheck`, and reports manual migration findings with file and
line references. It does not automatically rewrite publishing pipelines,
macOS signing/notarization setup, or typed-state UI logic.

## Advanced Commands

Most apps should start with:

```sh
dart run desktop_updater:release publish --platform macos
```

Use the low-level commands only when your pipeline needs to own each step:

```sh
dart run desktop_updater:package --help
dart run desktop_updater:app_archive --help
dart run desktop_updater:verify --help
```

## Testing This Package

```sh
dart format --set-exit-if-changed .
flutter analyze --no-fatal-infos
flutter test --no-pub
dart pub publish --dry-run
```

Provider e2e tests are documented in [Publishing desktop updates](docs/publishing.md).
