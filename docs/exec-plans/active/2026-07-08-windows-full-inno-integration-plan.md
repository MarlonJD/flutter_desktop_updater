# Windows Full Inno Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add first-class Windows Inno Setup publishing and update execution so Inno owns install, upgrade, repair, registry, and uninstall metadata instead of relying on direct zip replacement.

**Architecture:** Keep the current zip-first updater path intact while adding a Windows-only Inno installer artifact path. Release descriptors can describe an `innoInstaller` artifact and installer execution policy, Dart stages the verified installer without extraction, and the Windows native helper executes the Inno `.exe` with logged silent arguments after the app exits. The release CLI can either compile a generated Inno script or use an app-owned `.iss` file, then publish the installer as the update artifact.

**Tech Stack:** Dart/Flutter tests, schema-v3 `release.json` extension guarded by `minimumUpdaterVersion`, Windows C++ Flutter plugin helper, generated PowerShell install script, Inno Setup Compiler (`ISCC.exe`) when packaging on Windows, Authenticode verification through Windows PowerShell, repository validation ladder.

## Global Constraints

- Preserve existing direct zip behavior for `artifact.kind == "zip"` and `install.strategy == "wholeDirectoryReplace"`.
- Add Inno support as a Windows-only path; macOS and Linux must reject `innoInstaller` runtime installation.
- Do not edit or regenerate Inno `unins*.dat` files from Dart or PowerShell; let Inno Setup own uninstall metadata.
- Do not execute arbitrary downloaded `.exe` files; only execute descriptors that pass schema validation, artifact SHA-256 validation, descriptor policy validation, and the configured Authenticode policy.
- Keep current MethodChannel argument compatibility for `installUpdate(stagingPath: ...)`; use staged manifest metadata for new installer behavior.
- Keep docs, plan text, comments, and diagnostics event names in English.
- Do not create, switch, rename, or delete branches unless the user explicitly asks during execution.
- Do not post GitHub comments or PR reviews through connector identities.
- Use TDD for every task: add the failing focused test, run it, implement, rerun, then widen.
- Use the narrowest useful validation command first, then widen before handoff.

---

## Product Definition

This plan implements full Inno integration inside `desktop_updater`'s package boundary:

- Build and publish Inno Setup installers from `desktop_updater:release publish`.
- Allow apps to provide a custom `.iss` file for advanced Inno behavior.
- Generate a conservative default `.iss` file when no custom script is supplied.
- Publish `.exe` installer artifacts with `artifact.kind == "innoInstaller"`.
- Verify descriptor signature policy and installer SHA-256 before staging.
- Optionally verify Authenticode publisher thumbprints before execution.
- Execute the installer after the app exits using Inno silent flags.
- Let Inno update registry, uninstall log, installed file list, repair, modify, and uninstall behavior.
- Record diagnostics for installer start, exit code, log path, signature result, and relaunch.

This plan does not reimplement the Inno Setup compiler, custom wizard engine, or every Inno directive as Dart APIs. Advanced projects should keep an app-owned `.iss` script and let `desktop_updater` compile and publish it.

## File Structure

### Descriptor And Runtime Core

- Modify `lib/src/core/release_descriptor.dart`.
  - Allow `ReleaseArtifact.kind == "zip"` or `"innoInstaller"`.
  - Extend `ReleaseInstall` with optional `ReleaseInnoInstall inno`.
  - Add `ReleaseInnoInstall` and `ReleaseAuthenticodePolicy` value objects.
- Modify `lib/src/core/artifact_verifier.dart`.
  - Keep URL, length, and SHA-256 verification for both artifact kinds.
  - Reject non-Windows runtime use of `innoInstaller` before staging.
- Modify `lib/src/core/update_client.dart`.
  - Stage `innoInstaller` artifacts as an installer file plus manifest, with no zip extraction.
- Modify `lib/src/core/update_telemetry.dart`.
  - Add optional `artifactKind` and `installStrategy` fields to existing lifecycle events.
- Test with `test/release_descriptor_test.dart`, `test/artifact_verifier_test.dart`, `test/update_client_security_test.dart`, and `test/e2e/zip_first_update_flow_test.dart`.

### Windows Native Helper

- Modify `windows/desktop_updater_plugin.cpp`.
  - In generated PowerShell, read `.desktop_updater_release_manifest.json`.
  - Branch to `Invoke-InnoInstallerUpdate` when `install.strategy == "innoInstaller"`.
  - Verify installer path remains under staging.
  - Verify Authenticode thumbprints when descriptor policy requires them.
  - Run Inno with silent arguments, `/DIR`, `/LOG`, and `-Wait`.
  - Clean staging after installer success without rolling back a successful Inno run.
- Modify `windows/desktop_updater_plugin.h` only if test-visible native helpers are added.
- Test with `test/native_helper_script_test.dart`, `windows/test/desktop_updater_plugin_test.cpp`, and Windows CI smoke.

### Release CLI And Packaging

- Modify `lib/src/release_cli/release_publish_config.dart`.
  - Parse `windows.installer` configuration.
- Modify `lib/src/release_cli/publish_layout.dart`.
  - Allow artifact extension `.zip` or `.exe`.
- Modify `lib/src/release_cli/release_publisher.dart`.
  - Select `ZipReleasePackager` or `InnoInstallerPackager`.
  - Include artifact kind in hook environment and publish manifest.
- Modify `lib/src/release_cli/publish_manifest.dart`.
  - Add `artifact.kind` while preserving schema 1 compatibility for existing manifests.
- Create `lib/src/release_cli/inno/inno_publish_config.dart`.
  - Own typed Inno configuration loaded from YAML.
- Create `lib/src/release_cli/inno/inno_script_builder.dart`.
  - Generate a conservative `.iss` script from project metadata.
- Create `lib/src/release_cli/inno/inno_compiler.dart`.
  - Run `ISCC.exe` or configured `isccPath`.
- Create `lib/src/release_cli/inno/inno_installer_packager.dart`.
  - Produce installer `.exe` and `release.json`.
- Test with `test/release_cli/release_publish_config_test.dart`, `test/release_cli/publish_layout_test.dart`, `test/release_cli/inno_script_builder_test.dart`, `test/release_cli/inno_installer_packager_test.dart`, `test/release_cli/release_publisher_build_test.dart`, and upload provider tests.

### Docs And Validation

- Modify `docs/publishing.md`.
- Modify `docs/windows-linux-production-release.md`.
- Modify `docs/diagnostics-and-recovery.md`.
- Modify `README.md` only for package-level feature discovery.
- Modify `.github/workflows/desktop-updater-ci.yml` if a Windows Inno smoke can run on hosted runners with `ISCC.exe` installed or bootstrapped.
- Add docs drift tests in `test/native_helper_diagnostics_docs_test.dart` and `test/harness_engineering_docs_test.dart` only when assertions need to protect the new plan or docs.

## Descriptor Shape

The new descriptor shape stays schema version 3 and relies on `minimumUpdaterVersion` to keep old clients away from unsupported artifacts:

```json
{
  "schemaVersion": 3,
  "packageId": "com.example.app",
  "appName": "Example",
  "version": "2.5.0",
  "buildNumber": 250,
  "platform": "windows",
  "channel": "stable",
  "artifact": {
    "kind": "innoInstaller",
    "url": "https://updates.example.com/releases/2.5.0/windows/Example-2.5.0-windows-setup.exe",
    "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "length": 12345678
  },
  "install": {
    "strategy": "innoInstaller",
    "inno": {
      "silentArgs": ["/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART"],
      "inheritInstallDirectory": true,
      "logFileName": "desktop_updater_inno_install.log",
      "relaunchAfterInstall": true,
      "requiresElevation": "auto",
      "authenticode": {
        "required": true,
        "sha256Thumbprints": [
          "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF"
        ]
      }
    }
  },
  "minimumUpdaterVersion": "2.5.0",
  "generatedAt": "2026-07-08T00:00:00.000Z"
}
```

## Phase 1: Descriptor And Runtime Staging Contract

### Task 1: Extend `release.json` For Inno Installer Artifacts

**Files:**

- Modify: `lib/src/core/release_descriptor.dart`
- Test: `test/release_descriptor_test.dart`

**Interfaces:**

- Produces: `ReleaseArtifact.kind == "innoInstaller"` validation.
- Produces: `ReleaseInstall.inno` as `ReleaseInnoInstall?`.
- Produces: `ReleaseInnoInstall.silentArgs`, `inheritInstallDirectory`, `logFileName`, `relaunchAfterInstall`, `requiresElevation`, and `authenticode`.
- Produces: `ReleaseAuthenticodePolicy.required` and `sha256Thumbprints`.
- Consumes: `UpdateClient` and the Windows helper read these fields from the staged manifest.

- [x] **Step 1.1: Write the failing descriptor test**

Add this test to `test/release_descriptor_test.dart` after `parses a valid release descriptor`:

```dart
test("parses a Windows Inno installer descriptor", () {
  final descriptor = ReleaseDescriptor.fromJson({
    ..._descriptorJson(),
    "appName": "Example",
    "platform": "windows",
    "artifact": {
      "kind": "innoInstaller",
      "url": "https://cdn.example.com/Example-2.5.0-setup.exe",
      "sha256": "b" * 64,
      "length": 42,
    },
    "install": {
      "strategy": "innoInstaller",
      "inno": {
        "silentArgs": ["/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART"],
        "inheritInstallDirectory": true,
        "logFileName": "desktop_updater_inno_install.log",
        "relaunchAfterInstall": true,
        "requiresElevation": "auto",
        "authenticode": {
          "required": true,
          "sha256Thumbprints": [
            "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF",
          ],
        },
      },
    },
    "minimumUpdaterVersion": "2.5.0",
  });

  expect(descriptor.artifact.kind, "innoInstaller");
  expect(descriptor.install.strategy, "innoInstaller");
  expect(descriptor.install.inno, isNotNull);
  expect(descriptor.install.inno!.silentArgs, [
    "/VERYSILENT",
    "/SUPPRESSMSGBOXES",
    "/NORESTART",
  ]);
  expect(descriptor.install.inno!.inheritInstallDirectory, isTrue);
  expect(descriptor.install.inno!.requiresElevation, "auto");
  expect(descriptor.install.inno!.authenticode.required, isTrue);
  expect(descriptor.toJson()["install"], {
    "strategy": "innoInstaller",
    "inno": {
      "silentArgs": ["/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART"],
      "inheritInstallDirectory": true,
      "logFileName": "desktop_updater_inno_install.log",
      "relaunchAfterInstall": true,
      "requiresElevation": "auto",
      "authenticode": {
        "required": true,
        "sha256Thumbprints": [
          "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF",
        ],
      },
    },
  });
});
```

