# Native SDK Monorepo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> `superpowers:subagent-driven-development` (recommended) or
> `superpowers:executing-plans` to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Preserve the existing Flutter package and Dart runtime while adding
safe, independently consumable native install-helper SDKs for macOS, Windows,
and Linux. Full native check/download/verify/stage APIs remain a gated child
preview and must not be documented or published as production-ready by this
master plan.

**Architecture:** The repository keeps the Flutter/Dart package at its root.
Each Flutter platform adapter links the same local native helper sources that
non-Flutter consumers receive through SwiftPM, CMake, or NuGet. The master plan
owns safety contracts, helper extraction, package consumption, CLI build
adapters, and release gates; the child plan owns the duplicated Swift/C++
runtime that reads `app-archive.json` and `release.json`.

**Tech Stack:** Dart/Flutter, schema-v3 release contracts as implemented by
`desktop_updater` 2.7.0, SwiftPM/Swift/XCTest, CocoaPods fallback integration,
C++/CMake/GoogleTest, Windows C ABI, .NET P/Invoke, GitHub Actions, and local
consumer smoke projects.

## Global Constraints

- Root `pubspec.yaml` remains the single canonical version source.
- Do not bump versions, changelog headings, lockfiles, or tags while executing
  this plan unless release/version work is explicitly requested.
- The pub.dev package remains `desktop_updater`; do not add another pub
  package.
- Existing Flutter imports, plugin registration classes, MethodChannel method
  names, and Dart CLI entrypoints remain source compatible.
- Flutter apps continue to use the Dart `UpdateClient`, Dart diagnostics, and
  the existing MethodChannel handoff.
- The master plan exposes staged-artifact install helpers. It does not claim
  native `checkForUpdate`, download, verification, or staging APIs.
- Safety overrides compatibility. An install target that cannot be proven to
  be an app-owned bundle must fail closed even if the old helper inferred a
  target from the executable parent directory.
- Flutter builds must use native sources shipped in the pub package. They must
  not download SwiftPM, CocoaPods, NuGet, GoogleTest, or system CMake packages
  to compile the plugin.
- Native tests may fetch or locate test-only dependencies only when an
  explicit native-test option is enabled.
- Windows public interop uses a versioned C ABI. C++ STL types and C++
  exceptions never cross that ABI.
- The Windows Flutter plugin links a static native helper target. Native and
  .NET consumers load a shared DLL built from the same object sources.
- Windows .NET support is not complete until a test loads the produced DLL and
  exercises the C ABI, including `removedFiles`.
- Native macOS distribution is SwiftPM-only. CocoaPods remains a Flutter
  fallback and compiles the same helper sources inside the Flutter pod; it is
  not a separately published `DesktopUpdaterKit` pod.
- The first Linux native package is source-first through CMake. Do not publish
  a generic prebuilt Linux binary until compiler ABI, architecture, and glibc
  baselines have their own approved plan and consumer matrix.
- Every `ctest` lane must enable native tests explicitly and fail when zero
  tests are discovered.
- Package publication requires local-path consumer builds. Building the
  library inside its own source tree is not sufficient evidence.
- Do not change schema version 3 in this plan.

## Current 2.7 Contract Baseline

The plan must preserve or explicitly fail closed for this matrix:

| Platform | Artifact kinds | Install strategies |
| --- | --- | --- |
| macOS | `zip`, `dmg`, `pkgInstaller` | `wholeBundleReplace`, `pkgInstaller` |
| Windows | `zip`, `innoInstaller` | `wholeDirectoryReplace`, `innoInstaller` |
| Linux | `zip` | `wholeDirectoryReplace` for a verified self-contained directory bundle |

The shared contract also includes:

- integer build-number ordering;
- platform and channel selection;
- deterministic staged rollout;
- support policy and fresh-install metadata;
- exact index-to-descriptor version, build number, platform, and channel
  binding;
- descriptor package identity;
- `minimumUpdaterVersion` and `minimumOS`;
- lowercase SHA-256 and exact byte length;
- Ed25519 descriptor signatures using Dart-compatible canonical JSON and
  pinned `publicKeyId` values;
- install metadata for Inno, DMG, and PKG artifacts;
- stable helper JSONL events and bounded/redacted diagnostics.

This rebase adds one hardening rule beyond the current Dart selection API:
native applications must supply an app-owned expected package identity and the
native runtime must compare it with the signed descriptor. Do not describe
that comparison as existing Dart parity unless a separate additive Dart API
and its tests are implemented.

`app-archive.json` is discovery metadata in schema version 3; it is not itself
cryptographically authenticated. Trust comes from the signed descriptor,
expected package identity, exact index-to-descriptor binding, artifact hash,
and platform publisher checks. Do not claim that the index is signed. A signed
index requires separate schema work.

## Target Layout

Keep the Flutter/Dart package at the repository root:

```text
pubspec.yaml
lib/
bin/
test/
tool/
macos/
windows/
linux/
```

Add these native and consumer surfaces:

```text
Package.swift

fixtures/compat/native-contract/
  canonical-signature-cases.json
  descriptor-validation-cases.json
  diagnostics-redaction-cases.json
  helper-events.json
  release-contract/

macos/desktop_updater/Sources/DesktopUpdaterKit/
macos/desktop_updater/Sources/desktop_updater/
macos/desktop_updater/Tests/DesktopUpdaterKitTests/
example/native/macos/

windows/native/CMakeLists.txt
windows/native/include/desktop_updater_native_c.h
windows/native/include/desktop_updater_version.h
windows/native/src/
windows/native/test/
windows/native/cmake/
windows/native/dotnet/DesktopUpdater.Native/
windows/native/dotnet/DesktopUpdater.Native.Tests/
example/native/windows-dotnet/
example/native/windows-cmake/

linux/native/CMakeLists.txt
linux/native/include/desktop_updater_native.h
linux/native/include/desktop_updater_version.h
linux/native/src/
linux/native/test/
linux/native/cmake/
example/native/linux-cmake/
```

Native package names:

- macOS SwiftPM product: `DesktopUpdaterKit`
- Windows shared DLL and CMake target: `desktop_updater_native`
- Windows Flutter-only static target: `desktop_updater_native_static`
- Windows CMake alias: `desktop_updater::native`
- Windows NuGet package: `DesktopUpdater.Native`
- Linux source CMake target: `desktop_updater_native`
- Linux CMake alias: `desktop_updater::native`

## Execution Dependencies

1. Stage 0 freezes the current contract and adds the Linux destructive-root
   blocker. No helper extraction may begin before it passes.
2. Stages 1 and 2 establish CLI and fixture seams without changing behavior.
3. Stages 3-5 extract macOS, Windows, and Linux helpers.
4. Stage 6 proves that external consumers can install and link the packages.
5. Stage 7 defines the rebased child plan now; executing that child remains
   blocked until Stages 0-6 pass.
