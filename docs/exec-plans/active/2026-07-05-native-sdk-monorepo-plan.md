# Native SDK Monorepo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep the existing `desktop_updater` Flutter package, public API, plugin registration, and Dart CLI behavior fully compatible while adding standalone native updater SDKs for macOS, Windows, and Linux from the same repository.

**Architecture:** The pub.dev surface remains one package: `desktop_updater`. Native SDKs are Flutter-free packages that can be consumed directly by native apps and are also used by the Flutter plugin adapters. CLI release-contract logic remains shared in Dart; project-specific build behavior is isolated behind adapters so old Flutter commands keep their current defaults and native projects can opt into Xcode, CMake, or manual app-path flows.

**Tech Stack:** Dart/Flutter plugin, Dart CLI, SwiftPM, Swift/XCTest, C++/CMake, GoogleTest, GitHub Actions, existing zip-first `app-archive.json` and `release.json` contract.

---

## Non-Negotiable Compatibility Rules

- The pub.dev package remains `desktop_updater`; do not introduce a separate pub package such as `desktop_updater_core`.
- Existing Flutter imports remain valid:
  - `package:desktop_updater/desktop_updater.dart`
  - `package:desktop_updater/updater_controller.dart`
  - `package:desktop_updater/desktop_updater_platform_interface.dart`
  - `package:desktop_updater/desktop_updater_method_channel.dart`
- Existing Flutter plugin registration remains valid:
  - Linux `pluginClass: DesktopUpdaterPlugin`
  - macOS `pluginClass: DesktopUpdaterPlugin`
  - Windows `pluginClass: DesktopUpdaterPluginCApi`
- Existing Dart CLI commands keep their default Flutter behavior when run in a Flutter project:
  - `dart run desktop_updater:package`
  - `dart run desktop_updater:verify`
  - `dart run desktop_updater:app_archive`
  - `dart run desktop_updater:release publish --platform <platform>`
  - `dart run desktop_updater:release doctor --platform <platform>`
  - `dart run desktop_updater:release validate`
  - `dart run desktop_updater:release sign`
- Existing runtime semantics remain valid:
  - Dart lifecycle diagnostics stay in Dart for Flutter apps.
  - Native helper JSONL events stay stable.
  - `diagnosticsLogPath` remains app-owned and optional.
  - `UpdateProblemReport` redaction and bounded report behavior remain stable.
  - Windows/Linux Release CI lanes continue to build, run native tests, run integration tests, run publish smoke, and run update smoke.
- No current behavior is marked deprecated during this migration.
- Versioning has one source of truth: root `pubspec.yaml`. Do not use `.env`
  files for package versions.
- Flutter builds must not download SwiftPM, NuGet, CMake, or pkg-config
  packages from remote package feeds to use the plugin. The Flutter package
  consumes the native SDKs from local source targets included in the pub
  package.
- Windows native distribution must expose a stable `extern "C"` ABI for broad
  native app compatibility. C++ implementation details must not leak into the
  public ABI used by .NET P/Invoke, Rust, Go, Python, Electron native addons, or
  non-MSVC consumers.
- Windows .NET consumption is first-class from the initial Windows native SDK
  release, not a later optional add-on. The .NET wrapper must bind through the C
  ABI.
- macOS native SDK distribution is SwiftPM-only. CocoaPods remains only as an
  existing Flutter plugin fallback compatibility path; do not publish a
  `DesktopUpdaterKit` pod.

## Target Package Layout

Keep the root as the Flutter/Dart package:

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

Add native SDK surfaces without moving the Flutter package out of the root:

```text
Package.swift                                  # Root SwiftPM package for native Swift consumers.
macos/desktop_updater/Package.swift            # Flutter macOS plugin SwiftPM package remains.
macos/desktop_updater/Sources/DesktopUpdaterKit/
macos/desktop_updater/Sources/desktop_updater/ # Flutter adapter target remains.

windows/native/
windows/native/CMakeLists.txt
windows/native/include/
windows/native/src/
windows/native/dotnet/DesktopUpdater.Native/   # First-class .NET wrapper over the C ABI.
windows/native/test/
windows/desktop_updater_plugin.cpp             # Flutter adapter remains.

linux/native/
linux/native/CMakeLists.txt
linux/native/include/
linux/native/src/
linux/native/test/
linux/desktop_updater_plugin.cc                # Flutter adapter remains.
```

The native package names should be:

- macOS SwiftPM product: `DesktopUpdaterKit`
- Windows CMake target: `desktop_updater_native`
- Windows public ABI header: `desktop_updater_native_c.h`
- Linux CMake target: `desktop_updater_native`

## Stage 0: Baseline Freeze Before Refactor

**Purpose:** Capture current Flutter behavior and native helper behavior before any extraction.

**Files:**
- Modify: `test/compat/flutter_220_public_api_test.dart`
- Modify: `test/compat/flutter_220_channel_controller_contract_test.dart`
- Modify: `test/compat/native_helper_events_220_contract_test.dart`
- Modify: `test/macos_swift_package_test.dart`
- Modify: `.github/workflows/desktop-updater-ci.yml`

- [ ] **Step 0.1: Add explicit no-deprecation public API checks**

Add checks that the public Flutter facade and controller remain directly constructible:

```dart
test("Flutter facade remains the primary public API", () {
  expect(DesktopUpdater(), isA<DesktopUpdater>());
  expect(
    DesktopUpdaterController(
      appArchiveUrl: null,
      skipInitialVersionCheck: true,
    ),
    isA<DesktopUpdaterController>(),
  );
});
```

- [ ] **Step 0.2: Add explicit CLI backwards compatibility fixture**

Create a test in `test/release_cli/release_command_test.dart` that asserts help output still includes the existing command names:

```dart
test("release CLI keeps existing Flutter-first commands", () async {
  final output = StringBuffer();
  final exitCode = await runReleaseCommand(
    const ["publish", "--help"],
    output: output,
  );

  expect(exitCode, 0);
  expect(output.toString(), contains("--platform"));
  expect(output.toString(), contains("--config"));
  expect(output.toString(), contains("--version"));
  expect(output.toString(), contains("--build-number"));
});
```

- [ ] **Step 0.3: Run focused baseline tests**

Run:

```sh
flutter test --no-pub \
  test/compat/flutter_220_public_api_test.dart \
  test/compat/flutter_220_channel_controller_contract_test.dart \
  test/compat/native_helper_events_220_contract_test.dart \
  test/release_cli/release_command_test.dart
```

Expected: all pass before extraction.

- [ ] **Step 0.4: Commit baseline guardrails**

Commit message:

```sh
git commit -m "test: freeze updater compatibility contracts"
```

## Stage 1: CLI Adapter Boundary With No Behavior Change

