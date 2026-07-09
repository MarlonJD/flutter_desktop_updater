# macOS DMG And PKG Production Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add production-ready macOS DMG and PKG distribution/update support while preserving the existing direct `.app.zip` whole-bundle replacement path.

**Architecture:** Keep `zip` plus `wholeBundleReplace` as the backward-compatible macOS default, then add macOS-only descriptor branches for DMG and PKG artifacts. DMG updates mount a verified DMG, copy out and verify the contained `.app`, detach the image, and hand the `.app` to the existing safe bundle replacement helper. PKG updates stage a verified signed/notarized/stapled installer and hand it to an explicit installer-owned path that launches Installer.app; the package does not promise silent privileged installation without a separately designed signed privileged helper.

**Tech Stack:** Dart/Flutter unit and widget tests, schema-v3 `release.json`, macOS Swift MethodChannel helper, `/usr/bin/hdiutil`, `/usr/bin/codesign`, `/usr/sbin/spctl`, `/usr/bin/xcrun stapler`, `/usr/sbin/pkgutil`, `/usr/sbin/pkgbuild`, `/usr/bin/productbuild`, release CLI publish/validate commands, local MacBook production smoke harness.

## Global Constraints

- Do not create, switch, rename, or delete branches.
- Do not post GitHub comments, PR reviews, merge PRs, or publish releases.
- Protect existing user changes; inspect dirty worktree before touching files.
- Keep docs, code comments, API names, file names, and diagnostics text in English.
- Use `apply_patch` for manual edits.
- Use TDD task-by-task when implementation begins.
- Plan checkboxes are task/step checkboxes and remain unchecked until the implementation work is performed.
- Keep existing `.app.zip` direct update behavior backward-compatible.
- `.app.zip` direct updates remain existing whole-bundle replacement.
- DMG first-install UX is installer/distribution ergonomics.
- DMG update mode is mount plus verified `.app` replacement.
- PKG mode is installer-owned install/update.
- Silent privileged PKG install is out of scope unless separately planned.
- Production-ready macOS evidence requires real Apple trust validation, not only unit tests.
- The package must not create or import Apple certificates or notary credentials; apps and CI provide those credentials by reference.
- Release metadata SHA-256 remains artifact integrity; production authenticity still requires Apple trust gates and, where configured, signed `release.json`.

---

## Product Definition

This plan adds three macOS distribution lanes:

- **Direct zip update, unchanged:** `artifact.kind == "zip"` and `install.strategy == "wholeBundleReplace"`. The runtime downloads a `.app.zip`, extracts with `ditto`, verifies the staged `.app`, and replaces the installed bundle through the existing macOS helper.
- **DMG first install and update:** `artifact.kind == "dmg"` and `install.strategy == "wholeBundleReplace"`. The release CLI creates a signed/notarized/stapled DMG containing the `.app` and a `/Applications` alias. Runtime update mode mounts the verified DMG read-only, finds exactly one contained `.app` or the configured app name, copies it to staging, verifies it with the same bundle identity and Apple trust gates as zip updates, detaches the DMG, and reuses the existing whole-bundle replacement helper.
- **PKG installer install and update:** `artifact.kind == "pkgInstaller"` and `install.strategy == "pkgInstaller"`. The release CLI creates, signs, notarizes, staples, verifies, publishes, and validates a `.pkg`. Runtime mode downloads and verifies the `.pkg`, checks `pkgutil`, `spctl`, and stapler acceptance, stages it with a manifest, then launches Installer.app for user-confirmed installation. It does not call `sudo`, AppleScript privilege escalation, `AuthorizationExecuteWithPrivileges`, or a hidden root install.

The optional **Move to Applications** flow is separate from update artifacts. Apps opt in to a runtime prompt when launched from a DMG volume, Downloads, or another non-installed location. The prompt can copy the running app to `/Applications`, launch the copied app, and terminate the source instance.

## Descriptor Shape

Direct zip descriptors stay valid:

```json
{
  "artifact": {
    "kind": "zip",
    "url": "https://updates.example.com/releases/2.6.0/macos/Example-2.6.0-macos.zip",
    "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "length": 12345678
  },
  "install": {
    "strategy": "wholeBundleReplace"
  }
}
```

DMG update descriptors use a macOS-only artifact kind while preserving whole-bundle replacement semantics:

```json
{
  "artifact": {
    "kind": "dmg",
    "url": "https://updates.example.com/releases/2.6.0/macos/Example-2.6.0-macos.dmg",
    "sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    "length": 23456789
  },
  "install": {
    "strategy": "wholeBundleReplace",
    "macosDmg": {
      "appBundleName": "Example.app",
      "verifyPrimarySignature": true
    }
  },
  "minimumUpdaterVersion": "2.6.0"
}
```

PKG installer descriptors use installer-owned semantics:

```json
{
  "artifact": {
    "kind": "pkgInstaller",
    "url": "https://updates.example.com/releases/2.6.0/macos/Example-2.6.0-macos.pkg",
    "sha256": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
    "length": 34567890
  },
  "install": {
    "strategy": "pkgInstaller",
    "macosPkg": {
      "launchMode": "installerApp",
      "expectedPackageIds": ["com.example.app.pkg"],
      "relaunchAfterInstall": false
    }
  },
  "minimumUpdaterVersion": "2.6.0"
}
```

## File Map

### Descriptor And Runtime Core

- Modify `lib/src/core/release_descriptor.dart`.
  - Add `dmg` and `pkgInstaller` artifact kinds.
  - Add `ReleaseMacOSDmgInstall` and `ReleaseMacOSPkgInstall`.
  - Add validation tying `dmg` to `macos + wholeBundleReplace`, and `pkgInstaller` to `macos + pkgInstaller`.
- Modify `lib/src/core/artifact_verifier.dart`.
  - Keep URL, length, SHA-256, and optional descriptor signature verification shared across all artifact kinds.
- Modify `lib/src/core/update_client.dart`.
  - Keep zip staging unchanged.
  - Add DMG download, mount, app extraction, trust verification, and detach.
  - Add PKG download, trust verification, and installer staging.
- Create `lib/src/core/macos_distribution_artifacts.dart`.
  - Own DMG mount/detach, contained app discovery/copy, DMG assessment, PKG assessment, and test injection interfaces.
- Modify `lib/src/core/update_telemetry.dart`.
  - Ensure artifact kind and install strategy fields cover `dmg` and `pkgInstaller`.
- Test with `test/release_descriptor_test.dart`, `test/artifact_verifier_test.dart`, `test/update_client_security_test.dart`, `test/macos_distribution_artifacts_test.dart`, and `test/update_diagnostics_test.dart`.

### macOS Native Helper And Public API

- Modify `lib/desktop_updater_platform_interface.dart`.
  - Add macOS install-location and move-to-Applications platform methods.
- Modify `lib/desktop_updater_method_channel.dart`.
  - Forward new method channel calls.
- Modify `lib/desktop_updater.dart`.
  - Add public Dart facade APIs for macOS install-location checks and app move.
- Create `lib/src/macos_install_location.dart`.
  - Define `MacOSInstallLocationStatus`, `MacOSInstallLocationKind`, and prompt policy helpers.
- Create `lib/widget/macos_move_to_applications_prompt.dart`.
  - Optional Flutter prompt widget for apps that want the packaged UX.
- Modify `lib/widget/update_widget.dart` only if the prompt is offered as an opt-in wrapper around existing update surfaces.
- Modify `macos/desktop_updater/Sources/desktop_updater/DesktopUpdaterPlugin.swift`.
  - Add install-location detection.
  - Add move-to-Applications copy/relaunch.
  - Add `pkgInstaller` helper branch that opens the verified staged `.pkg` with Installer.app.
- Test with `test/desktop_updater_method_channel_test.dart`, `test/desktop_updater_test.dart`, `test/macos_install_location_test.dart`, `test/macos_move_to_applications_prompt_test.dart`, `test/native_helper_script_test.dart`, and `macos/desktop_updater/Tests/desktop_updaterTests/DesktopUpdaterSwiftPMTests.swift`.

### Release CLI And Packaging

- Modify `lib/src/release_cli/release_publish_config.dart`.
  - Parse `macos.artifact.kind: zip|dmg|pkg`.
  - Parse DMG and PKG configuration.
- Create `lib/src/release_cli/macos/macos_artifact_config.dart`.
  - Own typed DMG/PKG config objects and validation helpers.
- Create `lib/src/release_cli/macos/dmg_packager.dart`.
  - Build app plus `/Applications` alias staging and create `.dmg`.
- Create `lib/src/release_cli/macos/pkg_packager.dart`.
  - Build component/product packages, sign installer packages, and write descriptors.
- Create `lib/src/release_cli/macos/apple_trust_commands.dart`.
  - Centralize signing, notarization, stapling, and assessment command wrappers.
- Modify `lib/src/release_cli/release_publisher.dart`.
  - Select zip, DMG, or PKG packager for macOS.
  - Preserve existing Windows Inno selection.
  - Extend hook environment artifact kind detection beyond `.exe` and `.zip`.
- Modify `lib/src/release_cli/publish_layout.dart`.
  - Support `.dmg` and `.pkg` artifact extensions.
- Modify `lib/src/release_cli/publish_manifest.dart`.
  - Round-trip `dmg` and `pkgInstaller` artifact kinds.
- Modify `lib/src/release_cli/validate_command.dart` and `bin/verify.dart`.
  - Run macOS trust validation for hosted/downloaded DMG and PKG artifacts when the host is macOS.
- Test with `test/release_cli/release_publish_config_test.dart`, `test/release_cli/dmg_packager_test.dart`, `test/release_cli/pkg_packager_test.dart`, `test/release_cli/apple_trust_commands_test.dart`, `test/release_cli/release_publisher_build_test.dart`, `test/release_cli/publish_layout_test.dart`, `test/release_cli/publish_manifest_test.dart`, and `test/release_cli/release_validate_test.dart`.

### Local MacBook Production Smoke

- Create `tool/macos_production_smoke.dart`.
  - Provide `doctor`, `dmg-first-install`, `move-to-applications`, `dmg-update`, `pkg-installer`, and `all --cleanup`.
- Modify `example/tool/release_publish_smoke.dart` only if helper functions are shared safely.
- Modify `example/tool/updater_smoke.dart` only if the new smoke harness reuses current staging/install checks.
- Test with `test/macos_production_smoke_tool_test.dart`.

### Docs And Harness Checks

- Modify `README.md`.
  - Add only a short link to the detailed macOS DMG/PKG document.
- Create `docs/macos-dmg-pkg-installer-updates.md`.
  - Document first install, update modes, signing/notarization/stapling, acceptance gates, Move to Applications, PKG boundary, smoke commands, and cleanup.
- Modify `docs/publishing.md`.
  - Add concise macOS artifact config examples and link to the detailed doc.
- Modify `docs/github-actions-ci-cd.md`.
  - Explain CI secret boundary and `not run` labels for local-only Apple trust smoke.