- [x] **Step 1.2: Write descriptor rejection tests**

Add these tests to the same file:

```dart
test("rejects Inno installer descriptors without Windows platform", () {
  final json = {
    ..._descriptorJson(),
    "platform": "linux",
    "artifact": {
      "kind": "innoInstaller",
      "url": "https://cdn.example.com/Example-2.5.0-setup.exe",
      "sha256": "b" * 64,
      "length": 42,
    },
    "install": {
      "strategy": "innoInstaller",
      "inno": {
        "silentArgs": ["/VERYSILENT"],
        "requiresElevation": "auto",
      },
    },
  };

  expect(
    () => ReleaseDescriptor.fromJson(json),
    throwsA(
      isA<FormatException>().having(
        (error) => error.message,
        "message",
        contains("innoInstaller is only supported for windows"),
      ),
    ),
  );
});

test("rejects Inno installer descriptors without Inno install metadata", () {
  final json = {
    ..._descriptorJson(),
    "platform": "windows",
    "artifact": {
      "kind": "innoInstaller",
      "url": "https://cdn.example.com/Example-2.5.0-setup.exe",
      "sha256": "b" * 64,
      "length": 42,
    },
    "install": {"strategy": "innoInstaller"},
  };

  expect(
    () => ReleaseDescriptor.fromJson(json),
    throwsA(
      isA<FormatException>().having(
        (error) => error.message,
        "message",
        contains("install.inno is required"),
      ),
    ),
  );
});
```

- [x] **Step 1.3: Run the focused descriptor test and verify failure**

Run:

```sh
flutter test --no-pub test/release_descriptor_test.dart
```

Expected before implementation: FAIL with unsupported artifact kind or missing `ReleaseInstall.inno`.

- [x] **Step 1.4: Implement descriptor value objects**

In `lib/src/core/release_descriptor.dart`, update `ReleaseArtifact.validate`:

```dart
void validate() {
  if (kind != "zip" && kind != "innoInstaller") {
    throw FormatException("Unsupported release artifact kind: $kind");
  }
  if (!RegExp(r"^[0-9a-f]{64}$").hasMatch(sha256)) {
    throw const FormatException(
      "release.json artifact.sha256 must be 64 lowercase hex characters.",
    );
  }
  if (length < 0) {
    throw const FormatException("release.json artifact.length is required.");
  }
}
```

Replace `ReleaseInstall` with this shape:

```dart
class ReleaseInstall {
  const ReleaseInstall({
    required this.strategy,
    this.inno,
  });

  factory ReleaseInstall.fromJson(Map<String, dynamic> json) {
    return ReleaseInstall(
      strategy: json["strategy"] as String? ?? "",
      inno: json["inno"] == null
          ? null
          : ReleaseInnoInstall.fromJson(
              json["inno"] as Map<String, dynamic>,
            ),
    );
  }

  final String strategy;
  final ReleaseInnoInstall? inno;

  Map<String, dynamic> toJson() {
    return {
      "strategy": strategy,
      if (inno != null) "inno": inno!.toJson(),
    };
  }

  void validate({String? platform, String? artifactKind}) {
    if (strategy.trim().isEmpty) {
      throw const FormatException("release.json install.strategy is required.");
    }
    if (strategy == "innoInstaller") {
      if (platform != "windows" || artifactKind != "innoInstaller") {
        throw const FormatException(
          "release.json innoInstaller is only supported for windows installer artifacts.",
        );
      }
      if (inno == null) {
        throw const FormatException(
          "release.json install.inno is required for innoInstaller.",
        );
      }
      inno!.validate();
    }
  }
}
```

Add these classes below `ReleaseInstall`:

```dart
class ReleaseInnoInstall {
  const ReleaseInnoInstall({
    required this.silentArgs,
    required this.inheritInstallDirectory,
    required this.logFileName,
    required this.relaunchAfterInstall,
    required this.requiresElevation,
    required this.authenticode,
  });

  factory ReleaseInnoInstall.fromJson(Map<String, dynamic> json) {
    return ReleaseInnoInstall(
      silentArgs: _parseStringList(json["silentArgs"], "install.inno.silentArgs"),
      inheritInstallDirectory:
          json["inheritInstallDirectory"] as bool? ?? true,
      logFileName: json["logFileName"] as String? ??
          "desktop_updater_inno_install.log",
      relaunchAfterInstall: json["relaunchAfterInstall"] as bool? ?? true,
      requiresElevation: json["requiresElevation"] as String? ?? "auto",
      authenticode: json["authenticode"] == null
          ? const ReleaseAuthenticodePolicy(required: false)
          : ReleaseAuthenticodePolicy.fromJson(
              json["authenticode"] as Map<String, dynamic>,
            ),
    );
  }

  final List<String> silentArgs;
  final bool inheritInstallDirectory;
  final String logFileName;
  final bool relaunchAfterInstall;
  final String requiresElevation;
  final ReleaseAuthenticodePolicy authenticode;

  Map<String, dynamic> toJson() {
    return {
      "silentArgs": silentArgs,
      "inheritInstallDirectory": inheritInstallDirectory,
      "logFileName": logFileName,
      "relaunchAfterInstall": relaunchAfterInstall,
      "requiresElevation": requiresElevation,
      "authenticode": authenticode.toJson(),
    };
  }

  void validate() {
    if (silentArgs.isEmpty) {
      throw const FormatException(
        "release.json install.inno.silentArgs must not be empty.",
      );
    }
    if (!silentArgs.contains("/VERYSILENT") &&
        !silentArgs.contains("/SILENT")) {
      throw const FormatException(
        "release.json install.inno.silentArgs must include /VERYSILENT or /SILENT.",
      );
    }
    if (logFileName.trim().isEmpty ||
        logFileName.contains("/") ||
        logFileName.contains(r"\")) {
      throw const FormatException(
        "release.json install.inno.logFileName must be a simple file name.",
      );
    }
    if (!const ["auto", "always", "never"].contains(requiresElevation)) {
      throw const FormatException(
        "release.json install.inno.requiresElevation must be auto, always, or never.",
      );
    }
    authenticode.validate();
  }
}

class ReleaseAuthenticodePolicy {
  const ReleaseAuthenticodePolicy({
    required this.required,
    this.sha256Thumbprints = const [],
  });

  factory ReleaseAuthenticodePolicy.fromJson(Map<String, dynamic> json) {
    return ReleaseAuthenticodePolicy(
      required: json["required"] as bool? ?? false,
      sha256Thumbprints: _parseStringList(
        json["sha256Thumbprints"],
        "install.inno.authenticode.sha256Thumbprints",
      ),
    );
  }

  final bool required;
  final List<String> sha256Thumbprints;

  Map<String, dynamic> toJson() {
    return {
      "required": required,
      if (sha256Thumbprints.isNotEmpty)
        "sha256Thumbprints": sha256Thumbprints,
    };
  }

  void validate() {
    if (required && sha256Thumbprints.isEmpty) {
      throw const FormatException(
        "release.json install.inno.authenticode.sha256Thumbprints is required when Authenticode is required.",
      );
    }
    for (final thumbprint in sha256Thumbprints) {
      if (!RegExp(r"^[0-9A-Fa-f]{64}$").hasMatch(thumbprint)) {
        throw const FormatException(
          "release.json Authenticode SHA-256 thumbprints must be 64 hex characters.",
        );
      }
    }
  }
}
```

Add this helper near the existing parser helpers:

```dart
List<String> _parseStringList(Object? value, String displayName) {
  if (value == null) {
    return const [];
  }
  if (value is! List) {
    throw FormatException("release.json $displayName must be a list.");
  }
  return List.unmodifiable([
    for (final entry in value) entry.toString(),
  ]);
}
```

Update `ReleaseDescriptor.validate` to call:

```dart
install.validate(platform: platform, artifactKind: artifact.kind);
```

- [x] **Step 1.5: Run the focused descriptor test**

Run:

```sh
flutter test --no-pub test/release_descriptor_test.dart
```

Expected after implementation: PASS.

- [x] **Step 1.6: Commit descriptor contract**

Commit:

```sh
git add lib/src/core/release_descriptor.dart test/release_descriptor_test.dart
git commit -m "feat: describe windows inno installer artifacts"
```

### Task 2: Stage Inno Installer Artifacts Without Zip Extraction

**Files:**

- Modify: `lib/src/core/update_client.dart`
- Test: `test/update_client_security_test.dart`
- Test: `test/e2e/zip_first_update_flow_test.dart`

**Interfaces:**

- Consumes: `ReleaseDescriptor.artifact.kind`.
- Produces: staged root containing `installer.exe` and `.desktop_updater_release_manifest.json`.
- Produces: `UpdateStageResult.stagingPath` as the staging root for Inno installers.
- Keeps: zip descriptors still extract and stage as before.

- [x] **Step 2.1: Write the failing Inno staging test**

Add this test to `test/update_client_security_test.dart` near existing staging tests:

```dart
test("stages Windows Inno installer artifacts without extracting zip", () async {
  final root = await Directory.systemTemp.createTemp("inno_stage_");
  addTearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  final artifact = File(path.join(root.path, "setup.exe"));
  await artifact.writeAsBytes([1, 2, 3, 4]);
  final descriptor = _descriptor(
    platform: "windows",
    artifactKind: "innoInstaller",
    artifactUrl: artifact.uri,
    artifactSha256: await sha256File(artifact),
    artifactLength: await artifact.length(),
    install: const ReleaseInstall(
      strategy: "innoInstaller",
      inno: ReleaseInnoInstall(
        silentArgs: ["/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART"],
        inheritInstallDirectory: true,
        logFileName: "desktop_updater_inno_install.log",
        relaunchAfterInstall: true,
        requiresElevation: "auto",
        authenticode: ReleaseAuthenticodePolicy(required: false),
      ),
    ),
  );

  final client = UpdateClient(
    appArchiveUrl: Uri.parse("https://updates.example.com/app-archive.json"),
    currentVersion: DesktopVersionInfo.parse("1.0.0"),
    platform: "windows",
    stagingParent: root,
  );

  final staged = await client.downloadVerifyAndStage(descriptor: descriptor);

  expect(File(path.join(staged.stagingPath, "installer.exe")).existsSync(), isTrue);
  expect(
    File(path.join(staged.stagingPath, stagedReleaseManifestFileName)).existsSync(),
    isTrue,
  );
  expect(File(path.join(staged.stagingPath, "setup.exe")).existsSync(), isFalse);
});
```