**Purpose:** Make `release publish` choose a project adapter internally while preserving the existing Flutter default.

**Files:**
- Create: `lib/src/release_cli/project_adapter.dart`
- Create: `lib/src/release_cli/flutter_project_adapter.dart`
- Create: `lib/src/release_cli/manual_project_adapter.dart`
- Modify: `lib/src/release_cli/release_publish_config.dart`
- Modify: `lib/src/release_cli/release_publisher.dart`
- Modify: `lib/src/release_cli/publish_command.dart`
- Test: `test/release_cli/release_publisher_build_test.dart`
- Test: `test/release_cli/release_publish_config_test.dart`

- [ ] **Step 1.1: Add `ProjectAdapter` contract**

Create `lib/src/release_cli/project_adapter.dart`:

```dart
import "dart:io";

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
    required this.appPath,
    required this.packageId,
    required this.version,
    this.buildNumber,
  });

  final String appPath;
  final String packageId;
  final String version;
  final String? buildNumber;
}

abstract interface class ProjectAdapter {
  String get type;
  bool canHandle(Directory projectRoot);
  Future<ProjectBuildResult> build(ProjectBuildRequest request);
}
```

- [ ] **Step 1.2: Move current Flutter build behavior into `FlutterProjectAdapter`**

Create `lib/src/release_cli/flutter_project_adapter.dart` with the current `flutter build <platform> --release` behavior from `ReleasePublisher`. Preserve current output paths:

```dart
import "dart:io";

import "package:desktop_updater/src/release_cli/project_adapter.dart";
import "package:path/path.dart" as path;
import "package:pubspec_parse/pubspec_parse.dart";

final class FlutterProjectAdapter implements ProjectAdapter {
  const FlutterProjectAdapter();

  @override
  String get type => "flutter";

  @override
  bool canHandle(Directory projectRoot) {
    final pubspecFile = File(path.join(projectRoot.path, "pubspec.yaml"));
    if (!pubspecFile.existsSync()) {
      return false;
    }
    final pubspec = Pubspec.parse(pubspecFile.readAsStringSync());
    return pubspec.fields.containsKey("flutter");
  }

  @override
  Future<ProjectBuildResult> build(ProjectBuildRequest request) async {
    return buildFlutterProjectWithExistingReleasePublisherBehavior(request);
  }
}
```

`buildFlutterProjectWithExistingReleasePublisherBehavior` is a temporary
extraction target for the current `ReleasePublisher` build and metadata
resolution code. In this stage, move the existing implementation into that
function without changing command arguments, metadata resolution, or output
path resolution.

- [ ] **Step 1.3: Add manual app-path adapter**

Create `lib/src/release_cli/manual_project_adapter.dart`:

```dart
final class ManualProjectAdapter implements ProjectAdapter {
  const ManualProjectAdapter({
    required this.appPath,
    required this.packageId,
    required this.version,
    this.buildNumber,
  });

  final String appPath;
  final String packageId;
  final String version;
  final String? buildNumber;

  @override
  String get type => "manual";

  @override
  bool canHandle(Directory projectRoot) => appPath.isNotEmpty;

  @override
  Future<ProjectBuildResult> build(ProjectBuildRequest request) async {
    return ProjectBuildResult(
      appPath: appPath,
      packageId: packageId,
      version: version,
      buildNumber: buildNumber,
    );
  }
}
```

- [ ] **Step 1.4: Preserve old `release publish` default**

Modify `publish_command.dart` so that when no `--project-type` or `--app-path` is passed, Flutter remains the default in a Flutter project.

Detection order:

```text
1. --app-path present => manual
2. --project-type present => exact adapter
3. pubspec.yaml with Flutter app/plugin markers => flutter
4. one native project marker => native adapter in later stages
5. ambiguous or missing marker => usage error
```

- [ ] **Step 1.5: Add tests for no behavior change**

In `test/release_cli/release_publisher_build_test.dart`, add:

```dart
test("release publish defaults to Flutter adapter in Flutter projects", () async {
  final project = await createReleasePublishFixtureProject();
  final adapter = selectProjectAdapter(project.root, projectType: null, appPath: null);

  expect(adapter.type, "flutter");
});
```

In `test/release_cli/release_publish_config_test.dart`, add:

```dart
test("manual app path does not require Flutter project detection", () {
  final adapter = selectProjectAdapter(
    Directory.systemTemp,
    projectType: null,
    appPath: "/tmp/MyApp",
  );

  expect(adapter.type, "manual");
});
```

- [ ] **Step 1.6: Run focused CLI tests**

Run:

```sh
flutter test --no-pub \
  test/release_cli/release_publisher_build_test.dart \
  test/release_cli/release_publish_config_test.dart \
  test/release_cli/release_command_test.dart
```

Expected: all pass; existing Flutter publish fixtures still call Flutter.

- [ ] **Step 1.7: Commit CLI seam**

Commit message:

```sh
git commit -m "refactor: add release project adapter seam"
```

## Stage 2: Native Diagnostics Contract Fixtures

**Purpose:** Share diagnostics/report expectations across Dart, Swift, and C++ without forcing one language implementation.

**Files:**
- Create: `fixtures/compat/diagnostic-redaction-cases.json`
- Create: `fixtures/compat/native-helper-events.json` if it does not already exist
- Modify: `test/update_diagnostics_test.dart`
- Modify: `test/compat/diagnostics_recovery_220_contract_test.dart`

- [ ] **Step 2.1: Add shared redaction fixture**

Create `fixtures/compat/diagnostic-redaction-cases.json`:

```json
{
  "cases": [
    {
      "input": "Authorization: Bearer abc123 password=hunter2 signature=deadbeef",
      "mustContain": [
        "Authorization: <redacted>",
        "password=<redacted>",
        "signature=<redacted>"
      ],
      "mustNotContain": ["abc123", "hunter2", "deadbeef"]
    },
    {
      "input": "GET https://updates.example.com/release.json?token=abc&key=def&safe=value",
      "mustContain": [
        "token=<redacted>",
        "key=<redacted>",
        "safe=value"
      ],
      "mustNotContain": ["token=abc", "key=def"]
    }
  ]
}
```

- [ ] **Step 2.2: Make Dart diagnostics test read shared fixture**

Add a test that loops over the fixture and verifies `UpdateDiagnosticEntry.toRedactedLogLine()` and `UpdateProblemReport.toPlainText()`.

- [ ] **Step 2.3: Ensure helper events stay shared**

Keep the existing event fixture as the canonical list for native helper JSONL event names:

