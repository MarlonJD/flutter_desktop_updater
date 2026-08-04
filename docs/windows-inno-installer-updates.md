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
    protectedHelperInstallDir: C:\Program Files\DesktopUpdaterHelperGenerationV1--com.example.app--2.5.0
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
- `protectedHelperInstallDir`: required only for generated administrative
  installers. It must use the exact security-epoch generation leaf
  `C:\Program Files\DesktopUpdaterHelperGenerationV1--<package-id>--<release-version>`,
  remain disjoint from the app tree, and exactly match the native client's
  compiled `DESKTOP_UPDATER_PROTECTED_HELPER_INSTALL_DIR` value. The generation
  leaf is a direct child of trusted Program Files; the legacy nested
  `DesktopUpdater\Helpers` layout is rejected.
- `silentArgs`: installer args used by the updater. Defaults to
  `/VERYSILENT`, `/SUPPRESSMSGBOXES`, and `/NORESTART`.
- `requiresElevation`: descriptor hint: `auto`, `always`, or `never`.
- `authenticodeThumbprints`: allowed SHA-256 signer certificate fingerprints for
  runtime installer verification.

Generated mode also accepts `setupIcon`, `licenseFile`,
`architecturesAllowed`, and `architecturesInstallIn64BitMode`.
Use `x64compatible` for both architecture fields when an x64 Flutter build
should also install on Arm64 Windows 11 through x64 emulation. The legacy
`x64` identifier matches x64 Windows only.

Set the same protected directory before the Windows native client is
configured. For a native CMake build, pass it directly:

```powershell
cmake -S windows/native -B windows/native/build `
  '-DDESKTOP_UPDATER_PROTECTED_HELPER_INSTALL_DIR=C:/Program Files/DesktopUpdaterHelperGenerationV1--com.example.app--2.5.0'
```

For a Flutter Windows host, set the cache variable in the host's
`windows/CMakeLists.txt` before the generated Flutter plugin graph is added:

```cmake
set(DESKTOP_UPDATER_PROTECTED_HELPER_INSTALL_DIR
  "C:/Program Files/DesktopUpdaterHelperGenerationV1--com.example.app--2.5.0"
  CACHE PATH "Protected desktop_updater helper directory" FORCE)
