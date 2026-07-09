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
- `DESKTOP_UPDATER_HOSTED_SMOKE_DIAGNOSTICS_LOG`
- `DESKTOP_UPDATER_HOSTED_ALLOW_UNSIGNED_MACOS`

For public macOS distribution, keep unsigned updates disabled and use signed,
notarized, stapled artifacts.

## Windows Inno Smoke Scaffold

The repository includes a Windows-only Inno Setup smoke scaffold:

```powershell
pwsh ./tool/windows_inno_smoke.ps1
```

Run it from the repository root on Windows. The script exits with `not run`
when Windows or the Inno Setup Compiler is unavailable. When prerequisites are
present, it prepares
`reports/windows-inno-update-smoke-diagnostics.jsonl` for the full install,
update, uninstall, and cleanup smoke flow.