```json
{
  "events": [
    "helper scheduled",
    "waiting for parent process",
    "parent process exited",
    "backup start",
    "backup success",
    "backup failure",
    "move start",
    "move success",
    "move failure",
    "rollback start",
    "rollback success",
    "rollback failure",
    "cleanup start",
    "cleanup success",
    "cleanup failure",
    "relaunch attempt"
  ]
}
```

- [ ] **Step 2.4: Run diagnostics tests**

Run:

```sh
flutter test --no-pub \
  test/update_diagnostics_test.dart \
  test/compat/diagnostics_recovery_220_contract_test.dart \
  test/compat/native_helper_events_220_contract_test.dart
```

Expected: all pass.

- [ ] **Step 2.5: Commit diagnostics contract fixtures**

Commit message:

```sh
git commit -m "test: share diagnostics contract fixtures"
```

## Stage 3: macOS Standalone Swift SDK And Flutter Adapter

**Purpose:** Extract Flutter-free macOS updater code into `DesktopUpdaterKit` while keeping `DesktopUpdaterPlugin` as the Flutter MethodChannel adapter.

**Files:**
- Create: `Package.swift`
- Modify: `macos/desktop_updater/Package.swift`
- Create: `macos/desktop_updater/Sources/DesktopUpdaterKit/DesktopUpdaterKit.swift`
- Create: `macos/desktop_updater/Sources/DesktopUpdaterKit/MacInstallHelper.swift`
- Create: `macos/desktop_updater/Sources/DesktopUpdaterKit/Diagnostics.swift`
- Create: `macos/desktop_updater/Tests/DesktopUpdaterKitTests/DesktopUpdaterKitTests.swift`
- Modify: `macos/desktop_updater/Sources/desktop_updater/DesktopUpdaterPlugin.swift`
- Modify: `test/macos_swift_package_test.dart`

- [ ] **Step 3.1: Add root SwiftPM manifest for native consumers**

Create root `Package.swift`:

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "desktop-updater-native",
    platforms: [.macOS(.v10_15)],
    products: [
        .library(name: "DesktopUpdaterKit", targets: ["DesktopUpdaterKit"])
    ],
    targets: [
        .target(
            name: "DesktopUpdaterKit",
            path: "macos/desktop_updater/Sources/DesktopUpdaterKit"
        ),
        .testTarget(
            name: "DesktopUpdaterKitTests",
            dependencies: ["DesktopUpdaterKit"],
            path: "macos/desktop_updater/Tests/DesktopUpdaterKitTests"
        )
    ]
)
```

- [ ] **Step 3.2: Add `DesktopUpdaterKit` target to Flutter macOS package**

Modify `macos/desktop_updater/Package.swift` so:

```swift
.library(name: "DesktopUpdaterKit", targets: ["DesktopUpdaterKit"]),
.library(name: "desktop-updater", targets: ["desktop_updater"])
```

and the Flutter target depends on both `FlutterFramework` and `DesktopUpdaterKit`.

- [ ] **Step 3.3: Extract install helper into `MacInstallHelper`**

Create `MacInstallHelper` with this public entry point:

```swift
public struct MacInstallRequest: Sendable {
    public let stagingPath: String?
    public let allowUnsignedUpdates: Bool
    public let diagnosticsLogPath: String?
    public let currentProcessIdentifier: Int32
    public let bundlePath: String
}

public struct MacInstallHelper {
    public init() {}

    public func scheduleInstallAndRelaunch(_ request: MacInstallRequest) throws {
        let scriptURL = try writeHelperScript(request)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptURL.path]
        try process.run()
    }
}
```

Move the existing script generation, shell quoting, bundle ID checks, codesign checks, Gatekeeper checks, stapler checks, backup, move, rollback, cleanup, and relaunch script contents into this target without changing emitted helper event strings.

- [ ] **Step 3.4: Add Swift diagnostics types**

Create `Diagnostics.swift`:

```swift
public enum UpdateDiagnosticLevel: String, Sendable {
    case info
    case warning
    case error
}

public enum UpdateDiagnosticStage: String, Sendable {
    case check
    case descriptor
    case policy
    case download
    case verify
    case stage
    case install
    case cleanup
}

public struct UpdateDiagnosticEntry: Sendable {
    public let timestamp: Date
    public let stage: UpdateDiagnosticStage
    public let level: UpdateDiagnosticLevel
    public let message: String
    public let errorDescription: String?
}
```

Implement redaction using the shared fixture from Stage 2.

- [ ] **Step 3.5: Make Flutter plugin call `DesktopUpdaterKit`**

Modify `DesktopUpdaterPlugin.swift`:

```swift
import Cocoa
import FlutterMacOS
import DesktopUpdaterKit
```

Replace direct helper implementation with:

```swift
try MacInstallHelper().scheduleInstallAndRelaunch(
    MacInstallRequest(
        stagingPath: stagingPath,
        allowUnsignedUpdates: allowUnsignedMacOSUpdates,
        diagnosticsLogPath: diagnosticsLogPath,
        currentProcessIdentifier: ProcessInfo.processInfo.processIdentifier,
        bundlePath: Bundle.main.bundlePath
    )
)
```

Keep MethodChannel method names and argument parsing unchanged.

- [ ] **Step 3.6: Add SwiftPM tests**

Create XCTest cases that assert:

```swift
func testHelperScriptContainsStableEvents() throws {
    let script = try MacInstallHelper().makeScriptForTesting(...)
    XCTAssertTrue(script.contains("helper scheduled"))
    XCTAssertTrue(script.contains("backup start"))
    XCTAssertTrue(script.contains("move start"))
    XCTAssertTrue(script.contains("cleanup success"))
}
```

Add a no-Flutter import guard in `test/macos_swift_package_test.dart`:

```dart
test("DesktopUpdaterKit target does not import Flutter", () {
  final sources = Directory("macos/desktop_updater/Sources/DesktopUpdaterKit")
      .listSync(recursive: true)
      .whereType<File>()
      .map((file) => file.readAsStringSync())
      .join("\n");

  expect(sources, isNot(contains("FlutterMacOS")));
  expect(sources, isNot(contains("Flutter")));
});
```

- [ ] **Step 3.7: Run macOS-focused tests**

Run on macOS:

```sh
swift test
flutter test --no-pub test/macos_swift_package_test.dart test/desktop_updater_method_channel_test.dart
```

Expected: Swift tests pass; Flutter MethodChannel tests pass.

- [ ] **Step 3.8: Commit macOS SDK extraction**

Commit message:

```sh
git commit -m "feat: add standalone macos updater kit"
```

## Stage 4: Windows Native SDK And Flutter Adapter

**Purpose:** Move Windows helper logic into a Flutter-free C++ library while the Flutter Windows plugin remains the MethodChannel adapter.

**Files:**
- Create: `windows/native/CMakeLists.txt`
- Create: `windows/native/include/desktop_updater_native.h`
- Create: `windows/native/include/desktop_updater_native_c.h`
- Create: `windows/native/src/desktop_updater_native.cpp`
- Create: `windows/native/src/desktop_updater_native_c.cpp`
- Create: `windows/native/dotnet/DesktopUpdater.Native/DesktopUpdater.Native.csproj`
- Create: `windows/native/dotnet/DesktopUpdater.Native/DesktopUpdaterNative.cs`
- Create: `windows/native/dotnet/DesktopUpdater.Native.Tests/DesktopUpdater.Native.Tests.csproj`
- Create: `windows/native/dotnet/DesktopUpdater.Native.Tests/DesktopUpdaterNativeTests.cs`
- Create: `windows/native/test/desktop_updater_native_test.cpp`
- Modify: `windows/CMakeLists.txt`
- Modify: `windows/desktop_updater_plugin.cpp`
- Modify: `windows/desktop_updater_plugin.h`
- Modify: `windows/test/desktop_updater_plugin_test.cpp`
- Modify: `test/native_helper_script_test.dart`

- [ ] **Step 4.1: Add internal C++ helper API**

Create `desktop_updater_native.h`:

```cpp
#pragma once

