# GitHub Actions CI/CD For Automatic Updates

This guide has two separate parts:

- this package repository CI, which verifies `desktop_updater` itself without secrets;
- your app repository CD, which builds, signs, packages, verifies, and publishes update artifacts.

Do not commit Apple API keys, signing certificates, private update-host credentials, Team IDs, bundle IDs, or runner keychain paths into a public repository. Put secrets in GitHub Actions secrets, and put non-secret per-app values in GitHub Actions variables or protected environment variables.

## Package Repository CI

The `desktop_updater` repository is ready for public, secretless CI through `.github/workflows/desktop-updater-ci.yml`.

It runs on push, pull request, and manual `workflow_dispatch`.

The workflow first classifies changed paths. Ordinary pushes and pull requests
run the Dart, release-CLI, documentation, and platform lanes that own the
changed files; unrelated native-host jobs are skipped. Changes to workflow
definitions, dependency/analysis inputs, or shared tooling set the `full`
classification and run the complete matrix. The release-key CLI changes in
3.1 normally exercise the focused `test/release_cli` suite and CLI candidate
matrix without waiting for unrelated Windows, macOS, and Linux host lanes.

`workflow_dispatch` and version-tag pushes intentionally override path
selection and run the full applicable matrix. Treat a selective green PR as
focused evidence only. Before publishing 3.1.0, run the workflow from the
release commit or tag and wait for every required full-matrix check to pass;
the path classifier must not be used to bypass a release gate. Keep the final
`Selective CI gate` status check required in branch protection so a selected
job cannot be silently ignored.

The package CI covers:

- synchronized Dart/Swift/C++/CMake/NuGet versions, generated native contract
  and install-helper fixtures, sealed helper-policy drift checks, Dart
  formatting, analysis, full tests, CLI entrypoints, and
  `dart pub publish --dry-run`;
- macOS SwiftPM helper tests, a named unprivileged crash-recovery suite, an
  external Flutter-free Swift consumer, and separate Flutter SwiftPM and
  CocoaPods fallback build/integration lanes;
- Windows debug and release builds, named helper trust, pipe-spoofing,
  transaction, and crash-recovery tests, integration tests, and two fresh
  Debug plus two fresh Release update smokes;
- Windows installed CMake and local NuGet consumers against the real shared
  DLL; the NuGet inventory includes the Release helper executable and sealed
  policy JSON alongside the native libraries;
- Linux protected-root and unprivileged helper/recovery tests, a privileged
  mount-namespace rejection test, installed CMake/pkg-config consumers,
  integration tests, and update smokes under `xvfb`.

Each secretless helper lane rejects zero-test discovery. It uploads a small
redacted count artifact with fixed `platform`, `suite`, and `testCount` fields;
raw helper diagnostics are not uploaded as merge-gate evidence.

### Standalone CLI candidate matrix

Native-host jobs compile and checksum these exact executable candidates:

```text
desktop-updater-macos-arm64
desktop-updater-macos-x64
desktop-updater-windows-x64.exe
desktop-updater-linux-x64
```

Each uploaded artifact includes its executable and `SHA256SUMS`. These outputs
are explicitly `candidate-only`: the matrix proves compilation, command
startup, architecture, and checksum generation, but does not substitute for
the approved production signing workflow. macOS and Windows public assets must
pass their repository signing/notarization policy after their final bytes are
built.

### Native SDK Target-Host Gates

Package contents are not accepted from source unit tests alone. The target-host
jobs must install or pack each helper, consume it from outside the source
target, and run the relevant native tests:

- macOS runs root `DesktopUpdaterKit` SwiftPM tests, an external SwiftPM
  executable, and both Flutter integration modes;
- Windows installs the CMake export, loads the shared C ABI DLL through the
  external CMake and .NET consumers, validates the NuGet package version and
  contents, and rejects a zero-test CTest run;
- Linux installs the CMake export and pkg-config metadata, checks the canonical
  version, runs the external consumer, proves protected roots fail closed, and
  rejects a zero-test CTest run.

