# Publishing Desktop Updates

This guide covers the app-owned release publishing flow for desktop_updater 2.x.
The happy path is:

```sh
dart run desktop_updater:release publish --platform macos
dart run desktop_updater:release publish --platform windows
dart run desktop_updater:release publish --platform linux
```

The command builds one platform, packages the release, writes a consistent local
layout, optionally uploads it, and validates the hosted update path.

## EL10 Working Scenario

Think of your update host as one shelf on the internet.

1. Your app knows one URL: `https://updates.example.com/app-archive.json`.
2. `app-archive.json` says which releases exist for each platform and channel.
3. Each item points to a versioned `release.json`.
4. `release.json` points to one zip and records its length and SHA-256.
5. The app downloads the zip only after it has selected a valid newer release.
6. The app checks the zip length and hash before staging or installing it.
7. The publisher uploads the zip and `release.json` first.
8. The publisher uploads `app-archive.json` last, so users never see an index
   entry whose release files are missing.
9. `release validate` pretends to be an older app and tests the hosted files in
   the same order a real client uses them.

That is why `release.json` stays separate from `app-archive.json`: the archive
is a small, frequently refreshed index; each release descriptor is stable,
cacheable, versioned metadata for exactly one artifact.

## File Contract

`app-archive.json` is the top-level index. Clients fetch it first and select the
best release for the current platform, channel, and installed version.

```json
{
  "schemaVersion": 3,
  "appName": "Example App",
  "items": [
    {
      "version": "2.0.1",
      "buildNumber": 201,
      "platform": "macos",
      "channel": "stable",
      "mandatory": false,
      "release": "https://updates.example.com/releases/2.0.1/macos/release.json"
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
  "version": "2.0.1",
  "buildNumber": 201,
  "platform": "macos",
  "channel": "stable",
  "artifact": {
    "kind": "zip",
    "url": "https://updates.example.com/releases/2.0.1/macos/Example-2.0.1-macos.zip",
    "sha256": "64-lowercase-hex-characters",
    "length": 12345678
  },
  "install": {
    "strategy": "wholeBundleReplace"
  },
  "minimumUpdaterVersion": "2.0.0",
  "generatedAt": "2026-06-12T00:00:00Z"
}
```

`buildNumber` is optional in both files. Include it when your app exposes a
monotonic build number. Omit it when the installed app only exposes a semantic
version such as `1.2.3`.

`minimumUpdaterVersion` is enforced before artifact download. If a descriptor
requires a newer `desktop_updater` runtime than the app has, update checks skip
that descriptor and direct staging rejects it before fetching the zip.

`minimumOS` is optional descriptor metadata. Use it when a release should only
be offered to newer operating system versions:

```json
"minimumOS": {
  "macos": "13.0",
  "windows": "10.0.19045",
  "linux": "glibc-2.35"
}
```

The runtime parses and preserves this metadata. Apps that want enforcement
provide an `isMinimumOSSupported` callback to `DesktopUpdaterController` or
`UpdateClient`; without that callback the field is informational.

Supported install strategies:

- `wholeBundleReplace`: macOS `.app` bundle replacement.
- `wholeDirectoryReplace`: Windows and Linux app directory replacement.

The optional `signature` field adds package-owned metadata authenticity for
`release.json`. It signs the canonical descriptor bytes with the signature
value blanked, then stores the Ed25519 signature inline:

```json
"signature": {
  "algorithm": "ed25519",
  "publicKeyId": "stable-2026",
  "value": "base64-raw-ed25519-signature"
}
```

This signature proves the versioned update metadata came from a holder of the
matching private key before the updater trusts artifact metadata such as URL,
length, and SHA-256. It does not replace app-owned platform trust: Authenticode,
Apple Developer ID notarization, native package signing, store review, and
Linux repository signing remain the app publisher's responsibility.

## Runtime Policies

The runtime ships product-grade defaults but keeps storage and telemetry
app-owned:

- Optional update skip persistence is provided by an `UpdatePreferences`
  adapter. The package stores skipped versions in memory when no adapter is
  supplied and never depends on `shared_preferences` or another storage
  package.