- Modify `docs/diagnostics-and-recovery.md`.
  - Add DMG and PKG native helper event names.
- Modify `docs/migration/1.x-to-2.0.md` only if the new descriptor contract changes migration guidance.
- Test with `test/harness_engineering_docs_test.dart`, `test/native_helper_diagnostics_docs_test.dart`, and a new `test/macos_dmg_pkg_docs_test.dart`.

## Local Required Environment

The local MacBook production smoke requires:

```sh
export DESKTOP_UPDATER_DEV_ID_APP="Developer ID Application: Example Corp (TEAMID1234)"
export DESKTOP_UPDATER_DEV_ID_INSTALLER="Developer ID Installer: Example Corp (TEAMID1234)"
export DESKTOP_UPDATER_NOTARY_PROFILE="desktop-updater-notary"
export DESKTOP_UPDATER_TEST_BUNDLE_ID="com.example.desktopUpdaterSmoke"
```

Optional smoke variables:

```sh
export DESKTOP_UPDATER_TEST_APP_NAME="Desktop Updater Smoke"
export DESKTOP_UPDATER_TEST_VERSION_V1="1.0.0"
export DESKTOP_UPDATER_TEST_VERSION_V2="1.0.1"
export DESKTOP_UPDATER_TEST_UPDATE_BASE_URL="http://127.0.0.1:0/"
export DESKTOP_UPDATER_TEST_WORKDIR="/tmp/desktop_updater_macos_smoke"
export DESKTOP_UPDATER_KEEP_MACOS_SMOKE="1"
```

## Apple Acceptance Gates

Every production lane must be able to produce evidence from these commands:

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

For notary submissions that use `--keychain`, pass the same keychain used when storing the profile. The smoke harness should print the exact command with redacted credential paths and record the parsed acceptance status.

## Task 1: Extend Release Descriptors For macOS DMG And PKG

**Files:**

- Modify: `lib/src/core/release_descriptor.dart`
- Test: `test/release_descriptor_test.dart`

**Interfaces:**

- Consumes: existing `ReleaseDescriptor`, `ReleaseArtifact`, and `ReleaseInstall` constructors.
- Produces: `ReleaseArtifact.kind == "dmg"` for macOS DMG artifacts.
- Produces: `ReleaseArtifact.kind == "pkgInstaller"` for macOS PKG artifacts.
- Produces: `ReleaseInstall.macosDmg` as `ReleaseMacOSDmgInstall?`.
- Produces: `ReleaseInstall.macosPkg` as `ReleaseMacOSPkgInstall?`.
- Produces: validation that rejects unsupported platform/artifact/strategy pairings before download.

- [ ] **Step 1.1: Write failing descriptor parse tests**

Add these tests to `test/release_descriptor_test.dart` near the Inno descriptor tests:

```dart
test("parses a macOS DMG update descriptor", () {
  final descriptor = ReleaseDescriptor.fromJson({
    ..._descriptorJson(),
    "platform": "macos",
    "artifact": {
      "kind": "dmg",
      "url": "https://cdn.example.com/Example-2.6.0.dmg",
      "sha256": "b" * 64,
      "length": 42,
    },
    "install": {
      "strategy": "wholeBundleReplace",
      "macosDmg": {
        "appBundleName": "Example.app",
        "verifyPrimarySignature": true,
      },
    },
    "minimumUpdaterVersion": "2.6.0",
  });

  expect(descriptor.artifact.kind, "dmg");
  expect(descriptor.install.strategy, "wholeBundleReplace");
  expect(descriptor.install.macosDmg!.appBundleName, "Example.app");
  expect(descriptor.install.macosDmg!.verifyPrimarySignature, isTrue);
});

test("parses a macOS PKG installer descriptor", () {
  final descriptor = ReleaseDescriptor.fromJson({
    ..._descriptorJson(),
    "platform": "macos",
    "artifact": {
      "kind": "pkgInstaller",
      "url": "https://cdn.example.com/Example-2.6.0.pkg",
      "sha256": "c" * 64,
      "length": 43,
    },
    "install": {
      "strategy": "pkgInstaller",
      "macosPkg": {
        "launchMode": "installerApp",
        "expectedPackageIds": ["com.example.app.pkg"],
        "relaunchAfterInstall": false,
      },
    },
    "minimumUpdaterVersion": "2.6.0",
  });

  expect(descriptor.artifact.kind, "pkgInstaller");
  expect(descriptor.install.strategy, "pkgInstaller");
  expect(descriptor.install.macosPkg!.launchMode, "installerApp");
  expect(descriptor.install.macosPkg!.expectedPackageIds, [
    "com.example.app.pkg",
  ]);
  expect(descriptor.install.macosPkg!.relaunchAfterInstall, isFalse);
});
```

Run:

```sh
flutter test --no-pub test/release_descriptor_test.dart
```

Expected: FAIL with missing artifact kind and missing `macosDmg`/`macosPkg` accessors.

- [ ] **Step 1.2: Write failing rejection tests**

Add tests that prove the schema fails closed:

```dart
test("rejects DMG artifacts outside macOS whole-bundle replacement", () {
  final json = {
    ..._descriptorJson(),
    "platform": "windows",
    "artifact": {
      "kind": "dmg",
      "url": "https://cdn.example.com/Example.dmg",
      "sha256": "b" * 64,
      "length": 42,
    },
    "install": {"strategy": "wholeBundleReplace"},
  };

  expect(
    () => ReleaseDescriptor.fromJson(json),
    throwsA(isA<FormatException>().having(
      (error) => error.message,
      "message",
      contains("dmg artifacts are only supported for macos"),
    )),
  );
});

test("rejects PKG artifacts without pkgInstaller strategy", () {
  final json = {
    ..._descriptorJson(),
    "platform": "macos",
    "artifact": {
      "kind": "pkgInstaller",
      "url": "https://cdn.example.com/Example.pkg",
      "sha256": "c" * 64,
      "length": 43,
    },
    "install": {"strategy": "wholeBundleReplace"},
  };

  expect(
    () => ReleaseDescriptor.fromJson(json),
    throwsA(isA<FormatException>().having(
      (error) => error.message,
      "message",
      contains("pkgInstaller artifacts require install.strategy pkgInstaller"),
    )),
  );
});
```

Run:

```sh
flutter test --no-pub test/release_descriptor_test.dart
```

Expected: FAIL until validation supports the new cases.

- [ ] **Step 1.3: Implement descriptor value objects**

Modify `ReleaseArtifact.validate()` to allow `"dmg"` and `"pkgInstaller"`.

Extend `ReleaseInstall`:

```dart
const ReleaseInstall({
  required this.strategy,
  this.inno,
  this.macosDmg,
  this.macosPkg,
});

final ReleaseMacOSDmgInstall? macosDmg;
final ReleaseMacOSPkgInstall? macosPkg;
```

Add `ReleaseMacOSDmgInstall`:

```dart
class ReleaseMacOSDmgInstall {
  const ReleaseMacOSDmgInstall({
    required this.appBundleName,
    required this.verifyPrimarySignature,
  });

  factory ReleaseMacOSDmgInstall.fromJson(Map<String, dynamic> json) {
    return ReleaseMacOSDmgInstall(
      appBundleName: json["appBundleName"] as String? ?? "",
      verifyPrimarySignature: json["verifyPrimarySignature"] as bool? ?? true,
    );
  }

  final String appBundleName;
  final bool verifyPrimarySignature;

  Map<String, dynamic> toJson() {
    return {
      "appBundleName": appBundleName,
      "verifyPrimarySignature": verifyPrimarySignature,
    };
  }

  void validate() {
    if (!appBundleName.endsWith(".app") || appBundleName.contains("/")) {
      throw const FormatException(
        "release.json install.macosDmg.appBundleName must be a simple .app name.",
      );
    }
  }
}
```

Add `ReleaseMacOSPkgInstall`:

```dart
class ReleaseMacOSPkgInstall {
  const ReleaseMacOSPkgInstall({
    required this.launchMode,
    required this.expectedPackageIds,
    required this.relaunchAfterInstall,
  });

  factory ReleaseMacOSPkgInstall.fromJson(Map<String, dynamic> json) {
    return ReleaseMacOSPkgInstall(
      launchMode: json["launchMode"] as String? ?? "installerApp",
      expectedPackageIds: _parseStringList(
        json["expectedPackageIds"],
        "install.macosPkg.expectedPackageIds",
      ),
      relaunchAfterInstall: json["relaunchAfterInstall"] as bool? ?? false,
    );
  }

  final String launchMode;
  final List<String> expectedPackageIds;
  final bool relaunchAfterInstall;

  Map<String, dynamic> toJson() {
    return {
      "launchMode": launchMode,
      "expectedPackageIds": expectedPackageIds,
      "relaunchAfterInstall": relaunchAfterInstall,
    };
  }

  void validate() {
    if (launchMode != "installerApp") {
      throw const FormatException(
        "release.json install.macosPkg.launchMode must be installerApp.",
      );
    }
    if (expectedPackageIds.isEmpty) {
      throw const FormatException(
        "release.json install.macosPkg.expectedPackageIds must not be empty.",
      );
    }
  }
}
```

In `ReleaseInstall.validate`, add the platform rules:

```dart
if (artifactKind == "dmg") {
  if (platform != "macos" || strategy != "wholeBundleReplace") {
    throw const FormatException(
      "release.json dmg artifacts are only supported for macos wholeBundleReplace.",
    );
  }
  if (macosDmg == null) {
    throw const FormatException(
      "release.json install.macosDmg is required for dmg artifacts.",
    );
  }
  macosDmg!.validate();
}

if (artifactKind == "pkgInstaller") {
  if (platform != "macos" || strategy != "pkgInstaller") {
    throw const FormatException(
      "release.json pkgInstaller artifacts require install.strategy pkgInstaller on macos.",
    );
  }
  if (macosPkg == null) {
    throw const FormatException(
      "release.json install.macosPkg is required for pkgInstaller.",
    );
  }
  macosPkg!.validate();
}
```

- [ ] **Step 1.4: Verify descriptor tests**

Run:

```sh
flutter test --no-pub test/release_descriptor_test.dart
```

Expected: PASS.

- [ ] **Step 1.5: Commit**

Suggested commit:

```sh
git add lib/src/core/release_descriptor.dart test/release_descriptor_test.dart
git commit -m "feat: add macos dmg and pkg descriptor contracts"
```

## Task 2: Add macOS DMG And PKG Artifact Verification Helpers

**Files:**

- Create: `lib/src/core/macos_distribution_artifacts.dart`
- Test: `test/macos_distribution_artifacts_test.dart`
- Modify: `lib/src/macos_update.dart` only if existing Apple trust helpers should be reused from the new file.

**Interfaces:**

