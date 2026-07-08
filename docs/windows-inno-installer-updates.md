# Windows Inno Installer Updates

This guide explains how to publish Windows updates as Inno Setup installer
artifacts instead of direct zip artifacts.

Use this mode when Inno Setup must own install, update, repair, modify, and
uninstall behavior across versions. In this mode the update artifact is an
installer `.exe`; `release.json` uses `artifact.kind: innoInstaller` and
`install.strategy: innoInstaller`.

## When To Use It

Use Inno installer mode when:

- The first install and later updates should use the same installer technology.
- Uninstall must remove files introduced by later updates.
- Enterprise deployment expects an installer `.exe`.
- Your support policy depends on Inno's registry entry and uninstall metadata.

Use direct zip compatibility when:

- Your app was installed with Inno, but updates should remain simple directory
  replacements.
- You only need to preserve the existing `unins###.exe`, `unins###.dat`, and
  `unins###.msg` files.
- You accept that files introduced by later zip updates are not added to Inno's
  uninstall log.

Direct zip compatibility does not run an Inno installer and does not regenerate
`unins###.dat`. Full Inno installer mode lets Inno own that metadata.

## Prerequisites

Install Inno Setup on the Windows machine or CI runner that publishes Windows
releases. `release publish --platform windows` invokes `iscc` by default; set
`windows.installer.isccPath` when `iscc` is not on `PATH`.

Production releases should also use Authenticode:

- Sign the installer or use an Inno signing flow in your pipeline.
- Timestamp signatures.
- Configure `authenticodeThumbprints` when the updater should verify the staged
  installer certificate before execution.
- Keep the same app identity between the first install and updates.

## Config

Add a Windows installer section to `desktop_updater.yaml`:

```yaml
updates:
  baseUrl: https://updates.example.com/

windows:
  installer:
    kind: inno
    mode: generated
    appId: com.example.app
    publisher: Example Inc.
    publisherUrl: https://example.com/
    supportUrl: https://example.com/support
    updatesUrl: https://updates.example.com/
    privilegesRequired: admin
    silentArgs:
      - /VERYSILENT
      - /SUPPRESSMSGBOXES
      - /NORESTART
    requiresElevation: auto
    authenticodeThumbprints:
      - 0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF
```

Important fields:

- `kind`: must be `inno`.
- `mode`: `generated` or `script`. Defaults to `generated`.
- `appId`: Inno `AppId`. If omitted in generated mode, the package id is used.
- `isccPath`: optional explicit path to `ISCC.exe`.
- `outputBaseName`: optional installer filename stem. Defaults to
  `<app>-<version>-windows-setup`.
- `privilegesRequired`: `admin` or `lowest`. Defaults to `lowest`.
- `silentArgs`: installer args used by the updater. Defaults to
  `/VERYSILENT`, `/SUPPRESSMSGBOXES`, and `/NORESTART`.
- `requiresElevation`: descriptor hint: `auto`, `always`, or `never`.
- `authenticodeThumbprints`: allowed SHA-256 signer certificate fingerprints for
  runtime installer verification.

Generated mode also accepts `setupIcon`, `licenseFile`,
`architecturesAllowed`, and `architecturesInstallIn64BitMode`.

## Generated Script Mode

In generated mode the CLI writes a conservative `.iss` file next to the
installer artifact and invokes Inno Setup Compiler.

Generated scripts:

- Install the Flutter Windows Release directory into `{app}`.
- Use `DefaultDirName={autopf}\<app name>`.
- Create a Start Menu shortcut.
- Add a post-install launch action that is skipped during silent installs.
- Write the installer `.exe` into the normal `dist/desktop_updater` release
  layout.

Run:

```sh
dart run desktop_updater:release publish --platform windows
```

The generated `release.json` points at the installer `.exe` and uses:

```json
{
  "artifact": {
    "kind": "innoInstaller"
  },
  "install": {
    "strategy": "innoInstaller"
  }
}
```

## Custom Script Mode

Use script mode when your app already owns an Inno script:

```yaml
windows:
  installer:
    kind: inno
    mode: script
    script: packaging/windows/setup.iss
    outputBaseName: Example-2.5.0-windows-setup
```

The CLI copies your script into the release output directory and invokes ISCC.
Your script must write an installer whose filename matches `outputBaseName.exe`.

Keep these responsibilities in your script:

- Stable `AppId`.
- Correct install directory behavior.
- Signing and timestamping if your pipeline signs through Inno.
- File list, uninstall, repair, and upgrade behavior.

## Runtime Behavior

When the app downloads an Inno installer update:

1. The Dart update client downloads and verifies the installer length and
   SHA-256.
2. The installer is staged as `installer.exe`; it is not unzipped.
3. The verified `release.json` is written into the staging directory.
4. The app exits for install handoff.
5. The Windows helper reads the staged descriptor.
6. If Authenticode policy is required, the helper verifies the installer
   signature and signer certificate fingerprint.
7. The helper runs the installer with configured silent args, `/DIR=<current
   app root>`, and `/LOG=<temp log file>`.
8. The helper cleans up staging and relaunches the app when configured.

The direct zip updater path remains unchanged. Zip updates still use
`wholeDirectoryReplace` and preserve existing Inno uninstall files, but they do
not add new files to Inno's uninstall log.

## Diagnostics

When `diagnosticsLogPath` is supplied, Windows helper diagnostics can include:

- `inno manifest loaded`
- `inno authenticode verified`
- `inno authenticode failure`
- `inno installer start`
- `inno installer success`
- `inno installer failure exitCode=<code>`
- `inno relaunch attempt`

The Inno installer log file defaults to
`desktop_updater_inno_install.log` under the system temp directory.

## Validation

Useful local checks:

```sh
dart run desktop_updater:release doctor --platform windows
dart run desktop_updater:release publish --platform windows
dart run desktop_updater:release validate --manifest dist/desktop_updater/.desktop_updater_publish.json --from-version 2.4.0+240
dart run desktop_updater:verify --release dist/desktop_updater/releases/<version>/windows/release.json
```

CI can also run the scaffolded Windows Inno smoke:

```powershell
pwsh ./tool/windows_inno_smoke.ps1
```

The scaffold exits with `not run` on non-Windows hosts or when ISCC is missing.
On a Windows runner with Inno Setup available, it prepares
`reports/windows-inno-update-smoke-diagnostics.jsonl` for the full install,
update, uninstall, and cleanup smoke flow.

## Migration Notes

For apps already installed with Inno:

1. Keep the same `AppId`.
2. Publish the next Windows update in Inno installer mode.
3. Verify that the installer upgrades the existing app in place.
4. Verify uninstall after update removes files added by the new version.
5. Keep direct zip releases on their existing channel until you intentionally
   migrate those users.

Do not edit or regenerate `unins###.dat` from the updater. Inno owns uninstall
metadata in installer mode.