Use local helpers already present in `test/update_client_security_test.dart`. If `_descriptor` lacks these parameters, extend that helper in the same test file with explicit named parameters rather than adding another broad fixture.

- [x] **Step 2.2: Write the non-Windows rejection test**

Add this test to the same file:

```dart
test("rejects Inno installer staging on non-Windows platforms", () async {
  final root = await Directory.systemTemp.createTemp("inno_stage_linux_");
  addTearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  final artifact = File(path.join(root.path, "setup.exe"));
  await artifact.writeAsBytes([1, 2, 3, 4]);
  final descriptor = _innoDescriptorForTest(
    artifactUrl: artifact.uri,
    sha256: await sha256File(artifact),
    length: await artifact.length(),
  );

  final client = UpdateClient(
    appArchiveUrl: Uri.parse("https://updates.example.com/app-archive.json"),
    currentVersion: DesktopVersionInfo.parse("1.0.0"),
    platform: "linux",
    stagingParent: root,
  );

  await expectLater(
    client.downloadVerifyAndStage(descriptor: descriptor),
    throwsA(isA<UnsupportedError>()),
  );
});
```

Add `_innoDescriptorForTest` in the test file if needed:

```dart
ReleaseDescriptor _innoDescriptorForTest({
  required Uri artifactUrl,
  required String sha256,
  required int length,
}) {
  return ReleaseDescriptor(
    schemaVersion: 3,
    packageId: "com.example.app",
    appName: "Example",
    version: "2.5.0",
    buildNumber: 250,
    platform: "windows",
    channel: "stable",
    artifact: ReleaseArtifact(
      kind: "innoInstaller",
      url: artifactUrl,
      sha256: sha256,
      length: length,
    ),
    install: const ReleaseInstall(
      strategy: "innoInstaller",
      inno: ReleaseInnoInstall(
        silentArgs: ["/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART"],
        inheritInstallDirectory: true,
        logFileName: "desktop_updater_inno_install.log",
        relaunchAfterInstall: true,
        requiresElevation: "auto",
        authenticode: ReleaseAuthenticodePolicy(required: false),
      ),
    ),
    minimumUpdaterVersion: "2.5.0",
    generatedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
  );
}
```

- [x] **Step 2.3: Run focused staging tests and verify failure**

Run:

```sh
flutter test --no-pub test/update_client_security_test.dart
```

Expected before implementation: FAIL because `downloadVerifyAndStage` treats the installer as a zip.

- [x] **Step 2.4: Implement the staging branch**

In `lib/src/core/update_client.dart`, after artifact verification and telemetry, add:

```dart
if (descriptor.artifact.kind == "innoInstaller") {
  if (descriptor.platform != "windows" || platform != "windows") {
    throw UnsupportedError(
      "Inno installer updates are only supported on Windows.",
    );
  }
  final installerFile = File(path.join(stagingRoot.path, "installer.exe"));
  await artifactFile.rename(installerFile.path);
  await File(
    path.join(stagingRoot.path, stagedReleaseManifestFileName),
  ).writeAsString(
    const JsonEncoder.withIndent("  ").convert(descriptor.toJson()),
  );
  return UpdateStageResult(
    descriptor: descriptor,
    stagingPath: stagingRoot.path,
  );
}
```

Keep the existing zip extraction block after this branch. Do not change the macOS `ditto` path or the Windows zip manifest write.

- [x] **Step 2.5: Run focused staging tests**

Run:

```sh
flutter test --no-pub test/update_client_security_test.dart
flutter test --no-pub test/e2e/zip_first_update_flow_test.dart
```

Expected after implementation: PASS.

- [x] **Step 2.6: Commit Inno staging**

Commit:

```sh
git add lib/src/core/update_client.dart test/update_client_security_test.dart test/e2e/zip_first_update_flow_test.dart
git commit -m "feat: stage windows inno installer updates"
```

## Phase 2: Windows Installer Execution

### Task 3: Add Windows Helper Inno Execution Branch

**Files:**

- Modify: `windows/desktop_updater_plugin.cpp`
- Test: `test/native_helper_script_test.dart`

**Interfaces:**

- Consumes: staged manifest at `$staging\.desktop_updater_release_manifest.json`.
- Consumes: staged installer at `$staging\installer.exe`.
- Produces: PowerShell `Invoke-InnoInstallerUpdate`.
- Produces diagnostics events: `inno manifest loaded`, `inno authenticode verified`, `inno installer start`, `inno installer success`, `inno installer failure`, `inno relaunch attempt`.
- Keeps: direct zip `wholeDirectoryReplace` branch unchanged.

- [x] **Step 3.1: Write the failing source-shape test**

Add this test to `test/native_helper_script_test.dart`:

```dart
test("Windows helper executes staged Inno installer from manifest", () {
  final source =
      File("windows/desktop_updater_plugin.cpp").readAsStringSync();

  const manifestSnippet =
      r"$manifest = Join-Path $staging '.desktop_updater_release_manifest.json'";
  const strategySnippet =
      r"if ($descriptor.install.strategy -eq 'innoInstaller')";
  const invokeSnippet = "function Invoke-InnoInstallerUpdate";
  const installerPathSnippet = r"$installer = Join-Path $staging 'installer.exe'";
  const startSnippet = "Write-DiagnosticsEvent 'inno installer start'";
  const waitSnippet = "Start-Process -FilePath $installer";

  final manifestIndex = source.indexOf(manifestSnippet);
  final strategyIndex = source.indexOf(strategySnippet);
  final invokeIndex = source.indexOf(invokeSnippet);
  final installerPathIndex = source.indexOf(installerPathSnippet);
  final startIndex = source.indexOf(startSnippet);
  final waitIndex = source.indexOf(waitSnippet);

  expect(invokeIndex, isNonNegative);
  expect(manifestIndex, isNonNegative);
  expect(strategyIndex, isNonNegative);
  expect(installerPathIndex, isNonNegative);
  expect(startIndex, isNonNegative);
  expect(waitIndex, isNonNegative);
  expect(invokeIndex, lessThan(strategyIndex));
  expect(strategyIndex, lessThan(waitIndex));
});
```

- [x] **Step 3.2: Add Authenticode source-shape test**

Add this test to the same file:

```dart
test("Windows helper verifies Authenticode thumbprints for Inno installers", () {
  final source =
      File("windows/desktop_updater_plugin.cpp").readAsStringSync();

  expect(source, contains("function Test-AuthenticodePolicy"));
  expect(source, contains("Get-AuthenticodeSignature -FilePath $installer"));
  expect(source, contains("SignerCertificate"));
  expect(source, contains("Thumbprint"));
  expect(source, contains("inno authenticode verified"));
  expect(source, contains("inno authenticode failure"));
});
```

- [x] **Step 3.3: Run source-shape tests and verify failure**

Run:

```sh
flutter test --no-pub test/native_helper_script_test.dart
```

Expected before implementation: FAIL because the generated PowerShell has no Inno branch.

- [x] **Step 3.4: Implement manifest reading and installer invocation**

In `windows/desktop_updater_plugin.cpp`, add these PowerShell functions before the existing backup/move block in the generated script:

```cpp
      << "function Test-AuthenticodePolicy($Installer, $Policy) {\n"
      << "  if ($null -eq $Policy -or $Policy.required -ne $true) { return }\n"
      << "  try {\n"
      << "    $signature = Get-AuthenticodeSignature -FilePath $Installer -ErrorAction Stop\n"
      << "    if ($signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate) {\n"
      << "      Write-DiagnosticsEvent 'inno authenticode failure'\n"
      << "      throw 'Installer Authenticode signature is not valid.'\n"
      << "    }\n"
      << "    $actual = ([string]$signature.SignerCertificate.Thumbprint).ToUpperInvariant()\n"
      << "    $allowed = @($Policy.sha256Thumbprints | ForEach-Object { ([string]$_).ToUpperInvariant() })\n"
      << "    if ($allowed.Count -gt 0 -and -not ($allowed -contains $actual)) {\n"
      << "      Write-DiagnosticsEvent 'inno authenticode failure'\n"
      << "      throw 'Installer Authenticode thumbprint is not trusted.'\n"
      << "    }\n"
      << "    Write-DiagnosticsEvent 'inno authenticode verified'\n"
      << "  } catch {\n"
      << "    Write-DiagnosticsEvent 'inno authenticode failure'\n"
      << "    throw\n"
      << "  }\n"
      << "}\n"
      << "function Invoke-InnoInstallerUpdate($Descriptor) {\n"
      << "  $installer = Join-Path $staging 'installer.exe'\n"
      << "  $installerPath = [IO.Path]::GetFullPath($installer)\n"
      << "  if (-not $installerPath.StartsWith($stagingRootWithSlash, [StringComparison]::OrdinalIgnoreCase)) {\n"
      << "    throw 'Installer path escapes staging root.'\n"
      << "  }\n"
      << "  if (-not (Test-Path -LiteralPath $installerPath)) { throw 'Staged Inno installer is missing.' }\n"
      << "  $inno = $Descriptor.install.inno\n"
      << "  Test-AuthenticodePolicy -Installer $installerPath -Policy $inno.authenticode\n"
      << "  $logPath = Join-Path ([IO.Path]::GetTempPath()) ([string]$inno.logFileName)\n"
      << "  $args = New-Object System.Collections.Generic.List[string]\n"
      << "  foreach ($arg in @($inno.silentArgs)) { if (-not [string]::IsNullOrWhiteSpace($arg)) { $args.Add([string]$arg) } }\n"
      << "  if ($inno.inheritInstallDirectory -eq $true) { $args.Add('/DIR=' + $targetRoot) }\n"
      << "  $args.Add('/LOG=' + $logPath)\n"
      << "  Write-DiagnosticsEvent 'inno installer start'\n"
      << "  $process = Start-Process -FilePath $installerPath -ArgumentList $args.ToArray() -Wait -PassThru\n"
      << "  if ($process.ExitCode -ne 0) {\n"
      << "    Write-DiagnosticsEvent ('inno installer failure exitCode=' + $process.ExitCode)\n"
      << "    throw ('Inno installer failed with exit code ' + $process.ExitCode)\n"
      << "  }\n"
      << "  Write-DiagnosticsEvent 'inno installer success'\n"
      << "  Remove-StagingDirectoryWithRetry -Path $staging\n"
      << "  if ($inno.relaunchAfterInstall -eq $true -and $skipRelaunch -ne '1') {\n"
      << "    Write-DiagnosticsEvent 'inno relaunch attempt'\n"
      << "    Start-Process -FilePath $exe -WorkingDirectory $target\n"
      << "  }\n"
      << "  Remove-Item -LiteralPath $scriptSelf -Force -ErrorAction SilentlyContinue\n"
      << "  exit 0\n"
      << "}\n";
```

