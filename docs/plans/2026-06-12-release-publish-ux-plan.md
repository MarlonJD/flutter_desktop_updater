# Release Publish UX Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a high-level `desktop_updater:release publish` and `desktop_updater:release validate` UX that builds a platform release, creates upload-ready zip-first metadata, optionally uploads it, validates the hosted update path, and explains manual upload clearly when no provider is configured.

**Architecture:** Keep existing `package`, `app_archive`, and `verify` commands as low-level building blocks, then add a higher-level release orchestration layer with small focused units: config loading, Flutter project metadata resolution, platform build output resolution, dist layout planning, upload providers, hosted validation, and documentation. `publish` always produces the same local `dist/desktop_updater` layout first; upload providers only move those files to a host. `validate` simulates an older installed version with the same release-selection logic used by runtime update checks, then fetches hosted metadata and artifact bytes to prove the upload is usable.

**Tech Stack:** Dart 3.6+, Flutter CLI, existing `ReleaseIndex`, `ReleaseDescriptor`, `ZipReleasePackager`, `ArtifactVerifier`, `pubspec_parse`, `http`, `path`, optional upload dependencies or process-backed adapters, local Docker-backed e2e services for MinIO/S3, FTP, and SFTP, Flutter tests via `flutter test --no-pub`.

---

## Non-Negotiable Constraints

- Do not create, switch, rename, delete, or otherwise operate on branches unless the user explicitly asks for that branch action in the same execution turn.
- Do not post GitHub comments or review feedback through any Codex/GitHub connector identity.
- Do not commit, push, publish to pub.dev, or run real remote uploads unless the user explicitly asks in the execution turn.
- Keep canonical docs, file names, type names, method names, JSON field names, and source comments in English.
- Keep config minimal. Do not duplicate `pubspec.yaml` or platform project metadata in `desktop_updater.yaml` unless the CLI cannot reliably infer the value and an override is necessary.
- Keep credentials out of config. Passwords, access keys, secret keys, private keys, and tokens must come from environment variables, key files outside the repository, or an interactive prompt that does not echo.
- Plain FTP must be opt-in with `allowInsecure: true`; SFTP or S3-compatible upload should be preferred in docs.
- `updates.baseUrl` is required for `release publish`, even without auto-upload, because generated `app-archive.json` and `release.json` must contain final public URLs.
- If no upload provider is configured, `publish` must not imply that remote publication happened. It must say `Manual publish package is ready. Not uploaded yet.`
- If an upload provider is configured, `publish` must upload versioned files first, validate hosted `release.json` and artifact bytes, upload `app-archive.json` last, then run full hosted validation.
- `release validate` must work after manual upload from a generated publish manifest and must not require rebuilding an old app.
- Do not automatically build old app versions. Validate update availability by simulating an older installed version against hosted `app-archive.json`.
- Use `flutter test --no-pub` for normal validation to avoid `example/pubspec.lock` churn.

## Product UX Decisions

The public happy path is one command:

```sh
dart run desktop_updater:release publish --platform macos
```

If upload config exists, the command does:

```text
build -> package -> write dist layout -> upload versioned files -> validate release.json/artifact -> upload app-archive.json -> full hosted validate
```

If upload config does not exist, the command does:

```text
build -> package -> write dist layout -> print clickable local folder -> print validate command -> link docs for automatic upload
```

Manual output must look like this:

```text
Manual publish package is ready.
Not uploaded yet.

Upload this folder contents to your update host:
file:///Users/me/MyApp/dist/desktop_updater/

Expected remote root:
https://updates.example.com/

After upload, validate:
dart run desktop_updater:release validate --manifest dist/desktop_updater/.desktop_updater_publish.json

Want automatic upload next time?
See docs/publishing.md
```

Auto-upload output must look like this:

```text
Building macOS release...
Packaging update...
Uploading versioned files...
Validating hosted release descriptor...
Publishing app-archive.json last...
Validating hosted update selection...

OK: Published and validated.

App archive:
https://updates.example.com/app-archive.json

Release:
https://updates.example.com/releases/2.0.1/macos/release.json

Artifact:
https://updates.example.com/releases/2.0.1/macos/Example-2.0.1-macos.zip
```

## Minimum Config

Only the public update root is required:

```yaml
updates:
  baseUrl: https://updates.example.com
```

With only this config, `publish` prepares `dist/desktop_updater` and prints manual upload + validate instructions. It does not upload.

CLI flags can override minimum config:

```sh
dart run desktop_updater:release publish \
  --platform macos \
  --base-url https://updates.example.com
```

## Recommended Config

Recommended S3-compatible config:

```yaml
updates:
  baseUrl: https://updates.example.com

s3:
  bucket: my-update-bucket
  prefix: updates
  region: eu-central-1
  profile: desktop-updater
```

`profile` is optional. If omitted, the uploader uses the standard AWS credential chain: `AWS_PROFILE`, the default local AWS profile, environment variables, and any supported session or role credentials.

Recommended S3-compatible config for Cloudflare R2, MinIO, or custom endpoints:

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

Recommended SFTP config:

```yaml
updates:
  baseUrl: https://updates.example.com

sftp:
  host: deploy.example.com
  remotePath: /var/www/updates
  username: deploy
```

FTP config is supported for legacy hosts only:

```yaml
updates:
  baseUrl: https://updates.example.com

ftp:
  host: ftp.example.com
  remotePath: /public_html/updates
  username: deploy
  allowInsecure: true
```

Custom command config:

```yaml
updates:
  baseUrl: https://updates.example.com

customCommand:
  command: ./tool/upload_updates.sh
```