6. Stages 8-10 add native build adapters, standalone CLI distribution,
   versioning, publication, and final verification.

## Stage 0: Rebase And Safety Gate

**Purpose:** Freeze the actual 2.7 contract while refusing to freeze unsafe
install-root inference as compatible behavior.

**Files:**

- Create: `docs/native-contract.md`
- Create: `test/native_contract_baseline_test.dart`
- Modify: `lib/desktop_updater_platform_interface.dart`
- Modify: `lib/desktop_updater_method_channel.dart`
- Modify: `lib/updater_controller.dart`
- Modify: `test/compat/flutter_220_public_api_test.dart`
- Modify: `test/compat/flutter_220_channel_controller_contract_test.dart`
- Modify: `test/compat/native_helper_events_220_contract_test.dart`
- Modify: `test/desktop_updater_method_channel_test.dart`
- Modify: `test/native_helper_script_test.dart`
- Modify: `test/updater_controller_test.dart`
- Modify: `linux/desktop_updater_plugin_private.h`
- Modify: `linux/desktop_updater_plugin.cc`
- Modify: `linux/test/desktop_updater_plugin_test.cc`

**Interfaces:**

- Produces: one documented artifact/policy matrix used by all later stages.
- Produces: a validated Linux install target contract:

```cpp
struct InstallResult {
  bool ok;
  std::string error;
};

enum class LinuxInstallOperation {
  kRestart,
  kInstall,
};

struct LinuxInstallTarget {
  LinuxInstallOperation operation;
  std::string install_root;
  std::string executable_relative_path;
  std::string package_id;
};
```

- Produces:
  `ValidateLinuxInstallTarget(const LinuxInstallTarget&) -> InstallResult`.

- [x] **Step 0.1: Write the 2.7 baseline test**

Add `test/native_contract_baseline_test.dart` assertions for representative
schema-v3 descriptors containing all four artifact kinds, integer build
numbers, non-empty install strategies, and non-empty minimum updater versions.
Do not add public production API solely to make the test easier.

- [x] **Step 0.2: Run the baseline before extraction**

Run:

```sh
flutter test --no-pub \
  test/native_contract_baseline_test.dart \
  test/compat/flutter_220_public_api_test.dart \
  test/compat/flutter_220_channel_controller_contract_test.dart \
  test/compat/native_helper_events_220_contract_test.dart
```

Expected: PASS against the pre-extraction repository.

Verified locally on 2026-07-10: PASS, 5 tests.

- [x] **Step 0.3: Add failing Linux protected-root tests**

Add native/helper tests that reject these exact canonical install roots before
creating or launching a script:

```text
/
/bin
/sbin
/usr
/usr/bin
/usr/sbin
/usr/local
/usr/local/bin
/opt
/etc
/var
/home
```

The following remains valid because it is an app-owned directory below a
shared root:

```text
/opt/example-app
```

Required test cases:

```cpp
TEST(LinuxInstallTarget, RejectsUsrBinExecutableParent) {
  const auto result = ValidateLinuxInstallTarget({
      LinuxInstallOperation::kInstall,
      "/usr/bin",
      "my-app",
      "com.example.app",
  });
  EXPECT_FALSE(result.ok);
}

TEST(LinuxInstallTarget, AcceptsSelfContainedOptBundle) {
  const auto result = ValidateLinuxInstallTarget({
      LinuxInstallOperation::kInstall,
      "/opt/example-app",
      "bin/my-app",
      "com.example.app",
  });
  EXPECT_TRUE(result.ok);
}
```

RED verified locally on 2026-07-10: the new MethodChannel context,
controller package identity, and Linux target-validation tests failed for the
expected missing behavior.

- [x] **Step 0.4: Implement fail-closed Linux target validation**

Validation must:

- separate non-mutating restart requests from install requests;
- require an absolute canonical `install_root`;
- reject symlinked install roots;
- reject the exact protected roots listed in Step 0.3;
- require a non-empty relative executable path with no `..` segment;
- prove the executable resolves strictly inside `install_root`;
- require a non-empty package identity;
- reject staging paths equal to, inside, or an ancestor of `install_root`;
- validate every removed-file path after canonical resolution;
- generate no shell script when validation fails.

A restart request does not require package identity, backup, pruning, copy, or
rollback. It may only wait for the parent process and relaunch the already
resolved executable. An install request requires the full target contract
above before any backup or destructive command is generated.

The Flutter adapter may derive the candidate bundle root from the current
executable parent for compatibility, but it must pass that candidate through
the same validator. `/usr/bin/my-app` therefore fails closed instead of
treating `/usr/bin` as an application bundle.

- [x] **Step 0.5: Preserve Flutter API compatibility**

Keep existing public calls valid. Additional install context may be carried as
optional internal MethodChannel arguments:

```text
installRoot
executableRelativePath
packageId
```

Controller-owned update flows must populate the package identity from the
verified active descriptor. Direct legacy calls without enough context may
continue only when the native helper can independently prove a self-contained
bundle; otherwise return a clear `InstallError` directing the app to a fresh
installer.

- [x] **Step 0.6: Run the safety regression**

Run:

```sh
flutter test --no-pub \
  test/native_helper_script_test.dart \
  test/desktop_updater_method_channel_test.dart \
  test/compat/flutter_220_channel_controller_contract_test.dart
```

Expected: PASS, including rejection of `/usr/bin` before destructive commands
are emitted.

Verified locally on 2026-07-10:

- focused Stage 0 and compatibility suite: PASS;
- `dart format --set-exit-if-changed .`: PASS, 179 files unchanged;
- `flutter analyze --no-fatal-infos`: PASS with existing info-only lints;
- `flutter test --no-pub`: PASS, 449 tests with 3 external E2E skips;
- `dart pub publish --dry-run`: exit 0 with the expected dirty-tree warning;
- Linux native build/tests: not run locally on macOS; CI evidence pending.

- [x] **Step 0.7: Commit the safety baseline**

```sh
git add docs/native-contract.md test/native_contract_baseline_test.dart \
  test/native_helper_script_test.dart linux/desktop_updater_plugin.cc \
  linux/desktop_updater_plugin_private.h
git commit -m "fix: validate linux updater install roots"
```

## Stage 1: CLI Project Adapter Seam

**Purpose:** Isolate project building from release packaging without changing
the existing Flutter default or confusing an executable with a deployable
bundle.

**Files:**