- Consumes: `ProcessRunner` and existing `verifyMacOSNativeGates`.
- Produces: `MacOSDistributionVerifier`.
- Produces: `MountedDmg`.
- Produces: `mountDmgReadOnly`, `detachDmg`, `copyAppFromMountedDmg`, `verifyDmgPrimarySignature`, and `verifyPkgInstaller`.

- [ ] **Step 2.1: Write failing command-order tests for DMG**

Create `test/macos_distribution_artifacts_test.dart`:

```dart
import "dart:io";

import "package:desktop_updater/src/core/macos_distribution_artifacts.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  test("DMG verification assesses primary signature before attach", () async {
    final commands = <String>[];
    final verifier = MacOSDistributionVerifier(
      runProcess: (executable, arguments) async {
        commands.add([executable, ...arguments].join(" "));
        if (executable == "/usr/bin/hdiutil" && arguments.first == "attach") {
          return ProcessResult(
            0,
            0,
            "/dev/disk4\tApple_HFS\t/Volumes/Example\n",
            "",
          );
        }
        return ProcessResult(0, 0, "", "");
      },
    );

    final mounted = await verifier.mountVerifiedDmg(
      dmg: File("/tmp/Example.dmg"),
      verifyPrimarySignature: true,
    );

    expect(mounted.mountPoint, "/Volumes/Example");
    expect(commands, [
      startsWith(
        "/usr/sbin/spctl --assess --type open --context context:primary-signature",
      ),
      "/usr/bin/hdiutil attach -readonly -nobrowse /tmp/Example.dmg",
    ]);
  });
}
```

Run:

```sh
flutter test --no-pub test/macos_distribution_artifacts_test.dart
```

Expected: FAIL because the helper file does not exist.

- [ ] **Step 2.2: Write failing PKG verification test**

Add:

```dart
test("PKG verification runs package signature, install assessment, and stapler", () async {
  final commands = <String>[];
  final verifier = MacOSDistributionVerifier(
    createTempDirectory: () async => Directory("/tmp/pkg-expanded"),
    runProcess: (executable, arguments) async {
      commands.add([executable, ...arguments].join(" "));
      return ProcessResult(0, 0, "Package ID: com.example.app.pkg\n", "");
    },
  );

  await verifier.verifyPkgInstaller(
    pkg: File("/tmp/Example.pkg"),
    expectedPackageIds: const ["com.example.app.pkg"],
  );

  expect(commands, [
    "/usr/sbin/pkgutil --check-signature /tmp/Example.pkg",
    "/usr/sbin/spctl --assess --type install --verbose=2 /tmp/Example.pkg",
    "/usr/bin/xcrun stapler validate /tmp/Example.pkg",
    "/usr/sbin/pkgutil --expand-full /tmp/Example.pkg /tmp/pkg-expanded",
  ]);
});
```

Run the focused test again. Expected: FAIL.

- [ ] **Step 2.3: Implement the helper class with injectable process runner**

Create `lib/src/core/macos_distribution_artifacts.dart` with:

```dart
import "dart:io";

import "package:desktop_updater/src/macos_update.dart";
import "package:path/path.dart" as path;

class MountedDmg {
  const MountedDmg({required this.imagePath, required this.mountPoint});

  final String imagePath;
  final String mountPoint;
}

class MacOSDistributionVerifier {
  const MacOSDistributionVerifier({
    this.runProcess = defaultProcessRunner,
    this.createTempDirectory = _defaultCreateTempDirectory,
  });

  final ProcessRunner runProcess;
  final Future<Directory> Function() createTempDirectory;

  Future<MountedDmg> mountVerifiedDmg({
    required File dmg,
    required bool verifyPrimarySignature,
  }) async {
    if (verifyPrimarySignature) {
      await _runChecked("/usr/sbin/spctl", [
        "--assess",
        "--type",
        "open",
        "--context",
        "context:primary-signature",
        "--verbose=2",
        dmg.path,
      ]);
    }
    final result = await _runChecked("/usr/bin/hdiutil", [
      "attach",
      "-readonly",
      "-nobrowse",
      dmg.path,
    ]);
    return MountedDmg(
      imagePath: dmg.path,
      mountPoint: _parseMountPoint(result.stdout.toString()),
    );
  }

  Future<void> detachDmg(MountedDmg mounted) {
    return _runChecked("/usr/bin/hdiutil", ["detach", mounted.mountPoint]);
  }

  Future<Directory> copyAppFromMountedDmg({
    required MountedDmg mounted,
    required String appBundleName,
    required Directory destinationParent,
  }) async {
    final source = Directory(path.join(mounted.mountPoint, appBundleName));
    final destination = Directory(path.join(destinationParent.path, appBundleName));
    await _runChecked("/usr/bin/ditto", [source.path, destination.path]);
    return destination;
  }

  Future<void> verifyPkgInstaller({
    required File pkg,
    required List<String> expectedPackageIds,
  }) async {
    await _runChecked("/usr/sbin/pkgutil", ["--check-signature", pkg.path]);
    await _runChecked("/usr/sbin/spctl", [
      "--assess",
      "--type",
      "install",
      "--verbose=2",
      pkg.path,
    ]);
    await _runChecked("/usr/bin/xcrun", ["stapler", "validate", pkg.path]);
    final expanded = await createTempDirectory();
    try {
      await _runChecked("/usr/sbin/pkgutil", [
        "--expand-full",
        pkg.path,
        expanded.path,
      ]);
      await _verifyExpectedPackageIdsFromExpandedPkg(
        expanded: expanded,
        expectedPackageIds: expectedPackageIds,
      );
    } finally {
      if (await expanded.exists()) {
        await expanded.delete(recursive: true);
      }
    }
  }

  Future<ProcessResult> _runChecked(String executable, List<String> arguments) async {
    final result = await runProcess(executable, arguments);
    if (result.exitCode != 0) {
      throw ProcessException(
        executable,
        arguments,
        "${result.stdout}${result.stderr}",
        result.exitCode,
      );
    }
    return result;
  }
}
```

Parse identifiers from expanded `PackageInfo` and `Distribution` files after `pkgutil --expand-full`. The parser should collect `identifier="..."` from `<pkg-info>` and `id="..."` from `<pkg-ref>` entries, compare them against `expectedPackageIds`, and throw a `StateError` naming the missing package identifier when an expected value is absent.

- [ ] **Step 2.4: Add detach-on-error tests**

Add a test proving DMG mounts are detached when app copy or verification fails:

```dart
test("detaches mounted DMG when app extraction fails", () async {
  final commands = <String>[];
  final verifier = MacOSDistributionVerifier(
    runProcess: (executable, arguments) async {
      commands.add([executable, ...arguments].join(" "));
      if (executable == "/usr/bin/hdiutil" && arguments.first == "attach") {
        return ProcessResult(0, 0, "/dev/disk4\tApple_HFS\t/Volumes/Example\n", "");
      }
      if (executable == "/usr/bin/ditto") {
        return ProcessResult(1, 0, "", "copy failed");
      }
      return ProcessResult(0, 0, "", "");
    },
  );

  final mounted = await verifier.mountVerifiedDmg(
    dmg: File("/tmp/Example.dmg"),
    verifyPrimarySignature: false,
  );
  await expectLater(
    verifier.copyAppFromMountedDmg(
      mounted: mounted,
      appBundleName: "Example.app",
      destinationParent: Directory("/tmp/stage"),
    ),
    throwsA(isA<ProcessException>()),
  );
  await verifier.detachDmg(mounted);

  expect(commands.last, "/usr/bin/hdiutil detach /Volumes/Example");
});
```

Run:

```sh
flutter test --no-pub test/macos_distribution_artifacts_test.dart
```

Expected: PASS after implementation.

- [ ] **Step 2.5: Commit**

Suggested commit:

```sh
git add lib/src/core/macos_distribution_artifacts.dart test/macos_distribution_artifacts_test.dart
git commit -m "feat: add macos distribution artifact verification helpers"
```

## Task 3: Stage DMG And PKG Artifacts In UpdateClient

**Files:**

- Modify: `lib/src/core/update_client.dart`
- Modify: `lib/src/core/update_telemetry.dart` if event constructors need stricter documentation.
- Test: `test/update_client_security_test.dart`

**Interfaces:**

- Consumes: `ReleaseDescriptor.artifact.kind`, `ReleaseInstall.macosDmg`, and `ReleaseInstall.macosPkg`.
- Consumes: `MacOSDistributionVerifier`.
- Produces: DMG staging result whose `stagingPath` is a verified `.app` path.
- Produces: PKG staging result whose `stagingPath` is the staging root containing `installer.pkg` and `.desktop_updater_release_manifest.json`.

- [ ] **Step 3.1: Add failing DMG staging test**

In `test/update_client_security_test.dart`, add a fake verifier through a new `UpdateClient` constructor parameter:

```dart
test("stages macOS DMG artifacts as verified app bundles", () async {
  final root = await Directory.systemTemp.createTemp("dmg_stage_");
  addTearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  final dmg = File(path.join(root.path, "Example.dmg"));
  await dmg.writeAsBytes([1, 2, 3, 4]);
  final descriptor = _descriptor(
    platform: "macos",
    artifactKind: "dmg",
    artifactUrl: dmg.uri,
    artifactSha256: await sha256File(dmg),
    artifactLength: await dmg.length(),
    minimumUpdaterVersion: "2.6.0",
    install: const ReleaseInstall(
      strategy: "wholeBundleReplace",
      macosDmg: ReleaseMacOSDmgInstall(
        appBundleName: "Example.app",
        verifyPrimarySignature: true,
      ),
    ),
  );

  final client = UpdateClient(
    appArchiveUrl: Uri.parse("https://updates.example.com/app-archive.json"),
    currentVersion: DesktopVersionInfo.parse("1.0.0"),
    platform: "macos",
    stagingParent: root,
    macosDistributionVerifier: _FakeMacOSDistributionVerifier(
      copiedAppName: "Example.app",
    ),
  );

  final staged = await client.downloadVerifyAndStage(descriptor: descriptor);

  expect(staged.stagingPath, endsWith("Example.app"));
  expect(File(path.join(
    Directory(staged.stagingPath).parent.path,
    stagedReleaseManifestFileName,
  )).existsSync(), isTrue);
});
```

Run:

```sh
flutter test --no-pub test/update_client_security_test.dart
```

Expected: FAIL because `UpdateClient` has no `macosDistributionVerifier` injection and no DMG branch.

- [ ] **Step 3.2: Add failing PKG staging test**

Add:

```dart
test("stages macOS PKG installer artifacts without extracting", () async {
  final root = await Directory.systemTemp.createTemp("pkg_stage_");
  addTearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  final pkg = File(path.join(root.path, "Example.pkg"));
  await pkg.writeAsBytes([4, 3, 2, 1]);
  final descriptor = _descriptor(
    platform: "macos",
    artifactKind: "pkgInstaller",
    artifactUrl: pkg.uri,
    artifactSha256: await sha256File(pkg),
    artifactLength: await pkg.length(),
    minimumUpdaterVersion: "2.6.0",
    install: const ReleaseInstall(
      strategy: "pkgInstaller",
      macosPkg: ReleaseMacOSPkgInstall(
        launchMode: "installerApp",
        expectedPackageIds: ["com.example.app.pkg"],
        relaunchAfterInstall: false,
      ),
    ),
  );

  final client = UpdateClient(
    appArchiveUrl: Uri.parse("https://updates.example.com/app-archive.json"),
    currentVersion: DesktopVersionInfo.parse("1.0.0"),
    platform: "macos",
    stagingParent: root,
    macosDistributionVerifier: const _FakeMacOSDistributionVerifier(),
  );

  final staged = await client.downloadVerifyAndStage(descriptor: descriptor);

  expect(File(path.join(staged.stagingPath, "installer.pkg")).existsSync(), isTrue);
  expect(File(path.join(
    staged.stagingPath,
    stagedReleaseManifestFileName,
  )).existsSync(), isTrue);
});
```

Run the focused test. Expected: FAIL.

- [ ] **Step 3.3: Implement UpdateClient branching**

Add a constructor dependency:

```dart
MacOSDistributionVerifier macosDistributionVerifier =
    const MacOSDistributionVerifier(),
```

Store it as `_macosDistributionVerifier`.

In `downloadVerifyAndStage`, keep `artifact.zip` naming for zip and Inno only where it is accurate. Use an extension-aware temp artifact:

```dart
final artifactFile = File(path.join(
  stagingRoot.path,
  switch (descriptor.artifact.kind) {
    "dmg" => "artifact.dmg",
    "pkgInstaller" => "artifact.pkg",
    "innoInstaller" => "artifact.exe",
    _ => "artifact.zip",
  },
));
```

Add a DMG branch after SHA-256 verification:

```dart
if (descriptor.artifact.kind == "dmg") {
  if (descriptor.platform != "macos" || platform != "macos") {
    throw UnsupportedError("DMG updates are only supported on macOS.");
  }
  final dmg = descriptor.install.macosDmg!;
  final mounted = await _macosDistributionVerifier.mountVerifiedDmg(
    dmg: artifactFile,
    verifyPrimarySignature: dmg.verifyPrimarySignature,
  );
  try {
    final stagedApp = await _macosDistributionVerifier.copyAppFromMountedDmg(
      mounted: mounted,
      appBundleName: dmg.appBundleName,
      destinationParent: stagingRoot,
    );
    await rejectTopLevelMacOSAppSymlink(stagedApp.path);
    await File(path.join(stagingRoot.path, stagedReleaseManifestFileName))
        .writeAsString(const JsonEncoder.withIndent("  ").convert(descriptor.toJson()));
    return UpdateStageResult(descriptor: descriptor, stagingPath: stagedApp.path);
  } finally {
    await _macosDistributionVerifier.detachDmg(mounted);
  }
}
```

Add a PKG branch:

```dart
if (descriptor.artifact.kind == "pkgInstaller") {
  if (descriptor.platform != "macos" || platform != "macos") {
    throw UnsupportedError("PKG installer updates are only supported on macOS.");
  }
  await _macosDistributionVerifier.verifyPkgInstaller(
    pkg: artifactFile,
    expectedPackageIds: descriptor.install.macosPkg!.expectedPackageIds,
  );
  final installerFile = File(path.join(stagingRoot.path, "installer.pkg"));
  await artifactFile.rename(installerFile.path);
  await File(path.join(stagingRoot.path, stagedReleaseManifestFileName))
      .writeAsString(const JsonEncoder.withIndent("  ").convert(descriptor.toJson()));
  return UpdateStageResult(descriptor: descriptor, stagingPath: stagingRoot.path);
}
```

- [ ] **Step 3.4: Verify focused runtime tests**

Run:

```sh
flutter test --no-pub test/update_client_security_test.dart
```

Expected: PASS.

- [ ] **Step 3.5: Verify direct zip compatibility**

Run:

```sh
flutter test --no-pub test/e2e/zip_first_update_flow_test.dart
flutter test --no-pub test/macos_staged_app_symlink_test.dart
flutter test --no-pub test/macos_updater_manifest_test.dart
```

Expected: PASS. The `.app.zip` staging path and native helper manifest behavior stay unchanged.

- [ ] **Step 3.6: Commit**

Suggested commit:

```sh
git add lib/src/core/update_client.dart lib/src/core/update_telemetry.dart test/update_client_security_test.dart
git commit -m "feat: stage macos dmg and pkg update artifacts"
```

## Task 4: Add macOS PKG Native Helper Handoff

**Files:**

- Modify: `macos/desktop_updater/Sources/desktop_updater/DesktopUpdaterPlugin.swift`
- Test: `test/native_helper_script_test.dart`
- Test: `macos/desktop_updater/Tests/desktop_updaterTests/DesktopUpdaterSwiftPMTests.swift`

**Interfaces:**

- Consumes: staged root with `installer.pkg` and `.desktop_updater_release_manifest.json`.
- Consumes: `install.strategy == "pkgInstaller"` and `install.macosPkg.launchMode == "installerApp"`.
- Produces: native helper branch that opens Installer.app for the verified staged PKG.
- Produces: diagnostics events `pkg manifest loaded`, `pkg installer open`, and `pkg installer open failure`.

- [ ] **Step 4.1: Write failing helper source test**

Add to `test/native_helper_script_test.dart`:

```dart
test("macOS helper opens staged PKG installers without silent privilege escalation", () {
  final source = File(
    "macos/desktop_updater/Sources/desktop_updater/DesktopUpdaterPlugin.swift",
  ).readAsStringSync();

  expect(source, contains("pkgInstaller"));
  expect(source, contains("installer.pkg"));
  expect(source, contains("pkg installer open"));
  expect(source, contains("/usr/bin/open"));
  expect(source, isNot(contains("/usr/sbin/installer -pkg")));
  expect(source, isNot(contains("sudo")));
  expect(source, isNot(contains("osascript")));
});
```

Run:

```sh
flutter test --no-pub test/native_helper_script_test.dart
```

Expected: FAIL until the Swift helper adds a PKG branch.

- [ ] **Step 4.2: Implement manifest strategy detection**

In the generated shell script, read the staged manifest before `.app`-specific validation when `STAGING` is a directory containing `installer.pkg`:

```sh
MANIFEST="$STAGING/.desktop_updater_release_manifest.json"
if [ -f "$MANIFEST" ] && /usr/bin/grep -q '"strategy"[[:space:]]*:[[:space:]]*"pkgInstaller"' "$MANIFEST"; then
  log_event "pkg manifest loaded"
  PKG="$STAGING/installer.pkg"
  if [ ! -f "$PKG" ]; then
    echo "Staged macOS PKG installer is missing." >&2
    exit 1
  fi
  log_event "pkg installer open"
  if /usr/bin/open "$PKG"; then
    log_event "pkg installer opened"
    rm -f "$0"
    exit 0
  fi
  log_event "pkg installer open failure"
  exit 1
fi
```

Keep the existing `.app` path validation and whole-bundle replacement script for zip and DMG updates. Do not add a root `installer` command in this task.

- [ ] **Step 4.3: Add SwiftPM smoke assertion**

In `DesktopUpdaterSwiftPMTests.swift`, add a source or method-channel assertion that the macOS plugin exposes `installUpdate` and still compiles after the helper script changes. If the current SwiftPM test is only a compile test, keep it compile-focused and rely on Dart source tests for script text.

Run:

```sh
swift test
```

Expected: PASS on macOS. Label as `not run` on non-macOS hosts.

- [ ] **Step 4.4: Verify helper tests**

Run:

```sh
flutter test --no-pub test/native_helper_script_test.dart
```

Expected: PASS.

- [ ] **Step 4.5: Commit**

Suggested commit:

```sh
git add macos/desktop_updater/Sources/desktop_updater/DesktopUpdaterPlugin.swift test/native_helper_script_test.dart macos/desktop_updater/Tests/desktop_updaterTests/DesktopUpdaterSwiftPMTests.swift
git commit -m "feat: hand off macos pkg installers to Installer app"
```

## Task 5: Add Move To Applications Runtime API

**Files:**

- Create: `lib/src/macos_install_location.dart`
- Modify: `lib/desktop_updater.dart`
- Modify: `lib/desktop_updater_platform_interface.dart`
- Modify: `lib/desktop_updater_method_channel.dart`
- Modify: `macos/desktop_updater/Sources/desktop_updater/DesktopUpdaterPlugin.swift`
- Test: `test/macos_install_location_test.dart`
- Test: `test/desktop_updater_method_channel_test.dart`
- Test: `test/desktop_updater_test.dart`

**Interfaces:**

- Produces: `MacOSInstallLocationKind.installed`, `diskImage`, `downloads`, `other`, and `unsupported`.
- Produces: `MacOSInstallLocationStatus`.
- Produces: `DesktopUpdater.checkMacOSInstallLocation()`.
- Produces: `DesktopUpdater.moveMacOSAppToApplications({bool replaceExisting = false})`.
- Consumes: macOS native bundle path and destination `/Applications/<App>.app`.

- [ ] **Step 5.1: Write failing pure Dart model tests**

Create `test/macos_install_location_test.dart`:

```dart
import "package:desktop_updater/src/macos_install_location.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  test("classifies common macOS install locations", () {
    expect(
      classifyMacOSInstallLocation("/Applications/Example.app"),
      MacOSInstallLocationKind.installed,
    );
    expect(
      classifyMacOSInstallLocation("/Volumes/Example/Example.app"),
      MacOSInstallLocationKind.diskImage,
    );
    expect(
      classifyMacOSInstallLocation("/Users/me/Downloads/Example.app"),
      MacOSInstallLocationKind.downloads,
    );
    expect(
      classifyMacOSInstallLocation("/Users/me/Desktop/Example.app"),
      MacOSInstallLocationKind.other,
    );
  });
}
```

Run:

```sh
flutter test --no-pub test/macos_install_location_test.dart
```

Expected: FAIL because the model does not exist.

- [ ] **Step 5.2: Write failing method channel tests**

Add to `test/desktop_updater_method_channel_test.dart`:

```dart
test("checkMacOSInstallLocation parses native status", () async {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
    if (methodCall.method == "checkMacOSInstallLocation") {
      return {
        "kind": "diskImage",
        "bundlePath": "/Volumes/Example/Example.app",
        "targetPath": "/Applications/Example.app",
      };
    }
    return "42";
  });

  final status = await platform.checkMacOSInstallLocation();

  expect(status.kind, MacOSInstallLocationKind.diskImage);
  expect(status.targetPath, "/Applications/Example.app");
});

test("moveMacOSAppToApplications forwards replace policy", () async {
  late MethodCall capturedCall;
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
    capturedCall = methodCall;
    return null;
  });

  await platform.moveMacOSAppToApplications(replaceExisting: true);

  expect(capturedCall.method, "moveMacOSAppToApplications");
  expect(capturedCall.arguments, {"replaceExisting": true});
});
```