Credentials are not written to config. S3-compatible upload should use the local AWS profile or standard AWS credential chain by default; environment variables are mainly for CI/headless use. FTP and SFTP secrets remain environment variables:

```sh
AWS_PROFILE=desktop-updater
AWS_ACCESS_KEY_ID=...
AWS_SECRET_ACCESS_KEY=...
DESKTOP_UPDATER_SFTP_PASSWORD=...
DESKTOP_UPDATER_SFTP_PRIVATE_KEY=/Users/me/.ssh/deploy_key
DESKTOP_UPDATER_FTP_PASSWORD=...
```

## EL10 Working Scenario

Think of the update host as a shelf on the internet.

1. The developer runs `dart run desktop_updater:release publish --platform macos`.
2. The CLI reads the app version from `pubspec.yaml`, such as `2.0.1+201`.
3. The CLI builds the macOS app.
4. The CLI zips the app.
5. The CLI writes `release.json`, which says where the zip lives and what its hash is.
6. The CLI writes `app-archive.json`, which says "macOS stable has version 2.0.1, go read this release.json".
7. If upload config exists, the CLI puts the files on the internet shelf.
8. If upload config does not exist, the CLI gives a clickable local folder link and says "upload this folder".
9. After upload, `release validate` pretends to be an older app.
10. It downloads `app-archive.json`, finds the update, downloads `release.json`, finds the zip, downloads the zip, checks the hash, and says whether update publishing is correct.

## Target Dist Layout

Every provider uploads this exact tree:

```text
dist/desktop_updater/
  .desktop_updater_publish.json
  app-archive.json
  releases/
    2.0.1/
      macos/
        release.json
        Example-2.0.1-macos.zip
```

Remote URLs are derived from `updates.baseUrl`:

```text
https://updates.example.com/app-archive.json
https://updates.example.com/releases/2.0.1/macos/release.json
https://updates.example.com/releases/2.0.1/macos/Example-2.0.1-macos.zip
```

The publish manifest records exactly what was produced:

```json
{
  "schemaVersion": 1,
  "baseUrl": "https://updates.example.com/",
  "localRoot": "dist/desktop_updater",
  "appArchive": {
    "path": "app-archive.json",
    "url": "https://updates.example.com/app-archive.json"
  },
  "release": {
    "version": "2.0.1",
    "buildNumber": 201,
    "platform": "macos",
    "channel": "stable",
    "path": "releases/2.0.1/macos/release.json",
    "url": "https://updates.example.com/releases/2.0.1/macos/release.json"
  },
  "artifact": {
    "path": "releases/2.0.1/macos/Example-2.0.1-macos.zip",
    "url": "https://updates.example.com/releases/2.0.1/macos/Example-2.0.1-macos.zip",
    "sha256": "64-lowercase-hex-characters",
    "length": 12345678
  }
}
```

## File Structure

- Create: `bin/release.dart`
  - Public high-level CLI entrypoint with `publish` and `validate` subcommands.
- Create: `lib/src/release_cli/release_command.dart`
  - Parses subcommands and routes to publish or validate command handlers.
- Create: `lib/src/release_cli/publish_command.dart`
  - Orchestrates config loading, metadata resolution, build, packaging, local dist output, optional upload, and validation.
- Create: `lib/src/release_cli/validate_command.dart`
  - Validates hosted update selection and artifact bytes from a publish manifest.
- Create: `lib/src/release_cli/release_publish_config.dart`
  - Loads `desktop_updater.yaml`, applies CLI overrides, validates minimal config, and exposes provider config.
- Create: `lib/src/release_cli/project_metadata_resolver.dart`
  - Reads `pubspec.yaml` and platform project files to infer version, build number, app name, package id, and build output paths.
- Create: `lib/src/release_cli/platform_release_profile.dart`
  - Defines platform-specific defaults for build command, build output, install strategy, app name, and package id.
- Create: `lib/src/release_cli/publish_layout.dart`
  - Computes local paths and public URLs for `dist/desktop_updater`.
- Create: `lib/src/release_cli/publish_manifest.dart`
  - Reads and writes `.desktop_updater_publish.json`.
- Create: `lib/src/release_cli/release_publisher.dart`
  - Shared orchestration API used by `publish_command.dart`.
- Create: `lib/src/release_cli/upload/upload_provider.dart`
  - Defines provider interface and upload result contract.
- Create: `lib/src/release_cli/upload/manual_upload_provider.dart`
  - Reports local upload folder and validation instructions.
- Create: `lib/src/release_cli/upload/s3_upload_provider.dart`
  - Uploads to S3-compatible storage.
- Create: `lib/src/release_cli/upload/sftp_upload_provider.dart`
  - Uploads to SFTP.
- Create: `lib/src/release_cli/upload/ftp_upload_provider.dart`
  - Uploads to FTP only when `allowInsecure: true`.
- Create: `lib/src/release_cli/upload/custom_command_upload_provider.dart`
  - Runs a local command with publish manifest environment variables.
- Modify: `lib/src/package/app_archive_writer.dart`
  - Reuse in publish flow; add helper only if needed for remote index merge behavior.
- Modify: `bin/package.dart`
  - No behavior change; keep as low-level command.
- Modify: `bin/app_archive.dart`
  - No behavior change; keep as low-level command.
- Modify: `README.md`
  - Add short happy-path explanation and point to `docs/publishing.md`.
- Create: `docs/publishing.md`
  - Full usage guide with common settings, platform settings, provider settings, recommended settings, validation, and troubleshooting.
