# macOS DMG And PKG Installer Updates

This guide covers the three macOS lanes supported by `desktop_updater`:

| Lane | Artifact | Install strategy | Boundary |
| --- | --- | --- | --- |
| Direct update | `artifact.kind: zip` | `wholeBundleReplace` | Existing whole `.app` bundle replacement. |
| DMG update | `artifact.kind: dmg` | `wholeBundleReplace` | Mount a verified DMG, copy the contained `.app`, verify it, detach, then use whole-bundle replacement. |
| PKG update | `artifact.kind: pkgInstaller` | `install.strategy: pkgInstaller` | Stage a verified installer package and hand it to the bundled `SMAppService` root daemon for fixed `/usr/sbin/installer` execution. |

The direct `.app.zip` path stays backward-compatible. A zip descriptor still
means one verified archive, `ditto` extraction, staged `.app` verification, and
the existing macOS helper replacement path.

## DMG First Install

DMG first install is distribution UX. The release DMG should contain the app
bundle and an `/Applications` alias:

```text
Example.dmg
  Example.app
  Applications -> /Applications
```

Users drag the app to Applications. Apps that want an in-app nudge can opt in to
`MacOSMoveToApplicationsPrompt`; this prompt is separate from update artifacts.
It can offer to copy a DMG-launched app to `/Applications`, relaunch that copy,
and terminate the source instance.

## DMG Updates

DMG update descriptors preserve whole-bundle replacement semantics:

```json
{
  "artifact": {
    "kind": "dmg",
    "url": "https://updates.example.com/releases/stable/2.6.0/build-260/macos/Example-2.6.0-macos.dmg",
    "sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    "length": 23456789
  },
  "install": {
    "strategy": "wholeBundleReplace",
    "macosDmg": {
      "appBundleName": "Example.app",
      "verifyPrimarySignature": true
    }
  }
}
```

Runtime flow:

1. Download the DMG and verify descriptor URL, length, and SHA-256.
2. When `verifyPrimarySignature` is true, run primary-signature assessment.
3. Run `hdiutil attach -readonly -nobrowse`.
4. Copy the configured `.app` from the mounted volume.
5. Verify the staged app with Apple trust gates.
6. Detach the DMG.
7. Hand the verified `.app` to the existing whole-bundle replacement helper.

## PKG Installer Updates

PKG descriptors use installer-owned semantics:

```json
{
  "artifact": {
    "kind": "pkgInstaller",
    "url": "https://updates.example.com/releases/stable/2.6.0/build-260/macos/Example-2.6.0-macos.pkg",
    "sha256": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
    "length": 34567890
  },
  "install": {
    "strategy": "pkgInstaller",
    "macosPkg": {
      "launchMode": "privilegedInstallerTool",
      "expectedPackageIds": ["com.example.app.pkg"],
      "relaunchAfterInstall": false
    }
  }
}
```

The updater verifies and stages the PKG, then routes the sealed
`macosInstaller` + `verifiedInstallerHandoff` request through its bundled
`SMAppService` root daemon. The daemon accepts only the authenticated request
and runs the fixed `/usr/sbin/installer -pkg <sealed-stage>/installer.pkg
-target /` command. The runtime does not invoke `sudo`, AppleScript privilege
escalation, `AuthorizationExecuteWithPrivileges`, or Installer.app.

First enable and revoked consent fail before mutation with the stable
`PrivilegedHelperApprovalRequired` error. The verified stage is retained so the
application can open Background Items settings and retry. Once approved, the
same daemon approval is reused; users do not approve every update.

## Release CLI Config

Zip remains the default:

```yaml
updates:
  baseUrl: https://updates.example.com
macos:
  artifact:
    kind: zip
```

DMG:

```yaml
updates:
  baseUrl: https://updates.example.com
macos:
  notarize: true
  developerIdApplication: "Developer ID Application: Example Corp (TEAMID1234)"
  notaryProfile: desktop-updater-notary
  artifact:
    kind: dmg
  dmg:
    fileName: "Example-v{version}({buildNumber})-{platform}.dmg"
    volumeName: Example
    appBundleName: Example.app
    applicationsAlias: true
```