- Create: `lib/src/release_cli/project_adapter.dart`
- Create: `lib/src/release_cli/flutter_project_adapter.dart`
- Create: `lib/src/release_cli/manual_project_adapter.dart`
- Modify: `lib/src/release_cli/release_publisher.dart`
- Modify: `lib/src/release_cli/publish_command.dart`
- Modify: `lib/src/release_cli/release_publish_config.dart`
- Test: `test/release_cli/project_adapter_test.dart`
- Test: `test/release_cli/release_publisher_build_test.dart`

**Interfaces:**

```dart
final class ProjectBuildRequest {
  const ProjectBuildRequest({
    required this.projectRoot,
    required this.platform,
    required this.releaseMode,
  });

  final Directory projectRoot;
  final String platform;
  final bool releaseMode;
}

final class ProjectBuildResult {
  const ProjectBuildResult({
    required this.artifactRoot,
    required this.appName,
    required this.packageId,
    required this.version,
    this.buildNumber,
    this.executableRelativePath,
  });

  final FileSystemEntity artifactRoot;
  final String appName;
  final String packageId;
  final String version;
  final int? buildNumber;
  final String? executableRelativePath;
}

abstract interface class ProjectAdapter {
  String get type;
  bool canHandle(Directory projectRoot);
  Future<ProjectBuildResult> build(ProjectBuildRequest request);
}
```

`artifactRoot` is the complete directory or bundle that the release packager
must archive. It is never merely a Windows or Linux executable when sibling
DLLs, data, or resources are required.

- [x] **Step 1.1: Write adapter selection tests**

Cover this internal selection order:

```text
1. explicit adapter type supplied by the internal request
2. explicit manual artifact root and metadata
3. Flutter project markers
4. exactly one native project marker
5. ambiguity or no marker => usage error
```

Stage 8 exposes the corresponding CLI flags after this seam is stable.

The manual selector test must supply `artifactRoot`, `appName`, `packageId`,
and `version`; do not construct `ManualProjectAdapter` from an app path alone.

RED verified locally on 2026-07-10: the adapter contract test failed because
the project adapter files and selection types did not exist; the publisher
integration test then failed because internal manual-project overrides were
not implemented. A follow-up manual-root test also proved that symlinks were
followed until artifact validation was changed to inspect the link itself.

- [x] **Step 1.2: Extract existing Flutter behavior**

Move existing `flutter build <platform> --release`, metadata resolution, and
output-path logic behind `FlutterProjectAdapter`. Preserve command arguments,
`--dart-define` forwarding, artifact layout, hook environment, and all current
DMG/PKG/Inno branches.

- [x] **Step 1.3: Add the manual bundle adapter**

The adapter validates:

- `artifactRoot` exists;
- directory/bundle inputs are used when runtime siblings are required;
- `buildNumber` is `int?`;
- Windows `.exe` input is rejected unless an explicit
  `--single-file-artifact` mode is added and tested separately;
- Linux input is a self-contained directory bundle.

- [x] **Step 1.4: Keep the Flutter default**

With no new flags inside a Flutter project, selection must return
`FlutterProjectAdapter`. Existing `dart run desktop_updater:release publish`
fixtures must remain unchanged.

- [x] **Step 1.5: Run focused CLI tests**

```sh
flutter test --no-pub \
  test/release_cli/project_adapter_test.dart \
  test/release_cli/release_publisher_build_test.dart \
  test/release_cli/release_publish_config_test.dart \
  test/release_cli/release_command_test.dart
```

Verified locally on 2026-07-10:

- focused Stage 1 CLI suite: PASS, 49 tests;
- `dart format --set-exit-if-changed .`: PASS, 183 files unchanged;
- `flutter analyze --no-fatal-infos`: PASS with existing info-only lints;
- `flutter test --no-pub`: PASS, 461 tests with 3 external E2E skips.

- [x] **Step 1.6: Commit the adapter seam**

```sh
git add lib/src/release_cli test/release_cli
git commit -m "refactor: add deployable project adapter seam"
```

## Stage 2: Canonical Cross-Language Contracts

**Purpose:** Generate fixtures from the current Dart implementation so Swift
and C++ cannot silently invent a different schema, signature payload, rollout
algorithm, or diagnostics policy.

**Files:**

- Create: `tool/generate_native_contract_fixtures.dart`
- Create: `fixtures/compat/native-contract/README.md`
- Create: `fixtures/compat/native-contract/canonical-signature-cases.json`
- Create: `fixtures/compat/native-contract/descriptor-validation-cases.json`
- Create: `fixtures/compat/native-contract/selection-cases.json`
- Create: `fixtures/compat/native-contract/safe-path-cases.json`
- Create: `fixtures/compat/native-contract/diagnostics-redaction-cases.json`
- Create: `fixtures/compat/native-contract/helper-events.json`
- Create: `fixtures/compat/native-contract/release-contract/`
- Create: `test/native_contract_fixture_test.dart`
- Modify: `test/update_diagnostics_test.dart`
- Modify: `test/compat/native_helper_events_220_contract_test.dart`

**Interfaces:**

- Produces deterministic JSON generated by Dart serializers and canonical
  signature functions.
- Produces absolute `https://updates.example.test/...` fixture URLs.
- Produces integer `buildNumber` values.
- Produces one descriptor for every platform/artifact combination in the 2.7
  matrix.

- [x] **Step 2.1: Write the generator determinism test**

Run the generator twice into separate temporary directories and assert
byte-for-byte equality for every generated file.

RED verified locally on 2026-07-10: the fixture test failed because the
generator and its production API did not exist.

- [x] **Step 2.2: Generate valid release fixtures**

Every descriptor must include schema version, package identity, app name,
semantic version, integer build number, platform, channel, artifact kind,
absolute artifact URL, real SHA-256, real length, install strategy, minimum
updater version, and generated timestamp. Artifact-specific descriptors also
include the complete current Inno, DMG, or PKG install metadata.

- [x] **Step 2.3: Generate trust and selection cases**

Include positive and negative cases for:

- canonical JSON ordering;
- blanked signature value during canonicalization;
- Ed25519 `publicKeyId` lookup;
- wrong key, signature, package identity, version, build number, platform, or
  channel;
- build-number tiebreaking;
- prerelease ordering;
- rollout percentages 0, 1, 50, and 100 using fixed identities and salts;
- `minimumUpdaterVersion`;
- `minimumOS`;
- support policy before and after its deadline;
- fresh-install metadata.

- [x] **Step 2.4: Generate safe-path and diagnostics cases**

Safe-path cases must cover:

- `..` traversal;
- absolute POSIX paths;
- Windows drive-prefixed paths;
- backslash normalization;
- symbolic links;
- paths resolving outside the install root;
- exact protected Linux roots;
- valid nested bundle paths.

Diagnostics fixtures must retain current redaction and helper event strings.

- [x] **Step 2.5: Run Dart fixture validation**