Run:

```sh
flutter test --no-pub test/desktop_updater_method_channel_test.dart
```

Expected: FAIL until platform interfaces are added.

- [ ] **Step 5.3: Implement Dart API and channel forwarding**

Create `MacOSInstallLocationStatus`:

```dart
enum MacOSInstallLocationKind {
  installed,
  diskImage,
  downloads,
  other,
  unsupported,
}

class MacOSInstallLocationStatus {
  const MacOSInstallLocationStatus({
    required this.kind,
    required this.bundlePath,
    required this.targetPath,
  });

  factory MacOSInstallLocationStatus.fromJson(Map<String, Object?> json) {
    return MacOSInstallLocationStatus(
      kind: MacOSInstallLocationKind.values.byName(json["kind"] as String),
      bundlePath: json["bundlePath"] as String?,
      targetPath: json["targetPath"] as String?,
    );
  }

  final MacOSInstallLocationKind kind;
  final String? bundlePath;
  final String? targetPath;

  bool get shouldOfferMovePrompt {
    return kind == MacOSInstallLocationKind.diskImage ||
        kind == MacOSInstallLocationKind.downloads ||
        kind == MacOSInstallLocationKind.other;
  }
}
```

Expose facade methods from `DesktopUpdater` and platform interface. On non-macOS platforms, native implementations return `unsupported`.

- [ ] **Step 5.4: Implement macOS native detection and move**

In Swift:

- `checkMacOSInstallLocation` returns `kind`, `bundlePath`, and `targetPath`.
- `kind == installed` when bundle path is under `/Applications` or `$HOME/Applications`.
- `kind == diskImage` when bundle path is under `/Volumes/`.
- `kind == downloads` when bundle path is under the current user Downloads directory.
- `kind == other` for any other `.app` outside installed roots.
- `moveMacOSAppToApplications` copies the current bundle to `/Applications/<BundleName>.app` with `FileManager.copyItem`, refuses to overwrite unless `replaceExisting` is true, launches the copied app with `NSWorkspace.shared.openApplication`, then terminates the current app.

The native method must not detach a DMG or delete the source app. The user controls those outside this package.

- [ ] **Step 5.5: Verify focused tests**

Run:

```sh
flutter test --no-pub test/macos_install_location_test.dart
flutter test --no-pub test/desktop_updater_method_channel_test.dart
flutter test --no-pub test/desktop_updater_test.dart
swift test
```

Expected: PASS on macOS for `swift test`; Dart tests pass everywhere.

- [ ] **Step 5.6: Commit**

Suggested commit:

```sh
git add lib/src/macos_install_location.dart lib/desktop_updater.dart lib/desktop_updater_platform_interface.dart lib/desktop_updater_method_channel.dart macos/desktop_updater/Sources/desktop_updater/DesktopUpdaterPlugin.swift test/macos_install_location_test.dart test/desktop_updater_method_channel_test.dart test/desktop_updater_test.dart
git commit -m "feat: add macos move to applications runtime api"
```

## Task 6: Add Optional Move To Applications Prompt Widget

**Files:**

- Create: `lib/widget/macos_move_to_applications_prompt.dart`
- Modify: `lib/desktop_updater.dart`
- Modify: `lib/src/localization.dart`
- Test: `test/macos_move_to_applications_prompt_test.dart`
- Test: `test/localization_loader_test.dart` if bundled localization keys are added.

**Interfaces:**

- Consumes: `DesktopUpdater.checkMacOSInstallLocation`.
- Consumes: `DesktopUpdater.moveMacOSAppToApplications`.
- Produces: opt-in `MacOSMoveToApplicationsPrompt`.
- Produces: localized title, body, move, skip, and replace-existing error copy.

- [ ] **Step 6.1: Write failing widget test**

Create `test/macos_move_to_applications_prompt_test.dart`:

```dart
import "package:desktop_updater/desktop_updater.dart";
import "package:desktop_updater/src/macos_install_location.dart";
import "package:desktop_updater/widget/macos_move_to_applications_prompt.dart";
import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  testWidgets("shows prompt for disk image launches", (tester) async {
    var moveCalled = false;
    await tester.pumpWidget(MaterialApp(
      home: MacOSMoveToApplicationsPrompt(
        statusLoader: () async => const MacOSInstallLocationStatus(
          kind: MacOSInstallLocationKind.diskImage,
          bundlePath: "/Volumes/Example/Example.app",
          targetPath: "/Applications/Example.app",
        ),
        mover: ({required replaceExisting}) async {
          moveCalled = true;
        },
        child: const Text("Home"),
      ),
    ));

    await tester.pumpAndSettle();
    expect(find.text("Move to Applications?"), findsOneWidget);
    await tester.tap(find.text("Move"));
    await tester.pump();
    expect(moveCalled, isTrue);
  });
}
```

Run:

```sh
flutter test --no-pub test/macos_move_to_applications_prompt_test.dart
```

Expected: FAIL because the widget does not exist.

- [ ] **Step 6.2: Implement the opt-in widget**

Implement the widget as an app wrapper:

```dart
class MacOSMoveToApplicationsPrompt extends StatefulWidget {
  const MacOSMoveToApplicationsPrompt({
    super.key,
    required this.child,
    this.statusLoader,
    this.mover,
  });

  final Widget child;
  final Future<MacOSInstallLocationStatus> Function()? statusLoader;
  final Future<void> Function({required bool replaceExisting})? mover;
}
```

Behavior:

- Load status once after first frame.
- Render `child` normally while loading or when status is `installed` or `unsupported`.
- Show a Material dialog only when `status.shouldOfferMovePrompt` is true.
- `Move` calls `mover(replaceExisting: false)` by default.
- If native move returns an already-exists error, show a second confirmation with replace copy and call `replaceExisting: true` only after the user confirms.
- `Skip` closes the prompt for the current process.

- [ ] **Step 6.3: Verify widget and localization tests**

Run:

```sh
flutter test --no-pub test/macos_move_to_applications_prompt_test.dart
flutter test --no-pub test/localization_loader_test.dart
```

Expected: PASS.

- [ ] **Step 6.4: Commit**

Suggested commit:

```sh
git add lib/widget/macos_move_to_applications_prompt.dart lib/desktop_updater.dart lib/src/localization.dart test/macos_move_to_applications_prompt_test.dart test/localization_loader_test.dart
git commit -m "feat: add optional macos move to applications prompt"
```

## Task 7: Add macOS DMG And PKG Release CLI Config

**Files:**

- Modify: `lib/src/release_cli/release_publish_config.dart`
- Create: `lib/src/release_cli/macos/macos_artifact_config.dart`
- Test: `test/release_cli/release_publish_config_test.dart`

**Interfaces:**

- Produces: `MacOSArtifactKind.zip`, `dmg`, and `pkg`.
- Produces: `MacOSDmgPublishConfig`.
- Produces: `MacOSPkgPublishConfig`.
- Consumes: existing `MacOSPublishConfig` for notarization, stapling, and Gatekeeper settings.

- [ ] **Step 7.1: Write failing config tests**

Add to `test/release_cli/release_publish_config_test.dart`:

```dart
test("loads macOS DMG artifact publish config", () async {
  final config = await ReleasePublishConfig.fromYaml("""
updates:
  baseUrl: https://updates.example.com

macos:
  artifact:
    kind: dmg
  dmg:
    volumeName: Example
    appBundleName: Example.app
    applicationsAlias: true
""");

  expect(config.macos.artifactKind.name, "dmg");
  expect(config.macos.dmg.volumeName, "Example");
  expect(config.macos.dmg.appBundleName, "Example.app");
  expect(config.macos.dmg.applicationsAlias, isTrue);
});

test("loads macOS PKG artifact publish config", () async {
  final config = await ReleasePublishConfig.fromYaml("""
updates:
  baseUrl: https://updates.example.com

macos:
  artifact:
    kind: pkg
  pkg:
    packageIdentifier: com.example.app.pkg
    installLocation: /Applications
    signingIdentifier: "Developer ID Installer: Example Corp (TEAMID1234)"
""");

  expect(config.macos.artifactKind.name, "pkg");
  expect(config.macos.pkg.packageIdentifier, "com.example.app.pkg");
  expect(config.macos.pkg.installLocation, "/Applications");
  expect(
    config.macos.pkg.signingIdentifier,
    "Developer ID Installer: Example Corp (TEAMID1234)",
  );
});
```

Run:

```sh
flutter test --no-pub test/release_cli/release_publish_config_test.dart
```

Expected: FAIL because macOS artifact config is not implemented.

- [ ] **Step 7.2: Implement typed config**

Create `macos_artifact_config.dart`:

```dart
enum MacOSArtifactKind { zip, dmg, pkg }

class MacOSDmgPublishConfig {
  const MacOSDmgPublishConfig({
    required this.volumeName,
    required this.appBundleName,
    required this.applicationsAlias,
  });

  final String volumeName;
  final String appBundleName;
  final bool applicationsAlias;
}

class MacOSPkgPublishConfig {
  const MacOSPkgPublishConfig({
    required this.packageIdentifier,
    required this.installLocation,
    this.signingIdentifier,
  });

  final String packageIdentifier;
  final String installLocation;
  final String? signingIdentifier;
}
```

Extend `MacOSPublishConfig` with:

```dart
final MacOSArtifactKind artifactKind;
final MacOSDmgPublishConfig dmg;
final MacOSPkgPublishConfig pkg;
```

Defaults:

- `artifact.kind` defaults to `zip`.
- DMG defaults: `volumeName` from app name stem, `appBundleName` from `<AppName>.app`, `applicationsAlias` true.
- PKG requires `packageIdentifier` when `artifact.kind == pkg`.
- PKG `signingIdentifier` defaults to `DESKTOP_UPDATER_DEV_ID_INSTALLER` in smoke tooling, but release config should store only the non-secret identity string when provided.

- [ ] **Step 7.3: Verify config tests**

Run:

```sh
flutter test --no-pub test/release_cli/release_publish_config_test.dart
```

Expected: PASS.

- [ ] **Step 7.4: Commit**

Suggested commit:

```sh
git add lib/src/release_cli/release_publish_config.dart lib/src/release_cli/macos/macos_artifact_config.dart test/release_cli/release_publish_config_test.dart
git commit -m "feat: parse macos dmg and pkg publish config"
```

## Task 8: Add DMG And PKG Packagers

**Files:**

- Create: `lib/src/release_cli/macos/dmg_packager.dart`
- Create: `lib/src/release_cli/macos/pkg_packager.dart`
- Create: `lib/src/release_cli/macos/apple_trust_commands.dart`
- Modify: `lib/src/release_cli/release_publisher.dart`
- Test: `test/release_cli/dmg_packager_test.dart`
- Test: `test/release_cli/pkg_packager_test.dart`
- Test: `test/release_cli/apple_trust_commands_test.dart`
- Test: `test/release_cli/release_publisher_build_test.dart`