```

The release packager compares `protectedHelperInstallDir` with the nearest
build `CMakeCache.txt` when that cache is available and fails on a missing or
different cache value. Externally built signed inputs may not include their
local cache, so the explicit configured directory remains required and must be
shared by the build and installer pipelines.

## Generated Script Mode

In generated mode the CLI writes a conservative `.iss` file and its canonical
`*.install-identity.json` source next to the installer artifact, then invokes
Inno Setup Compiler. Keep the identity sidecar with the generated script if you
archive or recompile it; the `.iss` intentionally references that immutable
source instead of regenerating identity at install time.

Generated scripts:

- Install the Flutter Windows Release directory into `{app}`.
- For an administrative install, require the Release directory to contain the
  signed `desktop_updater_install_helper.exe` and consumer-specific sealed
  `desktop_updater_helper_policy.json`.
- Install those two files into `protectedHelperInstallDir`, outside `{app}`.
- Before mutation, `PrepareToInstall` verifies that the configured generation
  leaf is a direct child of trusted Program Files, is outside the app tree, and
  has no reparse point in its trusted parent ancestry. It does not read, hash,
  validate, or execute a pre-existing final leaf.
- For every installer run, create a cryptographically random fresh sibling
  under Program Files. That directory inherits trusted Program Files authority
  before the installer hardens it or copies the helper pair. No historically
  caller-writable `DesktopUpdater\Helpers\<package>` directory is used as a
  creation, mutation, or execution authority.
- Replace inherited ACLs with a protected DACL, set the owner to the built-in
  Administrators SID, grant write authority only to SYSTEM and Administrators,
  and grant Users read/execute access. Every fixed-system `icacls.exe` call is
  checked for a nonzero result. The fresh directory and both files are
  reparse-checked and matched to the packaged SHA-256 digests.
- At `ssPostInstall`, quarantine any exact final leaf without inspecting or
  executing it, atomically rename the fresh protected generation into the exact
  final path, then invoke `--validate-endpoint` and `--register-endpoint` only
  from that fresh leaf. Empty, helper-only, policy-only, unsafe-complete, and
  interrupted same-release leaves are self-repaired on retry. A validation
  failure quarantines the fresh leaf and leaves the final path empty. If
  registration fails after it starts, the already validated fresh leaf remains
  at the final path for an idempotent retry. A historical leaf is never restored
  after endpoint validation or registration begins because a registry write can
  have become durable before the helper reports failure.
- Keep older version-addressed generation leaves and endpoint records in place,
  so older apps and pending transactions retain their exact prior path/hash
  binding.
- Install canonical `.desktop_updater_install_identity.json` into `{app}` so a
  protected recovery host can prove an Inno-installed target even after the
  original caller exits.
- Mark the protected directory, helper, and policy `uninsneveruninstall` and do
  not add uninstall rules for DesktopUpdater transaction registry state. This
  preserves the authority and state needed to finish recovery until a native,
  pending-transaction-aware unregister operation exists.
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

A generated `PrivilegesRequired=lowest` installer remains an unprivileged
app-only installer and does not accept `protectedHelperInstallDir` or register
an elevated endpoint.

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
- Install the signed helper and sealed policy outside the atomically replaced
  app tree in the exact direct-Program-Files generation leaf compiled into the
  native client. Do not reuse the legacy nested helper parent and do not
  unregister older endpoint versions while they can still own pending
  transactions.
- Install canonical `.desktop_updater_install_identity.json` in the app
  root.
- Provision into a fresh installer-trusted sibling, verify the pair and digests,
  and promote it atomically. Never execute a pre-existing final leaf after a
  path-based digest check.
- Establish the trusted owner and protected DACL required by the helper before
  calling `--register-endpoint`, fail the install on any nonzero result, and
  preserve helper, policy, and pending transaction state during uninstall.

The CLI does not silently rewrite a custom script or infer its privileged
provisioning policy.

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

The 3.0 native API has no caller-selected diagnostics path. The standalone
Windows helper emits fixed, best-effort lifecycle events to the Windows
Application Event Log under
`DesktopUpdater.InstallHelper.ProtocolV1`. App-owned Dart and in-memory
diagnostics remain available before handoff.

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

Run the full Inno smoke locally on a Windows machine with PowerShell 7 and
Inno Setup 6:

```powershell
pwsh -NoProfile -File ./tool/windows_inno_smoke.ps1
```

The smoke publishes two installer versions through the release CLI, installs
version 1 into a disposable per-user directory, asks the installed example app
to hand version 2 to the Windows native Inno updater, verifies helper
diagnostics and staging cleanup, then runs the generated Inno uninstaller and
verifies that the version 2 payload is removed. Pass `-KeepArtifacts` to retain
the disposable fixture after a failure. This lane is intentionally local-only
and does not require production Authenticode credentials.

The repository's source and Dart tests verify the generated contract only.
Authenticode validation, the resulting owner/DACL metadata, nonzero
registration retry behavior, UAC behavior, and recovery-preserving uninstall
still require signed Windows target-host evidence; they are not proven by a
macOS package build.

## Migration Notes

For apps already installed with Inno:

1. Keep the same `AppId`.
2. Compile the next native client and configure the installer with the matching
   `DesktopUpdaterHelperGenerationV1--<package-id>--<release-version>` path.
   Do not carry the legacy nested `DesktopUpdater\Helpers` path into the new
   release.
3. Publish the next Windows update in Inno installer mode. Older endpoint paths
   remain registered and on disk for pending transactions.
4. Verify that the installer upgrades the existing app in place and that an
   interrupted same-release retry repairs the generation leaf.
5. Verify uninstall after update removes files added by the new version.
6. Keep direct zip releases on their existing channel until you intentionally
   migrate those users.

Do not edit or regenerate `unins###.dat` from the updater. Inno owns uninstall
metadata in installer mode.