- Create: `test/release_cli/release_publish_config_test.dart`
- Create: `test/release_cli/project_metadata_resolver_test.dart`
- Create: `test/release_cli/publish_layout_test.dart`
- Create: `test/release_cli/publish_manifest_test.dart`
- Create: `test/release_cli/release_validate_test.dart`
- Create: `test/release_cli/release_command_test.dart`
- Create: `test/release_cli/upload/manual_upload_provider_test.dart`
- Create: `test/release_cli/upload/custom_command_upload_provider_test.dart`
- Create: `test/e2e/release_publish_manual_e2e_test.dart`
- Create: `test/e2e/release_publish_s3_e2e_test.dart`
- Create: `test/e2e/release_publish_ftp_e2e_test.dart`
- Create: `test/e2e/release_publish_sftp_e2e_test.dart`
- Create: `test/e2e/release_publish_custom_command_e2e_test.dart`
- Create: `test/e2e/fixtures/release_publish_test_app/`
  - Minimal Flutter desktop app fixture, or a generated fixture helper if keeping a fixture app in the repo is too heavy.
- Create: `test/e2e/fixtures/upload_commands/copy_updates.dart`
  - Custom command fixture that copies local dist files to a local web root.
- Create: `test/e2e/docker/docker-compose.release-publish.yml`
  - Optional local MinIO, FTP, SFTP, and static HTTP services for e2e tests.

## Confirmed Execution Decisions

The first implementation can run unit tests without real external credentials. The user confirmed these execution decisions on 2026-06-12:

- Docker is approved for local MinIO, FTP, and SFTP e2e services.
- Docker image pulls are approved when required for local e2e.
- FTP is included in v1, guarded by `allowInsecure: true`.
- S3-compatible e2e targets local MinIO first.
- Optional real S3/R2 smoke tests are out of scope for v1 and can be added behind an explicit profile/config/env gate after the MinIO path is stable.
- The detailed guide path is `docs/publishing.md`.
- Upload credentials are non-interactive in v1. S3-compatible upload uses the standard AWS credential chain, including explicit `s3.profile`, `AWS_PROFILE`, default local profile, or CI environment variables. FTP and SFTP secrets use environment variables. Do not add interactive password prompts in the first implementation.

No real production bucket, FTP host, SFTP host, or secrets are required for the local e2e design. Local e2e may use fixed throwaway credentials inside Docker-only services, for example:

```text
MinIO: DESKTOP_UPDATER_E2E_S3_ACCESS_KEY=minioadmin
MinIO: DESKTOP_UPDATER_E2E_S3_SECRET_KEY=minioadmin
SFTP: DESKTOP_UPDATER_SFTP_PASSWORD=desktop-updater-test
FTP: DESKTOP_UPDATER_FTP_PASSWORD=desktop-updater-test
```

These values must only be used against local test services. Production S3/R2 credentials should come from an AWS profile or the standard AWS credential chain. Production FTP and SFTP secrets must come from the user's environment. Secrets must never be written into `desktop_updater.yaml`.

## Task 1: Release Publish Config

**Files:**
- Create: `lib/src/release_cli/release_publish_config.dart`
- Test: `test/release_cli/release_publish_config_test.dart`

- [x] **Step 1: Write failing tests for minimum config**

```dart
import "dart:io";

import "package:desktop_updater/src/release_cli/release_publish_config.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;

void main() {
  test("loads minimum updates baseUrl config", () async {
    final tempDir = await Directory.systemTemp.createTemp("release_config_");
    try {
      final configFile = File(path.join(tempDir.path, "desktop_updater.yaml"));
      await configFile.writeAsString("""
updates:
  baseUrl: https://updates.example.com
""");

      final config = await ReleasePublishConfig.load(
        projectRoot: tempDir,
        cliOverrides: const ReleasePublishOverrides(),
      );

      expect(config.baseUrl.toString(), "https://updates.example.com/");
      expect(config.uploadProvider, isA<ManualUploadConfig>());
      expect(config.outputDirectory.path, path.join(tempDir.path, "dist", "desktop_updater"));
      expect(config.channel, "stable");
    } finally {
      await tempDir.delete(recursive: true);
    }
  });

  test("rejects missing baseUrl", () async {
    final tempDir = await Directory.systemTemp.createTemp("release_config_");
    try {
      await expectLater(
        ReleasePublishConfig.load(
          projectRoot: tempDir,
          cliOverrides: const ReleasePublishOverrides(),
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            "message",
            contains("updates.baseUrl is required"),
          ),
        ),
      );
    } finally {
      await tempDir.delete(recursive: true);
    }
  });
}
```

- [x] **Step 2: Run test to verify it fails**

Run:

```sh
flutter test --no-pub test/release_cli/release_publish_config_test.dart
```

Expected: fails because `release_publish_config.dart` does not exist.

- [x] **Step 3: Implement config loader**

Create `ReleasePublishConfig`, `ReleasePublishOverrides`, `UploadConfig`, `ManualUploadConfig`, `S3UploadConfig`, `SftpUploadConfig`, `FtpUploadConfig`, and `CustomCommandUploadConfig`.

Key requirements:

- Read `desktop_updater.yaml` from project root by default.
- Accept `--config` path through `ReleasePublishOverrides`.
- Normalize `updates.baseUrl` with a trailing slash.
- Default `outputDirectory` to `<projectRoot>/dist/desktop_updater`.
- Default `channel` to `stable`.
- Use manual upload when no provider block exists.
- Reject `ftp` unless `allowInsecure: true`.
- Reject multiple upload provider blocks in one file.

- [x] **Step 4: Run test to verify it passes**

Run:

```sh
flutter test --no-pub test/release_cli/release_publish_config_test.dart
```

Expected: all config tests pass.