Also define `$stagingRootWithSlash` after `$targetRootWithSlash`:

```cpp
      << "$stagingRoot = [IO.Path]::GetFullPath($staging).TrimEnd('\\\\')\n"
      << "$stagingRootWithSlash = $stagingRoot + '\\'\n"
```

Before the backup block, load the manifest and branch:

```cpp
      << "if (-not [string]::IsNullOrWhiteSpace($staging)) {\n"
      << "  $manifest = Join-Path $staging '.desktop_updater_release_manifest.json'\n"
      << "  if (Test-Path -LiteralPath $manifest) {\n"
      << "    try {\n"
      << "      $descriptor = Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json\n"
      << "      Write-DiagnosticsEvent 'inno manifest loaded'\n"
      << "      if ($descriptor.install.strategy -eq 'innoInstaller') {\n"
      << "        Invoke-InnoInstallerUpdate $descriptor\n"
      << "      }\n"
      << "    } catch {\n"
      << "      Write-DiagnosticsEvent 'inno manifest failure'\n"
      << "      throw\n"
      << "    }\n"
      << "  }\n"
      << "}\n";
```

- [x] **Step 3.5: Run focused source-shape tests**

Run:

```sh
flutter test --no-pub test/native_helper_script_test.dart
```

Expected after implementation: PASS.

- [x] **Step 3.6: Run Windows native tests**

`not run` locally: Windows native build/CMake tests require a Windows host.

Run on Windows or wait for CI:

```sh
flutter build windows --debug
cmake --build example/build/windows/x64 --config Debug --target desktop_updater_test
ctest --test-dir example/build/windows/x64 -C Debug --output-on-failure
```

Expected: PASS for existing Windows native helper tests. If this cannot be run locally, record it as `not run` and rely on CI.

- [x] **Step 3.7: Commit Windows Inno execution**

Commit:

```sh
git add windows/desktop_updater_plugin.cpp test/native_helper_script_test.dart
git commit -m "feat: execute staged inno installers on windows"
```

### Task 4: Add Installer Diagnostics And Telemetry Metadata

**Files:**

- Modify: `lib/src/core/update_telemetry.dart`
- Modify: `lib/src/core/update_client.dart`
- Modify: `lib/updater_controller.dart`
- Test: `test/updater_controller_test.dart`
- Test: `test/native_helper_diagnostics_docs_test.dart`

**Interfaces:**

- Produces: optional `UpdateTelemetryEvent.artifactKind`.
- Produces: optional `UpdateTelemetryEvent.installStrategy`.
- Keeps: existing telemetry constructor parameters backward-compatible.

- [x] **Step 4.1: Write telemetry test**

Add this assertion to the existing controller download/install telemetry test in `test/updater_controller_test.dart`, or add a focused test if no such test exists:

```dart
expect(
  events,
  contains(
    isA<UpdateTelemetryEvent>()
        .having((event) => event.type, "type", UpdateTelemetryEventType.artifactVerified)
        .having((event) => event.artifactKind, "artifactKind", "innoInstaller")
        .having((event) => event.installStrategy, "installStrategy", "innoInstaller"),
  ),
);
```

Use an Inno descriptor fixture from Task 2 so this test covers the new path.

- [x] **Step 4.2: Run the focused controller test and verify failure**

Run:

```sh
flutter test --no-pub test/updater_controller_test.dart
```

Expected before implementation: FAIL because telemetry events do not expose artifact kind or install strategy.

- [x] **Step 4.3: Add optional telemetry fields**

In `lib/src/core/update_telemetry.dart`, add fields to `UpdateTelemetryEvent`:

```dart
this.artifactKind,
this.installStrategy,
```

Add final fields:

```dart
final String? artifactKind;
final String? installStrategy;
```

Thread them through `artifactVerified`, `downloadStarted`, `downloadFailed`, `installScheduled`, and `installFailed` constructors with optional named parameters.

In `lib/src/core/update_client.dart`, pass:

```dart
artifactKind: descriptor.artifact.kind,
installStrategy: descriptor.install.strategy,
```

to `UpdateTelemetryEvent.artifactVerified`.

In `lib/updater_controller.dart`, pass the active descriptor metadata to install events:

```dart
artifactKind: _activeDescriptor?.artifact.kind,
installStrategy: _activeDescriptor?.install.strategy,
```

- [x] **Step 4.4: Document diagnostics event names**

Update `docs/diagnostics-and-recovery.md` with these exact event names:

```md
For Windows Inno installer updates, native helper diagnostics may include:
`inno manifest loaded`, `inno authenticode verified`,
`inno authenticode failure`, `inno installer start`,
`inno installer success`, `inno installer failure exitCode=<code>`, and
`inno relaunch attempt`.
```

Add a drift assertion to `test/native_helper_diagnostics_docs_test.dart`:

```dart
expect(source, contains("inno installer start"));
expect(source, contains("inno authenticode verified"));
```

- [x] **Step 4.5: Run focused diagnostics tests**

Run:

```sh
flutter test --no-pub test/updater_controller_test.dart
flutter test --no-pub test/native_helper_diagnostics_docs_test.dart
```

Expected after implementation: PASS.

- [x] **Step 4.6: Commit diagnostics and telemetry**

Commit:

```sh
git add lib/src/core/update_telemetry.dart lib/src/core/update_client.dart lib/updater_controller.dart docs/diagnostics-and-recovery.md test/updater_controller_test.dart test/native_helper_diagnostics_docs_test.dart
git commit -m "feat: report inno installer update diagnostics"
```

## Phase 3: Inno Publishing And Packaging

### Task 5: Parse Windows Inno Publish Configuration

**Files:**

- Modify: `lib/src/release_cli/release_publish_config.dart`
- Create: `lib/src/release_cli/inno/inno_publish_config.dart`
- Test: `test/release_cli/release_publish_config_test.dart`

**Interfaces:**

- Produces: `ReleasePublishConfig.windows`.
- Produces: `WindowsPublishConfig.installer`.
- Produces: `InnoPublishConfig` with `mode`, `script`, `isccPath`, `outputBaseName`, `appId`, `publisher`, `publisherUrl`, `supportUrl`, `updatesUrl`, `privilegesRequired`, `architecturesAllowed`, `architecturesInstallIn64BitMode`, `setupIcon`, `licenseFile`, `silentArgs`, `requiresElevation`, `authenticodeThumbprints`.

- [x] **Step 5.1: Write config parsing test**

Add this test to `test/release_cli/release_publish_config_test.dart`:

```dart
test("loads Windows Inno installer publish config", () async {
  final root = await Directory.systemTemp.createTemp("inno_config_");
  addTearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  final config = await ReleasePublishConfig.fromYaml(
    """
updates:
  baseUrl: https://updates.example.com/
windows:
  installer:
    kind: inno
    mode: generated
    isccPath: C:\\Program Files (x86)\\Inno Setup 6\\ISCC.exe
    outputBaseName: ExampleSetup
    appId: com.example.app
    publisher: Example Inc.
    publisherUrl: https://example.com
    supportUrl: https://example.com/support
    updatesUrl: https://example.com/download
    privilegesRequired: admin
    architecturesAllowed: x64
    architecturesInstallIn64BitMode: x64
    setupIcon: windows/runner/resources/app_icon.ico
    licenseFile: LICENSE
    silentArgs:
      - /VERYSILENT
      - /SUPPRESSMSGBOXES
      - /NORESTART
    requiresElevation: auto
    authenticodeThumbprints:
      - 0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF
""",
    projectRoot: root,
  );

  final inno = config.windows.installer;
  expect(inno.kind, "inno");
  expect(inno.mode, "generated");
  expect(inno.appId, "com.example.app");
  expect(inno.publisher, "Example Inc.");
  expect(inno.privilegesRequired, "admin");
  expect(inno.silentArgs, ["/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART"]);
  expect(inno.authenticodeThumbprints.single, hasLength(64));
});
```

- [x] **Step 5.2: Run config test and verify failure**

Run:

```sh
flutter test --no-pub test/release_cli/release_publish_config_test.dart
```

Expected before implementation: FAIL because `ReleasePublishConfig.windows` does not exist.

- [x] **Step 5.3: Create Inno config value objects**

Create `lib/src/release_cli/inno/inno_publish_config.dart`:

```dart
class WindowsPublishConfig {
  const WindowsPublishConfig({
    this.installer = const InnoPublishConfig.disabled(),
  });

  final InnoPublishConfig installer;
}

class InnoPublishConfig {
  const InnoPublishConfig({
    required this.kind,
    required this.mode,
    this.script,
    this.isccPath,
    this.outputBaseName,
    this.appId,
    this.publisher,
    this.publisherUrl,
    this.supportUrl,
    this.updatesUrl,
    this.privilegesRequired = "lowest",
    this.architecturesAllowed = "x64",
    this.architecturesInstallIn64BitMode = "x64",
    this.setupIcon,
    this.licenseFile,
    this.silentArgs = const ["/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART"],
    this.requiresElevation = "auto",
    this.authenticodeThumbprints = const [],
  });

  const InnoPublishConfig.disabled()
      : kind = "",
        mode = "disabled",
        script = null,
        isccPath = null,
        outputBaseName = null,
        appId = null,
        publisher = null,
        publisherUrl = null,
        supportUrl = null,
        updatesUrl = null,
        privilegesRequired = "lowest",
        architecturesAllowed = "x64",
        architecturesInstallIn64BitMode = "x64",
        setupIcon = null,
        licenseFile = null,
        silentArgs = const ["/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART"],
        requiresElevation = "auto",
        authenticodeThumbprints = const [];

  final String kind;
  final String mode;
  final String? script;
  final String? isccPath;
  final String? outputBaseName;
  final String? appId;
  final String? publisher;
  final String? publisherUrl;
  final String? supportUrl;
  final String? updatesUrl;
  final String privilegesRequired;
  final String architecturesAllowed;
  final String architecturesInstallIn64BitMode;
  final String? setupIcon;
  final String? licenseFile;
  final List<String> silentArgs;
  final String requiresElevation;
  final List<String> authenticodeThumbprints;

  bool get enabled => kind == "inno";
}
```