#include <string>
#include <vector>

namespace desktop_updater_native {

struct InstallRequest {
  std::wstring staging_path;
  std::vector<std::wstring> removed_files;
  std::wstring diagnostics_log_path;
};

struct InstallResult {
  bool ok;
  std::string error;
};

InstallResult ScheduleInstallAndRelaunch(const InstallRequest& request);

}  // namespace desktop_updater_native
```

- [ ] **Step 4.2: Add stable public C ABI**

Create `desktop_updater_native_c.h`:

```c
#pragma once

#include <stddef.h>

#if defined(_WIN32)
#if defined(DESKTOP_UPDATER_NATIVE_BUILDING_DLL)
#define DESKTOP_UPDATER_EXPORT __declspec(dllexport)
#else
#define DESKTOP_UPDATER_EXPORT __declspec(dllimport)
#endif
#else
#define DESKTOP_UPDATER_EXPORT
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct desktop_updater_install_request {
  const wchar_t* staging_path;
  const wchar_t* diagnostics_log_path;
  const wchar_t* const* removed_files;
  size_t removed_file_count;
} desktop_updater_install_request;

typedef struct desktop_updater_result {
  int ok;
  const char* error_message;
} desktop_updater_result;

DESKTOP_UPDATER_EXPORT desktop_updater_result
desktop_updater_schedule_install_and_relaunch(
    const desktop_updater_install_request* request);

DESKTOP_UPDATER_EXPORT void desktop_updater_result_free(
    desktop_updater_result result);

#ifdef __cplusplus
}
#endif
```

ABI rules:

```text
Do not expose std::string, std::wstring, std::vector, C++ exceptions, C++
namespaces, templates, or STL-owned memory in desktop_updater_native_c.h.
Use UTF-16 wchar_t paths on Windows.
Return heap-owned error strings only through desktop_updater_result.
Always release result-owned memory through desktop_updater_result_free.
```

- [ ] **Step 4.3: Add first-class .NET P/Invoke wrapper**

Create `windows/native/dotnet/DesktopUpdater.Native/DesktopUpdater.Native.csproj`:

```xml
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFrameworks>net8.0;netstandard2.0</TargetFrameworks>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
    <PackageId>DesktopUpdater.Native</PackageId>
    <Description>Windows native updater bindings for desktop_updater.</Description>
  </PropertyGroup>
</Project>
```

Create `DesktopUpdaterNative.cs` with P/Invoke bindings to the C ABI:

```csharp
using System;
using System.Runtime.InteropServices;

namespace DesktopUpdater.Native;

public sealed class DesktopUpdaterException : Exception
{
    public DesktopUpdaterException(string message) : base(message) {}
}