```sh
dart run tool/generate_native_contract_fixtures.dart --check
flutter test --no-pub \
  test/native_contract_fixture_test.dart \
  test/update_diagnostics_test.dart \
  test/compat/native_helper_events_220_contract_test.dart
```

Expected: every JSON file parses through the current Dart models, every
descriptor validates, canonical bytes match, and generation is deterministic.

Verified locally on 2026-07-10:

- `dart run tool/generate_native_contract_fixtures.dart --check`: PASS;
- focused Stage 2 fixture, diagnostics, and helper suite: PASS, 16 tests;
- `dart format --set-exit-if-changed .`: PASS, 185 files unchanged;
- `flutter analyze --no-fatal-infos`: PASS with 377 existing info-only lints;
- `flutter test --no-pub`: PASS, 468 tests with 3 external E2E skips.

- [x] **Step 2.6: Commit canonical fixtures**

```sh
git add tool/generate_native_contract_fixtures.dart \
  fixtures/compat/native-contract test/native_contract_fixture_test.dart
git commit -m "test: generate native contract fixtures"
```

## Stage 3: macOS Helper SDK And Flutter Adapters

**Purpose:** Extract Flutter-free macOS install helpers into
`DesktopUpdaterKit` while keeping both SwiftPM and CocoaPods Flutter builds
working.

**Files:**

- Create: `Package.swift`
- Modify: `macos/desktop_updater/Package.swift`
- Modify: `macos/desktop_updater.podspec`
- Create: `macos/desktop_updater/Sources/DesktopUpdaterKit/MacInstallRequest.swift`
- Create: `macos/desktop_updater/Sources/DesktopUpdaterKit/MacInstallHelper.swift`
- Create: `macos/desktop_updater/Sources/DesktopUpdaterKit/Diagnostics.swift`
- Create: `macos/desktop_updater/Tests/DesktopUpdaterKitTests/`
- Modify: `macos/desktop_updater/Sources/desktop_updater/DesktopUpdaterPlugin.swift`
- Modify: `test/macos_swift_package_test.dart`
- Create: `test/macos_cocoapods_source_layout_test.dart`

**Interfaces:**

```swift
public struct MacInstallRequest: Sendable {
    public let stagingPath: String?
    public let allowUnsignedUpdates: Bool
    public let diagnosticsLogPath: String?
    public let currentProcessIdentifier: Int32
    public let bundlePath: String

    public init(
        stagingPath: String?,
        allowUnsignedUpdates: Bool,
        diagnosticsLogPath: String?,
        currentProcessIdentifier: Int32,
        bundlePath: String
    ) {
        self.stagingPath = stagingPath
        self.allowUnsignedUpdates = allowUnsignedUpdates
        self.diagnosticsLogPath = diagnosticsLogPath
        self.currentProcessIdentifier = currentProcessIdentifier
        self.bundlePath = bundlePath
    }
}

public struct MacInstallHelper {
    public init() {}
    public func scheduleInstallAndRelaunch(_ request: MacInstallRequest) throws
}
```

Every public Swift value type must declare public initializers; public stored
properties do not make the synthesized memberwise initializer public.

Keep the existing compatibility floors unless separately approved:

```text
SwiftPM package: macOS 10.15
CocoaPods Flutter fallback: macOS 10.14, Swift 5.0
```

Shared helper sources must compile at the CocoaPods 10.14 deployment target;
do not use a 10.15-only API without an availability branch.

- [x] **Step 3.1: Add root and plugin SwiftPM targets**

Root `Package.swift` exposes `DesktopUpdaterKit` only. The Flutter package
manifest exposes both `DesktopUpdaterKit` and the existing
`desktop-updater` adapter product. The adapter target depends on
`FlutterFramework` and `DesktopUpdaterKit`.

RED verified locally on 2026-07-10: five focused package-layout and adapter
tests failed because the root helper product, shared Swift sources, plugin
target dependency, and CocoaPods source layout did not exist.

- [x] **Step 3.2: Preserve the CocoaPods fallback**

The podspec compiles both source directories inside the existing Flutter pod:

```ruby
s.source_files = [
  File.join('desktop_updater', 'Sources', 'DesktopUpdaterKit', '**', '*.swift'),
  File.join('desktop_updater', 'Sources', 'desktop_updater', '**', '*.swift')
]
```

The Flutter adapter uses:

```swift
#if canImport(DesktopUpdaterKit)
import DesktopUpdaterKit
#endif
```

Under SwiftPM, helper types come from the `DesktopUpdaterKit` module. Under
CocoaPods, both source trees compile in the existing `desktop_updater` module,
so the same types are visible without publishing a native helper pod.

- [x] **Step 3.3: Extract the complete current helper**

Move shell generation, quoting, bundle identity, Team ID, codesign,
Gatekeeper, stapler, backup, replacement, rollback, cleanup, relaunch, and
PKG Installer.app handoff without weakening any current gate or changing
helper event strings.

Do not move Dart-owned discovery, rollout, HTTP, descriptor verification, DMG
staging, or lifecycle diagnostics into this master stage.

- [x] **Step 3.4: Add Swift API and fixture tests**

Tests must:

- instantiate every public request/diagnostics type from an external test
  module;
- prove `DesktopUpdaterKit` imports no Flutter module;
- read canonical diagnostics and helper-event fixtures;
- assert unsigned updates remain opt-in;
- assert ZIP/DMG staged `.app` identity checks and PKG Installer.app handoff
  remain available through the adapter.

- [x] **Step 3.5: Run both macOS integration lanes**

SwiftPM lane:

```sh
flutter config --enable-swift-package-manager
swift test
flutter build macos --debug
flutter test integration_test -d macos
```

CocoaPods fallback lane:

```sh
flutter config --no-enable-swift-package-manager
flutter clean
flutter build macos --debug
flutter test integration_test -d macos
```

Expected: both lanes compile the same helper behavior. Record CocoaPods as
`blocked` only when CocoaPods itself is unavailable; do not mark it verified
from source inspection alone.

Verified locally on 2026-07-10:

- root `swift build`: PASS;
- root `swift test`: PASS, 6 tests including external-module public API and
  canonical fixture coverage;
- focused macOS package, helper, symlink, diagnostics, and compatibility
  suite: PASS, 27 tests;
- SwiftPM Flutter host build: PASS;
- SwiftPM macOS integration suite: PASS, 2 tests;
- CocoaPods fallback host build: `blocked` because CocoaPods is not installed;
- `dart format --set-exit-if-changed .`: PASS, 186 files unchanged;
- `flutter analyze --no-fatal-infos`: PASS with 377 existing info-only lints;
- `flutter test --no-pub`: PASS, 471 tests with 3 external E2E skips.

- [x] **Step 3.6: Restore the user's Flutter SwiftPM setting**