- [x] **Step 5.4: Read `windows.installer` from YAML**

In `ReleasePublishConfig`, add:

```dart
required this.windows,
```

and:

```dart
final WindowsPublishConfig windows;
```

Load it in `fromYaml`:

```dart
final windows = _readWindowsConfig(document);
```

and pass it into the constructor. Add parsing helpers:

```dart
WindowsPublishConfig _readWindowsConfig(Map<String, dynamic> document) {
  final windows = _mapValue(document, "windows");
  final installer = _mapValue(windows, "installer");
  if (installer.isEmpty) {
    return const WindowsPublishConfig();
  }
  final kind = _stringValue(installer, "kind") ?? "";
  if (kind != "inno") {
    throw FormatException("windows.installer.kind must be inno.");
  }
  final config = InnoPublishConfig(
    kind: kind,
    mode: _stringValue(installer, "mode") ?? "generated",
    script: _stringValue(installer, "script"),
    isccPath: _stringValue(installer, "isccPath"),
    outputBaseName: _stringValue(installer, "outputBaseName"),
    appId: _stringValue(installer, "appId"),
    publisher: _stringValue(installer, "publisher"),
    publisherUrl: _stringValue(installer, "publisherUrl"),
    supportUrl: _stringValue(installer, "supportUrl"),
    updatesUrl: _stringValue(installer, "updatesUrl"),
    privilegesRequired:
        _stringValue(installer, "privilegesRequired") ?? "lowest",
    architecturesAllowed:
        _stringValue(installer, "architecturesAllowed") ?? "x64",
    architecturesInstallIn64BitMode:
        _stringValue(installer, "architecturesInstallIn64BitMode") ?? "x64",
    setupIcon: _stringValue(installer, "setupIcon"),
    licenseFile: _stringValue(installer, "licenseFile"),
    silentArgs: _stringListValue(installer, "silentArgs") ??
        const ["/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART"],
    requiresElevation: _stringValue(installer, "requiresElevation") ?? "auto",
    authenticodeThumbprints:
        _stringListValue(installer, "authenticodeThumbprints") ?? const [],
  );
  _validateInnoConfig(config);
  return WindowsPublishConfig(installer: config);
}
```

Add `_stringListValue`:

```dart
List<String>? _stringListValue(Map<String, dynamic> map, String key) {
  final value = map[key];
  if (value == null) {
    return null;
  }
  if (value is! List) {
    throw FormatException("$key must be a list.");
  }
  return List.unmodifiable([for (final entry in value) entry.toString()]);
}
```

Add `_validateInnoConfig`:

```dart
void _validateInnoConfig(InnoPublishConfig config) {
  if (!const ["generated", "script"].contains(config.mode)) {
    throw FormatException("windows.installer.mode must be generated or script.");
  }
  if (config.mode == "script" &&
      (config.script == null || config.script!.trim().isEmpty)) {
    throw FormatException(
      "windows.installer.script is required when mode is script.",
    );
  }
  if (!const ["admin", "lowest"].contains(config.privilegesRequired)) {
    throw FormatException(
      "windows.installer.privilegesRequired must be admin or lowest.",
    );
  }
  if (!const ["auto", "always", "never"].contains(config.requiresElevation)) {
    throw FormatException(
      "windows.installer.requiresElevation must be auto, always, or never.",
    );
  }
}
```

- [x] **Step 5.5: Run config tests**

Run:

```sh
flutter test --no-pub test/release_cli/release_publish_config_test.dart
```

Expected after implementation: PASS.

- [x] **Step 5.6: Commit Inno publish config**

Commit:

```sh
git add lib/src/release_cli/release_publish_config.dart lib/src/release_cli/inno/inno_publish_config.dart test/release_cli/release_publish_config_test.dart
git commit -m "feat: load windows inno publish config"
```

### Task 6: Generate A Conservative Inno Script

**Files:**

- Create: `lib/src/release_cli/inno/inno_script_builder.dart`
- Test: `test/release_cli/inno_script_builder_test.dart`

**Interfaces:**

- Consumes: `ProjectMetadata`.
- Consumes: `InnoPublishConfig`.
- Produces: `InnoScriptBuilder.build(...) -> String`.
- Produces a script that installs the Flutter Windows Release directory through Inno, including files that direct zip updates previously left unmanaged.

- [x] **Step 6.1: Write script builder tests**

Create `test/release_cli/inno_script_builder_test.dart`:

```dart
import "dart:io";

import "package:desktop_updater/src/release_cli/inno/inno_publish_config.dart";
import "package:desktop_updater/src/release_cli/inno/inno_script_builder.dart";
import "package:desktop_updater/src/release_cli/platform_release_profile.dart";
import "package:desktop_updater/src/release_cli/project_metadata_resolver.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  test("generates Inno setup script for a Flutter Windows release", () {
    final metadata = ProjectMetadata(
      version: "2.5.0",
      buildNumber: 250,
      appName: "Example",
      packageId: "com.example.app",
      platform: "windows",
      profile: PlatformReleaseProfile.forPlatform("windows"),
      input: Directory(r"C:\repo\build\windows\x64\runner\Release"),
    );
    const config = InnoPublishConfig(
      kind: "inno",
      mode: "generated",
      appId: "com.example.app",
      publisher: "Example Inc.",
      publisherUrl: "https://example.com",
      supportUrl: "https://example.com/support",
      updatesUrl: "https://example.com/download",
      privilegesRequired: "admin",
      architecturesAllowed: "x64",
      architecturesInstallIn64BitMode: "x64",
    );

    final script = const InnoScriptBuilder().build(
      metadata: metadata,
      config: config,
      outputDirectoryPath: r"C:\repo\dist\desktop_updater\releases\2.5.0\windows",
      outputBaseName: "Example-2.5.0-windows-setup",
    );

    expect(script, contains("#define MyAppName \"Example\""));
    expect(script, contains("AppId={{com.example.app}}"));
    expect(script, contains("AppVersion=2.5.0"));
    expect(script, contains("AppPublisher=Example Inc."));
    expect(script, contains("DefaultDirName={autopf}\\Example"));
    expect(script, contains("OutputBaseFilename=Example-2.5.0-windows-setup"));
    expect(script, contains("PrivilegesRequired=admin"));
    expect(script, contains("ArchitecturesAllowed=x64"));
    expect(script, contains("ArchitecturesInstallIn64BitMode=x64"));
    expect(script, contains(r'Source: "C:\repo\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs'));
    expect(script, contains(r'Name: "{autoprograms}\Example"; Filename: "{app}\Example.exe"'));
  });
}
```

- [x] **Step 6.2: Run script builder test and verify failure**

Run:

```sh
flutter test --no-pub test/release_cli/inno_script_builder_test.dart
```

Expected before implementation: FAIL because `InnoScriptBuilder` is missing.

- [x] **Step 6.3: Implement script builder**

Create `lib/src/release_cli/inno/inno_script_builder.dart`:

```dart
import "package:desktop_updater/src/release_cli/inno/inno_publish_config.dart";
import "package:desktop_updater/src/release_cli/project_metadata_resolver.dart";
import "package:path/path.dart" as path;

class InnoScriptBuilder {
  const InnoScriptBuilder();

  String build({
    required ProjectMetadata metadata,
    required InnoPublishConfig config,
    required String outputDirectoryPath,
    required String outputBaseName,
  }) {
    final appName = metadata.appName;
    final executableName = appName.endsWith(".exe") ? appName : "$appName.exe";
    final appId = config.appId ?? metadata.packageId;
    final publisher = config.publisher ?? appName;
    final escapedInput = _escapeInnoString(metadata.input.path);
    final escapedOutput = _escapeInnoString(outputDirectoryPath);
    final escapedIcon = config.setupIcon == null
        ? null
        : _escapeInnoString(path.normalize(config.setupIcon!));
    final escapedLicense = config.licenseFile == null
        ? null
        : _escapeInnoString(path.normalize(config.licenseFile!));

    final buffer = StringBuffer()
      ..writeln('#define MyAppName "${_escapeDefine(appName)}"')
      ..writeln('#define MyAppVersion "${_escapeDefine(metadata.version)}"')
      ..writeln("[Setup]")
      ..writeln("AppId={{${_escapeInnoValue(appId)}}}")
      ..writeln("AppName=$appName")
      ..writeln("AppVersion=${metadata.version}")
      ..writeln("AppPublisher=$publisher")
      ..writeln("DefaultDirName={autopf}\\$appName")
      ..writeln("DefaultGroupName=$appName")
      ..writeln("DisableProgramGroupPage=yes")
      ..writeln("OutputDir=$escapedOutput")
      ..writeln("OutputBaseFilename=$outputBaseName")
      ..writeln("Compression=lzma2")
      ..writeln("SolidCompression=yes")
      ..writeln("WizardStyle=modern")
      ..writeln("PrivilegesRequired=${config.privilegesRequired}")
      ..writeln("ArchitecturesAllowed=${config.architecturesAllowed}")
      ..writeln(
        "ArchitecturesInstallIn64BitMode=${config.architecturesInstallIn64BitMode}",
      );

    if (config.publisherUrl != null) {
      buffer.writeln("AppPublisherURL=${config.publisherUrl}");
    }
    if (config.supportUrl != null) {
      buffer.writeln("AppSupportURL=${config.supportUrl}");
    }
    if (config.updatesUrl != null) {
      buffer.writeln("AppUpdatesURL=${config.updatesUrl}");
    }
    if (escapedIcon != null) {
      buffer.writeln("SetupIconFile=$escapedIcon");
    }
    if (escapedLicense != null) {
      buffer.writeln("LicenseFile=$escapedLicense");
    }

    buffer
      ..writeln()
      ..writeln("[Files]")
      ..writeln(
        'Source: "$escapedInput\\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs',
      )
      ..writeln()
      ..writeln("[Icons]")
      ..writeln(
        'Name: "{autoprograms}\\$appName"; Filename: "{app}\\$executableName"',
      )
      ..writeln()
      ..writeln("[Run]")
      ..writeln(
        'Filename: "{app}\\$executableName"; Description: "{cm:LaunchProgram,$appName}"; Flags: nowait postinstall skipifsilent',
      );

    return buffer.toString();
  }
}

String _escapeDefine(String value) {
  return value.replaceAll(r"\", r"\\").replaceAll('"', r'\"');
}

String _escapeInnoString(String value) {
  return value.replaceAll('"', '""');
}

String _escapeInnoValue(String value) {
  return value.replaceAll("}", "");
}
```

