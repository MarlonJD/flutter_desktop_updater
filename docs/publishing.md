# Publishing Desktop Updates

## Quick Start

Add the minimum config to `desktop_updater.yaml`:

```yaml
updates:
  baseUrl: https://updates.example.com
```

Publish one platform:

```sh
dart run desktop_updater:release publish --platform macos
```

With only `updates.baseUrl`, the command builds and packages locally under
`dist/desktop_updater`, then prints manual upload instructions. With an upload
provider configured, it uploads versioned files first, validates the hosted
`release.json` and zip bytes, uploads `app-archive.json` last, then validates
the hosted update selection.

## How The Files Work EL10

Think of the update host as a shelf on the internet.

1. The developer runs `dart run desktop_updater:release publish --platform macos`.
2. The CLI reads the app version from `pubspec.yaml`, such as `2.0.1+201`.
3. The CLI builds the macOS app.
4. The CLI zips the app.
5. The CLI writes `release.json`, which says where the zip lives and what its hash is.
6. The CLI writes `app-archive.json`, which says macOS stable has version `2.0.1`.
7. If upload config exists, the CLI puts the files on the internet shelf.
8. If upload config does not exist, the CLI gives a clickable local folder link.
9. After upload, `release validate` pretends to be an older app.
10. It downloads `app-archive.json`, finds the update, downloads `release.json`, downloads the zip, checks the hash, and reports success or failure.

## Minimum Config

```yaml
updates:
  baseUrl: https://updates.example.com
```

`baseUrl` is the public HTTP(S) root users' apps can fetch. The command derives:

```text
https://updates.example.com/app-archive.json
https://updates.example.com/releases/2.0.1/macos/release.json
https://updates.example.com/releases/2.0.1/macos/Example-2.0.1-macos.zip
```

## Recommended Config

S3-compatible storage:

```yaml
updates:
  baseUrl: https://updates.example.com

s3:
  bucket: my-update-bucket
  prefix: updates
  region: eu-central-1
  profile: desktop-updater
```

S3-compatible storage with R2, MinIO, or a custom endpoint:

```yaml
updates:
  baseUrl: https://updates.example.com

s3:
  bucket: my-update-bucket
  prefix: updates
  region: auto
  endpoint: https://example-account.r2.cloudflarestorage.com
  pathStyle: true
  profile: desktop-updater-r2
```

SFTP:

```yaml
updates:
  baseUrl: https://updates.example.com

sftp:
  host: deploy.example.com
  remotePath: /var/www/updates
  username: deploy
```

FTP for legacy hosts only:

```yaml
updates:
  baseUrl: https://updates.example.com

ftp:
  host: ftp.example.com
  remotePath: /public_html/updates
  username: deploy
  allowInsecure: true
```

Custom command:

```yaml
updates:
  baseUrl: https://updates.example.com

customCommand:
  command: ./tool/upload_updates.sh
```

## Manual Upload

When no provider block is configured, `publish` prints:

```text
Manual publish package is ready.
Not uploaded yet.
```

Upload the contents of `dist/desktop_updater` to the configured `baseUrl`.
Do not change the relative paths.

## Validate After Manual Upload

Run:

```sh
dart run desktop_updater:release validate \
  --manifest dist/desktop_updater/.desktop_updater_publish.json
```

Use `--from-version` when you want to simulate a specific installed app:

```sh
dart run desktop_updater:release validate \
  --manifest dist/desktop_updater/.desktop_updater_publish.json \
  --from-version 2.0.0+200
```

Without `--from-version`, validation uses the previous hosted release for the
same platform and channel when available, or synthetic `0.0.0` for a first
release.

## Automatic Upload

Automatic providers upload versioned files first, validate hosted
`release.json` and artifact bytes, upload `app-archive.json` last, then run the
full hosted validation. This avoids clients seeing an update before its
descriptor and zip are reachable.

## Common Settings

```yaml
updates:
  baseUrl: https://updates.example.com
```

- `baseUrl` is required and must be the public HTTP(S) root.
- `output` defaults to `dist/desktop_updater`.
- `channel` defaults to `stable`.
- `version` and `buildNumber` default to `pubspec.yaml`.
- Credentials must be environment variables or standard local credential files, never `desktop_updater.yaml`.

CLI overrides:

```sh
dart run desktop_updater:release publish \
  --platform macos \
  --base-url https://updates.example.com \
  --channel stable
```

## macOS Settings

```sh
dart run desktop_updater:release publish --platform macos
```

The command runs `flutter build macos --release`, packages the Release `.app`
with macOS-safe zip behavior, and uses `wholeBundleReplace`.

Production-trusted updates require Developer ID signing, hardened runtime,
notarization, stapling, and Gatekeeper acceptance before packaging.

## Windows Settings

```sh
dart run desktop_updater:release publish --platform windows
```

The command runs `flutter build windows --release`, packages the Release runner
directory, and uses `wholeDirectoryReplace`.

Authenticode signing is recommended for production trust.

## Linux Settings

```sh
dart run desktop_updater:release publish --platform linux
```

The command runs `flutter build linux --release`, packages
`build/linux/x64/release/bundle`, and uses `wholeDirectoryReplace`.

Descriptor signing or another publisher-authenticity policy is recommended for
production trust.

## S3-Compatible Upload

Use S3 config for AWS S3, Cloudflare R2, MinIO, or compatible APIs:

```yaml
updates:
  baseUrl: https://updates.example.com

s3:
  bucket: my-update-bucket
  prefix: updates
  region: eu-central-1
  profile: desktop-updater
```

Credentials use the standard AWS chain:

- `s3.profile` when set;
- `AWS_PROFILE` when set;
- default local AWS profile;
- `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, and optional `AWS_SESSION_TOKEN` in CI.

The first transport uses `aws s3 cp` with `--profile` and `--endpoint-url` when
configured.

## SFTP Upload

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

## FTP Upload

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

## Custom Command Upload

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

## CI Example

```sh
flutter test --no-pub test/e2e/release_publish_manual_e2e_test.dart
flutter test --no-pub test/e2e/release_publish_custom_command_e2e_test.dart
DESKTOP_UPDATER_RUN_RELEASE_PUBLISH_E2E=1 AWS_ACCESS_KEY_ID=minioadmin AWS_SECRET_ACCESS_KEY=minioadmin AWS_DEFAULT_REGION=us-east-1 flutter test --no-pub test/e2e/release_publish_s3_e2e_test.dart
DESKTOP_UPDATER_RUN_RELEASE_PUBLISH_E2E=1 flutter test --no-pub test/e2e/release_publish_sftp_e2e_test.dart
DESKTOP_UPDATER_RUN_RELEASE_PUBLISH_E2E=1 flutter test --no-pub test/e2e/release_publish_ftp_e2e_test.dart
```

When running the Docker-backed provider e2e files in one command, add
`--concurrency=1` because they share one local docker-compose project.

## Troubleshooting

- `updates.baseUrl is required`: add `updates.baseUrl` or pass `--base-url`.
- `Update selection failed`: confirm `app-archive.json` was uploaded last and points at the expected `release.json`.
- `Artifact SHA-256 mismatch`: confirm the CDN or proxy is not transforming zip bytes.
- `AWS CLI executable not found`: install `aws` or use another provider.
- `ftp.allowInsecure: true is required`: use SFTP/S3, or explicitly opt in for a legacy FTP host.
- Long `Cache-Control` on `app-archive.json`: keep index caching short so clients see newly published releases promptly.