The current native merge-gate configuration also contains the normal macOS,
Windows, and Linux ZIP runtime smokes; the exact CocoaPods macOS 10.14
six-source typecheck; both current Flutter macOS integration modes; Windows
Unicode paths and relative redirects; Release NuGet packing, notice checks,
isolated P/Invoke consumption, and DLL hash proof; and Linux standard plus
multiarch pkg-config consumers. Every CTest invocation rejects “No tests were
found.” These are configured gates, not `verified in CI` evidence until that
exact revision runs successfully on the named target host.

The standalone helpers now implement the transaction journal, cross-process
target lock, Windows reparse checks, Linux mount/bind checks, and crash
recovery. Implementation and workflow configuration are not execution
evidence: each candidate must pass the mandatory secretless Windows and Linux
target-host lanes for its exact helper head. Ordinary source scans, mocks, dry
runs, or unrelated CTest lanes must not be labeled as signed, elevated,
notarized, or recovery evidence.

Evidence must stay literal: unavailable credentials or hosts are `blocked` or
`not run`; unsigned executables are `candidate-only`; only completed required
target-host and publisher-trust gates can be called `production-ready`.

Windows and Linux update smoke tests pass an explicit helper diagnostics log
path to the example app. The workflow uploads that log only when the job has
failed, or when the repository variable
`DESKTOP_UPDATER_UPLOAD_SMOKE_DIAGNOSTICS` is set to `1` for an intentional
diagnostics run. The package does not upload helper logs by default.

The package CI intentionally does not publish app update artifacts. Automatic updates belong to the app that is shipping the update because that app owns the bundle ID, signing identity, notarization credentials, versioning, update hosting, and release approval policy.

The credential and privileged helper gates are separate manual jobs:

- `macos-smappservice-helper` runs on a separately provisioned self-hosted
  `desktop-updater-smappservice` runner when
  `DESKTOP_UPDATER_RUN_SMAPPSERVICE_E2E=1`. Its administrator-approved signed
  apps exercise the bundled root daemon/XPC recovery path. A separately
  provisioned root-owned runtime app and signed, notarized PKG then exercise
  the real `/Applications` installer handoff and verify the installed package
  receipt. Configure these non-secret absolute target-host values:
  `DESKTOP_UPDATER_SMAPPSERVICE_SMOKE_APP`,
  `DESKTOP_UPDATER_SMAPPSERVICE_SMOKE_STAGED_APP`,
  `DESKTOP_UPDATER_SMAPPSERVICE_PKG_SMOKE_APP`,
  `DESKTOP_UPDATER_SMAPPSERVICE_PKG_SMOKE_ARTIFACT`,
  `DESKTOP_UPDATER_SMAPPSERVICE_PKG_RECEIPT_ID`,
  `DESKTOP_UPDATER_SMAPPSERVICE_PKG_EXPECTED_VERSION`, and
  `DESKTOP_UPDATER_SMAPPSERVICE_PKG_EXPECTED_BUILD`. The PKG runtime app must
  be installed directly under `/Applications`, start at `2.7.0+270`, use the
  `MacOSRuntimeCompile` executable, remain root-owned, and have its bundled
  daemon approved before dispatch. Its PKG must install the same app as the
  configured `2.7.1+271` target and preserve stapled trust. The
  `macos-notarized` hosted job separately owns Developer ID/notary credentials
  and proves the exact approval-required result; it is not privileged install
  success evidence.
- `windows-elevated-helper` runs only on a self-hosted
  `desktop-updater-uac` runner when
  `DESKTOP_UPDATER_RUN_ELEVATED_HELPER_E2E=1`. It signs the fixed Release
  helper, verifies Authenticode, and exercises the interactive UAC boundary.
- `linux-polkit-helper` runs only on a self-hosted
  `desktop-updater-polkit` runner when
  `DESKTOP_UPDATER_RUN_POLKIT_HELPER_E2E=1`. The runner needs CMake, OpenSSL,
  `jq`, polkit with an interactive authentication agent, and passwordless
  `sudo` for bounded fixture setup, static audit, and cleanup only. The job
  builds a test-only caller and crash-injection helper, seals the actual
  helper/caller SHA-256 values and deterministic test Ed25519 public key into
  the root-owned package policy, and audits the fixed installed bytes
  separately. Its non-root step then uses the public native API and `pkexec`
  fixed broker to mutate a protected root-owned target, query completed durable
  state, kill the helper exactly after the target-to-backup rename, and prove a
  fresh broker converges recovery. Configuration is not execution evidence;
  this lane remains `not run` until that self-hosted job passes for the current
  head.