- HTTP downloads retry transient statuses `408`, `429`, `500`, `502`, `503`,
  and `504` with `UpdateRetryPolicy(maxAttempts: 3, initialDelay: 500ms,
  maxDelay: 5s)`. Descriptor parse failures, signature failures, SHA-256
  mismatches, unsupported URL schemes, and zip safety failures are not retried.
- Optional telemetry is a `DesktopUpdaterTelemetry` callback with typed events.
  The package does not include a telemetry backend, and callback failures do not
  affect update checks, downloads, verification, or install handoff.
- Update diagnostics are recorded in memory and attached to `UpdateFailed` as a
  redacted `UpdateProblemReport` when check, download, verification, staging, or
  install handoff fails. Reports are bounded before copy/export. The package
  does not write report files, upload logs, or depend on a backend.
- Install scheduling emits a small in-memory `UpdateCleanupReport` through
  `DesktopUpdaterController.lastCleanupReport` and the optional
  `onCleanupReport` callback. The report records the staging path, descriptor
  version, whether cleanup was attempted, whether cleanup succeeded when known,
  whether a native helper reported backup rollback when known, and error text
  when scheduling or cleanup fails. Callback or persistence failures are ignored
  so install success is not blocked by reporting.

Advanced callers that use `HttpUpdateTransport` directly can provide a custom
`UpdateRetryPolicy` and delay function for tests or app-specific retry tuning.

Apps that want user-approved reporting can pass `onProblemReport` to
`DesktopUpdaterController` and send `report.toPlainText()` to their own Sentry,
email, issue-form, support, or API workflow. The callback is optional and is
invoked only by explicit user action in the ready-made problem report dialog.

## Common Minimum Setup

Do this once in the app repository.

1. Add the runtime dependency:

```yaml
dependencies:
  desktop_updater: ^2.0.0
```

2. Point the app at the hosted archive:

```dart
final controller = DesktopUpdaterController(
  appArchiveUrl: Uri.parse("https://updates.example.com/app-archive.json"),
);
```

3. Add `desktop_updater.yaml` at the app repository root, next to
   `pubspec.yaml`:

```yaml
updates:
  baseUrl: https://updates.example.com
```

By default, `release publish` looks for:

```text
<app-repo>/desktop_updater.yaml
<app-repo>/pubspec.yaml
```

Use `--config` only when your release config lives somewhere else:

```sh
dart run desktop_updater:release publish \
  --platform macos \
  --config tool/release/desktop_updater.yaml
```

`baseUrl` is the public HTTP(S) root users' apps can fetch. It produces these
hosted paths by default:

```text
https://updates.example.com/app-archive.json
https://updates.example.com/releases/2.0.1/macos/release.json
https://updates.example.com/releases/2.0.1/macos/Example-2.0.1-macos.zip
```

Run the doctor before the first production release for each platform:

```sh
dart run desktop_updater:release doctor --platform macos
dart run desktop_updater:release doctor --platform windows
dart run desktop_updater:release doctor --platform linux
```

The doctor reads `desktop_updater.yaml`, checks `pubspec.yaml` name/version
metadata, reports whether upload is manual or provider-backed, and calls out
platform trust gaps. It does not block internal, unsigned, or manual-upload
flows when the config is otherwise valid.

Exit codes:

- `0`: config loaded, or only warnings/info were found.
- `64`: invalid release config, such as a missing `updates.baseUrl`.
- `1`: unexpected filesystem or parser failure.

If `desktop_updater.yaml` is missing, the doctor prints the minimum config:

```yaml
updates:
  baseUrl: https://updates.example.com
```

Warnings to expect before production hardening:

- `http://` base URLs are allowed but warned because production hosts should
  use HTTPS.
- No provider means `release publish` prepares a manual upload package.
- Windows direct zip releases should run an app-owned Authenticode signing hook
  before packaging when publisher trust matters.
- Linux direct zip releases should sign `release.json` with an app-owned hook
  or another pinned descriptor signature policy before calling the flow
  production-trusted.
