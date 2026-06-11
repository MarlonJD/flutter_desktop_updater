# GitHub Actions CI/CD For Automatic Updates

This guide has two separate parts:

- this package repository CI, which verifies `desktop_updater` itself without secrets;
- your app repository CD, which builds, signs, packages, verifies, and publishes update artifacts.

Do not commit Apple API keys, signing certificates, private update-host credentials, Team IDs, bundle IDs, or runner keychain paths into a public repository. Put secrets in GitHub Actions secrets, and put non-secret per-app values in GitHub Actions variables or protected environment variables.

## Package Repository CI

The `desktop_updater` repository is ready for public, secretless CI through `.github/workflows/desktop-updater-ci.yml`.

It runs on push, pull request, and manual `workflow_dispatch`.

The package CI covers:

- Dart formatting, analysis, tests, CLI entrypoints, and `dart pub publish --dry-run`;
- Windows debug and release builds, native tests, integration tests, and update smoke tests;
- Linux debug and release builds, native tests, integration tests, and update smoke tests under `xvfb`.

The package CI intentionally does not publish app update artifacts. Automatic updates belong to the app that is shipping the update because that app owns the bundle ID, signing identity, notarization credentials, versioning, update hosting, and release approval policy.

## App Repository CD

Use an app-owned workflow when you want CI/CD to publish real desktop updates.

Recommended flow:

1. Trigger the workflow from a version tag such as `v2.0.0`, or from a protected manual `workflow_dispatch`.
2. Build the Flutter desktop app in Release mode.
3. Apply the platform publisher-authenticity layer.
4. Package the exact artifact with `dart run desktop_updater:package`.
5. Upload the zip artifact and `release.json` to stable, exact URLs.
6. Update `app-archive.json` to point at the new `release.json`.
7. Run `dart run desktop_updater:verify --release <release.json>` against the same descriptor and artifact clients will download.
8. Only then mark the release as published.

For atomic publishing, upload versioned artifacts first, verify them, and update `app-archive.json` last. If a CDN is in front of the bucket, avoid byte transformations and keep cache TTLs short for `app-archive.json`.

## Required Configuration

Use repository or environment variables for values that are not secret:

```text
APP_NAME
APP_PACKAGE_ID
APP_BUNDLE_ID
UPDATE_CHANNEL
UPDATE_BASE_URL
```

Use GitHub Actions secrets for private values:

```text
APPLE_DEVELOPER_ID_CERTIFICATE_P12_BASE64
APPLE_DEVELOPER_ID_CERTIFICATE_PASSWORD
APPLE_DEVELOPER_ID_APPLICATION
APPLE_API_KEY_ID
APPLE_API_ISSUER_ID
APPLE_API_PRIVATE_KEY_P8_BASE64
MACOS_KEYCHAIN_PASSWORD
UPDATE_HOST_ACCESS_KEY_ID
UPDATE_HOST_SECRET_ACCESS_KEY
UPDATE_HOST_BUCKET
UPDATE_HOST_ENDPOINT_URL
```

`APPLE_DEVELOPER_ID_APPLICATION` is often not confidential by itself, but keeping it in secrets avoids exposing personal or organization identity strings in a public workflow.

For Windows production-trusted direct distribution, add signing credentials when you are ready to sign `.exe` and `.dll` files:

```text
WINDOWS_CERTIFICATE_PFX_BASE64
WINDOWS_CERTIFICATE_PASSWORD
WINDOWS_TIMESTAMP_URL
```

For Linux direct zip distribution, add a release descriptor authenticity layer before treating the lane as production-trusted:

```text
DESKTOP_UPDATER_RELEASE_SIGNING_PRIVATE_KEY
DESKTOP_UPDATER_RELEASE_SIGNING_PUBLIC_KEY
```

The current 2.0 package CI proves Linux and Windows release mechanics. Publisher trust for Windows and Linux depends on the app's release policy and credentials.

## macOS Signing And Notarization

macOS production-trusted direct distribution requires:

- Release build;
- stable `CFBundleIdentifier`;
- stable Apple Team ID across releases;
- `Developer ID Application` signing identity;
- hardened runtime;
- notarization through App Store Connect API credentials;
- stapling before zipping the final app;
- Gatekeeper assessment after stapling.

In CI, create an ephemeral keychain and pass that same keychain to every command that stores or uses credentials. This is the CI equivalent of the local rule: if `store-credentials` prints a `--keychain` value, use that value again with `--keychain-profile`.

Example setup:

```yaml
- name: Import Developer ID certificate
  shell: bash
  run: |
    set -euo pipefail
    KEYCHAIN="$RUNNER_TEMP/build.keychain-db"
    CERTIFICATE="$RUNNER_TEMP/developer-id.p12"

    echo "${{ secrets.APPLE_DEVELOPER_ID_CERTIFICATE_P12_BASE64 }}" | base64 --decode > "$CERTIFICATE"
    security create-keychain -p "${{ secrets.MACOS_KEYCHAIN_PASSWORD }}" "$KEYCHAIN"
    security set-keychain-settings -lut 21600 "$KEYCHAIN"
    security unlock-keychain -p "${{ secrets.MACOS_KEYCHAIN_PASSWORD }}" "$KEYCHAIN"
    security import "$CERTIFICATE" \
      -k "$KEYCHAIN" \
      -P "${{ secrets.APPLE_DEVELOPER_ID_CERTIFICATE_PASSWORD }}" \
      -T /usr/bin/codesign
    security set-key-partition-list \
      -S apple-tool:,apple:,codesign: \
      -s \
      -k "${{ secrets.MACOS_KEYCHAIN_PASSWORD }}" \
      "$KEYCHAIN"
    echo "MACOS_BUILD_KEYCHAIN=$KEYCHAIN" >> "$GITHUB_ENV"
```

Store the App Store Connect API key in the runner only:

```yaml
- name: Configure notary profile
  shell: bash
  run: |
    set -euo pipefail
    API_KEY="$RUNNER_TEMP/AuthKey.p8"
    echo "${{ secrets.APPLE_API_PRIVATE_KEY_P8_BASE64 }}" | base64 --decode > "$API_KEY"
    chmod 600 "$API_KEY"

    xcrun notarytool store-credentials desktop-updater-notary \
      --key "$API_KEY" \
      --key-id "${{ secrets.APPLE_API_KEY_ID }}" \
      --issuer "${{ secrets.APPLE_API_ISSUER_ID }}" \
      --keychain "$MACOS_BUILD_KEYCHAIN" \
      --validate
```

When submitting, pass both the profile and the same keychain:

```sh
xcrun notarytool submit "$ZIP_PATH" \
  --keychain-profile desktop-updater-notary \
  --keychain "$MACOS_BUILD_KEYCHAIN" \
  --wait
```

If CI fails with `No Keychain password item found`, the profile was not read from the same keychain where it was stored, or the keychain was locked/removed. Recreate the profile in the current runner keychain and pass both `--keychain-profile` and `--keychain` consistently.

## macOS CD Skeleton

This is a skeleton for an app repository. Replace placeholders with your app's paths and upload provider.

```yaml
name: Publish desktop update

on:
  workflow_dispatch:
    inputs:
      version:
        description: Release version
        required: true
      build_number:
        description: Monotonic build number
        required: true
  push:
    tags:
      - "v*"

permissions:
  contents: read

jobs:
  macos:
    runs-on: macos-latest
    environment: production-updates
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
        with:
          channel: stable

      - name: Install dependencies
        run: flutter pub get

      - name: Resolve release metadata
        shell: bash
        run: |
          set -euo pipefail
          VERSION="${{ inputs.version }}"
          BUILD_NUMBER="${{ inputs.build_number }}"

          if [ -z "$VERSION" ]; then
            VERSION="${GITHUB_REF_NAME#v}"
          fi

          if [ -z "$BUILD_NUMBER" ]; then
            BUILD_NUMBER="$GITHUB_RUN_NUMBER"
          fi

          echo "RELEASE_VERSION=$VERSION" >> "$GITHUB_ENV"
          echo "RELEASE_BUILD_NUMBER=$BUILD_NUMBER" >> "$GITHUB_ENV"

      - name: Build Release app
        run: |
          flutter build macos --release \
            --build-name "$RELEASE_VERSION" \
            --build-number "$RELEASE_BUILD_NUMBER"

      - name: Import signing certificate
        run: ./tool/ci/import_macos_certificate.sh
        env:
          APPLE_DEVELOPER_ID_CERTIFICATE_P12_BASE64: ${{ secrets.APPLE_DEVELOPER_ID_CERTIFICATE_P12_BASE64 }}
          APPLE_DEVELOPER_ID_CERTIFICATE_PASSWORD: ${{ secrets.APPLE_DEVELOPER_ID_CERTIFICATE_PASSWORD }}
          MACOS_KEYCHAIN_PASSWORD: ${{ secrets.MACOS_KEYCHAIN_PASSWORD }}

      - name: Sign app
        run: |
          codesign --force --deep --options runtime --timestamp \
            --sign "${{ secrets.APPLE_DEVELOPER_ID_APPLICATION }}" \
            "build/macos/Build/Products/Release/${{ vars.APP_NAME }}.app"

      - name: Create notarization zip
        run: |
          /usr/bin/ditto -c -k --keepParent \
            "build/macos/Build/Products/Release/${{ vars.APP_NAME }}.app" \
            "$RUNNER_TEMP/notary.zip"

      - name: Configure notary profile
        run: ./tool/ci/configure_notary_profile.sh
        env:
          APPLE_API_PRIVATE_KEY_P8_BASE64: ${{ secrets.APPLE_API_PRIVATE_KEY_P8_BASE64 }}
          APPLE_API_KEY_ID: ${{ secrets.APPLE_API_KEY_ID }}
          APPLE_API_ISSUER_ID: ${{ secrets.APPLE_API_ISSUER_ID }}

      - name: Notarize and staple
        run: |
          xcrun notarytool submit "$RUNNER_TEMP/notary.zip" \
            --keychain-profile desktop-updater-notary \
            --keychain "$MACOS_BUILD_KEYCHAIN" \
            --wait
          xcrun stapler staple "build/macos/Build/Products/Release/${{ vars.APP_NAME }}.app"
          xcrun stapler validate "build/macos/Build/Products/Release/${{ vars.APP_NAME }}.app"
          spctl --assess --type execute --verbose=4 \
            "build/macos/Build/Products/Release/${{ vars.APP_NAME }}.app"

      - name: Package desktop_updater release
        run: |
          RELEASE_DIR="dist/$RELEASE_VERSION/macos"
          ARTIFACT_URL="${{ vars.UPDATE_BASE_URL }}/releases/$RELEASE_VERSION/macos/${{ vars.APP_NAME }}-$RELEASE_VERSION-macos.zip"

          dart run desktop_updater:package \
            --input "build/macos/Build/Products/Release/${{ vars.APP_NAME }}.app" \
            --output "$RELEASE_DIR" \
            --package-id "${{ vars.APP_BUNDLE_ID }}" \
            --app-name "${{ vars.APP_NAME }}" \
            --version "$RELEASE_VERSION" \
            --build-number "$RELEASE_BUILD_NUMBER" \
            --platform macos \
            --channel "${{ vars.UPDATE_CHANNEL }}" \
            --artifact-url "$ARTIFACT_URL"

      - name: Upload versioned files
        run: ./tool/ci/upload_update_files.sh
        env:
          UPDATE_HOST_ACCESS_KEY_ID: ${{ secrets.UPDATE_HOST_ACCESS_KEY_ID }}
          UPDATE_HOST_SECRET_ACCESS_KEY: ${{ secrets.UPDATE_HOST_SECRET_ACCESS_KEY }}
          UPDATE_HOST_BUCKET: ${{ secrets.UPDATE_HOST_BUCKET }}
          UPDATE_HOST_ENDPOINT_URL: ${{ secrets.UPDATE_HOST_ENDPOINT_URL }}

      - name: Verify hosted release
        run: |
          curl -fsS "${{ vars.UPDATE_BASE_URL }}/releases/$RELEASE_VERSION/macos/release.json" \
            -o "$RUNNER_TEMP/release.json"
          dart run desktop_updater:verify --release "$RUNNER_TEMP/release.json"

      - name: Publish app archive last
        run: ./tool/ci/publish_app_archive.sh
```