Return the global Flutter SwiftPM setting to its value recorded before Step
3.5.

Verified locally on 2026-07-10: the recorded value was `true`, and
`flutter config --list` reported `enable-swift-package-manager: true` after
the integration lanes.

- [x] **Step 3.7: Commit macOS extraction**

```sh
git add Package.swift macos test/macos_swift_package_test.dart \
  test/macos_cocoapods_source_layout_test.dart
git commit -m "feat: extract macos updater helper kit"
```

## Stage 4: Windows Native Helper, Versioned C ABI, And .NET

**Purpose:** Build one Windows helper implementation as a static Flutter
library and a loadable shared DLL with a stable C ABI.

**Files:**

- Create: `windows/native/CMakeLists.txt`
- Create: `windows/native/include/desktop_updater_native_c.h`
- Create: `windows/native/include/desktop_updater_version.h`
- Create: `windows/native/src/desktop_updater_native.cpp`
- Create: `windows/native/src/desktop_updater_native_c.cpp`
- Create: `windows/native/test/`
- Create: `windows/native/dotnet/DesktopUpdater.Native/`
- Create: `windows/native/dotnet/DesktopUpdater.Native.Tests/`
- Modify: `windows/CMakeLists.txt`
- Modify: `windows/desktop_updater_plugin.cpp`
- Modify: `windows/desktop_updater_plugin.h`
- Modify: `windows/test/desktop_updater_plugin_test.cpp`

**Interfaces:**

```c
#include <stddef.h>
#include <stdint.h>

#define DESKTOP_UPDATER_NATIVE_ABI_VERSION 1u

#if defined(_WIN32)
#define DESKTOP_UPDATER_CALL __cdecl
#else
#define DESKTOP_UPDATER_CALL
#endif

typedef struct desktop_updater_install_request_v1 {
  uint32_t abi_version;
  size_t struct_size;
  const uint16_t* staging_path;
  const uint16_t* diagnostics_log_path;
  const uint16_t* const* removed_files;
  size_t removed_file_count;
} desktop_updater_install_request_v1;

typedef struct desktop_updater_result_v1 {
  uint32_t abi_version;
  int32_t ok;
  const char* error_message_utf8;
} desktop_updater_result_v1;

desktop_updater_result_v1 DESKTOP_UPDATER_CALL
desktop_updater_schedule_install_and_relaunch_v1(
    const desktop_updater_install_request_v1* request);

void DESKTOP_UPDATER_CALL desktop_updater_result_free_v1(
    desktop_updater_result_v1* result);
```

Exported functions use explicit names, C linkage, and one documented calling
convention. Every entrypoint catches C++ exceptions and returns an owned error
through `desktop_updater_result_free_v1`. The free function clears the pointer
and status fields so calling it again on the same result object is safe.

- [x] **Step 4.1: Write ABI layout and failure tests**

Test null requests, wrong ABI versions, undersized structs, invalid UTF-16,
non-empty removed-file arrays, thrown internal exceptions, and repeated
freeing rules.

RED verified locally on 2026-07-10: five focused Windows native SDK layout,
ABI, adapter, .NET, and CI tests failed because the standalone package and
consumers did not exist.

- [x] **Step 4.2: Build static and shared targets from common objects**

`windows/native/CMakeLists.txt` must define:

```cmake
add_library(desktop_updater_native_objects OBJECT ${NATIVE_SOURCES})
add_library(desktop_updater_native_static STATIC
  $<TARGET_OBJECTS:desktop_updater_native_objects>)
add_library(desktop_updater_native SHARED
  $<TARGET_OBJECTS:desktop_updater_native_objects>)
add_library(desktop_updater::native ALIAS desktop_updater_native)
```

Define `DESKTOP_UPDATER_NATIVE_BUILDING_DLL` only for the shared target.

- [x] **Step 4.3: Link Flutter through the correct directory**

Modify `windows/CMakeLists.txt`:

```cmake
add_subdirectory("native")
target_link_libraries(${PLUGIN_NAME} PRIVATE desktop_updater_native_static)
```

Do not use the nonexistent `native/desktop_updater` path. Keep
`DesktopUpdaterPluginCApi` and the existing Flutter plugin DLL name.

- [x] **Step 4.4: Extract helper behavior**

Move only Flutter-free helper logic. Preserve UAC, protected-root detection,
writeability checks, PowerShell encoding, Authenticode/Inno handling, backup,
rollback, cleanup, relaunch, and stable JSONL events. MethodChannel parsing
stays in the Flutter adapter.

- [x] **Step 4.5: Add complete .NET marshalling**

The public .NET method accepts:

```csharp
public static void ScheduleInstallAndRelaunch(
    string? stagingPath,
    IReadOnlyList<string> removedFiles,
    string? diagnosticsLogPath)
```

Use explicit UTF-16 allocation for each removed-file pointer, free every
allocation in `finally`, and declare P/Invoke with:

```csharp
[DllImport(
    "desktop_updater_native",
    EntryPoint = "desktop_updater_schedule_install_and_relaunch_v1",
    ExactSpelling = true,
    CallingConvention = CallingConvention.Cdecl)]
```

Do not ship a wrapper that always sends `removed_file_count == 0`.

- [x] **Step 4.6: Add native DLL integration tests**

The .NET test output must receive the actual DLL. At least one test calls the
C ABI with an invalid request and verifies the native error. Merely
constructing `DesktopUpdaterException` is not sufficient.

- [x] **Step 4.7: Make native tests explicit and offline-safe for Flutter**

Use:

```cmake
option(DESKTOP_UPDATER_NATIVE_BUILD_TESTS
  "Build desktop_updater native tests" OFF)
```

When `OFF`, no GoogleTest discovery or download occurs. When `ON`, resolve a
pinned GoogleTest dependency and register at least one test. Use GoogleTest
v1.16.0, the final C++14-compatible release, from:

```text
https://github.com/google/googletest/archive/refs/tags/v1.16.0.zip
SHA-256 a9607c9215866bd425a725610c5e0f739eeb50887a57903df48891446ce6fb3c
```

Prefer `find_package(GTest CONFIG QUIET)` when the target host already provides
that exact version. Otherwise use `FetchContent` with `URL_HASH` set to the
digest above. This branch is reachable only when native tests are explicitly
enabled.

- [ ] **Step 4.8: Run the Windows matrix**

```powershell
flutter build windows --debug
cmake -S windows/native -B windows/native/build `
  -DDESKTOP_UPDATER_NATIVE_BUILD_TESTS=ON