The signed/notarized DMG and PKG smokes still need Developer ID Application,
Developer ID Installer, keychain, and notary credentials. Signed Windows
artifact smokes still need their explicit Windows signing credentials. When a
variable, credential, or required host is unavailable, the lane is `not run`;
no ordinary job substitutes for publisher-trust or production-ready evidence.

## App Repository CD

Use an app-owned workflow when you want CI/CD to publish real desktop updates.

Recommended high-level flow:

1. Trigger the workflow from a version tag such as `v3.1.0`, or from a protected manual `workflow_dispatch`.
2. Apply the platform publisher-authenticity layer, such as macOS signing, notarization, and stapling before packaging.
3. Import the encrypted release-key bundle into the runner's protected local
   key store, then run `dart run desktop_updater:release publish --platform
   macos`. The command uses the default `desktop_updater.keys.json` public
   profile. CI must not receive a raw
   private key through an environment variable or file; the bundle passphrase
   is the only signing secret supplied to the import step.
4. Let the command upload versioned files first, validate hosted `release.json` and artifact bytes, upload `app-archive.json` last, and validate hosted update selection.
5. Only then mark the release as published.

For atomic publishing, upload versioned artifacts first, verify them, and update `app-archive.json` last. If a CDN is in front of the bucket, avoid byte transformations and keep cache TTLs short for `app-archive.json`.

The lower-level `package`, `app_archive`, and `verify` commands remain useful
for custom pipelines that need to own every upload step.

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

For Linux direct zip distribution, restore the encrypted release-key bundle and
use the profile-backed `release publish`, `release sign`, or `verify` commands
before treating the lane as production-trusted. Do not add raw release-key
environment variables; the 3.1 CLI does not accept direct private/public key
inputs.

```text
DESKTOP_UPDATER_KEY_BUNDLE_PASSPHRASE
```

The current 3.1 package CI proves Linux and Windows release mechanics. Publisher trust for Windows and Linux depends on the app's release policy and credentials.

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

## macOS Advanced Low-Level CD Skeleton

This is a low-level skeleton for an app repository that needs to own each
packaging and upload step. Most apps should start with the signed
`dart run desktop_updater:release publish --platform macos` flow and only drop
down to these commands when
their release workflow needs that control.

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

      - name: Update app archive metadata
        run: |
          RELEASE_JSON_URL="${{ vars.UPDATE_BASE_URL }}/releases/$RELEASE_VERSION/macos/release.json"

          # If this is not the first release, restore the currently published
          # app-archive.json to dist/app-archive.json before this step.
          dart run desktop_updater:app_archive upsert \
            --archive dist/app-archive.json \
            --app-name "${{ vars.APP_NAME }}" \
            --version "$RELEASE_VERSION" \
            --build-number "$RELEASE_BUILD_NUMBER" \
            --platform macos \
            --channel "${{ vars.UPDATE_CHANNEL }}" \
            --release-url "$RELEASE_JSON_URL"

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
          dart run desktop_updater:verify \
            --release "$RUNNER_TEMP/release.json"

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
      "version": "3.1.0",
      "buildNumber": 310,
      "platform": "macos",
      "channel": "stable",
      "release": "https://updates.example.com/releases/3.1.0/macos/release.json"
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
dart run desktop_updater:verify \
  --release dist/$VERSION/windows/release.json
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
dart run desktop_updater:verify \
  --release dist/$VERSION/linux/release.json
```

Unsigned Windows and Linux Release builds are release-mechanics ready when build, packaging, download, SHA-256 verification, extraction, staging, and smoke tests pass. Treat them as production-trusted only after you add the signing or descriptor-authenticity gate your app requires.

## Safe Public Repository Rules

- Never commit `.p8`, `.p12`, `.pfx`, private keys, generated keychains, real API key IDs, issuer IDs, certificate passwords, or bucket credentials.
- Do not echo secrets in scripts; use `set -euo pipefail` without `set -x`.
- Use protected GitHub environments for production update publishing.
- Use exact versioned artifact URLs and do not mutate a zip after `release.json` is generated.
- Publish `app-archive.json` last and keep its cache TTL low.
- Re-run `dart run desktop_updater:verify` against hosted URLs before announcing an update.