- macOS unsigned/internal flows can use `allowUnsignedMacOSUpdates`, but
  production direct distribution should sign, notarize, staple, and verify
  Gatekeeper before packaging.

4. Keep `pubspec.yaml` version current:

```yaml
version: 2.0.1+201
```

By default, `release publish` reads `version` and build metadata from
`pubspec.yaml`. Override only when your release pipeline owns versioning:

```sh
dart run desktop_updater:release publish \
  --platform macos \
  --version 2.0.1 \
  --build-number 201
```

5. Publish one platform:

```sh
dart run desktop_updater:release publish --platform macos
```

With only the minimum config, the command writes:

```text
dist/desktop_updater/
  .desktop_updater_publish.json
  app-archive.json
  releases/<version>/<platform>/release.json
  releases/<version>/<platform>/<artifact>.zip
```

It then prints:

```text
Manual publish package is ready.
Not uploaded yet.
```

Upload the contents of `dist/desktop_updater` to `updates.baseUrl` without
changing relative paths.

6. Validate after manual upload:

```sh
dart run desktop_updater:release validate \
  --manifest dist/desktop_updater/.desktop_updater_publish.json
```

Use `--from-version` to simulate a specific installed version:

```sh
dart run desktop_updater:release validate \
  --manifest dist/desktop_updater/.desktop_updater_publish.json \
  --from-version 2.0.0+200
```

Without `--from-version`, validation uses the previous hosted release for the
same platform and channel when available, or synthetic `0.0.0` for a first
release.

To require a signed hosted `release.json`, pin public keys in an environment
variable and pass it to validation:

```sh
export DESKTOP_UPDATER_RELEASE_PUBLIC_KEYS='{"stable-2026":"base64-raw-ed25519-public-key"}'

dart run desktop_updater:release validate \
  --manifest dist/desktop_updater/.desktop_updater_publish.json \
  --require-signature \
  --public-keys-env DESKTOP_UPDATER_RELEASE_PUBLIC_KEYS
```

## Recommended Setup

For production, start from the minimum setup and add:

- HTTPS for `app-archive.json`, `release.json`, and zip artifacts.
- Short cache TTLs for `app-archive.json`.
- Long, immutable cache TTLs for versioned `release.json` and zip files.
- Signed `release.json` descriptors with public keys pinned by the app or
  release validation environment.
- S3-compatible storage, SFTP, or a custom upload command in CI.
- Platform publisher-trust gates before packaging.
- A release approval step before publishing `app-archive.json`.
- `release validate --require-signature` after every production upload.

### Signing release.json

Sign each generated descriptor after packaging and before uploading it:

```sh
dart run desktop_updater:release sign \
  --release dist/desktop_updater/releases/2.2.0/linux/release.json \
  --public-key-id stable-2026 \
  --private-key-env DESKTOP_UPDATER_RELEASE_PRIVATE_KEY
```

`DESKTOP_UPDATER_RELEASE_PRIVATE_KEY` must contain a base64-encoded raw
32-byte Ed25519 private seed. You can also keep the key outside the repository
and point to it explicitly:

```sh
dart run desktop_updater:release sign \
  --release dist/desktop_updater/releases/2.2.0/linux/release.json \
  --public-key-id stable-2026 \
  --private-key-file /secure/path/desktop-updater-release.key
```

Private signing keys are never read from `desktop_updater.yaml`. Keep them in
CI secret storage, a dedicated key file, or another app-owned secret manager.

### Trust Split

Signed `release.json` is the package-owned, platform-independent trust layer. It
protects update metadata across macOS, Windows, and Linux: which artifact URL is
selected, which length is expected, and which SHA-256 digest must match.

Platform trust remains app-owned. For Windows, use Authenticode or a trusted
installer/channel when your distribution requires it. For macOS, sign and
notarize the `.app` before packaging. For Linux, use native package repository
signing or store/channel trust when that is how users install your app. These
steps answer "will the platform trust this app"; the signed descriptor answers
"did this updater metadata come from my release key."