The optional `macos.dmg.fileName` changes the distributed DMG filename, without
renaming its app bundle or volume. It accepts a literal `.dmg` filename or the
placeholders `{appName}` (without `.app`), `{version}`, `{buildNumber}`, and
`{platform}`. The example produces `Example-v1.0.0(1)-macos.dmg` for version
`1.0.0+1`. Omit it to keep `{appName}-{version}-{platform}.dmg`.
`{buildNumber}` requires build metadata; paths and unsupported placeholders
fail before packaging. Artifact URLs and publish manifests use the same name.

PKG:

```yaml
updates:
  baseUrl: https://updates.example.com
macos:
  notarize: true
  developerIdApplication: "Developer ID Application: Example Corp (TEAMID1234)"
  notaryProfile: desktop-updater-notary
  staple: true
  artifact:
    kind: pkg
  pkg:
    packageIdentifier: com.example.app.pkg
    installLocation: /Applications
    signingIdentifier: "Developer ID Installer: Example Corp (TEAMID1234)"
```

The YAML stores non-secret identity names and profile/keychain references only.
Certificates, keychain passwords, App Store Connect API keys, and notary
credentials remain app-owned machine or CI secrets.

These examples omit `macos.keychain` to use the default Data Protection
Keychain. The maintainer Mac uses `general-notary`; follow the
[local profile note](publishing.md#local-notarization-profile-general-notary)
and leave `DESKTOP_UPDATER_MACOS_KEYCHAIN` unset for that profile.

For CI, the signing references can remain outside generated YAML. When the
fields are absent, set these canonical variables; the keychain variable is
only for the file-based keychain explicitly provisioned by the CI setup:

```sh
export DESKTOP_UPDATER_MACOS_DEVELOPER_ID_APPLICATION="Developer ID Application: Example Corp (TEAMID1234)"
export DESKTOP_UPDATER_MACOS_NOTARY_PROFILE="desktop-updater-notary"
export DESKTOP_UPDATER_MACOS_KEYCHAIN="$MACOS_BUILD_KEYCHAIN"
```

An explicit YAML value wins; an explicit blank or non-string value fails closed
and does not use an ambient value. Legacy aliases and environment notarization
flags are ignored. The publish smoke therefore keeps credentials in the
process environment and writes only `notarize`, `staple`, and
`gatekeeperAssess` to generated YAML.

## Apple Acceptance Gates

The publisher completes the app trust gate before packaging: configuration,
`prePackage`, read-only inventory, inner-to-outer signing, typed app
notarization acceptance, stapling, validation, and Gatekeeper assessment.
Notarized publishing requires the executable install helper, matching sealed
policy, and integer host build metadata before signing. Follow
[macOS setup](../README.md#macos-setup) in both the outgoing and incoming apps;
`macos.notarize` configures distribution signing and does not embed the helper.
Packaging then applies the same typed notarization/staple/assessment checks to
the exact DMG or PKG. The final distributable is audited before release
metadata is signed or uploaded; a macOS `postPackage` hook is rejected while
built-in notarization is enabled.

Production-ready macOS evidence uses real Apple trust validation:

```sh
codesign --verify --deep --strict --verbose=2 Example.app
codesign -dvvv Example.app
spctl --assess --type execute --verbose=2 Example.app
spctl --assess --type install --verbose=2 Example.pkg
spctl --assess --type open --context context:primary-signature --verbose=2 Example.dmg
xcrun stapler validate Example.app
xcrun stapler validate Example.dmg
xcrun stapler validate Example.pkg
pkgutil --check-signature Example.pkg
hdiutil attach -readonly -nobrowse Example.dmg
hdiutil detach /Volumes/Example
xcrun notarytool submit Example-notary.zip --keychain-profile "$DESKTOP_UPDATER_NOTARY_PROFILE" --wait
```

For a profile explicitly stored in a file-based keychain, pass the same
`--keychain` path to `store-credentials` and later `submit` calls. For the
existing local `general-notary` profile, omit `--keychain`; a login-keychain
lookup alone cannot establish that the profile is missing. See
[local notarization profile lookup](publishing.md#local-notarization-profile-general-notary).

## Local MacBook Production Smoke

Required environment:

```sh
export DESKTOP_UPDATER_DEV_ID_APP="Developer ID Application: Example Corp (TEAMID1234)"
export DESKTOP_UPDATER_DEV_ID_INSTALLER="Developer ID Installer: Example Corp (TEAMID1234)"
export DESKTOP_UPDATER_NOTARY_PROFILE="desktop-updater-notary"
export DESKTOP_UPDATER_TEST_BUNDLE_ID="com.example.desktopUpdaterSmoke"
```

On the maintainer Mac, use `DESKTOP_UPDATER_NOTARY_PROFILE=general-notary`
instead of the example profile above, and run the documented read-only
profile check before `doctor` or a new notarization.

Optional smoke overrides:

```sh
export DESKTOP_UPDATER_TEST_APP_NAME="Desktop Updater Smoke"
export DESKTOP_UPDATER_TEST_VERSION_V1="1.0.0"
export DESKTOP_UPDATER_TEST_VERSION_V2="1.0.1"
export DESKTOP_UPDATER_TEST_VERSION_V3="1.0.2"
export DESKTOP_UPDATER_TEST_BUILD_V1="100"
export DESKTOP_UPDATER_TEST_BUILD_V2="101"
export DESKTOP_UPDATER_TEST_BUILD_V3="102"
export DESKTOP_UPDATER_TEST_WORKDIR="/tmp/desktop_updater_macos_smoke"
```

Smoke commands:

```sh
dart run tool/macos_production_smoke.dart doctor
dart run tool/macos_production_smoke.dart app-update
dart run tool/macos_production_smoke.dart dmg-first-install
dart run tool/macos_production_smoke.dart move-to-applications
dart run tool/macos_production_smoke.dart dmg-update
dart run tool/macos_production_smoke.dart pkg-artifact
dart run tool/macos_production_smoke.dart pkg-install-verify
dart run tool/macos_production_smoke.dart all --cleanup
```

Evidence is written under `reports/macos-production-smoke/`.

`app-update` builds three signed, notarized, stapled Flutter apps and performs
two consecutive updates in the same installed bundle (v1 to v2 to v3).
Every outgoing version contains the current updater. Each transition checks
the exact new sentinel without modifying signed resources, a new process,
the expected version/build, one fully launched regular LaunchServices app,
and the installed bundle's Apple trust. Diagnostics are retained separately
for each transition. Set all version/build overrides to increasing values.

`pkg-artifact` builds and verifies the signed, notarized, stapled PKG without
attempting an install handoff. `pkg-install-verify` is a separate opt-in QA gate
that uses macOS administrator approval to run the system installer directly,
then verifies the smoke receipt, installed v2 app sentinel, and final app Apple
trust. It validates the package itself; it is not runtime-helper evidence.

The hosted approval-boundary lane runs a signed helper-embedded v1 app from
`/Applications` and requires the exact approval-required result, unchanged v1,
and a retained verified stage. This is not install-success evidence. The
self-hosted preapproved target-host lane owns the real privileged runtime
handoff: it requires the v2 app/build, package receipt/version, post-install
bundle/helper/LaunchDaemon identity and root ownership, and empty staging.

Cleanup removes only smoke-owned paths: the smoke app in `/Applications`, smoke
DMG volumes, smoke temp roots, and listed smoke package receipts. Receipt
forgetting requires `--cleanup-forget-receipt` and an exact smoke receipt
identifier match.

## CI Labels

Linux and Windows CI cannot prove Apple trust gates. For those runs, label
production Apple checks exactly as:

```text
not run: macOS production smoke requires local Developer ID Application cert, Developer ID Installer cert, notary profile, and Apple notarization service access.
```

Use `blocked` when a macOS host is available but a required certificate,
identity, keychain, or notary profile is missing.

```text
blocked: DESKTOP_UPDATER_DEV_ID_APP is required for macOS production smoke.
```