cmake --build windows/native/build --config Debug
ctest --test-dir windows/native/build -C Debug --output-on-failure
dotnet test windows/native/dotnet/DesktopUpdater.Native.Tests/DesktopUpdater.Native.Tests.csproj
flutter test integration_test -d windows
```

After CTest, assert its output does not contain `No tests were found`.

Candidate-only evidence on 2026-07-10:

- focused Windows SDK, helper, compatibility, and CI contract suite: PASS,
  27 tests;
- portable C ABI translation unit: compiled with local clang, with unmangled
  `desktop_updater_schedule_install_and_relaunch_v1` and
  `desktop_updater_result_free_v1` symbols;
- .NET wrapper and test projects: build PASS with 0 warnings and 0 errors;
- `dart format --set-exit-if-changed .`: PASS, 187 files unchanged;
- `flutter analyze --no-fatal-infos`: PASS with 377 existing info-only lints;
- `flutter test --no-pub`: PASS, 476 tests with 3 external E2E skips;
- Windows CMake, DLL, CTest, real P/Invoke, Flutter build, and integration:
  `not run locally` on the macOS host; CI commands are present and evidence is
  pending the final verification pass, so Step 4.8 remains unchecked.

- [x] **Step 4.9: Commit Windows extraction**

```sh
git add windows test/native_helper_script_test.dart
git commit -m "feat: extract windows updater native helper"
```

## Stage 5: Linux Source SDK And Safe Flutter Adapter

**Purpose:** Move the already hardened Linux helper into a Flutter-free source
library without reintroducing executable-parent deletion.

**Files:**

- Create: `linux/native/CMakeLists.txt`
- Create: `linux/native/include/desktop_updater_native.h`
- Create: `linux/native/include/desktop_updater_version.h`
- Create: `linux/native/src/desktop_updater_native.cc`
- Create: `linux/native/test/desktop_updater_native_test.cc`
- Modify: `linux/CMakeLists.txt`
- Modify: `linux/desktop_updater_plugin.cc`
- Modify: `linux/desktop_updater_plugin_private.h`
- Modify: `linux/test/desktop_updater_plugin_test.cc`

**Interfaces:**

```cpp
struct InstallRequest {
  LinuxInstallOperation operation;
  std::string staging_path;
  std::string install_root;
  std::string executable_relative_path;
  std::string package_id;
  std::vector<std::string> removed_files;
  std::string diagnostics_log_path;
};

InstallResult ValidateInstallRequest(const InstallRequest& request);
InstallResult ScheduleInstallAndRelaunch(const InstallRequest& request);
```

- [x] **Step 5.1: Move the validated implementation**

Move shell quoting, process/executable lookup, file writing, detached launch,
request validation, backup, copy, rollback, cleanup, permissions, and relaunch
into `linux/native`. Do not expose GTK or Flutter types from native headers.

- [x] **Step 5.2: Link the correct native directory**

Modify `linux/CMakeLists.txt`:

```cmake
add_subdirectory("native")
target_link_libraries(${PLUGIN_NAME} PRIVATE desktop_updater_native)
```

Do not use `native/desktop_updater`.

- [x] **Step 5.3: Prove destructive commands are bounded**

Native tests must inspect generated scripts and execute filesystem tests in a
temporary self-contained bundle. Required assertions:

- protected shared roots are rejected;
- install root and executable are canonical descendants;
- removed files cannot escape through `..` or symlinks;
- the helper never calls destructive commands against a shared root;
- rollback restores only the verified app-owned bundle;
- staging cleanup cannot delete the install root.

- [x] **Step 5.4: Keep Linux publication source-first**

Add CMake install/export rules and a pkg-config template for source builds.
Do not add a generic `.so` GitHub Release asset in this plan. Document that
prebuilt Linux binaries require a later compiler/glibc/architecture matrix.

- [ ] **Step 5.5: Run the Linux matrix**

```sh
flutter build linux --debug
cmake -S linux/native -B linux/native/build \
  -DDESKTOP_UPDATER_NATIVE_BUILD_TESTS=ON
cmake --build linux/native/build
ctest --test-dir linux/native/build --output-on-failure
xvfb-run -a flutter test integration_test -d linux
```

Assert CTest discovers at least one test.

Candidate-only evidence on 2026-07-10:

- the Stage 5 contract suite failed first with all 5 expected missing-layout,
  extraction, safety-test, and CI assertions before implementation;
- focused Linux SDK layout, helper, and compatibility suite: PASS, 25 tests;
- Flutter-free native helper: compiled locally as C++14 with
  `-Wall -Wextra -Werror`;
- direct native seam smoke: PASS for protected-root rejection, bounded script
  generation, failed-install rollback, and preservation of a file outside the
  verified bundle;
- `dart format --set-exit-if-changed .`: PASS, 188 files unchanged;
- `flutter analyze --no-fatal-infos`: PASS with 377 existing info-only lints;
- `flutter test --no-pub`: PASS, 481 tests with 3 external E2E skips;
- `dart pub publish --dry-run`: the package contains the Linux native CMake,
  headers, sources, tests, and pkg-config template; pre-commit validation
  reported only the expected dirty-tree warning and version hint;
- Linux source package CMake/GTest and Flutter integration matrix:
  `not run locally` on the macOS host because CMake and Linux host libraries
  are unavailable; CI commands are present and evidence is pending the final
  verification pass, so Step 5.5 remains unchecked.

- [x] **Step 5.6: Commit Linux extraction**

```sh
git add linux test/native_helper_script_test.dart
git commit -m "feat: extract safe linux updater helper"
```

## Stage 6: Installable Package Consumer Gates

**Purpose:** Prove packages work outside their own source tree before calling
them consumable.

**Files:**

- Create: `example/native/macos/`
- Create: `example/native/windows-cmake/`
- Create: `example/native/windows-dotnet/`
- Create: `example/native/linux-cmake/`
- Create: `windows/native/cmake/desktop_updater_nativeConfig.cmake.in`
- Create: `windows/native/dotnet/DesktopUpdater.Native/buildTransitive/`
- Create: `windows/native/dotnet/DesktopUpdater.Native/runtimes/win-x64/native/`
- Create: `linux/native/cmake/desktop_updater_nativeConfig.cmake.in`
- Create: `linux/native/cmake/desktop_updater_native.pc.in`
- Modify: `.github/workflows/desktop-updater-ci.yml`

- [x] **Step 6.1: Add a local SwiftPM consumer**

The sample depends on the repository root by local path, imports
`DesktopUpdaterKit`, constructs a public `MacInstallRequest`, and compiles
without importing Flutter.

- [x] **Step 6.2: Add installed CMake consumers**

Windows and Linux tests must install to a temporary prefix, configure consumer
projects with that prefix, build them, and run their tests. Consumer
`CMakeLists.txt` uses:

```cmake
find_package(desktop_updater_native CONFIG REQUIRED)
target_link_libraries(consumer PRIVATE desktop_updater::native)
```

- [x] **Step 6.3: Pack and consume NuGet**

The package must contain:

```text
lib/net8.0/DesktopUpdater.Native.dll
lib/netstandard2.0/DesktopUpdater.Native.dll
runtimes/win-x64/native/desktop_updater_native.dll
buildTransitive/DesktopUpdater.Native.targets
```

Create a temporary console project, install the local `.nupkg`, run it, and
exercise one native failure path.

- [x] **Step 6.4: Add package-content assertions**

Assert:

- pub dry-run contains local macOS/Windows/Linux helper sources;
- SwiftPM has no Flutter dependency;
- NuGet contains the DLL and wrapper for every advertised TFM/RID;
- Linux source archive contains install/export/pkg-config files;
- no package documentation claims full native runtime APIs yet.

- [ ] **Step 6.5: Run consumer CI**

Run each consumer on its target host. Package jobs fail when the consumer
compile, link, load, or execution step fails.

Candidate-only evidence on 2026-07-10:

- the Stage 6 consumer/package contract suite failed first with all 5 expected
  missing-consumer, install-config, NuGet-layout, and CI assertions;
- focused native SDK, consumer/package, and harness suite: PASS, 26 tests;
- external local-path SwiftPM consumer: build and execution PASS on macOS;
- `DesktopUpdater.Native`: both `net8.0` and `netstandard2.0` build PASS with
  0 warnings and 0 errors;
- local NuGet pack: PASS, with both wrapper TFMs, the win-x64 native slot, and
  build-transitive targets present; the local package consumer restored,
  built, and copied the native slot into its output;
- `dart format --set-exit-if-changed .`: PASS, 189 files unchanged;
- `flutter analyze --no-fatal-infos`: PASS with 377 existing info-only lints;
- `flutter test --no-pub`: PASS, 486 tests with 3 external E2E skips;
- `dart pub publish --dry-run`: package contents include all helper sources,
  installed-package metadata, and consumer samples; pre-commit validation
  reported only the expected dirty-tree warning and version hint;
- real Windows DLL pack/load/failure execution and installed Windows/Linux
  CMake consumer execution are `not run locally` on the macOS host; CI commands
  are present and evidence is pending the final verification pass, so Step 6.5
  remains unchecked.

- [x] **Step 6.6: Commit package gates**

```sh
git add example/native windows/native linux/native \
  .github/workflows/desktop-updater-ci.yml
