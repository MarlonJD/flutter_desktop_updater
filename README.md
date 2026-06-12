# desktop_updater

Flutter desktop updater plugin for macOS, Windows, and Linux.

The 2.0 line uses a zip-first release contract:

```text
app-archive.json -> release.json -> one verified zip artifact
```

This avoids public folder listing, works with signed URLs and private buckets, and lets the updater verify the exact artifact length and SHA-256 before extraction or installation.

![flutter_desktop_updater](https://github.com/user-attachments/assets/b05d9a13-0f44-4213-b3bd-58e07c18226d)

- [2.0 roadmap](https://github.com/MarlonJD/flutter_desktop_updater/blob/main/docs/2.0-roadmap.md)
- [1.x to 2.0 migration guide](https://github.com/MarlonJD/flutter_desktop_updater/blob/main/docs/migration/1.x-to-2.0.md)
- [GitHub Actions CI/CD guide](https://github.com/MarlonJD/flutter_desktop_updater/blob/main/docs/github-actions-ci-cd.md)
- [Agent migration prompt](https://github.com/MarlonJD/flutter_desktop_updater/blob/main/docs/migration/agent-prompt.md)

## Version Lines

- `1.x`: stable maintenance line for the legacy folder-based update contract.
- `2.x`: current stable line for the zip-first release contract.

Apps already shipping with 1.x should keep their existing release contract until their app code and publishing pipeline have both migrated to 2.0.

## Why 2.0 Was Rewritten

The 1.x updater expected a public or fetchable update folder. That worked for simple static hosting, but it made modern production setups awkward:

- private buckets and signed URLs do not naturally expose folder listings;
- CDN/proxy behavior can change directory-style publishing assumptions;
- macOS `.app` bundles are easy to damage when uploaded as raw directory trees;
- update clients need one exact artifact to hash, verify, stage, and install safely.

2.0 changes the release model to one descriptor and one zip artifact per platform release. The client never needs S3 bucket listing, public folder hosting, or directory traversal on the server.

## Install

```yaml
dependencies:
  desktop_updater: ^2.0.0
```

Install the CLI:

```sh
dart pub global activate desktop_updater
```

## Automated Migration

Preview the 1.x to 2.0 migration before editing a shipped app:

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
macOS signing/notarization setup, or typed-state UI logic. Review the report,
then run `flutter analyze`, `flutter test`, and
`dart run desktop_updater:verify --release <release.json>` against the same
artifact clients will download.

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
  );
}
```

Wrap your UI with one of the update widgets:

```dart
DesktopUpdateWidget(
  controller: controller,
  child: const YourHomePage(),
)
```

Use `skipInitialVersionCheck` when you want to control the first check yourself:

```dart
controller = DesktopUpdaterController(
  appArchiveUrl: Uri.parse("https://updates.example.com/app-archive.json"),
  skipInitialVersionCheck: true,
);

await controller.checkVersion();
```

macOS signing and notarization gates are enabled by default for Release
updates. Owners who deliberately support an unsigned direct-distribution lane
can opt out, but that lane is only release-mechanics ready and is not
production-trusted:

```dart
controller = DesktopUpdaterController(
  appArchiveUrl: Uri.parse("https://updates.example.com/app-archive.json"),
  allowUnsignedMacOSUpdates: true,
);
```

The same opt-out is available for manual installs:

```dart
await DesktopUpdater().installUpdate(
  stagingPath: "/path/to/staged/Example.app",
  allowUnsignedMacOSUpdates: true,
);
```

Prefer the typed 2.0 state API for new code:

```dart
switch (controller.state) {
  case UpdateAvailable(:final descriptor, :final mandatory):
    print("Update ${descriptor.version} is available. Mandatory: $mandatory");
  case UpdateDownloading(:final receivedBytes, :final totalBytes):
    print("Downloaded $receivedBytes of $totalBytes bytes");
  case UpdateReadyToInstall(:final stagingPath):
    print("Ready to install from $stagingPath");
  case UpdateFailed(:final error):
    print("Update failed: $error");
  default:
    break;
}
```

The legacy boolean getters such as `needUpdate`, `isDownloading`, `isDownloaded`, and `downloadProgress` remain available as compatibility helpers during migration.

## Release Contract

`app-archive.json` selects the best release for the current platform, channel, and installed version.

```json
{
  "schemaVersion": 3,
  "appName": "Example App",
  "items": [
    {
      "version": "2.0.0",
      "buildNumber": 200,
      "platform": "macos",
      "channel": "stable",
      "mandatory": false,
      "release": "https://updates.example.com/releases/example/2.0.0/macos/release.json"
    }
  ]
}
```

`release.json` describes exactly one zip artifact.

```json
{
  "schemaVersion": 3,
  "packageId": "com.example.app",
  "appName": "Example.app",
  "version": "2.0.0",
  "buildNumber": 200,
  "platform": "macos",
  "channel": "stable",
  "artifact": {
    "kind": "zip",
    "url": "https://cdn.example.com/releases/example/2.0.0/macos/Example-2.0.0-macos.zip",
    "sha256": "64-lowercase-hex-characters",
    "length": 12345678
  },
  "install": {
    "strategy": "wholeBundleReplace"
  },
  "minimumUpdaterVersion": "2.0.0",
  "generatedAt": "2026-06-11T00:00:00Z"
}
```

`buildNumber` is optional in both `app-archive.json` items and `release.json`.
Include it when your app exposes a monotonic build number. Omit it when the
installed app only exposes a semantic version such as `1.2.3`; in that case
2.0 uses semantic version ordering and will not treat a remote build number as
newer than an equal installed semantic version with no build metadata.

Supported install strategies:

- `wholeBundleReplace`: macOS `.app` bundle replacement.
- `wholeDirectoryReplace`: Windows and Linux app directory replacement.

The optional `signature` field is reserved for production authenticity policies. The built-in verifier currently validates descriptor shape, exact URL support, artifact length, SHA-256, and zip safety. Projects that require signed descriptors should wire `ArtifactVerificationPolicy.signatureVerifier` or wait for the planned first-party signing gate before calling a direct-zip Linux or Windows build fully production signed.

## Package A Release

Build your app first, then package the exact release artifact.

macOS:

```sh
flutter build macos --release

# Sign, notarize, and staple the .app before packaging.

dart run desktop_updater:package \
  --input build/macos/Build/Products/Release/Example.app \
  --output dist/2.0.0/macos \
  --package-id com.example.app \
  --app-name Example.app \
  --version 2.0.0 \
  --build-number 200 \
  --platform macos \
  --channel stable \
  --install-strategy wholeBundleReplace \
  --artifact-url https://cdn.example.com/releases/example/2.0.0/macos/Example.app.zip
```

Windows:

```sh
flutter build windows --release

dart run desktop_updater:package \
  --input build/windows/x64/runner/Release \
  --output dist/2.0.0/windows \
  --package-id com.example.app \
  --app-name Example \
  --version 2.0.0 \
  --build-number 200 \
  --platform windows \
  --channel stable \
  --install-strategy wholeDirectoryReplace \
  --artifact-url https://cdn.example.com/releases/example/2.0.0/windows/Example-windows.zip
```

Linux:

```sh
flutter build linux --release

dart run desktop_updater:package \
  --input build/linux/x64/release/bundle \
  --output dist/2.0.0/linux \
  --package-id com.example.app \
  --app-name Example \
  --version 2.0.0 \
  --build-number 200 \
  --platform linux \
  --channel stable \
  --install-strategy wholeDirectoryReplace \
  --artifact-url https://cdn.example.com/releases/example/2.0.0/linux/Example-linux.zip
```

Verify a packaged release:

```sh
dart run desktop_updater:verify --release dist/2.0.0/macos/release.json
```

`--build-number` is optional. Omit it when your app does not expose build
metadata and you want update checks to rely only on semantic versions.

Publish:

- `app-archive.json`
- `release.json`
- the zip artifact referenced by `release.json`

Do not publish or rely on public update folders for the 2.0 contract.

## GitHub Actions CI/CD

The package repository runs a public, secretless GitHub Actions CI matrix for
Dart, Linux, and Windows. It verifies formatting, analysis, tests, CLI
entrypoints, pub dry-runs, native tests, integration tests, and debug/release
update smoke tests.

Real automatic update publishing belongs in your app repository, not in this
package repository. Your app owns the bundle ID, signing certificate,
notarization credentials, update hosting, release approval policy, and platform
publisher-trust gates.

Use the CI/CD guide when wiring an app release workflow:

- [GitHub Actions CI/CD for automatic updates](https://github.com/MarlonJD/flutter_desktop_updater/blob/main/docs/github-actions-ci-cd.md)
- Build the app in Release mode.
- Sign, notarize, staple, and Gatekeeper-check macOS artifacts before zipping.
- Sign Windows artifacts when publisher trust is required.
- Add a descriptor authenticity layer for production-trusted Linux direct zip distribution.
- Run `dart run desktop_updater:package` to generate the zip and `release.json`.
- Upload versioned artifacts first, verify the hosted `release.json`, then publish `app-archive.json` last.

## Hosting Requirements

- Serve exact URLs for `app-archive.json`, `release.json`, and the zip artifact.
- Do not require bucket listing.
- Signed URLs are supported when they remain valid for the full check and download flow.
- CDN/proxy transformations that change bytes will fail SHA-256 verification by design.
- Use HTTPS for production update metadata and artifacts.

## Readiness And Platform Trust

desktop_updater separates update mechanics from platform publisher trust:

- `release-mechanics ready`: a Release build can check, download, verify,
  stage, install, relaunch, and roll back through the zip-first flow.
- `production-trusted ready`: the Release artifact also satisfies the
  platform's publisher-authenticity expectations.

Unsigned Windows and Linux Release builds can be accepted as
release-mechanics ready for this Flutter package. Most Flutter desktop apps
will not have Windows Authenticode certificates or a Linux-specific signing
policy. Those apps may still use the direct zip updater, but their users can
see operating-system or distribution trust warnings, and the package does not
claim platform trust for them.

macOS is stricter by default. Public direct distribution should be
Developer ID signed, hardened-runtime enabled, notarized, stapled, and
Gatekeeper accepted before being called production-trusted. Apps that need an
unsigned macOS lane can set `allowUnsignedMacOSUpdates: true`; this bypasses
the native codesign, Gatekeeper, stapler, and Team ID gates, while still
requiring a complete `.app` bundle with the same `CFBundleIdentifier`. A macOS
update installed with this opt-out remains release-mechanics only and may be
blocked or warned on by Gatekeeper.

## Platform Behavior

### macOS

macOS stages a complete `.app` and replaces the installed bundle only after native gates pass.

Production-trusted requirements:

- Build a Release `.app`.
- Sign with a `Developer ID Application` identity.
- Enable hardened runtime.
- Notarize the signed app.
- Staple the notarization ticket.
- Keep `CFBundleIdentifier` and Team ID stable across releases.
- Keep App Sandbox disabled for this whole-app replacement strategy.
- Ensure production entitlements do not include `get-task-allow`.

Notarization credentials are stored as a local Keychain profile. When creating
the profile, keep the exact `--keychain-profile` and `--keychain` values printed
by `notarytool`; use both values again for `history`, `submit`, and any
automation that notarizes release artifacts:

```sh
xcrun notarytool store-credentials desktop-updater-notary \
  --key "$HOME/Developer/secrets/AuthKey_XXXXXXXXXX.p8" \
  --key-id "XXXXXXXXXX" \
  --issuer "00000000-0000-0000-0000-000000000000" \
  --keychain "$HOME/Library/Keychains/login.keychain-db" \
  --validate

xcrun notarytool history \
  --keychain-profile desktop-updater-notary \
  --keychain "$HOME/Library/Keychains/login.keychain-db" \
  --output-format json
```

If `store-credentials` says the credentials were saved but a later command says
`No Keychain password item found`, the profile was not read from the same
Keychain. Re-run the command with an explicit `--keychain`, or copy the exact
`--keychain-profile ... --keychain ...` pair from the success message. When
copying multi-line shell commands, the trailing `\` must be the final character
on the line; a space after it breaks argument continuation.

The macOS Release helper requires these gates by default. Set
`allowUnsignedMacOSUpdates: true` only when the app owner intentionally accepts
unsigned release mechanics, such as an internal lab, a local enterprise flow,
or a user-controlled distribution channel. That opt-out does not make the app
production-trusted.

Validation commands:

```sh
codesign --verify --deep --strict --verbose=2 Example.app
spctl --assess --type execute --verbose=2 Example.app
xcrun stapler validate Example.app
codesign -dvvv --entitlements :- Example.app
```

Mac App Store or sandboxed apps should use the store update channel instead of this direct self-updater.

### Windows

Windows schedules a detached PowerShell helper so locked `.exe` and `.dll` files are replaced only after the running app exits. The helper backs up the current app directory and rolls back if replacement fails.

Unsigned Release builds can be accepted as release-mechanics ready. Production-trusted direct distribution should additionally sign `.exe` and `.dll` files with Authenticode and verify them with `signtool`.

### Linux

Linux schedules a detached Bash helper that resolves the running executable, replaces the app directory without relying on the current working directory, rejects removed paths outside the app root, and rolls back on failure.

Linux has no single OS-level Developer ID equivalent. Unsigned Release builds can be accepted as release-mechanics ready. Direct zip distribution should use release descriptor signing or another publisher-authenticity layer before being treated as production-trusted. Flatpak, Snap, deb, rpm, or distro repositories should normally use their own update channels.

## SwiftPM And CocoaPods On macOS

Swift Package Manager is the primary macOS plugin integration path for 2.0. CocoaPods remains supported as a fallback for apps that disable SwiftPM or still run older Flutter tooling.

SwiftPM lane:

```sh
flutter config --enable-swift-package-manager
cd example
flutter test integration_test -d macos
```

CocoaPods fallback lane:

```sh
flutter config --no-enable-swift-package-manager
cd example
flutter test integration_test -d macos
```

Do not commit a `Podfile` in the SwiftPM-first example app. When SwiftPM is disabled, Flutter creates the CocoaPods files needed for the fallback lane and then runs `pod install`.

## Testing

Dart/package checks:

```sh
dart format --set-exit-if-changed .
flutter analyze --no-fatal-infos
flutter test --no-pub
dart pub publish --dry-run
```

macOS native smoke:

```sh
cd example
flutter build macos --debug
dart run tool/updater_smoke.dart
```

macOS production smoke requires a signed, notarized, stapled staged `.app` that already contains the smoke sentinel before signing:

```sh
cd example
dart run tool/updater_smoke.dart \
  --production-gates \
  --app /path/to/installed/Example.app \
  --staged-app /path/to/notarized/update/Example.app
```

Windows smoke:

```sh
cd example
flutter build windows --debug
dart run tool/updater_smoke.dart
```

Linux smoke:

```sh
cd example
flutter build linux --debug
dart run tool/updater_smoke.dart
```

By default the smoke runner skips relaunch so CI does not leave an app open. Add `--relaunch` when you want to test the close-copy-reopen flow manually.

## Migration

Read [Migrating From 1.x To 2.0](https://github.com/MarlonJD/flutter_desktop_updater/blob/main/docs/migration/1.x-to-2.0.md) before changing a shipped app. The migration must update both sides of the system:

- automated pass: run `dart run desktop_updater:migrate --path .` first, then
  `--apply` only after reviewing the dry-run report;
- app code: prefer typed `UpdateState` and keep compatibility getters only during migration;
- release publishing: replace folder uploads with `app-archive.json -> release.json -> zip`;
- platform validation: add macOS signing/notarization/stapling for production-trusted distribution, Windows signing when publisher trust is required, and Linux descriptor authenticity when direct zip publisher trust is required.