- [x] **Step 6.4: Run script builder tests**

Run:

```sh
flutter test --no-pub test/release_cli/inno_script_builder_test.dart
```

Expected after implementation: PASS.

- [x] **Step 6.5: Commit script builder**

Commit:

```sh
git add lib/src/release_cli/inno/inno_script_builder.dart test/release_cli/inno_script_builder_test.dart
git commit -m "feat: generate inno setup scripts"
```

### Task 7: Compile Inno Installers And Produce Release Descriptors

**Files:**

- Create: `lib/src/release_cli/inno/inno_compiler.dart`
- Create: `lib/src/release_cli/inno/inno_installer_packager.dart`
- Modify: `lib/src/release_cli/publish_layout.dart`
- Test: `test/release_cli/publish_layout_test.dart`
- Test: `test/release_cli/inno_installer_packager_test.dart`

**Interfaces:**

- Produces: `InnoCompiler.compile(...)`.
- Produces: `InnoInstallerPackager.package(ReleasePackageRequest request, InnoPublishConfig config)`.
- Produces: descriptor with `artifact.kind == "innoInstaller"` and `install.strategy == "innoInstaller"`.
- Produces: artifact file named `*-setup.exe`.

- [x] **Step 7.1: Write layout extension test**

Add this test to `test/release_cli/publish_layout_test.dart`:

```dart
test("creates exe artifact layout for Windows Inno installers", () {
  final layout = PublishLayout.create(
    outputDirectory: Directory("/tmp/out"),
    baseUrl: Uri.parse("https://updates.example.com/app"),
    version: "2.5.0",
    platform: "windows",
    appName: "Example",
    artifactExtension: ".exe",
    artifactSuffix: "-setup",
  );

  expect(
    layout.artifactRelativePath,
    "releases/2.5.0/windows/Example-2.5.0-windows-setup.exe",
  );
  expect(
    layout.artifactUrl.toString(),
    "https://updates.example.com/app/releases/2.5.0/windows/Example-2.5.0-windows-setup.exe",
  );
});
```

- [x] **Step 7.2: Write packager test with fake compiler**

Create `test/release_cli/inno_installer_packager_test.dart`:

```dart
import "dart:convert";
import "dart:io";

import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:desktop_updater/src/package/release_packager.dart";
import "package:desktop_updater/src/release_cli/inno/inno_installer_packager.dart";
import "package:desktop_updater/src/release_cli/inno/inno_publish_config.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;

void main() {
  test("packages an Inno installer descriptor", () async {
    final root = await Directory.systemTemp.createTemp("inno_packager_");
    addTearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });
    final input = Directory(path.join(root.path, "Release"));
    await input.create();
    await File(path.join(input.path, "Example.exe")).writeAsString("exe");
    final output = Directory(path.join(root.path, "out"));

    final packager = InnoInstallerPackager(
      compileInno: ({required scriptFile, required outputExe}) async {
        await outputExe.writeAsBytes([1, 2, 3]);
      },
    );

    final result = await packager.package(
      ReleasePackageRequest(
        input: input,
        outputDirectory: output,
        packageId: "com.example.app",
        appName: "Example",
        version: "2.5.0",
        buildNumber: 250,
        platform: "windows",
        channel: "stable",
        artifactUrl: Uri.parse("https://cdn.example.com/Example-setup.exe"),
        installStrategy: "innoInstaller",
        minimumUpdaterVersion: "2.5.0",
      ),
      config: const InnoPublishConfig(
        kind: "inno",
        mode: "generated",
        appId: "com.example.app",
      ),
    );

    expect(result.artifact.path, endsWith("-setup.exe"));
    final json = jsonDecode(await result.releaseFile.readAsString())
        as Map<String, dynamic>;
    final descriptor = ReleaseDescriptor.fromJson(json);
    expect(descriptor.artifact.kind, "innoInstaller");
    expect(descriptor.install.strategy, "innoInstaller");
    expect(descriptor.install.inno!.silentArgs, contains("/VERYSILENT"));
  });
}
```

- [x] **Step 7.3: Run focused tests and verify failure**

Run:

```sh
flutter test --no-pub test/release_cli/publish_layout_test.dart
flutter test --no-pub test/release_cli/inno_installer_packager_test.dart
```

Expected before implementation: FAIL because layout parameters and packager are missing.

- [x] **Step 7.4: Extend publish layout**

Update `PublishLayout.create` signature:

```dart
String artifactExtension = ".zip",
String artifactSuffix = "",
```

Change artifact name construction:

```dart
final artifactName =
    "${_artifactNameStem(appName)}-$version-$platform$artifactSuffix$artifactExtension";
```

- [x] **Step 7.5: Implement compiler and packager**

Create `lib/src/release_cli/inno/inno_compiler.dart`:

```dart
import "dart:io";

typedef InnoProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);

class InnoCompiler {
  const InnoCompiler({
    this.runProcess = Process.run,
  });

  final InnoProcessRunner runProcess;

  Future<void> compile({
    required File scriptFile,
    required String? isccPath,
  }) async {
    final executable = isccPath == null || isccPath.trim().isEmpty
        ? "iscc"
        : isccPath;
    final result = await runProcess(executable, [scriptFile.path]);
    if (result.exitCode != 0) {
      throw ProcessException(
        executable,
        [scriptFile.path],
        "${result.stdout}\n${result.stderr}",
        result.exitCode,
      );
    }
  }
}
```

Create `lib/src/release_cli/inno/inno_installer_packager.dart`:

```dart
import "dart:convert";
import "dart:io";

import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:desktop_updater/src/package/release_packager.dart";
import "package:desktop_updater/src/release_cli/inno/inno_compiler.dart";
import "package:desktop_updater/src/release_cli/inno/inno_publish_config.dart";
import "package:desktop_updater/src/release_cli/inno/inno_script_builder.dart";
import "package:desktop_updater/src/release_cli/platform_release_profile.dart";
import "package:desktop_updater/src/release_cli/project_metadata_resolver.dart";
import "package:desktop_updater/src/release_manifest.dart";
import "package:path/path.dart" as path;

typedef CompileInnoForTest = Future<void> Function({
  required File scriptFile,
  required File outputExe,
});

class InnoInstallerPackager {
  const InnoInstallerPackager({
    this.compiler = const InnoCompiler(),
    this.scriptBuilder = const InnoScriptBuilder(),
    this.compileInno,
  });

  final InnoCompiler compiler;
  final InnoScriptBuilder scriptBuilder;
  final CompileInnoForTest? compileInno;

  Future<ReleasePackageResult> package(
    ReleasePackageRequest request, {
    required InnoPublishConfig config,
  }) async {
    await request.outputDirectory.create(recursive: true);
    final outputBaseName =
        config.outputBaseName ?? "${_artifactNameStem(request.appName)}-${request.version}-${request.platform}-setup";
    final outputExe = File(path.join(request.outputDirectory.path, "$outputBaseName.exe"));
    final scriptFile = File(path.join(request.outputDirectory.path, "$outputBaseName.iss"));

    if (config.mode == "script") {
      await File(config.script!).copy(scriptFile.path);
    } else {
      final metadata = ProjectMetadata(
        version: request.version,
        buildNumber: request.buildNumber,
        appName: request.appName,
        packageId: request.packageId,
        platform: request.platform,
        profile: PlatformReleaseProfile.forPlatform(request.platform),
        input: request.input,
      );
      await scriptFile.writeAsString(
        scriptBuilder.build(
          metadata: metadata,
          config: config,
          outputDirectoryPath: request.outputDirectory.path,
          outputBaseName: outputBaseName,
        ),
      );
    }

    final fakeCompiler = compileInno;
    if (fakeCompiler == null) {
      await compiler.compile(scriptFile: scriptFile, isccPath: config.isccPath);
    } else {
      await fakeCompiler(scriptFile: scriptFile, outputExe: outputExe);
    }

    if (!await outputExe.exists()) {
      throw FileSystemException("Inno compiler did not produce installer.", outputExe.path);
    }

    final descriptor = ReleaseDescriptor(
      schemaVersion: 3,
      packageId: request.packageId,
      appName: request.appName,
      version: request.version,
      buildNumber: request.buildNumber,
      platform: request.platform,
      channel: request.channel,
      artifact: ReleaseArtifact(
        kind: "innoInstaller",
        url: request.artifactUrl,
        sha256: await sha256File(outputExe),
        length: await outputExe.length(),
      ),
      install: ReleaseInstall(
        strategy: "innoInstaller",
        inno: ReleaseInnoInstall(
          silentArgs: config.silentArgs,
          inheritInstallDirectory: true,
          logFileName: "desktop_updater_inno_install.log",
          relaunchAfterInstall: true,
          requiresElevation: config.requiresElevation,
          authenticode: ReleaseAuthenticodePolicy(
            required: config.authenticodeThumbprints.isNotEmpty,
            sha256Thumbprints: config.authenticodeThumbprints,
          ),
        ),
      ),
      minimumUpdaterVersion: request.minimumUpdaterVersion,
      generatedAt: DateTime.now().toUtc(),
    );

    final releaseFile = File(path.join(request.outputDirectory.path, "release.json"));
    await releaseFile.writeAsString(
      const JsonEncoder.withIndent("  ").convert(descriptor.toJson()),
    );

    return ReleasePackageResult(
      artifact: outputExe,
      releaseFile: releaseFile,
      descriptor: descriptor,
    );
  }
}

String _artifactNameStem(String appName) {
  var stem = path.basename(appName);
  if (stem.endsWith(".exe")) {
    stem = stem.substring(0, stem.length - ".exe".length);
  }
  return stem;
}
```