git commit -m "test: verify native sdk consumers"
```

## Stage 7: Full Native Runtime Child Gate

**Purpose:** Keep helper extraction separate from duplicated native discovery
and staging runtimes.

**Files:**

- Modify:
  `docs/exec-plans/active/2026-07-05-full-native-runtime-preview-plan.md`
- Modify: `docs/exec-plans/index.md` only if its link is missing
- Test: `test/harness_engineering_docs_test.dart`

- [x] **Step 7.1: Rebase the child plan**

The child plan must:

- depend on successful Stages 0-6;
- consume generated fixtures from Stage 2;
- cover all current 2.7 policies and artifact kinds;
- use the extracted helpers from Stages 3-5;
- add real macOS, Windows, and Linux sample update smokes;
- remain preview until all target-host evidence exists.

- [x] **Step 7.2: Remove premature runtime documentation**

Master-plan docs may show only helper APIs:

```text
scheduleInstallAndRelaunch(alreadyVerifiedStagedArtifact)
```

Do not show `checkForUpdate` or `downloadVerifyAndStage` until the child plan
implements and verifies them.

- [x] **Step 7.3: Keep plan tracking literal**

The child plan and index already exist. Do not leave their creation shown as
unchecked future work. Record the rebase date and leave only unimplemented
runtime tasks unchecked.

- [x] **Step 7.4: Run the plan/index test**

```sh
flutter test --no-pub test/harness_engineering_docs_test.dart
```

Verified locally on 2026-07-10: PASS, 8 tests.

- [x] **Step 7.5: Commit the plan rebase**

```sh
git add docs/exec-plans
git commit -m "docs: rebase native runtime plans"
```

## Stage 8: Native Publish Build Adapters

**Purpose:** Build deployable Xcode/CMake install trees while keeping Flutter
publish behavior unchanged.

**Files:**

- Create: `lib/src/release_cli/xcode_project_adapter.dart`
- Create: `lib/src/release_cli/cmake_project_adapter.dart`
- Modify: `lib/src/release_cli/project_adapter.dart`
- Modify: `lib/src/release_cli/publish_command.dart`
- Modify: `lib/src/release_cli/release_publish_config.dart`
- Test: `test/release_cli/project_adapter_test.dart`
- Test: `test/release_cli/release_publisher_build_test.dart`

- [ ] **Step 8.1: Add explicit project-type options**

Supported values:

```text
flutter
xcode
cmake
manual
```

`manual` requires a complete artifact root, app name, package ID, and version.
`xcode` requires a project/workspace and scheme. `cmake` requires a configured
install target or an already installed bundle root.

- [ ] **Step 8.2: Build Xcode into a deterministic output**

Use an explicit project/workspace, scheme, Release configuration, macOS
destination, and derived-data path. Resolve the `.app` from build settings and
return the whole bundle.

- [ ] **Step 8.3: Build CMake through install staging**

Run configure/build and:

```sh
cmake --install <build-dir> --prefix <temporary-install-root>
```

Return the application-owned install tree, not `MyApp.exe` or a single Linux
executable. Require `executableRelativePath` for helper relaunch.

- [ ] **Step 8.4: Test ambiguity and Flutter default**

Existing unqualified Flutter publish commands must select `flutter`.
Directories containing both Xcode and CMake markers require explicit
`--project-type`.

- [ ] **Step 8.5: Run CLI tests**

```sh
flutter test --no-pub \
  test/release_cli/project_adapter_test.dart \
  test/release_cli/release_publisher_build_test.dart \
  test/release_cli/release_publish_config_test.dart \
  test/release_cli/publish_layout_test.dart \
  test/release_cli/publish_manifest_test.dart
