# What is Desktop Updater?
This Flutter plugin supports desktop platforms including macOS, Windows, and Linux. It checks a remote app archive, downloads only changed files, verifies staged files before install, and installs the update on restart.

# How does it work?
The update flow is intentionally split into safe phases:

1. The Dart layer downloads `app-archive.json` and the target version metadata.
2. Windows and Linux use the existing `hashes.json` file diff.
3. macOS uses `release-manifest.json`, content-addressed gzip payloads for regular files, symlink manifest entries, and a full `.zip` fallback archive.
4. Changed files are staged into a temporary directory, not into the running app bundle/folder.
5. The staged update is verified before install.
6. On restart, a small native helper waits until the app process exits, verifies the staged update again, replaces the app, cleans staging, and relaunches the app.

On macOS the helper replaces the complete `YourApp.app` bundle after `codesign`, Gatekeeper, stapler, bundle identifier, and Team ID checks pass. On Windows it uses a detached PowerShell helper so locked `.exe` and `.dll` files are replaced only after the current app has fully closed.

![flutter_desktop_updater](https://github.com/user-attachments/assets/b05d9a13-0f44-4213-b3bd-58e07c18226d)

## Getting Started
Add dependency to your `pubspec.yaml`:
```
dependencies:
  ...
  desktop_updater: ^2.0.0-dev.1
```

Install as CLI, 
Run in your terminal:
```
dart pub global activate desktop_updater
```

# Usage

Add the following codes to your home page or any page you want to see the update card.

```dart
import 'package:desktop_updater/desktop_updater.dart';

late DesktopUpdaterController _desktopUpdaterController;

@override
void initState() {
    super.initState();
    _desktopUpdaterController = DesktopUpdaterController(
        appArchiveUrl: Uri.parse(
        "https://www.yoursite.com/app-archive.json",
        ),
    );
}
```

Then wrap your home page with `DesktopUpdater` widget, under the Scaffold widget.

```dart
@override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Your App Home Page"),
      ),
      body: DesktopUpdateWidget(
        controller: _desktopUpdaterController,
        child: Center(
            child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                    const Text(
                        'Hello World!',
                    ),
                ],
            ),
        ),
      ),
    );
}
```

there is also sliver for custom scroll view, you can use `DesktopUpdateSliver` widget.

```dart
@override
Widget build(BuildContext context) {
    return Scaffold(
        appBar: AppBar(
        title: const Text("Your App Home Page"),
        ),
        body: CustomScrollView(
            slivers: <Widget>[
                DesktopUpdateSliver(
                    controller: _desktopUpdaterController,
                ),
                SliverList(
                    delegate: SliverChildListDelegate(
                    [
                        const Text(
                        'Hello World!',
                        ),
                    ],
                ),
            ],
        ),
    );
}
```

You can use this directly as a card for custom purposes. While you cannot modify the scaffold background in `DesktopUpdateSliver` or `DesktopUpdateWidget`, you can adjust colors and use it anywhere as needed
```dart
@override
Widget build(BuildContext context) {
    return Scaffold(
        backgroundColor: Colors.blue,
        appBar: AppBar(
        title: const Text("Plugin example app"),
        ),
        body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Center(
            child: Column(
                children: [
                    Theme(
                        data: ThemeData(
                            colorScheme:
                                ColorScheme.fromSeed(seedColor: Colors.blue).copyWith(
                            onSurface: Theme.of(context).colorScheme.onSurface,
                            onSurfaceVariant:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                            primary: Theme.of(context).colorScheme.primary,
                            surfaceContainerLowest:
                                Theme.of(context).colorScheme.surfaceContainerLowest,
                            surfaceContainerLow:
                                Theme.of(context).colorScheme.surfaceContainerLow,
                            surfaceContainerHighest:
                                Theme.of(context).colorScheme.surfaceContainerHighest,
                            ),
                        ),
                        child: DesktopUpdateDirectCard(
                            controller: _desktopUpdaterController,
                            child: const Text("This is a child widget"),
                        ),
                    ),
                    const Text(
                    "Running on: 1.0.0+1",
                    ),
                    Text("Running on: $_platformVersion\n"),
                ],
            ),
        ),
        ),
    );
}
```

You can use as alert dialog a with `UpdateDialogListener`:
```dart
@override
Widget build(BuildContext context) {
    return Scaffold(
    appBar: AppBar(
        title: const Text("Plugin example app"),
    ),
    body: Column(
        children: [
            /// This widget not rendering
            UpdateDialogListener(
                controller: _desktopUpdaterController,
            ),
        ],
    )
```

# Creating app-archive.json
```
{
    "appName": "Desktop Updater",
    "description": "This is my app description",
    "items": [
        {
            "version": "0.1.8",
            "shortVersion": 9,
            "changes": [
                {
                    "type": "chore",
                    "message": "Fix bug #1"
                },
                {
                    "type": "feat",
                    "message": "Add new feature #1"
                },
                {
                    "message": "Add new feature #2"
                }
            ],
            "date": "2025-01-10",
            "mandatory": true,
            "url": "https://www.yourwebsite.com/archive/desktop_updater/0.1.8%2B9-windows",
            "platform": "windows"
        },
        {
            "version": "0.1.7",
            "shortVersion": 8,
            "changes": [
                {
                    "type": "chore",
                    "message": "Fix bug #1"
                },
                {
                    "type": "feat",
                    "message": "Add new feature #1"
                },
                {
                    "message": "Add new feature #2"
                }
            ],
            "date": "2025-01-10",
            "mandatory": true,
            "url": "https://www.yourwebsite.com/archive/desktop_updater/0.1.7%2B8-macos",
            "platform": "macos",
            "manifest": "release-manifest.json",
            "channel": "stable"
        }
    ]
}
```

# Release artifacts

Never upload or publish a raw macOS `.app` directory tree. Raw app trees can lose symlinks, modes, extended attributes, resource metadata, or framework bundle structure when copied by generic hosting or CI tools.

The macOS artifact set is:

- `release-manifest.json`: SHA-256 manifest with regular files, file modes, symlink paths and exact targets, expected `CFBundleIdentifier`, expected Apple Developer `TeamIdentifier`, version, build, and channel.
- `payloads/<sha256>.gz`: content-addressed compressed payloads for regular files.
- `<App>.zip`: full fallback archive containing the signed, notarized, stapled `.app`.

Publish the artifact directory, not a ZIP-only release. The manifest and payloads allow delta downloads and exact symlink reconstruction; the ZIP is kept as a recovery fallback when delta staging fails or the local app cannot be patched safely. A ZIP-only release is simpler, but it makes every update a full app download and removes the content-addressed delta path.

Create the full archive on macOS with:

```sh
/usr/bin/ditto -c -k --keepParent --sequesterRsrc <App.app> <App.zip>
```

Extract the full archive only into a fresh staging directory with:

```sh
/usr/bin/ditto -x -k <App.zip> <staging-dir>
```

Do not use default `/usr/bin/zip -r` for `.app` bundles, and do not unzip and re-zip macOS artifacts in CI/CD.

# Release flow

The published version/build/channel state is stored in `app-archive.json` under each item: `version`, `shortVersion`, `platform`, optional `channel`, and the item `url` pointing at that release's artifact directory. For macOS, the artifact directory contains `release-manifest.json`, `payloads/`, and the full fallback ZIP.

End-to-end release flow:

1. Make code changes and update the app changelog.
2. Build the macOS app.
3. Sign, notarize, and staple the built `.app`.
4. Generate updater artifacts with the CLI.
5. Update `app-archive.json` with the new version, build, channel, platform, and artifact URL.
6. Run a publish dry-run that checks every referenced manifest, payload, and ZIP exists.
7. Publish the artifact directory and `app-archive.json`.
8. Run an update smoke test from the previous version.

# Commands
You need to update the `version` in `pubspec.yaml` and run the following commands to build the application. Both Flutter version formats are supported:

```yaml
version: 1.0.0
```

```yaml
version: 1.0.0+1
```

Using a build number is still recommended for updater releases because it gives every artifact a monotonic ordering value. If you omit the build number, increase the semantic version for every release, for example `1.0.0` to `1.0.1`.

`dart run desktop_updater:release macos`

For macOS this only builds the app. Sign, notarize, and staple the `.app`, then generate the publishable artifact directory:

`dart run desktop_updater:archive macos --app path/to/YourApp.app --channel stable`

The macOS archive command creates a directory such as `dist/1/1.0.0+1-macos` containing only `release-manifest.json`, `payloads/`, and `<App>.zip`. You can override the destination with `--output path/to/artifacts`.

For Windows and Linux, you'll see a folder such as `1.0.0+1-windows` in `dist/1`. Upload that folder as-is to your static host, S3 bucket, GitHub Pages site, or other public file server. The folder must include `hashes.json` and every file path listed inside it.

Hash paths are normalized with `/` separators so Windows archives can be served over normal HTTP URLs.

# App Archive JSON Structure
You should add your versions to the `items` array. Each version should have the following fields:
- `version`: Required, The version number of the app.
- `shortVersion`: Optional, The monotonic build number of the app. This is used to compare versions when present. If omitted, `desktop_updater` compares the semantic `version` value instead.
- `changes`: Required, The changes made in this version. This is an array of objects with the following fields:
    - `type`: Optional, the type of the change. This can be one of the following values: feat, fix, chore, docs, style, refactor, perf, test, build, ci, or other.
    - `message`: Required, The message describing the change.
- `date`: Required, The date when this version was released.
- `mandatory`: Required, A boolean value indicating whether this version is mandatory. If this is true, the user will not be able to skip this version.
- `url`: Required, The URL where the app can be downloaded. This should be a direct link of the folder containing the app files.
- `platform`: Required, The platform for which this version is available. This can be one of the following values: windows, macos, or linux.
- `manifest`: Optional for macOS, defaults to `release-manifest.json`.
- `channel`: Optional release channel label, for example `stable`, `beta`, or `nightly`.

# Production notes

- The updater must have write permission to the installed app directory. Apps installed under protected locations such as `C:\Program Files` may still require an elevated installer.
- macOS updates must be built, signed, notarized, and stapled as a complete app before creating updater artifacts.
- Before replacing the installed macOS app, the staged app must pass all gates:
  - `/usr/bin/codesign --verify --deep --strict --verbose=2 <staged-app>`
  - `/usr/sbin/spctl --assess --type execute --verbose=2 <staged-app>`
  - `/usr/bin/xcrun stapler validate <staged-app>`
  - `CFBundleIdentifier` must match the currently installed app bundle identifier.
  - `TeamIdentifier` from `/usr/bin/codesign -dv --verbose=4 <staged-app>` must match the currently installed app Team ID.
- macOS delta updates stage a complete `.app` by copying the installed bundle into a temporary directory, applying verified payload and symlink changes, rejecting unsafe symlinks, verifying the manifest, and then replacing the installed app as a whole bundle after restart. The live `.app` is never patched in place.
- For non-Mac App Store macOS builds, make sure the App Sandbox is disabled in both debug and release entitlements. The restart helper needs file-system access to replace files inside the app bundle after the main process exits:

```xml
<!-- macos/Runner/DebugProfile.entitlements and macos/Runner/Release.entitlements -->
<key>com.apple.security.app-sandbox</key>
<false/>
```

  If your app must stay sandboxed, use a dedicated installer or privileged update path instead of the direct bundle-copy flow.
- The update host should serve files with stable byte content. Any transformation by a CDN or proxy will fail hash verification, which is intentional.

# Testing the restart installer

Do not put the restart/install test inside `integration_test`. The app must close itself, so the Flutter test runner dies with it.

For macOS packaging and extraction regressions, run the package tests:

```sh
flutter test test/macos_updater_manifest_test.dart
```

A full macOS replacement smoke must use a signed, notarized, stapled staged `.app` produced from `release-manifest.json`; the helper intentionally rejects ad hoc file-only staging.

On Windows, use the external smoke runner:

```sh
cd example
flutter build windows --debug
dart run tool/updater_smoke.dart
```

The smoke runner launches the built example app with a temporary staged update. The app calls the real native `installUpdate`, closes, the helper copies a sentinel file into the installation directory, and the runner verifies that the staging directory was cleaned up.

By default the runner skips relaunch so CI does not leave an app open. Add `--relaunch` when you want to test the full close-copy-reopen flow manually.

# Customization

You can change text and button text by passing `DesktopUpdateLocalization` to controller.

```dart
@override
void initState() {
    super.initState();
    _desktopUpdaterController = DesktopUpdaterController(
        appArchiveUrl: Uri.parse(
        "https://www.yoursite.com/app-archive.json",
        ),
        localization: const DesktopUpdateLocalization(
            updateAvailableText: "Update available",
            newVersionAvailableText: "{} {} is available",
            newVersionLongText:
                "New version is ready to download, click the button below to start downloading. This will download {} MB of data.",
            restartText: "Restart to update",
            warningTitleText: "Are you sure?",
            restartWarningText:
                "A restart is required to complete the update installation.\nAny unsaved changes will be lost. Would you like to restart now?",
            warningCancelText: "Not now",
            warningConfirmText: "Restart",
        ),
    );
}
```