## Task 2: Project Metadata And Platform Profiles

**Files:**
- Create: `lib/src/release_cli/project_metadata_resolver.dart`
- Create: `lib/src/release_cli/platform_release_profile.dart`
- Test: `test/release_cli/project_metadata_resolver_test.dart`

- [x] **Step 1: Write failing tests for pubspec version parsing**

```dart
test("resolves version and build number from pubspec", () async {
  final fixture = await createReleaseFixture(
    pubspecVersion: "2.0.1+201",
    platform: "macos",
  );

  final metadata = await ProjectMetadataResolver().resolve(
    projectRoot: fixture.root,
    platform: "macos",
    overrides: const ReleasePublishOverrides(),
  );

  expect(metadata.version, "2.0.1");
  expect(metadata.buildNumber, 201);
});
```

- [x] **Step 2: Write failing tests for platform defaults**

```dart
test("macOS profile uses Release app bundle output", () async {
  final profile = PlatformReleaseProfile.forPlatform("macos");

  expect(profile.flutterBuildArgs, ["build", "macos", "--release"]);
  expect(profile.defaultInputPath("Example"), endsWith("build/macos/Build/Products/Release/Example.app"));
  expect(profile.installStrategy, "wholeBundleReplace");
});
```

- [x] **Step 3: Run tests to verify they fail**

Run:

```sh
flutter test --no-pub test/release_cli/project_metadata_resolver_test.dart
```

Expected: fails because resolver/profile files do not exist.

- [x] **Step 4: Implement metadata resolver**

Resolver behavior:

- `pubspec.yaml` version `2.0.1+201` maps to `version=2.0.1`, `buildNumber=201`.
- `pubspec.yaml` version `2.0.1` maps to `version=2.0.1`, `buildNumber=null`.
- `--version` and `--build-number` override pubspec values.
- macOS package id comes from `PRODUCT_BUNDLE_IDENTIFIER` in `macos/Runner/Configs/AppInfo.xcconfig` first, then Xcode project fallback.
- macOS app name defaults to `<PRODUCT_NAME>.app` or `<pubspec name>.app`.
- Windows app name defaults to Flutter project name or runner executable name.
- Linux application id comes from `example/linux/CMakeLists.txt` style `APPLICATION_ID` when available; otherwise fallback to package id override is required.
- If required metadata cannot be inferred, fail with a specific CLI flag suggestion such as `--package-id`.

- [x] **Step 5: Run tests to verify they pass**

Run:

```sh
flutter test --no-pub test/release_cli/project_metadata_resolver_test.dart
```

Expected: all metadata tests pass.

## Task 3: Publish Layout And Manifest

**Files:**
- Create: `lib/src/release_cli/publish_layout.dart`
- Create: `lib/src/release_cli/publish_manifest.dart`
- Test: `test/release_cli/publish_layout_test.dart`
- Test: `test/release_cli/publish_manifest_test.dart`

- [x] **Step 1: Write failing layout test**

```dart
test("creates stable local and remote release paths", () {
  final layout = PublishLayout.create(
    outputDirectory: Directory("/tmp/app/dist/desktop_updater"),
    baseUrl: Uri.parse("https://updates.example.com"),
    version: "2.0.1",
    platform: "macos",
    appName: "Example.app",
  );

  expect(layout.appArchiveRelativePath, "app-archive.json");
  expect(layout.releaseRelativePath, "releases/2.0.1/macos/release.json");
  expect(layout.artifactRelativePath, "releases/2.0.1/macos/Example-2.0.1-macos.zip");
  expect(layout.releaseUrl.toString(), "https://updates.example.com/releases/2.0.1/macos/release.json");
});
```

- [x] **Step 2: Write failing manifest round-trip test**

```dart
test("writes publish manifest used by validate", () async {
  final tempDir = await Directory.systemTemp.createTemp("publish_manifest_");
  try {
    final manifest = PublishManifest(
      schemaVersion: 1,
      baseUrl: Uri.parse("https://updates.example.com/"),
      localRoot: tempDir.path,
      appArchive: PublishManifestFile(
        path: "app-archive.json",
        url: Uri.parse("https://updates.example.com/app-archive.json"),
      ),
      release: PublishManifestRelease(
        version: "2.0.1",
        buildNumber: 201,
        platform: "macos",
        channel: "stable",
        path: "releases/2.0.1/macos/release.json",
        url: Uri.parse("https://updates.example.com/releases/2.0.1/macos/release.json"),
      ),
      artifact: PublishManifestArtifact(
        path: "releases/2.0.1/macos/Example-2.0.1-macos.zip",
        url: Uri.parse("https://updates.example.com/releases/2.0.1/macos/Example-2.0.1-macos.zip"),
        sha256: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        length: 12,
      ),
    );

    final file = File(path.join(tempDir.path, ".desktop_updater_publish.json"));
    await manifest.writeTo(file);
    final parsed = await PublishManifest.readFrom(file);

    expect(parsed.release.version, "2.0.1");
    expect(parsed.artifact.length, 12);
  } finally {
    await tempDir.delete(recursive: true);
  }
});
```

- [x] **Step 3: Run tests to verify they fail**

Run:

```sh
flutter test --no-pub test/release_cli/publish_layout_test.dart test/release_cli/publish_manifest_test.dart
```

Expected: fails because layout and manifest files do not exist.

- [x] **Step 4: Implement layout and manifest models**

Use ASCII JSON field names exactly as shown in the manifest example. Always write a trailing newline to JSON files.

- [x] **Step 5: Run tests to verify they pass**

Run:

```sh
flutter test --no-pub test/release_cli/publish_layout_test.dart test/release_cli/publish_manifest_test.dart
```