The upload scripts are app-specific because S3, Cloudflare R2, GCS, GitHub Releases, and private proxies all authenticate differently. Keep the rule the same regardless of provider: upload the zip and `release.json` first, verify the hosted descriptor, then publish `app-archive.json` last.

The final `app-archive.json` should point at the hosted descriptor, not at a folder:

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
      "release": "https://updates.example.com/releases/2.0.0/macos/release.json"
    }
  ]
}
```

## Windows And Linux CD

Windows and Linux can use the same `desktop_updater:package` and `desktop_updater:verify` pattern after their Release build.

Windows example:

```sh
flutter build windows --release
dart run desktop_updater:package \
  --input build/windows/x64/runner/Release \
  --output dist/$VERSION/windows \
  --package-id "$APP_PACKAGE_ID" \
  --app-name "$APP_NAME" \
  --version "$VERSION" \
  --build-number "$BUILD_NUMBER" \
  --platform windows \
  --channel "$UPDATE_CHANNEL" \
  --artifact-url "$UPDATE_BASE_URL/releases/$VERSION/windows/$APP_NAME-$VERSION-windows.zip"
dart run desktop_updater:verify --release dist/$VERSION/windows/release.json
```

Linux example:

```sh
flutter build linux --release
dart run desktop_updater:package \
  --input build/linux/x64/release/bundle \
  --output dist/$VERSION/linux \
  --package-id "$APP_PACKAGE_ID" \
  --app-name "$APP_NAME" \
  --version "$VERSION" \
  --build-number "$BUILD_NUMBER" \
  --platform linux \
  --channel "$UPDATE_CHANNEL" \
  --artifact-url "$UPDATE_BASE_URL/releases/$VERSION/linux/$APP_NAME-$VERSION-linux.zip"
dart run desktop_updater:verify --release dist/$VERSION/linux/release.json
```

Unsigned Windows and Linux Release builds are release-mechanics ready when build, packaging, download, SHA-256 verification, extraction, staging, and smoke tests pass. Treat them as production-trusted only after you add the signing or descriptor-authenticity gate your app requires.

## Safe Public Repository Rules

- Never commit `.p8`, `.p12`, `.pfx`, private keys, generated keychains, real API key IDs, issuer IDs, certificate passwords, or bucket credentials.
- Do not echo secrets in scripts; use `set -euo pipefail` without `set -x`.
- Use protected GitHub environments for production update publishing.
- Use exact versioned artifact URLs and do not mutate a zip after `release.json` is generated.
- Publish `app-archive.json` last and keep its cache TTL low.
- Re-run `dart run desktop_updater:verify` against hosted URLs before announcing an update.