For Windows and Linux production signing choices, native package channels, and
country or provider restrictions, see
[Windows And Linux Production Release Options](windows-linux-production-release.md).

For macOS production-trusted direct distribution, also plan the Apple trust
setup before the first release:

- Create or install a `Developer ID Application` certificate for the app's Team
  ID.
- Configure App Store Connect API key credentials for notarization.
- Store those notarization credentials with `notarytool store-credentials` in
  the keychain used by the release job.
- Sign the Release `.app`, notarize it, staple it, and verify Gatekeeper before
  packaging the zip that users will download.

The high-level `release publish --platform macos` command does not create Apple
credentials and does not silently notarize an app just because a Developer ID
identity exists. Production macOS notarization should be an explicit app-owned
release step, not a hidden side effect.

Recommended S3-compatible config:

```yaml
updates:
  baseUrl: https://updates.example.com
  channel: stable
  output: dist/desktop_updater

s3:
  bucket: my-update-bucket
  prefix: updates
  region: eu-central-1
  profile: desktop-updater
```

Recommended R2, MinIO, or custom endpoint config:

```yaml
updates:
  baseUrl: https://updates.example.com
  channel: stable

s3:
  bucket: my-update-bucket
  prefix: updates
  region: auto
  endpoint: https://example-account.r2.cloudflarestorage.com
  pathStyle: true
  profile: desktop-updater-r2
```

S3 credentials use the standard AWS credential chain:

- `s3.profile` when set.
- `AWS_PROFILE` when set.
- Default local AWS profile.
- `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, and optional
  `AWS_SESSION_TOKEN` in CI.

Do not put credentials in `desktop_updater.yaml`.

## Optional Setup

These settings are optional and can be added when your release process needs
them.

```yaml
updates:
  baseUrl: https://updates.example.com
  output: dist/desktop_updater
  channel: beta
```

Common CLI overrides:

```sh
dart run desktop_updater:release publish \
  --platform macos \
  --config tool/release/desktop_updater.yaml \
  --base-url https://updates.example.com \
  --output dist/desktop_updater \
  --channel beta \
  --version 2.0.1 \
  --build-number 201 \
  --package-id com.example.app \
  --app-name Example.app
```

Use optional provider blocks when you want automatic upload:

- `s3`: AWS S3, Cloudflare R2, MinIO, and compatible APIs.
- `sftp`: SSH file transfer with password or private key from environment.
- `ftp`: legacy hosts only, requires `allowInsecure: true`.
- `customCommand`: call your own upload script with environment variables.

Only one provider block can be configured at a time. If no provider block is
configured, `manual` is used.

### App-Owned Release Hooks

Optional hooks let your app keep platform trust work in your own scripts while
making the release doctor aware of the gates:

```yaml
hooks:
  prePackage:
    - command: ./tool/sign_windows_release.ps1
      platforms: [windows]
  postPackage:
    - command: ./tool/sign_release_json.sh
      platforms: [linux, windows, macos]