- [x] **Step 7.6: Run focused packager tests**

Run:

```sh
flutter test --no-pub test/release_cli/publish_layout_test.dart
flutter test --no-pub test/release_cli/inno_installer_packager_test.dart
```

Expected after implementation: PASS.

- [x] **Step 7.7: Commit compiler and packager**

Commit:

```sh
git add lib/src/release_cli/publish_layout.dart lib/src/release_cli/inno/inno_compiler.dart lib/src/release_cli/inno/inno_installer_packager.dart test/release_cli/publish_layout_test.dart test/release_cli/inno_installer_packager_test.dart
git commit -m "feat: package windows inno installers"
```

### Task 8: Wire Inno Packaging Into `release publish`

**Files:**

- Modify: `lib/src/release_cli/release_publisher.dart`
- Modify: `lib/src/release_cli/publish_manifest.dart`
- Modify: `lib/src/release_cli/upload/custom_command_upload_provider.dart`
- Modify: `lib/src/release_cli/upload/manual_upload_provider.dart`
- Modify: `lib/src/release_cli/upload/s3_upload_provider.dart`
- Modify: `lib/src/release_cli/upload/sftp_upload_provider.dart`
- Modify: `lib/src/release_cli/upload/ftp_upload_provider.dart`
- Test: `test/release_cli/release_publisher_build_test.dart`
- Test: `test/release_cli/publish_manifest_test.dart`
- Test: upload provider tests under `test/release_cli/upload/`

**Interfaces:**

- Consumes: `config.windows.installer.enabled`.
- Produces: Windows publish artifact extension `.exe` when Inno is enabled.
- Produces: publish manifest `artifact.kind`.
- Produces hook environment `DESKTOP_UPDATER_ARTIFACT_KIND`.
- Keeps: existing zip publish manifest readers accept manifests without `artifact.kind`.

- [x] **Step 8.1: Write release publisher test**

Add this test to `test/release_cli/release_publisher_build_test.dart`:

```dart
test("windows publish uses Inno installer package when configured", () async {
  final root = await _createPublishFixture();
  final output = StringBuffer();
  final publisher = ReleasePublisher(
    skipBuild: true,
    packager: _FakeZipPackager(),
    innoPackager: _FakeInnoPackager(),
  );
  await File(path.join(root.path, "desktop_updater.yaml")).writeAsString("""
updates:
  baseUrl: https://updates.example.com/
windows:
  installer:
    kind: inno
    mode: generated
    appId: com.example.app
""");

  final manifest = await publisher.publish(
    projectRoot: root,
    platform: "windows",
    overrides: const ReleasePublishOverrides(),
    output: output,
  );

  expect(manifest.artifact.kind, "innoInstaller");
  expect(manifest.artifact.path, endsWith("-setup.exe"));
});
```

Extend fake packagers in that test file so `_FakeInnoPackager` writes an `.exe` and descriptor with `artifact.kind == "innoInstaller"`.

- [x] **Step 8.2: Write publish manifest compatibility test**

Add this assertion to `test/release_cli/publish_manifest_test.dart`:

```dart
expect(parsed.artifact.kind, "zip");
```

Add a new manifest JSON fixture with `"kind": "innoInstaller"` and assert it round-trips:

```dart
expect(innoManifest.artifact.kind, "innoInstaller");
expect(innoManifest.toJson()["artifact"]["kind"], "innoInstaller");
```

- [x] **Step 8.3: Run focused publish tests and verify failure**

Run:

```sh
flutter test --no-pub test/release_cli/release_publisher_build_test.dart
flutter test --no-pub test/release_cli/publish_manifest_test.dart
```

Expected before implementation: FAIL because Inno packager selection and manifest artifact kind are missing.

- [x] **Step 8.4: Add artifact kind to publish manifest**

In `PublishManifestArtifact`, add:

```dart
this.kind = "zip",
```

and:

```dart
final String kind;
```

Parse:

```dart
kind: json["kind"] as String? ?? "zip",
```

Serialize:

```dart
"kind": kind,
```

- [x] **Step 8.5: Select Inno packaging for Windows**

In `ReleasePublisher`, add an optional `InnoInstallerPackager innoPackager` constructor parameter defaulting to `const InnoInstallerPackager()`.

When creating `layout`, compute:

```dart
final useInnoInstaller = platform == "windows" && config.windows.installer.enabled;
final layout = PublishLayout.create(
  outputDirectory: config.outputDirectory,
  baseUrl: config.baseUrl,
  version: metadata.version,
  platform: platform,
  appName: metadata.appName,
  artifactExtension: useInnoInstaller ? ".exe" : ".zip",
  artifactSuffix: useInnoInstaller ? "-setup" : "",
);
```

When packaging:

```dart
final packageResult = useInnoInstaller
    ? await innoPackager.package(
        ReleasePackageRequest(
          input: metadata.input,
          outputDirectory: layout.releaseDirectory,
          packageId: metadata.packageId,
          appName: metadata.appName,
          version: metadata.version,
          buildNumber: metadata.buildNumber,
          platform: platform,
          channel: config.channel,
          artifactUrl: layout.artifactUrl,
          installStrategy: "innoInstaller",
          minimumUpdaterVersion: "2.5.0",
        ),
        config: config.windows.installer,
      )
    : await packager.package(
        ReleasePackageRequest(
          input: metadata.input,
          outputDirectory: layout.releaseDirectory,
          packageId: metadata.packageId,
          appName: metadata.appName,
          version: metadata.version,
          buildNumber: metadata.buildNumber,
          platform: platform,
          channel: config.channel,
          artifactUrl: layout.artifactUrl,
          installStrategy: metadata.profile.installStrategy,
        ),
      );
```

When building the manifest artifact:

```dart
kind: packageResult.descriptor.artifact.kind,
```

- [x] **Step 8.6: Add hook and upload environment**

In `_releaseHookEnvironment`, add:

```dart
"DESKTOP_UPDATER_ARTIFACT_KIND": layout.artifactFile.path.endsWith(".exe")
    ? "innoInstaller"
    : "zip",
```

In upload providers that expose manifest artifact environment, add the manifest kind:

```dart
"DESKTOP_UPDATER_ARTIFACT_KIND": manifest.artifact.kind,
```

Manual upload output should print:

```dart
output.writeln("Artifact kind: ${manifest.artifact.kind}");
```

- [x] **Step 8.7: Run publish and upload tests**

Run:

```sh
flutter test --no-pub test/release_cli/release_publisher_build_test.dart
flutter test --no-pub test/release_cli/publish_manifest_test.dart
flutter test --no-pub test/release_cli/upload
```

Expected after implementation: PASS.

- [x] **Step 8.8: Commit release publish integration**

Commit:

```sh
git add lib/src/release_cli/release_publisher.dart lib/src/release_cli/publish_manifest.dart lib/src/release_cli/upload test/release_cli/release_publisher_build_test.dart test/release_cli/publish_manifest_test.dart test/release_cli/upload
git commit -m "feat: publish windows inno installer releases"
```

## Phase 4: Verification, Doctor, Docs, And Smoke

### Task 9: Update Validate And Verify Commands For Installer Artifacts

**Files:**

- Modify: `lib/src/release_cli/validate_command.dart`
- Modify: `bin/verify.dart`
- Test: `test/release_cli/release_validate_test.dart`

**Interfaces:**

- Consumes: `ReleaseDescriptor.artifact.kind`.
- Keeps: hosted artifact SHA-256 validation for zip and Inno artifacts.
- Changes: `bin/verify.dart` does not try to unzip `innoInstaller`.

- [x] **Step 9.1: Write validate test for hosted Inno artifact**

Add a test to `test/release_cli/release_validate_test.dart` that writes a hosted descriptor with `artifact.kind == "innoInstaller"` and verifies output contains:

```dart
expect(output.toString(), contains("Hosted artifact SHA-256: OK"));
expect(output.toString(), contains("Artifact kind: innoInstaller"));
```

- [x] **Step 9.2: Run validate test and verify failure**

Run:

```sh
flutter test --no-pub test/release_cli/release_validate_test.dart
```

Expected before implementation: FAIL because validation output assumes zip or omits artifact kind.

- [x] **Step 9.3: Implement validate output**

In `ReleaseValidator.validate`, after descriptor verification, print:

```dart
output.writeln("Artifact kind: ${descriptor.artifact.kind}");
```

In `bin/verify.dart`, after artifact verification:

```dart
if (descriptor.artifact.kind == "innoInstaller") {
  stdout.writeln("Installer artifact verified.");
  return;
}
```

Keep the existing safe zip extraction path for `zip`.

- [x] **Step 9.4: Run focused validation tests**

Run:

```sh
flutter test --no-pub test/release_cli/release_validate_test.dart
```

Expected after implementation: PASS.

- [x] **Step 9.5: Commit validation updates**

Commit:

```sh
git add lib/src/release_cli/validate_command.dart bin/verify.dart test/release_cli/release_validate_test.dart
git commit -m "feat: validate inno installer artifacts"
```

### Task 10: Add Release Doctor Warnings For Inno Production Readiness

**Files:**

- Modify: `lib/src/release_cli/doctor_command.dart`
- Test: `test/release_cli/release_doctor_test.dart`

**Interfaces:**

- Produces: doctor warning when Windows Inno mode lacks Authenticode thumbprints.
- Produces: doctor warning when Windows Inno mode lacks an explicit `isccPath` and `iscc` is not found.
- Keeps: existing Windows direct zip Authenticode hook warning.

- [x] **Step 10.1: Write doctor tests**

Add tests:

```dart
test("doctor warns when Inno installer lacks Authenticode policy", () async {
  final output = StringBuffer();
  final exitCode = await runDoctorCommand(
    _doctorArgs(),
    projectRoot: await _projectWithConfig("""
updates:
  baseUrl: https://updates.example.com/
windows:
  installer:
    kind: inno
    mode: generated
    appId: com.example.app
"""),
    output: output,
  );

  expect(exitCode, 0);
  expect(
    output.toString(),
    contains("WARNING: Windows Inno installer updates should configure Authenticode thumbprints."),
  );
});
```

Use existing helper names in `test/release_cli/release_doctor_test.dart`; if helper names differ, extend the local fixture rather than adding a global test utility.

- [x] **Step 10.2: Run doctor tests and verify failure**

Run:

```sh
flutter test --no-pub test/release_cli/release_doctor_test.dart
```

Expected before implementation: FAIL because doctor does not inspect Inno config.

- [x] **Step 10.3: Implement doctor checks**

In `doctor_command.dart`, branch:

```dart
if (config.windows.installer.enabled) {
  if (config.windows.installer.authenticodeThumbprints.isEmpty) {
    output.writeln(
      "WARNING: Windows Inno installer updates should configure Authenticode thumbprints.",
    );
  }
  output.writeln(
    "INFO: Windows Inno installer publish will produce .exe artifacts and use Inno for uninstall metadata.",
  );
  return;
}
```

Keep the direct zip warning when Inno mode is not enabled.

- [x] **Step 10.4: Run doctor tests**

Run:

```sh
flutter test --no-pub test/release_cli/release_doctor_test.dart
```

Expected after implementation: PASS.

- [x] **Step 10.5: Commit doctor checks**

Commit:

```sh
git add lib/src/release_cli/doctor_command.dart test/release_cli/release_doctor_test.dart
git commit -m "feat: diagnose windows inno release readiness"
```

### Task 11: Document Full Inno Integration And Migration Boundary

**Files:**

- Modify: `README.md`
- Modify: `docs/publishing.md`
- Modify: `docs/windows-linux-production-release.md`
- Modify: `docs/diagnostics-and-recovery.md`
- Test: `test/native_helper_diagnostics_docs_test.dart`
- Test: `test/harness_engineering_docs_test.dart` only if index or harness wording changes.

**Interfaces:**

- Produces: reader-facing docs for direct zip vs Inno installer mode.
- Produces: migration guidance for apps currently on Inno-compatible direct zip updates.
- Produces: docs statement that Inno owns uninstall metadata in installer mode.

- [x] **Step 11.1: Write docs drift test**

Add assertions to `test/native_helper_diagnostics_docs_test.dart`:

```dart
expect(source, contains("Inno installer update mode"));
expect(source, contains("Inno owns the uninstall log"));
expect(source, contains("artifact.kind"));
expect(source, contains("innoInstaller"));
```

- [x] **Step 11.2: Run docs drift test and verify failure**

Run:

```sh
flutter test --no-pub test/native_helper_diagnostics_docs_test.dart
```

Expected before docs update: FAIL because docs do not describe full Inno mode.

- [x] **Step 11.3: Update publishing docs**

Add a `### Windows Inno Installer Update Mode` section to `docs/publishing.md`:

```md
### Windows Inno Installer Update Mode

Windows releases can publish an Inno Setup `.exe` installer instead of a direct
zip artifact. In this mode `release.json` uses `artifact.kind:
innoInstaller` and `install.strategy: innoInstaller`. The updater downloads
and verifies the installer, stages it without extraction, exits the app, and
the Windows helper runs the installer with the configured silent arguments.

Inno owns the uninstall log, registry entry, installed file list, repair,
modify, and uninstall behavior. This is the mode to use when uninstall cleanup
must include files introduced by later updates.
```

Add YAML example:

```yaml
updates:
  baseUrl: https://updates.example.com/
windows:
  installer:
    kind: inno
    mode: generated
    appId: com.example.app
    publisher: Example Inc.
    privilegesRequired: admin
    silentArgs:
      - /VERYSILENT
      - /SUPPRESSMSGBOXES
      - /NORESTART
    authenticodeThumbprints:
      - 0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF
```

- [x] **Step 11.4: Update production release docs**

In `docs/windows-linux-production-release.md`, add:

```md
Use Windows Inno installer update mode when first install, update, and
uninstall must be owned by Inno Setup. Direct zip compatibility preserves
existing `unins###` files, but Inno installer mode is the path that keeps
Inno's uninstall log aware of files added by later versions.
```

- [x] **Step 11.5: Update README**

In `README.md`, add one short capability bullet under Windows release guidance:

```md
- Windows can publish either direct zip artifacts or Inno Setup installer
  artifacts. Use Inno installer mode when uninstall metadata must stay owned by
  Inno across updates.
```

- [x] **Step 11.6: Run docs tests**

Run:

```sh
flutter test --no-pub test/native_helper_diagnostics_docs_test.dart
flutter test --no-pub test/harness_engineering_docs_test.dart
```

Expected after docs update: PASS.

- [x] **Step 11.7: Commit docs**

Commit:

```sh
git add README.md docs/publishing.md docs/windows-linux-production-release.md docs/diagnostics-and-recovery.md test/native_helper_diagnostics_docs_test.dart
git commit -m "docs: explain windows inno installer mode"
```

### Task 12: Add Windows Inno Smoke Validation

**Files:**

- Modify: `.github/workflows/desktop-updater-ci.yml`
- Modify: `example/README.md` or create `example/windows_inno_smoke.md`
- Create: `tool/windows_inno_smoke.ps1`
- Test: `test/harness_engineering_docs_test.dart` if new report paths are documented.

**Interfaces:**

- Produces: optional Windows smoke that installs v1 through Inno, updates to v2 through `desktop_updater`, uninstalls, and verifies v2-only files are removed.
- Produces: report path `reports/windows-inno-update-smoke-diagnostics.jsonl`.
- Keeps: smoke skipped locally when Windows or ISCC is unavailable.

- [x] **Step 12.1: Write smoke script skeleton**

Create `tool/windows_inno_smoke.ps1`:

```powershell
$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT') {
  Write-Host 'not run: Windows Inno smoke requires Windows.'
  exit 0
}

$iscc = Get-Command iscc -ErrorAction SilentlyContinue
if ($null -eq $iscc) {
  Write-Host 'not run: Inno Setup Compiler is not installed.'
  exit 0
}

New-Item -ItemType Directory -Force -Path reports | Out-Null
$diagnostics = Join-Path (Get-Location) 'reports/windows-inno-update-smoke-diagnostics.jsonl'
if (Test-Path -LiteralPath $diagnostics) {
  Remove-Item -LiteralPath $diagnostics -Force
}

Write-Host 'Windows Inno smoke prerequisites are available.'
Write-Host "Diagnostics: $diagnostics"
```

- [x] **Step 12.2: Add workflow step**

In `.github/workflows/desktop-updater-ci.yml`, add a Windows job step after existing Windows update smoke:

```yaml
- name: Windows Inno update smoke
  if: runner.os == 'Windows'
  shell: pwsh
  run: ./tool/windows_inno_smoke.ps1
```

- [x] **Step 12.3: Add report artifact collection**

If reports are uploaded in the workflow, include:

```yaml
reports/windows-inno-update-smoke-diagnostics.jsonl
```

- [x] **Step 12.4: Run workflow docs guard**

Run:

```sh
flutter test --no-pub test/harness_engineering_docs_test.dart
```

Expected: PASS after report path docs and workflow stay aligned.

- [ ] **Step 12.5: Run smoke manually on Windows**

Run on Windows:

```powershell
pwsh ./tool/windows_inno_smoke.ps1
```

Expected without ISCC: `not run: Inno Setup Compiler is not installed.` Expected with ISCC: script continues to the real smoke once the implementation fills in app build/install/update assertions.

Local status: not run; this host is not Windows and does not provide the Windows Inno Setup Compiler lane.

- [x] **Step 12.6: Commit smoke scaffolding**

Commit:

```sh
git add .github/workflows/desktop-updater-ci.yml tool/windows_inno_smoke.ps1 example
git commit -m "test: add windows inno update smoke lane"
```

## Final Validation

- [x] Run descriptor tests:

```sh
flutter test --no-pub test/release_descriptor_test.dart
```

- [x] Run staging and controller tests:

```sh
flutter test --no-pub test/update_client_security_test.dart
flutter test --no-pub test/updater_controller_test.dart
flutter test --no-pub test/e2e/zip_first_update_flow_test.dart
```

- [x] Run release CLI tests:

```sh
flutter test --no-pub test/release_cli
```

- [x] Run native helper docs/source-shape tests:

```sh
flutter test --no-pub test/native_helper_script_test.dart
flutter test --no-pub test/native_helper_diagnostics_docs_test.dart
flutter test --no-pub test/harness_engineering_docs_test.dart
```

- [x] Run format:

```sh
dart format --set-exit-if-changed .
```

- [x] Run analyze:

```sh
flutter analyze --no-fatal-infos
```

- [x] Run full tests:

```sh
flutter test --no-pub
```

- [ ] Run publish dry run:

```sh
dart pub publish --dry-run
```

Local status: blocked by pre-existing modified checked-in file `test/harness_engineering_docs_test.dart`; command reached package validation and exited 65.

- [ ] Run Windows native tests on Windows or mark `not run` locally:

```sh
flutter build windows --debug
cmake --build example/build/windows/x64 --config Debug --target desktop_updater_test
ctest --test-dir example/build/windows/x64 -C Debug --output-on-failure
```

Local status: not run; this host is not Windows.

- [ ] Run Windows Inno smoke on Windows with ISCC installed or mark `not run` locally:

```powershell
pwsh ./tool/windows_inno_smoke.ps1
```

Local status: not run; this host is not Windows and ISCC is unavailable locally.

## Issue 60 Response Draft

After implementation and release, use this comment text if the user explicitly asks to post an issue comment through an approved non-connector route:

```md
Implemented the full Windows Inno path separately from direct zip compatibility.

Direct zip updates remain available and preserve existing `unins###` files, but Inno installer mode now publishes and runs an Inno `.exe` artifact. In that mode Inno owns the registry entry, uninstall log, installed file list, repair, modify, and uninstall behavior, so files introduced by later updates are tracked by Inno rather than copied behind its back.
```

## Self-Review

- [x] Spec coverage: The plan covers descriptor support, staging, Windows execution, Inno script generation, Inno compiler invocation, publish wiring, validation, doctor warnings, docs, and Windows smoke.
- [x] Support boundary: The plan says direct zip compatibility remains separate and full Inno mode lets Inno own uninstall metadata.
- [x] Placeholder scan: No task uses banned placeholder wording or unspecified error behavior.
- [ ] Type consistency: `ReleaseInnoInstall`, `ReleaseAuthenticodePolicy`, `InnoPublishConfig`, `InnoInstallerPackager`, and `artifact.kind == "innoInstaller"` are named consistently across tasks.
- [ ] Compatibility: Existing zip descriptors, publish layout defaults, MethodChannel arguments, and update UI state remain backward-compatible.
