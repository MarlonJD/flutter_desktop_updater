# desktop_updater 2.x example

This app demonstrates the desktop_updater 2.x zip-first update flow:

```text
app-archive.json -> release.json -> zip artifact
```

The example does not check the network automatically on startup. Press
**Check for updates** to run the controller against the configured archive URL.

## Configure

By default the app displays `https://updates.example.com/app-archive.json`.
Point it at your own hosted 2.x index before testing a real update:

```sh
DESKTOP_UPDATER_APP_ARCHIVE_URL=https://updates.example.com/app-archive.json \
flutter run -d macos
```

## Production Smoke Hooks

The CI smoke tools still use environment variables to drive unattended checks:

- `DESKTOP_UPDATER_SMOKE_STAGING`
- `DESKTOP_UPDATER_SMOKE_MARKER`
- `DESKTOP_UPDATER_HOSTED_SMOKE`
- `DESKTOP_UPDATER_HOSTED_SMOKE_MARKER`
- `DESKTOP_UPDATER_HOSTED_ALLOW_UNSIGNED_MACOS`

For public macOS distribution, keep unsigned updates disabled and use signed,
notarized, stapled artifacts.