Expected: all layout and manifest tests pass.

## Task 4: Release Publish Command Without Upload

**Files:**
- Create: `bin/release.dart`
- Create: `lib/src/release_cli/release_command.dart`
- Create: `lib/src/release_cli/publish_command.dart`
- Create: `lib/src/release_cli/release_publisher.dart`
- Create: `lib/src/release_cli/upload/upload_provider.dart`
- Create: `lib/src/release_cli/upload/manual_upload_provider.dart`
- Test: `test/release_cli/release_command_test.dart`
- Test: `test/release_cli/upload/manual_upload_provider_test.dart`

- [x] **Step 1: Write failing command test**

```dart
test("publish without upload provider prints manual upload instructions", () async {
  final fixture = await createReleasePublishFixture(
    config: """
updates:
  baseUrl: https://updates.example.com
""",
  );
  final output = StringBuffer();

  final exitCode = await runReleaseCommand(
    ["publish", "--platform", "macos", "--skip-build-for-test"],
    projectRoot: fixture.root,
    output: output,
  );

  expect(exitCode, 0);
  expect(output.toString(), contains("Manual publish package is ready."));
  expect(output.toString(), contains("Not uploaded yet."));
  expect(output.toString(), contains("file://"));
  expect(output.toString(), contains("release validate --manifest"));
  expect(output.toString(), contains("docs/publishing.md"));
});
```

- [x] **Step 2: Run test to verify it fails**

Run:

```sh
flutter test --no-pub test/release_cli/release_command_test.dart
```

Expected: fails because `release_command.dart` does not exist.

- [x] **Step 3: Implement command skeleton and manual provider**

Implementation requirements:

- `dart run desktop_updater:release publish --platform macos`
- `--platform` allowed values: `macos`, `windows`, `linux`.
- `--base-url`, `--config`, `--output`, `--channel`, `--version`, `--build-number`, `--package-id`, `--app-name`, `--skip-build-for-test`.
- In normal mode, call `flutter build <platform> --release`.
- In test mode, use fixture input path and do not shell out to Flutter.
- Use `ZipReleasePackager` to create zip and `release.json` under the final dist release directory.
- Use `upsertAppArchive` to write `app-archive.json`.
- Write `.desktop_updater_publish.json`.
- Manual provider prints clickable `file://` folder link, absolute local path, validate command, and docs link.

- [x] **Step 4: Run test to verify it passes**

Run:

```sh
flutter test --no-pub test/release_cli/release_command_test.dart test/release_cli/upload/manual_upload_provider_test.dart
```

Expected: all command/manual-provider tests pass.

## Task 5: Hosted Validate Command

**Files:**
- Create: `lib/src/release_cli/validate_command.dart`
- Test: `test/release_cli/release_validate_test.dart`

- [x] **Step 1: Write failing validate test with local HTTP server**

```dart
test("validate simulates an older version and verifies hosted artifact", () async {
  final fixture = await createHostedPublishFixture(
    targetVersion: "2.0.1",
    targetBuildNumber: 201,
    previousVersion: "2.0.0",
    previousBuildNumber: 200,
  );
  final output = StringBuffer();

  final exitCode = await runReleaseCommand(
    [
      "validate",
      "--manifest",
      fixture.manifestFile.path,
      "--from-version",
      "2.0.0+200",
    ],
    projectRoot: fixture.projectRoot,
    output: output,
  );

  expect(exitCode, 0);
  expect(output.toString(), contains("Hosted app archive: OK"));
  expect(output.toString(), contains("Update selection: OK"));
  expect(output.toString(), contains("Hosted release descriptor: OK"));
  expect(output.toString(), contains("Hosted artifact SHA-256: OK"));
});
```

- [x] **Step 2: Run test to verify it fails**

Run:

```sh
flutter test --no-pub test/release_cli/release_validate_test.dart
```

Expected: fails because `validate_command.dart` does not exist.

- [x] **Step 3: Implement validate command**

Validation behavior:

- Read `.desktop_updater_publish.json`.
- Fetch hosted `app-archive.json` from manifest.
- Parse `ReleaseIndex`.
- Simulate current version:
  - use `--from-version` when provided;
  - else use the previous release item for the same platform/channel when one exists;
  - else use synthetic `0.0.0` and print `First release synthetic version check`.
- Use `selectReleaseIndexItem()` to choose update.
- Require selected item URL to equal manifest release URL.
- Fetch hosted `release.json`.
- Parse `ReleaseDescriptor`.
- Require descriptor artifact URL to equal manifest artifact URL.
- Download artifact to temp file.
- Verify exact length and SHA-256 with `ArtifactVerifier`.
- Print clear `OK` lines.
- Return non-zero exit code with a direct message when any check fails.
- Warn if hosted `app-archive.json` has `Cache-Control: max-age` greater than 300 seconds.

- [x] **Step 4: Run test to verify it passes**

Run:

```sh
flutter test --no-pub test/release_cli/release_validate_test.dart
```

Expected: validate tests pass.

## Task 6: S3-Compatible Uploader

**Files:**
- Create: `lib/src/release_cli/upload/s3_upload_provider.dart`
- Test: `test/release_cli/upload/s3_upload_provider_test.dart`
- E2E: `test/e2e/release_publish_s3_e2e_test.dart`

- [x] **Step 1: Write failing unit test for upload order**

