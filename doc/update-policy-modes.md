# Update Policy Modes

desktop_updater separates normal update mechanics from release pressure. Apps
can publish soft prompts, required prompts, support deadlines, or fresh-install
handoffs through `app-archive.json` metadata without rebuilding the old client.

Use these modes together intentionally:

- Optional updates are for normal improvements.
- Mandatory updates are for releases that must keep prompting until installed.
- `supportPolicy` is for old clients that must eventually fail closed.
- `freshInstall` is for releases that should not use the in-app updater.

## Optional Updates

When `mandatory` is absent or `false`, the ready-made UI treats the release as a
soft prompt:

- Shows `Download`.
- Shows `Skip this version` when skip persistence is available.
- Allows restart confirmation to use `Not now`.
- May persist a skipped version through an app-supplied `UpdatePreferences`
  adapter.

```json
{
  "version": "2.4.0",
  "buildNumber": 240,
  "platform": "macos",
  "channel": "stable",
  "mandatory": false,
  "release": "https://updates.example.com/releases/2.4.0/macos/release.json"
}
```

This is still the right default for normal improvements and non-critical
releases.

## Mandatory Updates

When `mandatory` is `true`, the release is required but still protects unsaved
work:

- Skipped versions are ignored for update selection.
- Ready-made available-update UI hides `Skip this version`.
- After download, `UpdateReadyToInstall` keeps the mandatory state.
- Restart confirmation shows `Save first` and `Restart`.
- `Save first` lets the user return to the app to save work; it does not persist
  a skipped version.
- The mandatory prompt appears again until the update is installed.

```json
{
  "version": "2.4.0",
  "buildNumber": 240,
  "platform": "macos",
  "channel": "stable",
  "mandatory": true,
  "release": "https://updates.example.com/releases/2.4.0/macos/release.json"
}
```

Dialog-based integrations can choose whether mandatory ready-to-install flows
show the save-first confirmation:

```dart
UpdateDialogListener(
  controller: controller,
  mandatoryReadyToInstallBehavior:
      MandatoryReadyToInstallBehavior.restartWithoutPrompt,
)
```

## Support Policy

`supportPolicy` is a top-level `app-archive.json` fail-safe. It belongs at the
top level because the app needs the policy before downloading any artifact.

```json
{
  "schemaVersion": 3,
  "appName": "Example App",
  "supportPolicy": {
    "minimumSupportedVersion": "2.4.0",
    "enforcedAfter": "2026-07-15T00:00:00Z"
  },
  "items": [
    {
      "version": "2.4.0",
      "buildNumber": 240,
      "platform": "macos",
      "channel": "stable",
      "mandatory": true,
      "release": "https://updates.example.com/releases/2.4.0/macos/release.json"
    }
  ]
}
```

Runtime behavior:

- Missing `supportPolicy`: no support deadline is used.
- If one support-policy field is present, both fields are required.
- Before `enforcedAfter`: warn strongly, but allow normal app usage.
- After `enforcedAfter`: replace normal usage with blocking required-update UI.
- If the selected release also has `freshInstall`, the blocking UI points to the
  fresh download instead of the in-app updater.

Use `mandatory` for required releases, and add `supportPolicy` when old clients
must eventually stop using the app after a deadline.

## Fresh Install

`freshInstall` is item-level release metadata. Use it when the old updater should
not apply the update itself, for example when the package layout changed, signing
changed, the old updater is too old, or a safe migration requires a clean
installer.

```json
{
  "version": "2.4.0",
  "buildNumber": 240,
  "platform": "macos",
  "channel": "stable",
  "mandatory": true,
  "freshInstall": {
    "downloadUrl": "https://example.com/download/latest",
    "message": "This update must be installed from a fresh download."
  },
  "release": "https://updates.example.com/releases/2.4.0/macos/release.json"
}
```

Runtime behavior:

- Missing `freshInstall`: use the normal in-app update flow.
- Present `freshInstall`: ready-made UI shows a fresh-install prompt and
  `Download latest`.
- `downloadUrl` is required.
- `message` is optional release-specific copy.
- Default title, body, and button copy stay in Flutter localization, not in JSON.
- Custom UI can override the ready-made UI by switching on controller state.

## CLI Flags

The publish command writes policy JSON only when matching optional flags are
provided.

Mandatory only:

```sh
dart run desktop_updater:release publish \
  --platform macos \
  --mandatory
```

Support deadline only:

```sh
dart run desktop_updater:release publish \
  --platform macos \
  --minimum-supported-version 2.4.0 \
  --enforced-after 2026-07-15T00:00:00Z
```

Fresh install only:

```sh
dart run desktop_updater:release publish \
  --platform macos \
  --fresh-install-url https://example.com/download/latest \
  --fresh-install-message "This update must be installed from a fresh download."
```

Mandatory update with a fail-safe deadline and fresh download fallback:

```sh
dart run desktop_updater:release publish \
  --platform macos \
  --mandatory \
  --minimum-supported-version 2.4.0 \
  --enforced-after 2026-07-15T00:00:00Z \
  --fresh-install-url https://example.com/download/latest \
  --fresh-install-message "This update must be installed from a fresh download."
```

Generation rules:

- If `--minimum-supported-version` and `--enforced-after` are both absent,
  `supportPolicy` is omitted.
- If one support-policy flag is present, the other is required.
- If `--fresh-install-url` is absent, `freshInstall` is omitted.
- `--fresh-install-message` is valid only with `--fresh-install-url`.

## Ready-Made UI States

The built-in card, sliver, and dialog surfaces read the typed controller state:

- `UpdateAvailable`: shows download and, when optional, skip actions.
- `UpdateReadyToInstall`: shows restart/install actions. Optional releases can
  use `Not now`; mandatory releases keep the staged update active and use
  `Save first` plus `Restart`.
- `UpdateBlockedBySupportPolicy`: shows blocking required-update UI and hides
  skip actions.
- `UpdateFreshInstallRequired`: shows the fresh-install message and
  `Download latest` instead of in-app download.

For custom UI, wrap your surface in `DesktopUpdaterInheritedNotifier` or pass a
controller directly, then switch on `controller.state` and handle the same typed
states.