```

- [ ] **Step 8.6: Commit build adapters**

```sh
git add lib/src/release_cli test/release_cli
git commit -m "feat: add native install-tree build adapters"
```

## Stage 9: Standalone CLI Contract And Distribution

**Purpose:** Provide one compiled CLI without inventing commands or flags that
do not exist.

**Files:**

- Create: `bin/desktop_updater.dart`
- Create: `lib/src/cli/desktop_updater_cli.dart`
- Refactor: `bin/package.dart`
- Refactor: `bin/verify.dart`
- Refactor: `bin/app_archive.dart`
- Refactor: `bin/release.dart`
- Modify: `.github/workflows/desktop-updater-ci.yml`
- Test: `test/desktop_updater_cli_test.dart`

**Interfaces:**

```dart
Future<int> runDesktopUpdaterCli(
  List<String> args, {
  Directory? projectRoot,
  StringSink? output,
  Map<String, String>? environment,
});
```

Top-level subcommands:

```text
release
package
verify
app-archive
```

- [ ] **Step 9.1: Extract reusable command runners**

Refactor existing bin entrypoints so the dispatcher calls the same parsers and
implementations. Existing `dart run desktop_updater:package` and other bin
commands remain valid.

- [ ] **Step 9.2: Keep flag names consistent**

`desktop-updater package` uses the existing `--input` flag. Do not document
`--app-path` for the package command unless it is intentionally added as a
tested alias. `--app-path` belongs only to publish/project-adapter selection.

- [ ] **Step 9.3: Test every documented command**

Tests invoke:

```text
desktop-updater --help
desktop-updater --version
desktop-updater release publish --help
desktop-updater package --help
desktop-updater verify --help
desktop-updater app-archive --help
```

No documentation may reference `runDesktopUpdaterCli` before this task creates
it.

- [ ] **Step 9.4: Build the release matrix**

Build on native hosts:

```text
desktop-updater-macos-arm64
desktop-updater-macos-x64
desktop-updater-windows-x64.exe
desktop-updater-linux-x64
```

Generate SHA-256 checksums. macOS and Windows production release assets require
the repository's approved signing/notarization workflows; unsigned local
builds are `candidate-only`.

- [ ] **Step 9.5: Commit the CLI**

```sh
git add bin lib/src/cli test/desktop_updater_cli_test.dart \
  .github/workflows/desktop-updater-ci.yml
git commit -m "feat: add standalone desktop updater cli"
```

## Stage 10: Versioning, Publication, Documentation, And Final Matrix

**Purpose:** Synchronize versions, publish only verified surfaces, and preserve
literal evidence labels.

**Files:**

- Create: `tool/version_check.dart`
- Create: `tool/sync_versions.dart`
- Modify: `tool/harness_check.dart`
- Create: `docs/native-sdk.md`
- Modify: `README.md`
- Modify: `docs/publishing.md`
- Modify: `docs/github-actions-ci-cd.md`
- Modify: `.github/workflows/desktop-updater-ci.yml`
- Test: `test/native_sdk_docs_test.dart`

- [ ] **Step 10.1: Generate checked version constants**

Read root `pubspec.yaml` and generate/check:

- Dart package/CLI full version;
- Swift helper version string;
- Windows and Linux header version strings;
- CMake numeric `MAJOR.MINOR.PATCH`;
- NuGet-compatible SemVer.

The sync tool never changes `pubspec.yaml`, changelog, or Git tags.

- [ ] **Step 10.2: Document package surfaces honestly**

Document:

```text
Flutter: pub.dev desktop_updater with local native helper sources
macOS helper: DesktopUpdaterKit through SwiftPM
Windows helper: CMake DLL/static package and DesktopUpdater.Native NuGet
Linux helper: source-first CMake package with generated pkg-config metadata
CLI: dart run entrypoints and signed standalone release assets
Full native runtime: preview child plan, unavailable until its gates pass
```

- [ ] **Step 10.3: Add release asset and consumer checks**

CI must validate package contents, versions, checksums, consumer builds, C ABI
version, and target-host native tests. A package job cannot pass from source
unit tests alone.

- [ ] **Step 10.4: Run the complete Flutter ladder**

```sh
dart format --set-exit-if-changed .
flutter analyze --no-fatal-infos
flutter test --no-pub
dart pub publish --dry-run
dart run tool/version_check.dart
```

- [ ] **Step 10.5: Run target-host helper and consumer matrices**

Required evidence:

```text
macOS SwiftPM helper tests: verified locally or CI
macOS Flutter SwiftPM build/integration: verified locally or CI
macOS Flutter CocoaPods fallback build/integration: verified locally or CI
Windows static Flutter helper: verified in Windows CI
Windows shared C ABI DLL: verified in Windows CI
Windows .NET local NuGet consumer: verified in Windows CI
Linux protected-root tests: verified in Linux CI
Linux Flutter helper: verified in Linux CI
Linux installed CMake consumer: verified in Linux CI
Standalone CLI matrix: candidate-only until signed release workflow passes
```

- [ ] **Step 10.6: Add full release smoke without weakening current lanes**

Keep current Windows/Linux publish and update smoke commands. Keep macOS
Developer ID/notary smoke separately gated by explicit secrets and approved
workflow dispatch.

- [ ] **Step 10.7: Commit release documentation and gates**

```sh
git add tool docs README.md test/native_sdk_docs_test.dart \
  .github/workflows/desktop-updater-ci.yml
git commit -m "docs: define native sdk release gates"
```

## Final Release Gate

The master plan is complete only when:

- the Linux helper rejects shared/system roots before script creation;
- the macOS helper builds through SwiftPM and CocoaPods fallback;
- the Windows Flutter plugin links static helper objects;
- the Windows NuGet consumer loads the shared DLL and exercises `removedFiles`;
- Windows and Linux CMake consumers use installed package exports;
- every native CTest lane discovers and runs tests;
- pub dry-run includes all local helper sources;
- existing Flutter API/CLI/plugin compatibility tests pass;
- documentation exposes helper APIs only;
- the child runtime plan is rebased but remains separately gated.

Missing credentials or unavailable target hosts must be recorded as `blocked`
or `not run`. They must not be rewritten as passing evidence.

## Rebase Status

As of 2026-07-10:

- the child plan file and index entry already exist;
- the target `windows/native`, `linux/native`, root `Package.swift`,
  standalone CLI, and native SDK documentation do not yet exist;
- old checkbox counts are not execution evidence;
- this rebase resets implementation work to the explicit unchecked tasks
  above and treats the already-created child-plan file as repository context,
  not completed runtime work.

## Self-Review

- **Safety:** destructive Linux operations require a verified app-owned root;
  executable-parent inference alone is never sufficient.
- **Trust:** canonical JSON, Ed25519 key ID, package identity, index binding,
  artifact integrity, and platform publisher gates are named explicitly.
- **Platform integration:** macOS covers SwiftPM and CocoaPods; Windows covers
  static Flutter and shared .NET/C ABI; Linux is source-first.
- **Boundary:** helper extraction and full native runtime are separate plans.
- **Buildability:** CMake paths match the target layout and native tests are
  explicitly enabled.
- **Packageability:** every package has an external consumer gate.
- **CLI consistency:** documented entrypoints, subcommands, and flags are
  created before use.
- **2.7 parity:** DMG, PKG, Inno, rollout, build numbers, minimum policies,
  support/fresh-install metadata, and signatures are in the baseline.
