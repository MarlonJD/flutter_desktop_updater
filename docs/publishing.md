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

Supported install strategies:

- `wholeBundleReplace`: macOS `.app` bundle replacement.
- `wholeDirectoryReplace`: Windows and Linux app directory replacement.

The optional `signature` field is reserved for production authenticity policies.
The built-in verifier currently validates descriptor shape, exact URL support,
artifact length, SHA-256, and zip safety.

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

3. Add `desktop_updater.yaml`:

```yaml
updates:
  baseUrl: https://updates.example.com
```

`baseUrl` is the public HTTP(S) root users' apps can fetch. It produces these
hosted paths by default:

```text
https://updates.example.com/app-archive.json
https://updates.example.com/releases/2.0.1/macos/release.json
https://updates.example.com/releases/2.0.1/macos/Example-2.0.1-macos.zip
```

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

## Recommended Setup

For production, start from the minimum setup and add:

- HTTPS for `app-archive.json`, `release.json`, and zip artifacts.
- Short cache TTLs for `app-archive.json`.
- Long, immutable cache TTLs for versioned `release.json` and zip files.
- S3-compatible storage, SFTP, or a custom upload command in CI.
- Platform publisher-trust gates before packaging.
- A release approval step before publishing `app-archive.json`.
- `release validate` after every upload.

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

What you must do before production packaging:

- Sign with a `Developer ID Application` identity.
- Enable hardened runtime.
- Notarize the signed app.
- Staple the notarization ticket.
- Verify Gatekeeper acceptance.
- Keep `CFBundleIdentifier` and Team ID stable across releases.
- Keep App Sandbox disabled for this whole-app replacement strategy.
- Ensure production entitlements do not include `get-task-allow`.

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
6. Download artifact bytes.
7. Verify exact length and SHA-256.
8. Print clear OK or failure lines.

Example:

```sh
dart run desktop_updater:release validate \
  --manifest dist/desktop_updater/.desktop_updater_publish.json
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