```

Use `prePackage` for gates that must happen before the zip is created, such as
Windows Authenticode signing or macOS notarization when you own that outside the
built-in `macos.notarize` flow. Use `postPackage` for metadata gates such as
signing generated `release.json`.

`release publish` runs matching hooks for the requested platform. Each hook gets
the normal process environment plus these variables:

- `DESKTOP_UPDATER_HOOK_PHASE`: `prePackage` or `postPackage`.
- `DESKTOP_UPDATER_PLATFORM`: `macos`, `windows`, or `linux`.
- `DESKTOP_UPDATER_PROJECT_ROOT`: app repository root.
- `DESKTOP_UPDATER_APP_PATH`: platform Release app/bundle path.
- `DESKTOP_UPDATER_BASE_URL`: normalized `updates.baseUrl`.
- `DESKTOP_UPDATER_OUTPUT_ROOT`: local `dist/desktop_updater` root.
- `DESKTOP_UPDATER_CHANNEL`, `DESKTOP_UPDATER_APP_NAME`,
  `DESKTOP_UPDATER_PACKAGE_ID`, `DESKTOP_UPDATER_VERSION`, and optional
  `DESKTOP_UPDATER_BUILD_NUMBER`.
- `DESKTOP_UPDATER_PUBLISH_MANIFEST`: `.desktop_updater_publish.json` path.
- `DESKTOP_UPDATER_APP_ARCHIVE_FILE`, `DESKTOP_UPDATER_RELEASE_FILE`, and
  `DESKTOP_UPDATER_ARTIFACT_FILE`.
- `DESKTOP_UPDATER_APP_ARCHIVE_URL`, `DESKTOP_UPDATER_RELEASE_URL`, and
  `DESKTOP_UPDATER_ARTIFACT_URL`.

The YAML stores command paths and platform filters only. Do not put credentials,
private keys, passwords, tokens, or inline environment maps in
`desktop_updater.yaml`; hooks should read secrets from CI secret storage,
keychains, standard credential files, or environment variables owned by the
calling release job.

### macOS Notarization Opt-In

`release publish --platform macos` notarizes only when you explicitly opt in.
Use the CLI flag:

```sh
dart run desktop_updater:release publish --platform macos --notarize
```

or enable it in YAML:

```yaml
# desktop_updater.yaml, at the app repository root next to pubspec.yaml.
updates:
  baseUrl: https://updates.example.com

macos:
  notarize: true
  developerIdApplication: "Developer ID Application: Example Corp (TEAMID1234)"
  notaryProfile: desktop-updater-notary
  keychain: /Users/me/Library/Keychains/login.keychain-db
  staple: true
  gatekeeperAssess: true
```

The YAML must contain only non-secret references. The `.p8` App Store Connect
API key, `.p12` Developer ID certificate, passwords, API key ID, issuer ID, and
CI keychain password must still come from the user's machine, keychain, CI
secrets, or standard environment setup.

When notarization is enabled, publish runs:

1. Build the Release `.app`.
2. Sign with `macos.developerIdApplication`.
3. Submit the signed app with `macos.notaryProfile` and `macos.keychain`.
4. Staple when `macos.staple` is true.
5. Run Gatekeeper assessment when `macos.gatekeeperAssess` is true.
6. Package, upload, and validate only after those gates pass.

This keeps notarization intentional and avoids silently using whatever Developer
ID identity happens to be installed on the machine.

## Platform-Specific Work

### macOS

Command:

```sh
dart run desktop_updater:release publish --platform macos
```

What the command does:

- Runs `flutter build macos --release`.
- Uses `build/macos/Build/Products/Release/<AppName>.app`.
- Packages the `.app` with macOS-safe zip behavior.
- Writes `wholeBundleReplace` in `release.json`.

Important trust boundary:

- `release publish --platform macos` handles release mechanics: build, package,
  publish, and validate.
- It does not automatically import Developer ID certificates.
- It does not automatically create a notary profile.
- It notarizes and staples only when you explicitly pass `--notarize` or set
  `macos.notarize: true`.
- If you need production-trusted macOS updates, configure that explicit
  notarization gate before packaging the artifact that will be uploaded.

What you must do for production-trusted macOS updates:

- Sign with a `Developer ID Application` identity.
- Enable hardened runtime.
- Notarize the signed app.
- Staple the notarization ticket.
- Verify Gatekeeper acceptance.
- Keep `CFBundleIdentifier` and Team ID stable across releases.
- Keep App Sandbox disabled for this whole-app replacement strategy.
- Ensure production entitlements do not include `get-task-allow`.

### macOS Developer ID And Notary Setup

One-time Apple setup:

1. Join the Apple Developer Program.
2. Create or download a `Developer ID Application` certificate for the Team ID
   that owns the app.
3. Install that certificate locally, or export it as a password-protected `.p12`
   for CI secret storage.
4. Create an App Store Connect API key with access to notarization.
5. Download the `AuthKey_<KEY_ID>.p8` file and record the Key ID and Issuer ID.

Never commit `.p8`, `.p12`, generated keychains, certificate passwords, Team
IDs, Issuer IDs, or real API key IDs to a public repository.

Check the local Developer ID identity:

```sh
security find-identity -v -p codesigning
```

Create a local notary profile:

```sh
xcrun notarytool store-credentials desktop-updater-notary \
  --key "$HOME/Developer/secrets/AuthKey_XXXXXXXXXX.p8" \
  --key-id "XXXXXXXXXX" \
  --issuer "00000000-0000-0000-0000-000000000000" \
  --keychain "$HOME/Library/Keychains/login.keychain-db" \
  --validate