```dart
test("s3 uploader uploads app archive last", () async {
  final recorder = RecordingObjectStorageClient();
  final provider = S3UploadProvider(client: recorder);

  await provider.upload(
    localRoot: Directory("/tmp/dist"),
    manifest: testPublishManifest(),
    config: S3UploadConfig(
      bucket: "updates",
      prefix: "desktop",
      region: "local",
    ),
  );

  expect(recorder.putKeys.last, "desktop/app-archive.json");
  expect(recorder.putKeys, contains("desktop/releases/2.0.1/macos/release.json"));
});
```

- [x] **Step 2: Run test to verify it fails**

Run:

```sh
flutter test --no-pub test/release_cli/upload/s3_upload_provider_test.dart
```

Expected: fails because S3 uploader does not exist.

- [x] **Step 3: Implement S3-compatible uploader**

Implementation options:

- Prefer a small S3-compatible Dart client if a stable dependency is acceptable.
- If avoiding a new dependency in the first slice, implement a process-backed provider that shells out to `aws s3 cp` only when `aws` is installed. This is less portable and should be a deliberate trade-off before execution.

Required behavior:

- Upload every file except `app-archive.json`.
- Run hosted release validation step for descriptor/artifact before final index upload when called from `publish`.
- Upload `app-archive.json` last.
- Resolve S3-compatible credentials through the standard AWS credential chain:
  - `s3.profile` when set in config;
  - `AWS_PROFILE` when set in the environment;
  - default local AWS profile from `~/.aws/config` and `~/.aws/credentials`;
  - `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, and optional `AWS_SESSION_TOKEN` for CI/headless use;
  - supported session or role credentials when available in the chosen client.
- Support `endpoint`, `pathStyle`, and `profile` for R2/MinIO.
- If the implementation uses the AWS CLI as the first transport, call `aws s3 cp` or `aws s3 sync` with `--profile` when a profile is selected and `--endpoint-url` when `endpoint` is configured. Fail clearly when the `aws` executable is missing.

- [x] **Step 4: Add local MinIO e2e**

Use `test/e2e/docker/docker-compose.release-publish.yml` service `minio` and a static HTTP service pointed at the same storage export or a test bridge that serves uploaded files. Gate the test behind:

```sh
DESKTOP_UPDATER_RUN_RELEASE_PUBLISH_E2E=1
```

Run:

```sh
DESKTOP_UPDATER_RUN_RELEASE_PUBLISH_E2E=1 flutter test --no-pub test/e2e/release_publish_s3_e2e_test.dart
```

Expected: publish uploads to local MinIO-compatible service, validate passes, and uploaded `app-archive.json` is last.

## Task 7: SFTP Uploader

**Files:**
- Create: `lib/src/release_cli/upload/sftp_upload_provider.dart`
- Test: `test/release_cli/upload/sftp_upload_provider_test.dart`
- E2E: `test/e2e/release_publish_sftp_e2e_test.dart`

- [x] **Step 1: Write failing unit test for config and upload order**

```dart
test("sftp uploader uploads versioned files before app archive", () async {
  final recorder = RecordingRemoteFileClient();
  final provider = SftpUploadProvider(client: recorder);

  await provider.upload(
    localRoot: Directory("/tmp/dist"),
    manifest: testPublishManifest(),
    config: SftpUploadConfig(
      host: "localhost",
      port: 2222,
      remotePath: "/updates",
      username: "deploy",
    ),
  );

  expect(recorder.writes.last.remotePath, "/updates/app-archive.json");
});
```

- [x] **Step 2: Run test to verify it fails**

Run:

```sh
flutter test --no-pub test/release_cli/upload/sftp_upload_provider_test.dart
```

Expected: fails because SFTP uploader does not exist.

- [x] **Step 3: Implement SFTP uploader**

Requirements:

- Read password from `DESKTOP_UPDATER_SFTP_PASSWORD` or private key path from `DESKTOP_UPDATER_SFTP_PRIVATE_KEY`.
- Never print secrets.
- Create remote directories recursively.
- Upload versioned files first and `app-archive.json` last.
- Fail with clear message if neither password nor private key is available.

- [x] **Step 4: Add local SFTP e2e**

Use a local Docker SFTP service with a test username and password. The test should upload to the SFTP server and expose the uploaded directory through a local static HTTP server, then run `release validate`.

Run:

```sh
DESKTOP_UPDATER_RUN_RELEASE_PUBLISH_E2E=1 flutter test --no-pub test/e2e/release_publish_sftp_e2e_test.dart
```

Expected: SFTP publish succeeds and hosted validate passes through local HTTP.

## Task 8: FTP Uploader

**Files:**
- Create: `lib/src/release_cli/upload/ftp_upload_provider.dart`
- Test: `test/release_cli/upload/ftp_upload_provider_test.dart`
- E2E: `test/e2e/release_publish_ftp_e2e_test.dart`

- [x] **Step 1: Write failing tests for insecure opt-in**

```dart
test("ftp config requires allowInsecure true", () async {
  await expectLater(
    ReleasePublishConfig.fromYaml("""
updates:
  baseUrl: https://updates.example.com
ftp:
  host: ftp.example.com
  remotePath: /public_html/updates
  username: deploy
"""),
    throwsA(
      isA<FormatException>().having(
        (error) => error.message,
        "message",
        contains("ftp.allowInsecure: true is required"),
      ),
    ),
  );
});
```

- [x] **Step 2: Run test to verify it fails**

Run:

```sh
flutter test --no-pub test/release_cli/upload/ftp_upload_provider_test.dart
```

Expected: fails until FTP config validation and uploader exist.

- [x] **Step 3: Implement FTP uploader**

Requirements:

- Only allow when `allowInsecure: true`.
- Read password from `DESKTOP_UPDATER_FTP_PASSWORD`.
- Upload versioned files first and `app-archive.json` last.
- Print warning: `FTP is insecure. Prefer SFTP or S3-compatible upload.`
- Never print password.

- [x] **Step 4: Add local FTP e2e**

Use a local Docker FTP service and a static HTTP server over the uploaded directory. Gate behind:

```sh
DESKTOP_UPDATER_RUN_RELEASE_PUBLISH_E2E=1
```

Expected: FTP publish succeeds only with `allowInsecure: true`; hosted validate passes.

## Task 9: Custom Command Uploader

**Files:**
- Create: `lib/src/release_cli/upload/custom_command_upload_provider.dart`
- Test: `test/release_cli/upload/custom_command_upload_provider_test.dart`
- Fixture: `test/e2e/fixtures/upload_commands/copy_updates.dart`

- [x] **Step 1: Write failing test for environment contract**

```dart
test("custom command receives publish manifest environment", () async {
  final tempDir = await Directory.systemTemp.createTemp("custom_upload_");
  try {
    final logFile = File(path.join(tempDir.path, "env.log"));
    final script = File(path.join(tempDir.path, "upload.sh"));
    await script.writeAsString("""
#!/bin/sh
printf '%s\n' "$DESKTOP_UPDATER_PUBLISH_MANIFEST" > "${logFile.path}"
""");
    if (!Platform.isWindows) {
      final chmod = await Process.run("chmod", ["+x", script.path]);
      expect(chmod.exitCode, 0);
    }

    final provider = CustomCommandUploadProvider();
    await provider.upload(
      localRoot: Directory(path.join(tempDir.path, "dist")),
      manifest: testPublishManifest(),
      config: CustomCommandUploadConfig(command: script.path),
    );

    expect(await logFile.readAsString(), contains(".desktop_updater_publish.json"));
  } finally {
    await tempDir.delete(recursive: true);
  }
});
```

- [x] **Step 2: Run test to verify it fails**

Run:

```sh
flutter test --no-pub test/release_cli/upload/custom_command_upload_provider_test.dart
```

Expected: fails until custom command provider exists.

- [x] **Step 3: Implement custom command provider**

Environment contract:

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

The command exits non-zero on failure. The provider must pass stdout/stderr through. Quiet mode is intentionally out of scope for the first implementation.

- [x] **Step 4: Add local custom-command e2e**

Use `copy_updates.dart` to copy local dist files to a temp web root, serve that directory over a local HTTP server, and run `release validate`.

Run:

```sh
flutter test --no-pub test/e2e/release_publish_custom_command_e2e_test.dart
```

Expected: custom command publish copies files and hosted validate passes.

## Task 10: README Short Explanation

**Files:**
- Modify: `README.md`

- [x] **Step 1: Add short happy path**

Add a compact section near release packaging:

````markdown
## Publish A Release

For most apps, use the high-level release command:

```sh
dart run desktop_updater:release publish --platform macos
```

The command reads the app version from `pubspec.yaml`, builds the selected
platform, writes `app-archive.json`, `release.json`, and the zip artifact under
`dist/desktop_updater`, and validates the hosted update path after upload.

If no upload provider is configured, it prints a clickable local folder link
and the `release validate` command to run after manual upload.

See [Publishing desktop updates](docs/publishing.md) for provider config,
manual upload, S3-compatible, FTP, SFTP, custom command, and CI examples.
````

- [x] **Step 2: Keep low-level commands documented but secondary**

Keep `package`, `app_archive`, and `verify` as advanced building blocks below the happy path.

- [x] **Step 3: Review README for contradictions**

Run:

```sh
rg -n "dart run desktop_updater:package|app_archive|release publish|verify" README.md
```

Expected: README presents `release publish` first and low-level commands as advanced/manual alternatives.

## Task 11: Detailed Publishing Guide

**Files:**
- Create: `docs/publishing.md`

- [x] **Step 1: Add guide structure**

Use this structure:

```markdown
# Publishing Desktop Updates