**Interfaces:**

- Consumes: `ReleasePackageRequest`, `MacOSDmgPublishConfig`, `MacOSPkgPublishConfig`, and `MacOSPublishConfig`.
- Produces: DMG `ReleasePackageResult` with `artifact.kind == "dmg"` and `install.strategy == "wholeBundleReplace"`.
- Produces: PKG `ReleasePackageResult` with `artifact.kind == "pkgInstaller"` and `install.strategy == "pkgInstaller"`.
- Produces: command wrappers for codesign, notarytool submit, stapler, spctl, hdiutil, pkgbuild, productbuild, and pkgutil.

- [ ] **Step 8.1: Write failing DMG packager test**

Create `test/release_cli/dmg_packager_test.dart`:

```dart
import "dart:convert";
import "dart:io";

import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:desktop_updater/src/package/release_packager.dart";
import "package:desktop_updater/src/release_cli/macos/dmg_packager.dart";
import "package:desktop_updater/src/release_cli/macos/macos_artifact_config.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;

void main() {
  test("packages a macOS DMG descriptor", () async {
    final root = await Directory.systemTemp.createTemp("dmg_packager_");
    addTearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });
    final app = Directory(path.join(root.path, "Example.app"));
    await app.create();
    final output = Directory(path.join(root.path, "out"));
    final commands = <String>[];

    final result = await DmgPackager(
      runProcess: (executable, arguments) async {
        commands.add([executable, ...arguments].join(" "));
        if (arguments.contains("-create")) {
          await File(path.join(output.path, "Example-2.6.0-macos.dmg"))
              .writeAsBytes([1, 2, 3]);
        }
        return ProcessResult(0, 0, "", "");
      },
    ).package(
      ReleasePackageRequest(
        input: app,
        outputDirectory: output,
        packageId: "com.example.app",
        appName: "Example.app",
        version: "2.6.0",
        buildNumber: 260,
        platform: "macos",
        channel: "stable",
        artifactUrl: Uri.parse("https://cdn.example.com/Example.dmg"),
        installStrategy: "wholeBundleReplace",
        minimumUpdaterVersion: "2.6.0",
      ),
      config: const MacOSDmgPublishConfig(
        volumeName: "Example",
        appBundleName: "Example.app",
        applicationsAlias: true,
      ),
    );

    final descriptor = ReleaseDescriptor.fromJson(
      jsonDecode(await result.releaseFile.readAsString()) as Map<String, dynamic>,
    );
    expect(result.artifact.path, endsWith(".dmg"));
    expect(descriptor.artifact.kind, "dmg");
    expect(descriptor.install.macosDmg!.appBundleName, "Example.app");
    expect(commands.any((command) => command.contains("hdiutil create")), isTrue);
  });
}
```

Run:

```sh
flutter test --no-pub test/release_cli/dmg_packager_test.dart
```

Expected: FAIL because `DmgPackager` does not exist.

- [ ] **Step 8.2: Write failing PKG packager test**

Create `test/release_cli/pkg_packager_test.dart`:

```dart
import "dart:convert";
import "dart:io";

import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:desktop_updater/src/package/release_packager.dart";
import "package:desktop_updater/src/release_cli/macos/macos_artifact_config.dart";
import "package:desktop_updater/src/release_cli/macos/pkg_packager.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;

void main() {
  test("packages a signed macOS PKG descriptor", () async {
    final root = await Directory.systemTemp.createTemp("pkg_packager_");
    addTearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });
    final app = Directory(path.join(root.path, "Example.app"));
    await app.create();
    final output = Directory(path.join(root.path, "out"));
    final commands = <String>[];

    final result = await PkgPackager(
      runProcess: (executable, arguments) async {
        commands.add([executable, ...arguments].join(" "));
        if (executable == "/usr/bin/productbuild") {
          await File(path.join(output.path, "Example-2.6.0-macos.pkg"))
              .writeAsBytes([1, 2, 3, 4]);
        }
        return ProcessResult(0, 0, "", "");
      },
    ).package(
      ReleasePackageRequest(
        input: app,
        outputDirectory: output,
        packageId: "com.example.app",
        appName: "Example.app",
        version: "2.6.0",
        buildNumber: 260,
        platform: "macos",
        channel: "stable",
        artifactUrl: Uri.parse("https://cdn.example.com/Example.pkg"),
        installStrategy: "pkgInstaller",
        minimumUpdaterVersion: "2.6.0",
      ),
      config: const MacOSPkgPublishConfig(
        packageIdentifier: "com.example.app.pkg",
        installLocation: "/Applications",
        signingIdentifier: "Developer ID Installer: Example Corp (TEAMID1234)",
      ),
    );

    final descriptor = ReleaseDescriptor.fromJson(
      jsonDecode(await result.releaseFile.readAsString()) as Map<String, dynamic>,
    );
    expect(result.artifact.path, endsWith(".pkg"));
    expect(descriptor.artifact.kind, "pkgInstaller");
    expect(descriptor.install.strategy, "pkgInstaller");
    expect(descriptor.install.macosPkg!.expectedPackageIds, [
      "com.example.app.pkg",
    ]);
    expect(commands.any((command) => command.startsWith("/usr/sbin/pkgbuild")), isTrue);
    expect(commands.any((command) => command.startsWith("/usr/bin/productbuild")), isTrue);
  });
}
```

Run:

```sh
flutter test --no-pub test/release_cli/pkg_packager_test.dart
```

Expected: FAIL.

- [ ] **Step 8.3: Implement Apple trust command wrappers**

Create command wrapper methods:

```dart
class AppleTrustCommands {
  const AppleTrustCommands({this.runProcess = defaultProcessRunner});

  final ProcessRunner runProcess;

  Future<void> codesignApp({
    required Directory app,
    required String identity,
  });

  Future<void> verifyApp(Directory app);

  Future<void> submitForNotarization({
    required File archive,
    required String notaryProfile,
    String? keychain,
  });

  Future<void> staple(FileSystemEntity artifact);

  Future<void> validateStaple(FileSystemEntity artifact);

  Future<void> assessExecute(Directory app);

  Future<void> assessInstall(File pkg);

  Future<void> assessDmg(File dmg);

  Future<void> checkPkgSignature(File pkg);
}
```

Tests in `apple_trust_commands_test.dart` must assert exact executable and argument lists for:

- `codesign --verify --deep --strict --verbose=2`
- `codesign -dvvv`
- `spctl --assess --type execute`
- `spctl --assess --type install`
- `spctl --assess --type open --context context:primary-signature`
- `xcrun stapler validate`
- `pkgutil --check-signature`
- `xcrun notarytool submit --wait`

- [ ] **Step 8.4: Implement DMG packager**

Implementation outline:

1. Create temporary DMG root.
2. Copy `.app` into root with `/usr/bin/ditto`.
3. Create `/Applications` symlink when `applicationsAlias` is true:

   ```dart
   await Link(path.join(dmgRoot.path, "Applications")).create("/Applications");
   ```

4. Run:

   ```sh
   hdiutil create -volname "$VOLUME" -srcfolder "$DMG_ROOT" -ov -format UDZO "$DMG"
   ```

5. Assess DMG primary signature when signing/notarization has produced a final artifact.
6. Write `release.json` with `artifact.kind == "dmg"` and `install.strategy == "wholeBundleReplace"`.

- [ ] **Step 8.5: Implement PKG packager**

Implementation outline:

1. Build a component package:

   ```sh
   pkgbuild --root "$APP_PARENT" --install-location /Applications --identifier "$PACKAGE_ID" --version "$VERSION" "$COMPONENT_PKG"
   ```

2. Build signed product package:

   ```sh
   productbuild --package "$COMPONENT_PKG" --sign "$DEVELOPER_ID_INSTALLER" "$FINAL_PKG"
   ```

3. Verify:

   ```sh
   pkgutil --check-signature "$FINAL_PKG"
   spctl --assess --type install --verbose=2 "$FINAL_PKG"
   ```

4. Write `release.json` with `artifact.kind == "pkgInstaller"` and `install.strategy == "pkgInstaller"`.

- [ ] **Step 8.6: Wire release publisher selection**

In `ReleasePublisher.publish`, select macOS artifact extension:

```dart
final macosArtifact = platform == "macos" ? config.macos.artifactKind : null;
final artifactExtension = switch (macosArtifact) {
  MacOSArtifactKind.dmg => ".dmg",
  MacOSArtifactKind.pkg => ".pkg",
  _ => useInnoInstaller ? ".exe" : ".zip",
};
```

Use `DmgPackager` or `PkgPackager` when `platform == "macos"` and the config selects those artifact kinds. Keep existing `ZipReleasePackager` default and Windows Inno branch unchanged.

- [ ] **Step 8.7: Verify focused release CLI tests**

Run:

```sh
flutter test --no-pub test/release_cli/dmg_packager_test.dart
flutter test --no-pub test/release_cli/pkg_packager_test.dart
flutter test --no-pub test/release_cli/apple_trust_commands_test.dart
flutter test --no-pub test/release_cli/release_publisher_build_test.dart
```

Expected: PASS.

- [ ] **Step 8.8: Commit**

Suggested commit:

```sh
git add lib/src/release_cli/macos lib/src/release_cli/release_publisher.dart test/release_cli/dmg_packager_test.dart test/release_cli/pkg_packager_test.dart test/release_cli/apple_trust_commands_test.dart test/release_cli/release_publisher_build_test.dart
git commit -m "feat: package macos dmg and pkg release artifacts"
```

## Task 9: Extend Publish Layout, Manifest, Validate, And Verify

**Files:**

- Modify: `lib/src/release_cli/publish_layout.dart`
- Modify: `lib/src/release_cli/publish_manifest.dart`
- Modify: `lib/src/release_cli/validate_command.dart`
- Modify: `bin/verify.dart`
- Test: `test/release_cli/publish_layout_test.dart`
- Test: `test/release_cli/publish_manifest_test.dart`
- Test: `test/release_cli/release_validate_test.dart`

**Interfaces:**

- Consumes: DMG and PKG descriptors from prior tasks.
- Produces: stable hosted `.dmg` and `.pkg` paths.
- Produces: hosted validation output that reports artifact kind and macOS trust gate results.
- Produces: `desktop_updater:verify` support for DMG and PKG artifacts.

- [ ] **Step 9.1: Write failing layout tests**

Add to `test/release_cli/publish_layout_test.dart`:

```dart
test("creates dmg artifact layout for macOS DMG updates", () {
  final layout = PublishLayout.create(
    outputDirectory: Directory("/tmp/out"),
    baseUrl: Uri.parse("https://updates.example.com"),
    version: "2.6.0",
    platform: "macos",
    appName: "Example.app",
    artifactExtension: ".dmg",
  );

  expect(
    layout.artifactRelativePath,
    "releases/2.6.0/macos/Example-2.6.0-macos.dmg",
  );
});

test("creates pkg artifact layout for macOS PKG installers", () {
  final layout = PublishLayout.create(
    outputDirectory: Directory("/tmp/out"),
    baseUrl: Uri.parse("https://updates.example.com"),
    version: "2.6.0",
    platform: "macos",
    appName: "Example.app",
    artifactExtension: ".pkg",
  );

  expect(
    layout.artifactRelativePath,
    "releases/2.6.0/macos/Example-2.6.0-macos.pkg",
  );
});
```

Run:

```sh
flutter test --no-pub test/release_cli/publish_layout_test.dart
```

Expected: PASS if `PublishLayout` already supports arbitrary extensions; keep the tests as regression coverage.

- [ ] **Step 9.2: Write failing manifest and validate tests**

Add manifest round-trip tests for `dmg` and `pkgInstaller`. Add validate tests that expect output:

```text
Artifact kind: dmg
macOS DMG primary signature: OK
```

and:

```text
Artifact kind: pkgInstaller
macOS PKG signature: OK
macOS PKG Gatekeeper install assessment: OK
macOS PKG stapler validation: OK
```

Run:

```sh
flutter test --no-pub test/release_cli/publish_manifest_test.dart
flutter test --no-pub test/release_cli/release_validate_test.dart
```

Expected: manifest tests may already pass for arbitrary kinds; validate tests fail until macOS trust validation is added.

- [ ] **Step 9.3: Implement macOS validation branches**

In `ReleaseValidator.validateReleaseFiles`, after SHA-256 verification:

```dart
if (descriptor.platform == "macos" && Platform.isMacOS) {
  switch (descriptor.artifact.kind) {
    case "dmg":
      await macosVerifier.verifyDmgPrimarySignature(artifactFile);
      output.writeln("macOS DMG primary signature: OK");
    case "pkgInstaller":
      await macosVerifier.verifyPkgInstaller(
        pkg: artifactFile,
        expectedPackageIds: descriptor.install.macosPkg!.expectedPackageIds,
      );
      output.writeln("macOS PKG signature: OK");
      output.writeln("macOS PKG Gatekeeper install assessment: OK");
      output.writeln("macOS PKG stapler validation: OK");
  }
}
```

When the validator is not running on macOS, print:

```text
macOS artifact trust validation: not run (requires macOS host)
```

Do not fail Linux/Windows CI for macOS-only Apple trust commands.

- [ ] **Step 9.4: Update `bin/verify.dart`**

`verify` should:

- Download the artifact with its real extension.
- For `zip`, keep existing zip safety behavior.
- For `dmg` on macOS, assess primary signature, mount read-only, locate/copy app into temp, run app trust gates, detach.
- For `pkgInstaller` on macOS, run `pkgutil`, install assessment, and stapler validation.
- For `dmg` or `pkgInstaller` on non-macOS, verify descriptor plus artifact length/SHA-256, then print a `not run` trust validation line.

- [ ] **Step 9.5: Verify focused command tests**

Run:

```sh
flutter test --no-pub test/release_cli/publish_layout_test.dart
flutter test --no-pub test/release_cli/publish_manifest_test.dart
flutter test --no-pub test/release_cli/release_validate_test.dart
```

Expected: PASS.

- [ ] **Step 9.6: Commit**

Suggested commit:

```sh
git add lib/src/release_cli/publish_layout.dart lib/src/release_cli/publish_manifest.dart lib/src/release_cli/validate_command.dart bin/verify.dart test/release_cli/publish_layout_test.dart test/release_cli/publish_manifest_test.dart test/release_cli/release_validate_test.dart
git commit -m "feat: validate macos dmg and pkg release artifacts"
```

## Task 10: Build Local MacBook Production Smoke Harness

**Files:**

- Create: `tool/macos_production_smoke.dart`
- Test: `test/macos_production_smoke_tool_test.dart`
- Modify: `.github/workflows/desktop-updater-ci.yml` only to document that the smoke is local/manual unless explicit secrets are configured.

**Interfaces:**

- Produces: `dart run tool/macos_production_smoke.dart doctor`.
- Produces: `dmg-first-install`, `move-to-applications`, `dmg-update`, `pkg-installer`, and `all --cleanup`.
- Consumes: `DESKTOP_UPDATER_DEV_ID_APP`, `DESKTOP_UPDATER_DEV_ID_INSTALLER`, `DESKTOP_UPDATER_NOTARY_PROFILE`, and `DESKTOP_UPDATER_TEST_BUNDLE_ID`.
- Produces: evidence files under `reports/macos-production-smoke/`.

- [ ] **Step 10.1: Write failing command parser tests**

Create `test/macos_production_smoke_tool_test.dart`:

```dart
import "dart:io";

import "package:flutter_test/flutter_test.dart";

void main() {
  test("macOS production smoke exposes required commands", () {
    final source = File("tool/macos_production_smoke.dart").readAsStringSync();

    expect(source, contains("doctor"));
    expect(source, contains("dmg-first-install"));
    expect(source, contains("move-to-applications"));
    expect(source, contains("dmg-update"));
    expect(source, contains("pkg-installer"));
    expect(source, contains("all"));
    expect(source, contains("--cleanup"));
  });

  test("macOS production smoke documents required environment", () {
    final source = File("tool/macos_production_smoke.dart").readAsStringSync();

    expect(source, contains("DESKTOP_UPDATER_DEV_ID_APP"));
    expect(source, contains("DESKTOP_UPDATER_DEV_ID_INSTALLER"));
    expect(source, contains("DESKTOP_UPDATER_NOTARY_PROFILE"));
    expect(source, contains("DESKTOP_UPDATER_TEST_BUNDLE_ID"));
  });
}
```

Run:

```sh
flutter test --no-pub test/macos_production_smoke_tool_test.dart
```

Expected: FAIL because the tool does not exist.

- [ ] **Step 10.2: Implement `doctor`**

`doctor` checks:

- Host is macOS.
- `flutter`, `dart`, `xcrun`, `codesign`, `spctl`, `pkgutil`, `hdiutil`, `pkgbuild`, and `productbuild` exist.
- Required env vars are present.
- `security find-identity -v -p codesigning` includes `DESKTOP_UPDATER_DEV_ID_APP`.
- `security find-identity -v -p basic` or `productbuild` signing probe can use `DESKTOP_UPDATER_DEV_ID_INSTALLER`.
- `xcrun notarytool history --keychain-profile "$DESKTOP_UPDATER_NOTARY_PROFILE"` succeeds.

Command:

```sh
dart run tool/macos_production_smoke.dart doctor
```

Expected evidence:

```text
doctor: macOS host OK
doctor: Developer ID Application OK
doctor: Developer ID Installer OK
doctor: notary profile OK
```

- [ ] **Step 10.3: Implement `dmg-first-install`**

The command:

1. Builds example app version v1.
2. Signs app with `DESKTOP_UPDATER_DEV_ID_APP`.
3. Notarizes and staples app.
4. Creates DMG with `.app` plus `/Applications` alias.
5. Notarizes and staples DMG.
6. Runs:

   ```sh
   spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
   hdiutil attach -readonly -nobrowse "$DMG"
   codesign --verify --deep --strict --verbose=2 "/Volumes/$VOLUME/$APP.app"
   spctl --assess --type execute --verbose=2 "/Volumes/$VOLUME/$APP.app"
   xcrun stapler validate "/Volumes/$VOLUME/$APP.app"
   hdiutil detach "/Volumes/$VOLUME"
   ```

Expected evidence:

```text
dmg-first-install: DMG primary signature OK
dmg-first-install: mounted read-only OK
dmg-first-install: contained app Gatekeeper OK
dmg-first-install: detach OK
```

- [ ] **Step 10.4: Implement `move-to-applications`**

The command:

1. Mounts the first-install DMG.
2. Launches the app from `/Volumes/...`.
3. Exercises the optional move API or prompt with a smoke environment flag.
4. Verifies the copied app exists at `/Applications/<TestApp>.app`.
5. Verifies the copied app launches and reports the expected bundle ID/version.
6. Detaches the DMG.

Expected evidence:

```text
move-to-applications: source classified as diskImage
move-to-applications: copied to /Applications OK
move-to-applications: relaunched copied app OK
move-to-applications: source DMG detached OK
```

- [ ] **Step 10.5: Implement `dmg-update`**

The command:

1. Installs v1 into `/Applications`.
2. Builds/signs/notarizes/staples v2.
3. Publishes a DMG update artifact to a local static server.
4. Runs the example app against that local `app-archive.json`.
5. Downloads, verifies, mounts, copies, verifies, stages, and installs v2.
6. Verifies app relaunch and v2 sentinel.

Expected evidence:

```text
dmg-update: hosted app archive OK
dmg-update: DMG artifact SHA-256 OK
dmg-update: DMG primary signature OK
dmg-update: contained app Apple trust OK
dmg-update: whole-bundle replacement OK
dmg-update: v2 relaunch OK
```

- [ ] **Step 10.6: Implement `pkg-installer`**

The command:

1. Builds/signs/notarizes/staples v2 app.
2. Builds signed Developer ID Installer PKG.
3. Notarizes and staples PKG.
4. Runs:

   ```sh
   pkgutil --check-signature "$PKG"
   spctl --assess --type install --verbose=2 "$PKG"
   xcrun stapler validate "$PKG"
   ```

5. Stages PKG via update flow.
6. Opens Installer.app for the staged PKG.
7. Records that user confirmation is required for actual installation.

Expected evidence:

```text
pkg-installer: package signature OK
pkg-installer: Gatekeeper install assessment OK
pkg-installer: stapler validation OK
pkg-installer: Installer.app handoff OK
pkg-installer: silent privileged install not run
```

- [ ] **Step 10.7: Implement cleanup**

`all --cleanup` removes only known smoke-owned paths:

- `/Applications/$DESKTOP_UPDATER_TEST_APP_NAME.app`
- mounted DMGs whose volume name matches the smoke volume.
- temp roots created under `DESKTOP_UPDATER_TEST_WORKDIR` or system temp with the smoke prefix.
- local static server temp files.

Package receipts must be handled safely:

- Print matching receipts with `pkgutil --pkgs | grep "$DESKTOP_UPDATER_TEST_BUNDLE_ID"`.
- Do not run `pkgutil --forget` automatically unless the receipt identifier is exactly the smoke package identifier and the user passed `--cleanup-forget-receipt`.
- Never delete unrelated `/Applications` apps or user Downloads files.

Command:

```sh
dart run tool/macos_production_smoke.dart all --cleanup
```

Expected evidence:

```text
cleanup: removed smoke app from /Applications
cleanup: detached smoke DMG volumes
cleanup: removed smoke temp dirs
cleanup: package receipts listed
```

- [ ] **Step 10.8: Verify tool tests**

Run:

```sh
flutter test --no-pub test/macos_production_smoke_tool_test.dart
```

Expected: PASS.

- [ ] **Step 10.9: Run local MacBook smoke**

Run on the local MacBook only:

```sh
dart run tool/macos_production_smoke.dart doctor
dart run tool/macos_production_smoke.dart dmg-first-install
dart run tool/macos_production_smoke.dart move-to-applications
dart run tool/macos_production_smoke.dart dmg-update
dart run tool/macos_production_smoke.dart pkg-installer
dart run tool/macos_production_smoke.dart all --cleanup
```

Expected: PASS with evidence files under `reports/macos-production-smoke/`.

Label CI/non-local evidence:

```text
not run: macOS production smoke requires local Developer ID Application cert, Developer ID Installer cert, notary profile, and Apple notarization service access.
```

- [ ] **Step 10.10: Commit**

Suggested commit:

```sh
git add tool/macos_production_smoke.dart test/macos_production_smoke_tool_test.dart .github/workflows/desktop-updater-ci.yml
git commit -m "test: add local macos production smoke harness"
```

## Task 11: Document macOS DMG And PKG Distribution

**Files:**

- Modify: `README.md`
- Create: `docs/macos-dmg-pkg-installer-updates.md`
- Modify: `docs/publishing.md`
- Modify: `docs/github-actions-ci-cd.md`
- Modify: `docs/diagnostics-and-recovery.md`
- Modify: `docs/migration/1.x-to-2.0.md` only if descriptor migration text needs the new artifact kinds.
- Test: `test/macos_dmg_pkg_docs_test.dart`
- Test: `test/native_helper_diagnostics_docs_test.dart`
- Test: `test/harness_engineering_docs_test.dart`

**Interfaces:**

- Produces: reader-facing macOS DMG/PKG production guide.
- Consumes: all implemented command names, config keys, descriptor kinds, diagnostics events, and smoke commands.
- Produces: docs drift tests guarding the new public claims.

- [ ] **Step 11.1: Write failing docs drift test**

Create `test/macos_dmg_pkg_docs_test.dart`:

```dart
import "dart:io";

import "package:flutter_test/flutter_test.dart";

void main() {
  test("macOS DMG and PKG docs cover artifact boundaries and smoke commands", () {
    final doc = File("docs/macos-dmg-pkg-installer-updates.md").readAsStringSync();

    expect(doc, contains("artifact.kind: dmg"));
    expect(doc, contains("artifact.kind: pkgInstaller"));
    expect(doc, contains("install.strategy: pkgInstaller"));
    expect(doc, contains("silent privileged install is not promised"));
    expect(doc, contains("dart run tool/macos_production_smoke.dart doctor"));
    expect(doc, contains("hdiutil attach -readonly -nobrowse"));
    expect(doc, contains("pkgutil --check-signature"));
  });

  test("README links to detailed macOS DMG and PKG docs without bloating quick start", () {
    final readme = File("README.md").readAsStringSync();

    expect(readme, contains("docs/macos-dmg-pkg-installer-updates.md"));
    expect(readme.split("docs/macos-dmg-pkg-installer-updates.md"), hasLength(2));
  });
}
```

Run:

```sh
flutter test --no-pub test/macos_dmg_pkg_docs_test.dart
```

Expected: FAIL until docs are written.

- [ ] **Step 11.2: Write detailed macOS doc**

Create `docs/macos-dmg-pkg-installer-updates.md` with sections:

- Overview and support matrix.
- Existing `.app.zip` direct update compatibility.
- DMG first-install layout with `.app` and `/Applications` alias.
- Optional Move to Applications prompt and app opt-in code.
- DMG update descriptor shape and runtime mount/copy/verify/detach flow.
- PKG descriptor shape and Installer.app handoff.
- Explicit boundary: silent privileged PKG install is not promised.
- Release CLI YAML examples for `zip`, `dmg`, and `pkg`.
- Apple signing/notarization setup with required env/config names.
- Acceptance gates with all commands from this plan.
- Local MacBook production smoke commands and expected evidence.
- Cleanup strategy.
- `not run` labels for CI/non-local validation.

- [ ] **Step 11.3: Update concise docs**

Update `README.md` with one short link in the production trust area:

```markdown
For macOS DMG first installs, DMG update artifacts, PKG installer artifacts, and the local Apple-trust smoke harness, see [macOS DMG and PKG installer updates](docs/macos-dmg-pkg-installer-updates.md).
```

Update `docs/publishing.md` with concise config examples and link to the detailed page. Keep the README short.

Update `docs/diagnostics-and-recovery.md` with DMG and PKG helper events:

- `dmg primary signature verified`
- `dmg mounted`
- `dmg app copied`
- `dmg detached`
- `pkg manifest loaded`
- `pkg installer open`
- `pkg installer opened`
- `pkg installer open failure`

- [ ] **Step 11.4: Verify docs tests**

Run:

```sh
flutter test --no-pub test/macos_dmg_pkg_docs_test.dart
flutter test --no-pub test/native_helper_diagnostics_docs_test.dart
flutter test --no-pub test/harness_engineering_docs_test.dart
```

Expected: PASS.

- [ ] **Step 11.5: Commit**

Suggested commit:

```sh
git add README.md docs/macos-dmg-pkg-installer-updates.md docs/publishing.md docs/github-actions-ci-cd.md docs/diagnostics-and-recovery.md docs/migration/1.x-to-2.0.md test/macos_dmg_pkg_docs_test.dart test/native_helper_diagnostics_docs_test.dart test/harness_engineering_docs_test.dart
git commit -m "docs: document macos dmg and pkg update support"
```

## Task 12: Final Validation And Release Readiness Evidence

**Files:**

- Modify only files that previous validation reveals as broken.
- Produce evidence under `reports/` when local MacBook smoke runs.

**Interfaces:**

- Consumes: all prior tasks.
- Produces: local verification report and clear `not run` labels for unavailable Apple/CI gates.

- [ ] **Step 12.1: Run focused tests from changed areas**

Run:

```sh
flutter test --no-pub test/release_descriptor_test.dart
flutter test --no-pub test/macos_distribution_artifacts_test.dart
flutter test --no-pub test/update_client_security_test.dart
flutter test --no-pub test/native_helper_script_test.dart
flutter test --no-pub test/macos_install_location_test.dart
flutter test --no-pub test/macos_move_to_applications_prompt_test.dart
flutter test --no-pub test/release_cli/release_publish_config_test.dart
flutter test --no-pub test/release_cli/dmg_packager_test.dart
flutter test --no-pub test/release_cli/pkg_packager_test.dart
flutter test --no-pub test/release_cli/apple_trust_commands_test.dart
flutter test --no-pub test/release_cli/release_publisher_build_test.dart
flutter test --no-pub test/release_cli/release_validate_test.dart
flutter test --no-pub test/macos_production_smoke_tool_test.dart
flutter test --no-pub test/macos_dmg_pkg_docs_test.dart
```

Expected: PASS.

- [ ] **Step 12.2: Run repository validation ladder**

Run:

```sh
dart format --set-exit-if-changed .
flutter analyze --no-fatal-infos
flutter test --no-pub
dart pub publish --dry-run
```

Expected: PASS.

- [ ] **Step 12.3: Run SwiftPM macOS plugin tests**

Run on macOS:

```sh
swift test
```

Expected: PASS.

If not on macOS, record:

```text
not run: swift test requires macOS SwiftPM host for the macOS plugin package.
```

- [ ] **Step 12.4: Run local MacBook production smoke**

Run on the local MacBook with real Apple credentials:

```sh
dart run tool/macos_production_smoke.dart all --cleanup
```

Expected evidence:

- `verified locally`: Developer ID Application signing.
- `verified locally`: Developer ID Installer signing.
- `verified locally`: notarization accepted.
- `verified locally`: stapler validation for `.app`, `.dmg`, and `.pkg`.
- `verified locally`: Gatekeeper execute assessment for `.app`.
- `verified locally`: Gatekeeper open assessment for `.dmg`.
- `verified locally`: Gatekeeper install assessment for `.pkg`.
- `verified locally`: DMG mount/detach.
- `verified locally`: Move to Applications flow.
- `verified locally`: v1 to v2 DMG update.
- `verified locally`: PKG Installer.app handoff.
- `verified locally`: cleanup of smoke app, mounted DMGs, and temp dirs.

If the local MacBook lacks credentials or Apple service access, record:

```text
not run: local MacBook production smoke requires DESKTOP_UPDATER_DEV_ID_APP, DESKTOP_UPDATER_DEV_ID_INSTALLER, DESKTOP_UPDATER_NOTARY_PROFILE, DESKTOP_UPDATER_TEST_BUNDLE_ID, and Apple notarization access.
```

- [ ] **Step 12.5: Run final git inspection**

Run:

```sh
git status --short
git diff --stat
```

Expected: only files from this plan are changed, plus any pre-existing user changes intentionally preserved.

- [ ] **Step 12.6: Commit final fixes**

Suggested commit for validation-only fixes:

```sh
git add .
git commit -m "test: verify macos dmg and pkg production support"
```

## Cleanup Strategy

The implementation and smoke harness must clean up only resources it owns:

- Remove the smoke test app from `/Applications` only when its bundle identifier equals `DESKTOP_UPDATER_TEST_BUNDLE_ID`.
- Detach mounted DMGs whose volume names match the smoke harness volume prefix.
- Remove temp directories created by `tool/macos_production_smoke.dart`.
- Stop local static servers started by the smoke harness.
- Remove generated smoke reports only when the user passes an explicit cleanup flag for reports.
- Avoid deleting unrelated user apps, Downloads files, mounted volumes, keychains, certificates, or notary profiles.
- Handle package receipts safely: list matching receipts by default, and only run `pkgutil --forget` for the exact smoke package identifier when an explicit receipt cleanup flag is passed.

## CI And Non-Local Labels

Use literal evidence labels:

- `verified locally`: the command ran on the local machine and passed.
- `not run`: the command was not run.
- `blocked`: the command could not run because credentials, Apple service access, or host platform were unavailable.
- `candidate-only`: the code path is ready for a credentialed smoke but has not passed it yet.
- `release pending`: production publication has not happened.
- `production-ready`: only after real Apple trust validation, local smoke, and the repository validation ladder all pass.

Do not label DMG or PKG support `production-ready` from unit tests alone.

## Open Questions And Blockers

- The PKG runtime path intentionally opens Installer.app and does not promise a silent privileged update. A future silent path needs a separate design for a signed privileged helper, authorization policy, uninstall/receipt ownership, and rollback evidence.
- PKG package-id checks should use `pkgutil --expand-full` and parse expanded `PackageInfo`/`Distribution` metadata; do not rely on installed receipts because the smoke may run before installation.
- CI can keep macOS production smoke `not run` unless the user explicitly provides secrets and approves workflow dispatch. Local MacBook smoke is the production evidence source for this plan.