```

Use the same `--keychain-profile` and `--keychain` pair for every later
`notarytool` command. If `notarytool` later says
`No Keychain password item found`, it is usually reading a different keychain
from the one where the profile was stored.

CI should create an ephemeral keychain, import the Developer ID `.p12`, and
store the notary profile into that same keychain:

```sh
KEYCHAIN="$RUNNER_TEMP/build.keychain-db"
CERTIFICATE="$RUNNER_TEMP/developer-id.p12"
API_KEY="$RUNNER_TEMP/AuthKey.p8"

security create-keychain -p "$MACOS_KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$MACOS_KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$CERTIFICATE" \
  -k "$KEYCHAIN" \
  -P "$APPLE_DEVELOPER_ID_CERTIFICATE_PASSWORD" \
  -T /usr/bin/codesign
security set-key-partition-list \
  -S apple-tool:,apple:,codesign: \
  -s \
  -k "$MACOS_KEYCHAIN_PASSWORD" \
  "$KEYCHAIN"

xcrun notarytool store-credentials desktop-updater-notary \
  --key "$API_KEY" \
  --key-id "$APPLE_API_KEY_ID" \
  --issuer "$APPLE_API_ISSUER_ID" \
  --keychain "$KEYCHAIN" \
  --validate
```

### macOS Production Packaging Order

Use this order for production-trusted macOS artifacts:

1. Build the Release app.
2. Sign the app with the Developer ID identity and hardened runtime.
3. Verify the signature.
4. Create a temporary notarization zip with `ditto`.
5. Submit that zip to Apple notarization and wait for acceptance.
6. Staple the accepted ticket onto the `.app`.
7. Verify Gatekeeper and stapler acceptance.
8. Package and publish the stapled `.app`.
9. Validate the hosted update.

The high-level command supports this order with `--notarize` or
`macos.notarize: true`. Apps with more complex signing needs can still use the
low-level `package`, `app_archive`, upload, and `release validate` commands
after an app-owned signing/notarization script has stapled the app.

Example signing/notarization shell outline:

```sh
APP="build/macos/Build/Products/Release/Example.app"
IDENTITY="Developer ID Application: Example Corp (TEAMID1234)"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
NOTARY_ZIP="$(mktemp -t desktop-updater-notary).zip"

codesign --force --options runtime --timestamp \
  --sign "$IDENTITY" \
  "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"

/usr/bin/ditto -c -k --keepParent --sequesterRsrc "$APP" "$NOTARY_ZIP"

xcrun notarytool submit "$NOTARY_ZIP" \
  --keychain-profile desktop-updater-notary \
  --keychain "$KEYCHAIN" \
  --wait