## Quick Start
## How The Files Work EL10
## Minimum Config
## Recommended Config
## Manual Upload
## Validate After Manual Upload
## Automatic Upload
## Common Settings
## macOS Settings
## Windows Settings
## Linux Settings
## S3-Compatible Upload
## SFTP Upload
## FTP Upload
## Custom Command Upload
## CI Example
## Troubleshooting
```

- [x] **Step 2: Document common settings**

Include:

```yaml
updates:
  baseUrl: https://updates.example.com
```

Explain:

- `baseUrl` is the public HTTP(S) root users' apps can fetch.
- `output` defaults to `dist/desktop_updater`.
- `channel` defaults to `stable`.
- `version` and `buildNumber` default to `pubspec.yaml`.
- Credentials must be env vars.

- [x] **Step 3: Document platform settings**

macOS:

```sh
dart run desktop_updater:release publish --platform macos
```

Explain:

- Builds `flutter build macos --release`.
- Packages `.app` with macOS-safe zip behavior.
- Uses `wholeBundleReplace`.
- Production-trusted updates require Developer ID signing, hardened runtime, notarization, stapling, and Gatekeeper acceptance before packaging.

Windows:

```sh
dart run desktop_updater:release publish --platform windows
```

Explain:

- Builds `flutter build windows --release`.
- Packages Release runner directory.
- Uses `wholeDirectoryReplace`.
- Authenticode signing is recommended for production trust.

Linux:

```sh
dart run desktop_updater:release publish --platform linux
```

Explain:

- Builds `flutter build linux --release`.
- Packages `build/linux/x64/release/bundle`.
- Uses `wholeDirectoryReplace`.
- Descriptor signing or another publisher-authenticity policy is recommended for production trust.

- [x] **Step 4: Document providers**

Include exact config examples from the Minimum and Recommended Config sections of this plan.

- [x] **Step 5: Document validate**

Include:

```sh
dart run desktop_updater:release validate \
  --manifest dist/desktop_updater/.desktop_updater_publish.json