public static class DesktopUpdaterNative
{
    public static void ScheduleInstallAndRelaunch(
        string? stagingPath,
        string? diagnosticsLogPath)
    {
        var request = new NativeInstallRequest
        {
            stagingPath = stagingPath,
            diagnosticsLogPath = diagnosticsLogPath,
            removedFiles = IntPtr.Zero,
            removedFileCount = UIntPtr.Zero,
        };
        var result = desktop_updater_schedule_install_and_relaunch(ref request);
        try
        {
            if (result.ok == 0)
            {
                var message = Marshal.PtrToStringUTF8(result.errorMessage)
                    ?? "desktop_updater native call failed.";
                throw new DesktopUpdaterException(message);
            }
        }
        finally
        {
            desktop_updater_result_free(result);
        }
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct NativeInstallRequest
    {
        public string? stagingPath;
        public string? diagnosticsLogPath;
        public IntPtr removedFiles;
        public UIntPtr removedFileCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeResult
    {
        public int ok;
        public IntPtr errorMessage;
    }

    [DllImport("desktop_updater_native", CharSet = CharSet.Unicode)]
    private static extern NativeResult desktop_updater_schedule_install_and_relaunch(
        ref NativeInstallRequest request);

    [DllImport("desktop_updater_native")]
    private static extern void desktop_updater_result_free(NativeResult result);
}
```

The .NET package is part of the first Windows native SDK release and must use
the C ABI, not the internal C++ API.

- [ ] **Step 4.4: Move helper-only functions into native library**

Move these Flutter-free functions from `windows/desktop_updater_plugin.cpp` into `desktop_updater_native.cpp`:

```text
Utf8ToWide
WideToUtf8
WindowsErrorMessage
CurrentExecutablePath
Utf8PowerShellScriptContents
PowerShellQuote
Base64Encode
Base64EncodeWide
Sha256Hex
PowerShellArray
IsProcessElevated
ProtectedInstallRootPaths
IsKnownProtectedInstallDirectory
CanWriteDirectory
StartElevatedPowerShell
StartPowerShell
ScheduleInstallAndRelaunch
```

Keep Flutter-specific MethodChannel parsing in `windows/desktop_updater_plugin.cpp`.

- [ ] **Step 4.5: Link Flutter plugin against native target**

Modify `windows/CMakeLists.txt`:

```cmake
add_subdirectory("native/desktop_updater")
target_link_libraries(${PLUGIN_NAME} PRIVATE desktop_updater_native)
```

The plugin target still includes `desktop_updater_plugin_c_api.cpp` and keeps `DesktopUpdaterPluginCApi`.

- [ ] **Step 4.6: Guard native tests behind an explicit CMake option**

In `windows/native/CMakeLists.txt`, add:

```cmake
option(DESKTOP_UPDATER_NATIVE_BUILD_TESTS "Build desktop_updater native tests" OFF)

add_library(desktop_updater_native STATIC
  src/desktop_updater_native.cpp
  src/desktop_updater_native_c.cpp
)

target_include_directories(desktop_updater_native PUBLIC
  "${CMAKE_CURRENT_SOURCE_DIR}/include"
)

if(DESKTOP_UPDATER_NATIVE_BUILD_TESTS)
  enable_testing()
  add_executable(desktop_updater_native_test
    test/desktop_updater_native_test.cpp
  )
  target_link_libraries(desktop_updater_native_test PRIVATE
    desktop_updater_native
    gtest_main
    gmock
  )
endif()
```

Flutter plugin builds must not build or fetch native SDK GoogleTest targets.

- [ ] **Step 4.7: Add Windows native tests**

Create GoogleTest cases:

```cpp
TEST(DesktopUpdaterNative, ProductVersionBuildNumberWithMetadata) {
  std::wstring build_number;
  EXPECT_EQ(ParseProductVersionBuildNumber(L"1.2.3+4", &build_number),
            ProductVersionBuildParseResult::kBuildNumber);
  EXPECT_EQ(build_number, L"4");
}

TEST(DesktopUpdaterNative, ProgramFilesInstallDirectoryIsProtected) {
  EXPECT_TRUE(IsKnownProtectedInstallDirectoryForTesting(
      L"C:\\Program Files\\Example",
      {L"C:\\Program Files", L"C:\\Program Files (x86)"}));
}
```

- [ ] **Step 4.8: Add ABI tests**

Add tests that call the C ABI directly:

```cpp
TEST(DesktopUpdaterNativeCAbi, NullRequestFailsWithoutThrowing) {
  desktop_updater_result result =
      desktop_updater_schedule_install_and_relaunch(nullptr);

  EXPECT_EQ(result.ok, 0);
  ASSERT_NE(result.error_message, nullptr);
  desktop_updater_result_free(result);
}
```

- [ ] **Step 4.9: Add .NET wrapper tests**

Create `windows/native/dotnet/DesktopUpdater.Native.Tests/DesktopUpdaterNativeTests.cs`:

```csharp
using DesktopUpdater.Native;
using Xunit;

public sealed class DesktopUpdaterNativeTests
{
    [Fact]
    public void ExceptionTypeIsPublic()
    {
        var error = new DesktopUpdaterException("example");
        Assert.Equal("example", error.Message);
    }
}
```

This first test does not load the native DLL. Add host-specific P/Invoke tests
after the C ABI build artifact is copied into the test output directory.

- [ ] **Step 4.10: Keep Flutter plugin tests**

Update `windows/test/desktop_updater_plugin_test.cpp` so it still verifies:

```cpp
TEST(DesktopUpdaterPlugin, GetPlatformVersion) {
  DesktopUpdaterPlugin plugin;
  // Existing MethodChannel behavior remains.
}
```

- [ ] **Step 4.11: Run Windows lane**

Run on Windows:

```sh
flutter build windows --debug
cmake --build example/build/windows/x64 --config Debug --target desktop_updater_test
ctest --test-dir example/build/windows/x64 -C Debug --output-on-failure
dotnet test windows/native/dotnet/DesktopUpdater.Native.Tests/DesktopUpdater.Native.Tests.csproj
flutter test integration_test -d windows
```

Expected: Flutter plugin and native helper behavior unchanged.

- [ ] **Step 4.12: Commit Windows SDK extraction**

Commit message:

```sh
git commit -m "feat: add standalone windows updater native library"
```

## Stage 5: Linux Native SDK And Flutter Adapter

**Purpose:** Move Linux helper logic into a Flutter-free C++ library while the Flutter Linux plugin remains the MethodChannel adapter.

**Files:**
- Create: `linux/native/CMakeLists.txt`
- Create: `linux/native/include/desktop_updater_native.h`
- Create: `linux/native/src/desktop_updater_native.cc`
- Create: `linux/native/test/desktop_updater_native_test.cc`
- Modify: `linux/CMakeLists.txt`
- Modify: `linux/desktop_updater_plugin.cc`
- Modify: `linux/desktop_updater_plugin_private.h`
- Modify: `linux/test/desktop_updater_plugin_test.cc`
- Modify: `test/native_helper_script_test.dart`

- [ ] **Step 5.1: Add Linux native helper API**

Create `desktop_updater_native.h`:

```cpp
#pragma once

#include <string>
#include <vector>

namespace desktop_updater_native {

struct InstallRequest {
  std::string staging_path;
  std::vector<std::string> removed_files;
  std::string diagnostics_log_path;
};

struct InstallResult {
  bool ok;
  std::string error;
};

InstallResult ScheduleInstallAndRelaunch(const InstallRequest& request);

}  // namespace desktop_updater_native
```

- [ ] **Step 5.2: Move helper-only functions into native library**

Move these Flutter-free functions from `linux/desktop_updater_plugin.cc`:

```text
shell_quote
current_executable_path
parent_directory
base_name
shell_array
write_file
start_detached_script
schedule_install_update
```

Keep `FlMethodCall`, `FlMethodResponse`, GTK, and Flutter Linux code in `linux/desktop_updater_plugin.cc`.

- [ ] **Step 5.3: Link Flutter plugin against native target**

Modify `linux/CMakeLists.txt`:

```cmake
add_subdirectory("native/desktop_updater")
target_link_libraries(${PLUGIN_NAME} PRIVATE desktop_updater_native)
```

Keep existing `flutter` and `PkgConfig::GTK` links for the Flutter plugin target only.

- [ ] **Step 5.4: Add native tests**

Create tests:

```cpp
TEST(DesktopUpdaterNative, ShellQuoteEscapesSingleQuotes) {
  EXPECT_EQ(ShellQuoteForTesting("a'b"), "'a'\\''b'");
}

TEST(DesktopUpdaterNative, MissingStagingDirectoryFails) {
  auto result = ScheduleInstallAndRelaunch({
      "/tmp/desktop_updater_missing_staging",
      {},
      "",
  });
  EXPECT_FALSE(result.ok);
  EXPECT_THAT(result.error, testing::HasSubstr("Staged update directory"));
}
```

- [ ] **Step 5.5: Run Linux lane**

Run on Linux:

```sh
flutter build linux --debug
cmake --build example/build/linux/x64/debug --target desktop_updater_test
ctest --test-dir example/build/linux/x64/debug --output-on-failure
xvfb-run -a flutter test integration_test -d linux
```

Expected: Flutter plugin and native helper behavior unchanged.

- [ ] **Step 5.6: Commit Linux SDK extraction**

Commit message:

```sh
git commit -m "feat: add standalone linux updater native library"
```

## Stage 6: Full Native Runtime Preview Child Plan

**Files:**
- Create: `docs/exec-plans/active/2026-07-05-full-native-runtime-preview-plan.md`
- Modify: `docs/exec-plans/index.md`
- Test: `test/harness_engineering_docs_test.dart`

- [ ] **Step 6.1: Split full native runtime into a child plan**

Create `docs/exec-plans/active/2026-07-05-full-native-runtime-preview-plan.md`
with this scope:

```text
Build preview native runtime APIs for non-Flutter apps:
- check app-archive.json
- parse release.json
- select version/platform/channel
- download artifact
- verify length/SHA-256
- safe extract/stage
- hand off to the native helper SDKs from Stages 3-5
```

Out of scope for the child plan:

```text
Replacing the Flutter Dart UpdateClient.
Changing the existing Flutter public API.
Changing release.json or app-archive.json schema.
Publishing native runtime as production-ready before platform tests exist.
```

- [ ] **Step 6.2: Add child plan to exec-plan index**

Add:

```markdown
- [2026-07-05 - Full native runtime preview](active/2026-07-05-full-native-runtime-preview-plan.md)
```

- [ ] **Step 6.3: Keep Flutter runtime explicitly on Dart**

Add this invariant to the child plan and docs:

```text
Flutter apps continue to use the Dart UpdateClient, Dart lifecycle diagnostics,
and existing MethodChannel handoff. Native runtime preview APIs are additive
for non-Flutter apps only.
```

- [ ] **Step 6.4: Run plan index test**

Run:

```sh
flutter test --no-pub test/harness_engineering_docs_test.dart
```

- [ ] **Step 6.5: Commit child plan split**

```sh
git commit -m "docs: split native runtime preview plan"
```


## Stage 7: Native Build Adapters For CLI Publish

**Purpose:** Let the same CLI publish Flutter, Xcode, CMake, and manual app-path projects without duplicating release packaging logic.

**Files:**
- Create: `lib/src/release_cli/xcode_project_adapter.dart`
- Create: `lib/src/release_cli/cmake_project_adapter.dart`
- Modify: `lib/src/release_cli/project_adapter.dart`
- Modify: `lib/src/release_cli/publish_command.dart`
- Modify: `lib/src/release_cli/release_publish_config.dart`
- Modify: `docs/publishing.md`
- Test: `test/release_cli/release_publisher_build_test.dart`
- Test: `test/release_cli/release_publish_config_test.dart`

- [ ] **Step 7.1: Add `--project-type` option**

Supported values:

```text
flutter
xcode
cmake
manual
```

Validation:

```text
--project-type manual requires --app-path, --package-id, --version
--project-type xcode requires --scheme or config project.xcode.scheme
--project-type cmake requires appPath or target output mapping
```

- [ ] **Step 7.2: Add Xcode adapter**

Public behavior:

```sh
desktop-updater release publish --platform macos --project-type xcode --scheme MyApp
```

Adapter behavior:

```text
run xcodebuild -scheme MyApp -configuration Release
resolve .app path from build settings or config
read CFBundleIdentifier
read CFBundleShortVersionString
read CFBundleVersion
return ProjectBuildResult
```

- [ ] **Step 7.3: Add CMake adapter**

Public behavior:

```sh
desktop-updater release publish --platform linux --project-type cmake --app-path build/my_app
desktop-updater release publish --platform windows --project-type cmake --app-path build/Release/MyApp.exe
```

Adapter behavior:

```text
run cmake build only when build command is configured
use appPath for packaging
read packageId/version/buildNumber from config or CLI flags
return ProjectBuildResult
```

- [ ] **Step 7.4: Keep Flutter default**

Add tests:

```dart
test("unqualified release publish in Flutter project uses Flutter adapter", () {
  final adapter = selectProjectAdapter(flutterFixture.root, projectType: null, appPath: null);
  expect(adapter.type, "flutter");
});

test("ambiguous project requires explicit project type", () {
  expect(
    () => selectProjectAdapter(ambiguousRoot, projectType: null, appPath: null),
    throwsA(isA<UsageException>()),
  );
});
```

- [ ] **Step 7.5: Run CLI tests**

Run:

```sh
flutter test --no-pub \
  test/release_cli/release_publisher_build_test.dart \
  test/release_cli/release_publish_config_test.dart \
  test/release_cli/release_command_test.dart \
  test/release_cli/publish_layout_test.dart \
  test/release_cli/publish_manifest_test.dart
```

Expected: old Flutter publish tests pass; new native adapter tests pass.

- [ ] **Step 7.6: Commit native CLI adapters**

Commit message:

```sh
git commit -m "feat: add native project adapters to release cli"
```

## Stage 8: Standalone CLI Distribution Without Breaking `dart run`

**Purpose:** Native users can run `desktop-updater` without a Flutter project, while Flutter users keep `dart run desktop_updater:release`.

**Files:**
- Create: `bin/desktop_updater.dart`
- Modify: `pubspec.yaml`
- Modify: `.github/workflows/desktop-updater-ci.yml`
- Modify: `docs/github-actions-ci-cd.md`

- [ ] **Step 8.1: Add standalone Dart CLI entrypoint**

Create `bin/desktop_updater.dart`:

```dart
import "package:desktop_updater/src/release_cli/release_command.dart";

Future<void> main(List<String> args) {
  return runDesktopUpdaterCli(args);
}
```

Keep existing `bin/package.dart`, `bin/verify.dart`, `bin/app_archive.dart`, and `bin/release.dart`.

- [ ] **Step 8.2: Add compiled binary CI check**

Add CI step:

```yaml
- name: Compile standalone CLI
  run: dart compile exe bin/desktop_updater.dart -o build/desktop-updater
- name: Check standalone CLI help
  run: build/desktop-updater release publish --help
- name: Check standalone CLI version
  run: build/desktop-updater --version
```

- [ ] **Step 8.3: Define standalone CLI release assets**

Document and test these asset names:

```text
desktop-updater-macos-arm64
desktop-updater-macos-x64
desktop-updater-windows-x64.exe
desktop-updater-linux-x64
desktop-updater-checksums.txt
```

Each binary must print the same full version as root `pubspec.yaml`:

```sh
desktop-updater --version
```

The checksums file must include SHA-256 values for every uploaded standalone CLI
binary.

- [ ] **Step 8.4: Keep old CLI checks**

Keep existing CI:

```yaml
dart run desktop_updater:package --help
dart run desktop_updater:verify --help
dart run desktop_updater:release publish --help
```

- [ ] **Step 8.5: Commit standalone CLI entrypoint**

Commit message:

```sh
git commit -m "feat: add standalone desktop updater cli entrypoint"
```

## Stage 9: Native Package Publication Surfaces

**Purpose:** Make native SDKs consumable through their ecosystem package managers without changing pub.dev package identity. Flutter still consumes local native sources from the pub package; external native package feeds are for non-Flutter consumers.

**Files:**
- Modify: `README.md`
- Modify: `docs/publishing.md`
- Create: `docs/native-sdk.md`
- Create: `windows/native/desktop_updater_nativeConfig.cmake.in`
- Create: `linux/native/desktop_updater_native.pc.in`
- Create: `windows/native/desktop_updater_native.nuspec`

- [ ] **Step 9.1: Document package channels**

Document:

```text
Flutter: pub.dev package desktop_updater
macOS: SwiftPM product DesktopUpdaterKit from repository tags; no native SDK CocoaPods publication
Windows: CMake package, GitHub Release asset, NuGet package with .NET wrapper
Linux: CMake package, pkg-config file, GitHub Release source/binary asset
CLI: dart run desktop_updater:* for Flutter users, desktop-updater binary for native users
```

macOS CocoaPods rule:

```text
Keep macos/desktop_updater.podspec only for existing Flutter CocoaPods fallback
compatibility. Do not document or publish DesktopUpdaterKit as a pod.
```

- [ ] **Step 9.2: Document that Flutter uses local native sources**

Add this rule to `docs/native-sdk.md` and release docs:

```text
Flutter apps do not install DesktopUpdaterKit, NuGet, or system CMake packages
separately. The `desktop_updater` pub package includes the native adapter
sources and links them locally through Flutter's normal macOS, Windows, and
Linux plugin build.
```

Implementation expectation:

```text
macOS Flutter plugin -> local SwiftPM target DesktopUpdaterKit
Windows Flutter plugin -> add_subdirectory(windows/native)
Linux Flutter plugin -> add_subdirectory(linux/native)
```

- [ ] **Step 9.3: Add macOS Swift usage docs**

Example:

```swift
import DesktopUpdaterKit

let updater = DesktopUpdater(
    archiveURL: URL(string: "https://updates.example.com/app-archive.json")!,
    currentVersion: .fromMainBundle()
)

if let update = try await updater.checkForUpdate() {
    let staged = try await updater.downloadVerifyAndStage(update.descriptor)
    try await updater.installAndRelaunch(staged, diagnosticsLogURL: helperLogURL)
}
```

- [ ] **Step 9.4: Add Windows/Linux usage docs**

Example:

```cpp
desktop_updater_native::UpdateClient client({
    .app_archive_url = "https://updates.example.com/app-archive.json",
    .current_version = {"1.0.0", "100"},
    .platform = "linux",
});

auto update = client.CheckForUpdate();
if (update.has_value()) {
  auto staged = client.DownloadVerifyAndStage(update->descriptor);
  desktop_updater_native::ScheduleInstallAndRelaunch({
      staged.staging_path,
      {},
      "/var/tmp/my_app_update_helper.jsonl",
  });
}
```

- [ ] **Step 9.5: Add docs drift tests**

Add tests that verify README and docs mention:

```text
pub.dev package remains desktop_updater
SwiftPM product DesktopUpdaterKit
CMake target desktop_updater_native
existing Dart CLI commands
standalone desktop-updater CLI
Flutter uses local native sources instead of external native package feeds
```

- [ ] **Step 9.6: Commit native package docs**

Commit message:

```sh
git commit -m "docs: describe native updater sdk packages"
```

## Stage 10: Single Version Source

**Purpose:** Release all package surfaces from one canonical version without manually editing five package metadata files.

**Files:**
- Create: `tool/version_check.dart`
- Create: `tool/sync_versions.dart`
- Modify: `tool/harness_check.dart`
- Modify: `lib/src/package_version.dart`
- Create: `macos/desktop_updater/Sources/DesktopUpdaterKit/DesktopUpdaterKitVersion.swift`
- Create: `windows/native/include/desktop_updater_version.h`
- Create: `linux/native/include/desktop_updater_version.h`
- Modify: `windows/native/CMakeLists.txt`
- Modify: `linux/native/CMakeLists.txt`
- Modify: `windows/native/desktop_updater_nativeConfig.cmake.in`
- Modify: `linux/native/desktop_updater_native.pc.in`
- Modify: `windows/native/desktop_updater_native.nuspec`
- Test: `test/native_helper_diagnostics_docs_test.dart`
- Test: `test/harness_engineering_docs_test.dart`

- [ ] **Step 10.1: Declare root `pubspec.yaml` as canonical**

Add this release rule to `docs/native-sdk.md`:

```text
The root `pubspec.yaml` version is the single source of truth for all release
surfaces: pub.dev, SwiftPM tags, CMake packages, NuGet packages,
pkg-config metadata, and the standalone CLI. Do not store release versions in
`.env` files.
```

- [ ] **Step 10.2: Add generated/checked version surfaces**

Use generated or checked constants:

```dart
// lib/src/package_version.dart
const desktopUpdaterPackageVersion = "2.5.0";
```

```swift
// macos/desktop_updater/Sources/DesktopUpdaterKit/DesktopUpdaterKitVersion.swift
public enum DesktopUpdaterKitVersion {
    public static let current = "2.5.0"
}
```

```cpp
// windows/native/include/desktop_updater_version.h
#pragma once
#define DESKTOP_UPDATER_NATIVE_VERSION "2.5.0"
```

```cpp
// linux/native/include/desktop_updater_version.h
#pragma once
#define DESKTOP_UPDATER_NATIVE_VERSION "2.5.0"
```

The concrete version shown above is illustrative; implementation must read the
actual value from root `pubspec.yaml`.

Version normalization rules:

```text
fullVersion: exact pubspec value, for example 2.5.0-dev.1
semverCore: numeric MAJOR.MINOR.PATCH, for example 2.5.0
cmakeNumericVersion: same as semverCore because CMake project(VERSION) does not
  accept prerelease suffixes
nugetVersion: fullVersion converted to NuGet-compatible SemVer when needed
swiftVersionString: fullVersion
cliVersionString: fullVersion
```

Do not feed `2.5.0-dev.1` directly to CMake `project(VERSION ...)`.

- [ ] **Step 10.3: Add version check tool**

Create `tool/version_check.dart` that:

```text
reads root pubspec.yaml version
derives fullVersion, semverCore, cmakeNumericVersion, nugetVersion, swiftVersionString, cliVersionString
checks lib/src/package_version.dart
checks DesktopUpdaterKitVersion.swift
checks Windows desktop_updater_version.h
checks Linux desktop_updater_version.h
checks CMake project VERSION values against cmakeNumericVersion
checks pkg-config Version value
checks NuGet version value against nugetVersion
exits non-zero with all mismatches listed
```

- [ ] **Step 10.4: Add version sync tool**

Create `tool/sync_versions.dart` that:

```text
reads root pubspec.yaml version
rewrites only generated version literals/templates
does not bump pubspec.yaml
does not edit CHANGELOG.md
does not create git tags
```

This keeps release/version work explicit: humans change `pubspec.yaml`, then run
the sync tool.

- [ ] **Step 10.5: Add version check to local harness**

Modify `tool/harness_check.dart` to run:

```sh
dart run tool/version_check.dart
```

Place it after formatting and before analyze so drift is caught early.

- [ ] **Step 10.6: Add release publication order**

Document the release order:

```text
1. Update root pubspec.yaml version only.
2. Run dart run tool/sync_versions.dart.
3. Run dart run tool/version_check.dart.
4. Run dart run tool/harness_check.dart.
5. Create one repository tag, for example v2.5.0.
6. Publish pub.dev package desktop_updater.
7. Publish native artifacts from the same tag:
   - SwiftPM is available through the Git tag.
   - GitHub Release uploads standalone CLI and CMake/pkg-config assets.
   - NuGet package uses the same version.
```

- [ ] **Step 10.7: Add docs drift tests**

Add tests that assert docs mention:

```text
pubspec.yaml is the single version source
no .env file is used for package versions
Flutter uses local native sources
native package feeds are for non-Flutter consumers
```

- [ ] **Step 10.8: Run focused version tests**

Run:

```sh
dart run tool/version_check.dart
flutter test --no-pub test/harness_engineering_docs_test.dart test/native_helper_diagnostics_docs_test.dart
```

Expected: version check passes and docs tests pass.

- [ ] **Step 10.9: Commit single version source**

Commit message:

```sh
git commit -m "chore: add single version source checks"
```

## Stage 11: Full Verification Matrix

**Purpose:** Prove Flutter did not regress and native SDKs work independently.

**Files:**
- Modify: `.github/workflows/desktop-updater-ci.yml`
- Modify: `docs/harness-engineering.md`
- Modify: `tool/harness_check.dart` only if a local native check can run secretlessly on the host

- [ ] **Step 11.1: Keep local Flutter ladder**

Run:

```sh
flutter test --no-pub test/<focused_test>.dart
dart format --set-exit-if-changed .
flutter analyze --no-fatal-infos
flutter test --no-pub
dart pub publish --dry-run
```

- [ ] **Step 11.2: Add macOS native CI lane**

Add macOS job:

```yaml
- name: Test SwiftPM native SDK
  run: swift test
- name: Compile standalone CLI
  run: dart compile exe bin/desktop_updater.dart -o build/desktop-updater
```

- [ ] **Step 11.3: Extend Windows CI lane**

Keep existing Windows steps and add:

```yaml
- name: Build Windows native SDK tests
  working-directory: windows/native
  run: cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
- name: Run Windows native SDK tests
  working-directory: windows/native
  run: cmake --build build --config Release && ctest --test-dir build -C Release --output-on-failure
```

- [ ] **Step 11.4: Extend Linux CI lane**

Keep existing Linux steps and add:

```yaml
- name: Build Linux native SDK tests
  working-directory: linux/native
  run: cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
- name: Run Linux native SDK tests
  working-directory: linux/native
  run: cmake --build build && ctest --test-dir build --output-on-failure
```

- [ ] **Step 11.5: Run release smoke tests unchanged**

Ensure existing smoke commands are still present:

```sh
dart run tool/release_publish_smoke.dart --platform windows
dart run tool/updater_smoke.dart --config Release --diagnostics-log ../reports/windows-update-smoke-release-diagnostics.jsonl
dart run tool/release_publish_smoke.dart --platform linux
xvfb-run -a dart run tool/updater_smoke.dart --config Release --diagnostics-log ../reports/linux-update-smoke-release-diagnostics.jsonl
```

- [ ] **Step 11.6: Commit CI verification**

Commit message:

```sh
git commit -m "ci: verify native updater sdk packages"
```

## Stage 12: Migration And Release Notes

**Purpose:** Explain that this is additive and not a Flutter breaking change.

**Files:**
- Modify: `README.md`
- Modify: `docs/migration/1.x-to-2.0.md` only if needed for 2.x native SDK notes
- Modify: `docs/publishing.md`
- Modify: `docs/native-sdk.md`

- [ ] **Step 12.1: Add additive-change language**

Use this exact reader-facing claim:

```text
The Flutter package remains the primary pub.dev package and keeps the existing Dart API, MethodChannel behavior, and release CLI commands. Native SDKs are additive package surfaces for apps that do not use Flutter.
```

- [ ] **Step 12.2: Add command matrix**

Document:

```text
Flutter release publish:
dart run desktop_updater:release publish --platform linux

Standalone CLI Flutter project:
desktop-updater release publish --platform linux --project-type flutter

Native Xcode project:
desktop-updater release publish --platform macos --project-type xcode --scheme MyApp

Native CMake/manual output:
desktop-updater package --platform linux --app-path build/my_app --package-id com.example.myapp --version 1.2.0 --build-number 42
```

- [ ] **Step 12.3: Run docs tests**

Run:

```sh
flutter test --no-pub \
  test/harness_engineering_docs_test.dart \
  test/native_helper_diagnostics_docs_test.dart \
  test/release_cli/release_command_test.dart
```

- [ ] **Step 12.4: Commit docs**

Commit message:

```sh
git commit -m "docs: document additive native sdk migration"
```

## Final Release Gate

Before merging the full migration:

```sh
dart run tool/harness_check.dart
```

Target platform evidence:

```sh
swift test
flutter build macos --debug
flutter test integration_test -d macos
flutter build windows --debug
cmake --build example/build/windows/x64 --config Debug --target desktop_updater_test
ctest --test-dir example/build/windows/x64 -C Debug --output-on-failure
flutter build linux --debug
cmake --build example/build/linux/x64/debug --target desktop_updater_test
ctest --test-dir example/build/linux/x64/debug --output-on-failure
```

CI evidence must include:

```text
Dart Package passed
Windows passed
Linux passed
macOS SwiftPM native SDK passed
```

## Self-Review

- Spec coverage: The plan preserves the existing Flutter API, plugin registration, Dart diagnostics, old CLI commands, and old Flutter-first publish behavior while adding native package surfaces and native CLI adapters.
- Duplication control: CLI release contract code stays in Dart and is shared. Repeated native runtime code is limited to language-specific SDK ergonomics and tested against shared fixtures.
- Type consistency: `ProjectAdapter`, `ProjectBuildRequest`, `ProjectBuildResult`, `DesktopUpdaterKit`, and `desktop_updater_native` names are used consistently across stages.
- Risk boundaries: Helper extraction is separate from full native runtime implementation, so Flutter plugin behavior can be verified before native apps get full check/download/stage APIs.