xcrun stapler staple "$APP"
```

For complex apps, sign nested frameworks, helper tools, and extensions with the
app's normal release signing process before signing the outer `.app`. Do not
rely on a single outer-app signature as your whole production signing strategy.

Useful checks:

```sh
codesign --verify --deep --strict --verbose=2 Example.app
spctl --assess --type execute --verbose=2 Example.app
xcrun stapler validate Example.app
codesign -dvvv --entitlements :- Example.app
```

The runtime rejects unsigned macOS updates by default. Use
`allowUnsignedMacOSUpdates: true` only for an intentional internal or
user-controlled lane. That opt-out keeps release mechanics working, but it does
not make the update production-trusted.

Mac App Store or sandboxed apps should use the store update channel instead of
this direct self-updater.

### Windows

Command:

```sh
dart run desktop_updater:release publish --platform windows
```

What the command does:

- Runs `flutter build windows --release`.
- Uses `build/windows/x64/runner/Release`.
- Packages the Release runner directory.
- Writes `wholeDirectoryReplace` in `release.json`.

What you should do for production trust:

- Sign `.exe` and `.dll` files with Authenticode.
- Verify signatures before packaging.
- Keep the app executable and package identity stable.
- Test update install from a normal user account, not only an admin shell.

Unsigned Windows Release builds can be release-mechanics ready, but users can
still see publisher-trust warnings.

For Authenticode, Microsoft Artifact Signing, MSIX/Store, winget, enterprise
trust, and country/provider constraints, see
[Windows And Linux Production Release Options](windows-linux-production-release.md).

### Linux

Command:

```sh
dart run desktop_updater:release publish --platform linux
```

What the command does:

- Runs `flutter build linux --release`.
- Uses `build/linux/x64/release/bundle`.
- Packages the Release bundle directory.
- Writes `wholeDirectoryReplace` in `release.json`.

What you should do for production trust:

- Decide whether direct zip updates are appropriate for your distribution.
- Add descriptor signing or another publisher-authenticity policy when needed.
- Keep `APPLICATION_ID` stable, or pass `--package-id`.
- Test install and rollback on the Linux distributions you support.

Flatpak, Snap, deb, rpm, and distro repositories should normally use their own
update channels.

For direct zip descriptor signing, Sigstore/TUF options, native package
repositories, Flatpak/Snap/AppImage tradeoffs, and country/provider constraints,
see [Windows And Linux Production Release Options](windows-linux-production-release.md).

## Upload Providers

### Manual

Manual is the default provider:

```yaml
updates:
  baseUrl: https://updates.example.com
```

After `release publish`, upload the entire `dist/desktop_updater` directory to
the public root. Do not rename files or change relative paths. Then run
`release validate`.

### S3-Compatible

Use this for AWS S3, Cloudflare R2, MinIO, or compatible APIs:

```yaml
updates:
  baseUrl: https://updates.example.com

s3:
  bucket: my-update-bucket
  prefix: updates
  region: eu-central-1
  endpoint: https://example-account.r2.cloudflarestorage.com
  pathStyle: true
  profile: desktop-updater
```

The transport uses AWS CLI commands such as `aws s3 cp`. When configured, it
passes `--profile` and `--endpoint-url`.

### SFTP

```yaml
updates:
  baseUrl: https://updates.example.com

sftp:
  host: deploy.example.com
  port: 22
  remotePath: /var/www/updates
  username: deploy
```

Set one of:

```sh
DESKTOP_UPDATER_SFTP_PASSWORD=...
DESKTOP_UPDATER_SFTP_PRIVATE_KEY=/Users/me/.ssh/deploy_key
```

No interactive password prompts are used.

### FTP

FTP is insecure and exists for legacy hosts only:

```yaml
updates:
  baseUrl: https://updates.example.com

ftp:
  host: ftp.example.com
  port: 21
  remotePath: /public_html/updates
  username: deploy
  allowInsecure: true
```

Set:

```sh
DESKTOP_UPDATER_FTP_PASSWORD=...
```

Prefer SFTP or S3-compatible upload for production.

### Custom Command

```yaml
updates:
  baseUrl: https://updates.example.com

customCommand:
  command: ./tool/upload_updates.sh
```

The command receives:

```text
DESKTOP_UPDATER_LOCAL_ROOT
DESKTOP_UPDATER_PUBLISH_MANIFEST
DESKTOP_UPDATER_BASE_URL
DESKTOP_UPDATER_APP_ARCHIVE_URL
DESKTOP_UPDATER_RELEASE_URL
DESKTOP_UPDATER_ARTIFACT_URL
DESKTOP_UPDATER_PLATFORM
DESKTOP_UPDATER_VERSION
DESKTOP_UPDATER_CHANNEL
```

Compatibility aliases are also provided: `PUBLISH_MANIFEST`, `BASE_URL`,
`APP_ARCHIVE_URL`, `RELEASE_URL`, `ARTIFACT_URL`, `PLATFORM`, `VERSION`, and
`CHANNEL`.

## Validation Contract

Validation must prove the hosted files work in client order:

1. Read `.desktop_updater_publish.json`.
2. Simulate an older installed version from `--from-version`, the previous
   hosted release, or synthetic `0.0.0`.
3. Fetch hosted `app-archive.json`.
4. Select an update for platform and channel.
5. Fetch hosted `release.json`.
6. Verify its Ed25519 signature when `--require-signature` is enabled.
7. Download artifact bytes.
8. Verify exact length and SHA-256.
9. Print clear OK or failure lines.

Example:

```sh
dart run desktop_updater:release validate \
  --manifest dist/desktop_updater/.desktop_updater_publish.json