```

Explain old-version simulation and `--from-version 2.0.0+200`.

## Task 12: E2E Harness And CI Strategy

**Files:**
- Create: `test/e2e/docker/docker-compose.release-publish.yml`
- Create: `test/e2e/release_publish_manual_e2e_test.dart`
- Create: `test/e2e/release_publish_s3_e2e_test.dart`
- Create: `test/e2e/release_publish_ftp_e2e_test.dart`
- Create: `test/e2e/release_publish_sftp_e2e_test.dart`
- Create: `test/e2e/release_publish_custom_command_e2e_test.dart`
- Create: `test/e2e/fixtures/release_publish_test_app/`
- Create: `test/e2e/fixtures/upload_commands/copy_updates.dart`

- [x] **Step 1: Add e2e opt-in gate**

Each provider e2e test starts with:

```dart
if (Platform.environment["DESKTOP_UPDATER_RUN_RELEASE_PUBLISH_E2E"] != "1") {
  markTestSkipped(
    "Set DESKTOP_UPDATER_RUN_RELEASE_PUBLISH_E2E=1 to run release publish provider e2e tests.",
  );
  return;
}
```

- [x] **Step 2: Add local manual e2e**

Manual e2e should not require Docker:

1. Create fixture app files.
2. Run `release publish --skip-build-for-test`.
3. Copy `dist/desktop_updater` to a temp web root.
4. Serve web root with local Dart HTTP server.
5. Rewrite manifest `baseUrl` to local server or generate with local server base URL.
6. Run `release validate --manifest`.

- [x] **Step 3: Add Docker-backed provider e2e**

`docker-compose.release-publish.yml` includes:

- MinIO or S3-compatible service.
- FTP service with a test user.
- SFTP service with a test user.
- Static HTTP service serving the uploaded files.

Do not run this compose file in normal unit test runs.

- [x] **Step 4: Add custom-command e2e without Docker**

Custom-command e2e should:

1. Create fixture app files.
2. Run `release publish --skip-build-for-test` with `customCommand.command` pointing at `copy_updates.dart`.
3. Have the command copy files from `DESKTOP_UPDATER_LOCAL_ROOT` to a temp web root.
4. Serve the web root with a local Dart HTTP server.
5. Run `release validate --manifest`.

- [x] **Step 5: Add CI docs but do not force CI execution**

In `docs/publishing.md`, show:

```sh
flutter test --no-pub test/e2e/release_publish_manual_e2e_test.dart
flutter test --no-pub test/e2e/release_publish_custom_command_e2e_test.dart
DESKTOP_UPDATER_RUN_RELEASE_PUBLISH_E2E=1 flutter test --no-pub test/e2e/release_publish_s3_e2e_test.dart
DESKTOP_UPDATER_RUN_RELEASE_PUBLISH_E2E=1 flutter test --no-pub test/e2e/release_publish_sftp_e2e_test.dart
DESKTOP_UPDATER_RUN_RELEASE_PUBLISH_E2E=1 flutter test --no-pub test/e2e/release_publish_ftp_e2e_test.dart
```

## Task 13: Final Verification

**Files:**
- All files changed by the implementation.

- [x] **Step 1: Format changed Dart files**

Run:

```sh
dart format bin/release.dart lib/src/release_cli test/release_cli test/e2e
```

Expected: formatted files only.

- [x] **Step 2: Run targeted release CLI tests**

Run:

```sh
flutter test --no-pub test/release_cli
```

Expected: all release CLI tests pass.

- [ ] **Step 3: Run package tests**

Run:

```sh
flutter test --no-pub
```

Expected: all tests pass.

- [x] **Step 4: Run optional provider e2e after user confirms Docker**

Run:

```sh
flutter test --no-pub test/e2e/release_publish_manual_e2e_test.dart
flutter test --no-pub test/e2e/release_publish_custom_command_e2e_test.dart
DESKTOP_UPDATER_RUN_RELEASE_PUBLISH_E2E=1 flutter test --no-pub test/e2e/release_publish_s3_e2e_test.dart
DESKTOP_UPDATER_RUN_RELEASE_PUBLISH_E2E=1 flutter test --no-pub test/e2e/release_publish_sftp_e2e_test.dart
DESKTOP_UPDATER_RUN_RELEASE_PUBLISH_E2E=1 flutter test --no-pub test/e2e/release_publish_ftp_e2e_test.dart
```

Expected: manual and custom-command e2e pass without Docker; provider e2e passes when Docker services are available.

- [x] **Step 5: Check docs**

Run:

```sh
rg -n "release publish|release validate|docs/publishing.md|app_archive|package" README.md docs/publishing.md docs/migration/1.x-to-2.0.md docs/github-actions-ci-cd.md
```

Expected: docs present the high-level `release publish` UX first and keep low-level commands as advanced alternatives.

## Self-Review Notes

- Spec coverage: This plan covers minimum config, recommended config, EL10 scenario, README short explanation, full publishing guide, common settings, platform settings, provider settings, validate behavior, auto-upload behavior, manual-upload behavior, and e2e tests for S3, FTP, SFTP, and custom command.
- Completeness scan: No unresolved provider behavior remains.
- Type consistency: `ReleasePublishConfig`, `ReleasePublishOverrides`, `PublishLayout`, `PublishManifest`, `UploadConfig`, `UploadProvider`, `runReleaseCommand`, and provider config type names are used consistently across tasks.
