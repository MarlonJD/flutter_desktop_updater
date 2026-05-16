# What is Desktop Updater?
This Flutter plugin supports desktop platforms including macOS, Windows, and Linux. It checks a remote app archive, downloads only changed files, verifies every file against `hashes.json`, and installs the update on restart.

# How does it work?
The update flow is intentionally split into safe phases:

1. The Dart layer downloads `app-archive.json` and the target version's `hashes.json`.
2. It hashes the currently installed app and builds a diff.
3. Changed files are downloaded into a temporary staging directory, not into the running app bundle/folder.
4. Each downloaded file is checked for length and Blake2b hash before it is accepted.
5. On restart, a small native helper waits until the app process exits, copies the staged files into the app directory, removes deleted files, cleans the staging directory, and relaunches the app.

On macOS the native helper updates `YourApp.app/Contents` after the process exits. On Windows it uses a detached PowerShell helper so locked `.exe` and `.dll` files are replaced only after the current app has fully closed.

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
            "platform": "macos"
        }
    ]
}
```

# How to use it?
The steps are as follows:

- Prepare an app-archive file.
- Add a JSON file specifying the new version.
- Build the application using the CLI and generate the output.
- Upload the output directory, ensuring all its contents are accessible.

# Commands
You need to update version on `pubspec.yaml` file and run the following commands to build the application:

`dart run desktop_updater:release macos`

then it will create a folder named dist, then run the following command:

`dart run desktop_updater:archive macos`

You'll see a folder such as `1.0.0+1-macos` in `dist/1`. Upload that folder as-is to your static host, S3 bucket, GitHub Pages site, or other public file server. The folder must include `hashes.json` and every file path listed inside it.

Hash paths are normalized with `/` separators so Windows archives can be served over normal HTTP URLs.

# App Archive JSON Structure
You should add your versions to the `items` array. Each version should have the following fields:
- `version`: Required, The version number of the app.
- `shortVersion`: Required, The short version number of the app. This is used to compare the versions.
- `changes`: Required, The changes made in this version. This is an array of objects with the following fields:
    - `type`: Optional, the type of the change. This can be one of the following values: feat, fix, chore, docs, style, refactor, perf, test, build, ci, or other.
    - `message`: Required, The message describing the change.
- `date`: Required, The date when this version was released.
- `mandatory`: Required, A boolean value indicating whether this version is mandatory. If this is true, the user will not be able to skip this version.
- `url`: Required, The URL where the app can be downloaded. This should be a direct link of the folder containing the app files.
- `platform`: Required, The platform for which this version is available. This can be one of the following values: windows, macos, or linux.

# Production notes

- The updater must have write permission to the installed app directory. Apps installed under protected locations such as `C:\Program Files` may still require an elevated installer.
- macOS updates should be built and signed as a complete app before creating the archive. Updating signed app contents with unsigned files will invalidate the bundle signature.
- The update host should serve files with stable byte content. Any transformation by a CDN or proxy will fail hash verification, which is intentional.

# Testing the restart installer

Do not put the restart/install test inside `integration_test`. The app must close itself, so the Flutter test runner dies with it. Use an external smoke runner instead:

```sh
cd example
flutter build macos --debug
dart run tool/updater_smoke.dart
```

On Windows:

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