```

Signed validation:

```sh
dart run desktop_updater:release validate \
  --manifest dist/desktop_updater/.desktop_updater_publish.json \
  --require-signature \
  --public-keys-env DESKTOP_UPDATER_RELEASE_PUBLIC_KEYS
```

## Low-Level Commands

Use these only when your pipeline needs to own each packaging/upload step.

Package a release manually:

```sh
dart run desktop_updater:package \
  --input build/macos/Build/Products/Release/Example.app \
  --output dist/2.0.1/macos \
  --package-id com.example.app \
  --app-name Example.app \
  --version 2.0.1 \
  --build-number 201 \
  --platform macos \
  --channel stable \
  --install-strategy wholeBundleReplace \
  --artifact-url https://updates.example.com/releases/2.0.1/macos/Example-2.0.1-macos.zip
```

Update `app-archive.json`:

```sh
dart run desktop_updater:app_archive upsert \
  --archive dist/app-archive.json \
  --app-name "Example App" \
  --version 2.0.1 \
  --build-number 201 \
  --platform macos \
  --channel stable \
  --release-url https://updates.example.com/releases/2.0.1/macos/release.json
```

Verify one release descriptor and artifact:

```sh
dart run desktop_updater:verify --release dist/2.0.1/macos/release.json
```

## CI

In CI, keep secrets in the CI secret store or standard credential files, not in
`desktop_updater.yaml`.

Typical flow:

1. Check out code.
2. Install Flutter and platform build tools.
3. Restore signing credentials for the target platform.
4. Build/sign/notarize/staple when required.
5. Run `dart run desktop_updater:release publish --platform <platform>`.
6. Fail the job if upload or hosted validation fails.

The package's own provider e2e tests are Docker-gated:

```sh
flutter test --no-pub test/e2e/release_publish_manual_e2e_test.dart
flutter test --no-pub test/e2e/release_publish_custom_command_e2e_test.dart

DESKTOP_UPDATER_RUN_RELEASE_PUBLISH_E2E=1 \
AWS_ACCESS_KEY_ID=minioadmin \
AWS_SECRET_ACCESS_KEY=minioadmin \
AWS_DEFAULT_REGION=us-east-1 \
flutter test --no-pub --concurrency=1 \
  test/e2e/release_publish_s3_e2e_test.dart \
  test/e2e/release_publish_ftp_e2e_test.dart \
  test/e2e/release_publish_sftp_e2e_test.dart
```

Use the [GitHub Actions CI/CD guide](github-actions-ci-cd.md) for a longer
workflow skeleton.

## Troubleshooting

- `updates.baseUrl is required`: add `updates.baseUrl` or pass `--base-url`.
- `updates.baseUrl must be an absolute URL`: use a full `https://...` URL.
- `Linux package id could not be inferred`: set `APPLICATION_ID` in
  `linux/CMakeLists.txt` or pass `--package-id`.
- `Update selection failed`: confirm `app-archive.json` was uploaded last and
  points at the expected `release.json`.
- `Artifact SHA-256 mismatch`: confirm the CDN or proxy is not transforming zip
  bytes.
- `AWS CLI executable not found`: install `aws` or use another provider.
- `ftp.allowInsecure: true is required`: use SFTP/S3, or explicitly opt in for
  a legacy FTP host.
- Long `Cache-Control` on `app-archive.json`: keep index caching short so
  clients see newly published releases promptly.
