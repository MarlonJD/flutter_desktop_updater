# Full Native Runtime Preview Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add preview native runtime APIs for non-Flutter macOS, Windows, and Linux apps to check, download, verify, stage, and install updates using the existing zip-first release contract.

**Architecture:** Flutter apps continue to use the existing Dart `UpdateClient`, Dart lifecycle diagnostics, and MethodChannel handoff. Native runtime preview APIs live inside the platform native SDKs and consume the same `app-archive.json`, `release.json`, diagnostics fixtures, and helper SDKs. Shared behavior is protected by cross-language fixtures, not by forcing all runtimes to share one implementation language.

**Tech Stack:** SwiftPM/Swift/XCTest, C++/CMake/GoogleTest, Windows C ABI, .NET P/Invoke wrapper, Dart fixture tests, existing schema version 3 release contract.

---

## Preview Boundaries

- This is additive and preview-only until each platform has native SDK tests and at least one native sample app.
- Do not replace Flutter's Dart `UpdateClient`.
- Do not change `app-archive.json` or `release.json` schema.
- Do not publish native runtime APIs as production-ready until update smoke evidence exists outside Flutter.
- Windows public interop must use the C ABI from the master plan; C++ runtime classes remain internal or ergonomic-only.
- .NET wrapper APIs bind through the C ABI.

## Target Files

```text
fixtures/compat/release-contract/
  app-archive.json
  release-linux.json
  release-macos.json
  release-windows.json
  artifact.zip

macos/desktop_updater/Sources/DesktopUpdaterKit/
  ReleaseIndex.swift
  ReleaseDescriptor.swift
  UpdateClient.swift
  ArtifactVerifier.swift
  SafeZipExtractor.swift

windows/native/include/
  desktop_updater_runtime_c.h
windows/native/src/
  release_descriptor.cpp
  update_client.cpp
  artifact_verifier.cpp
  safe_zip_extractor.cpp
  desktop_updater_runtime_c.cpp
windows/native/dotnet/DesktopUpdater.Native/
  DesktopUpdaterClient.cs

linux/native/include/
  desktop_updater_runtime.h
linux/native/src/
  release_descriptor.cc
  update_client.cc
  artifact_verifier.cc
  safe_zip_extractor.cc
```

## Task 1: Shared Runtime Contract Fixtures

**Files:**
- Create: `fixtures/compat/release-contract/app-archive.json`
- Create: `fixtures/compat/release-contract/release-linux.json`
- Create: `fixtures/compat/release-contract/release-macos.json`
- Create: `fixtures/compat/release-contract/release-windows.json`
- Create: `fixtures/compat/release-contract/README.md`
- Test: `test/e2e/zip_first_update_flow_test.dart`

- [ ] **Step 1.1: Add schema version 3 fixture metadata**

Create `app-archive.json`:

```json
{
  "schemaVersion": 3,
  "appName": "Example",
  "items": [
    {
      "version": "2.0.0",
      "buildNumber": "200",
      "platform": "linux",
      "channel": "stable",
      "release": "release-linux.json"
    },
    {
      "version": "2.0.0",
      "buildNumber": "200",
      "platform": "macos",
      "channel": "stable",
      "release": "release-macos.json"
    },
    {
      "version": "2.0.0",
      "buildNumber": "200",
      "platform": "windows",
      "channel": "stable",
      "release": "release-windows.json"
    }
  ]
}
```

- [ ] **Step 1.2: Add descriptor fixtures**

Each `release-<platform>.json` must include:

```json
{
  "schemaVersion": 3,
  "appName": "Example",
  "packageId": "com.example.app",
  "version": "2.0.0",
  "buildNumber": "200",
  "platform": "linux",
  "channel": "stable",
  "artifact": {
    "url": "artifact.zip",
    "length": 0,
    "sha256": "replace-with-fixture-sha"
  }
}
```

Use the correct `platform` value in each descriptor. Generate the fixture
artifact and replace `length` and `sha256` with real values before tests rely on
the fixture.

- [ ] **Step 1.3: Add Dart fixture sanity test**

Add a Dart test that loads all fixture JSON files through existing Dart models
so fixture drift is caught before native implementations consume them.

- [ ] **Step 1.4: Run fixture sanity test**

Run:

```sh
flutter test --no-pub test/e2e/zip_first_update_flow_test.dart
```

Expected: existing Dart runtime still passes.

## Task 2: Swift Runtime Preview

**Files:**
- Create: `macos/desktop_updater/Sources/DesktopUpdaterKit/ReleaseIndex.swift`
- Create: `macos/desktop_updater/Sources/DesktopUpdaterKit/ReleaseDescriptor.swift`
- Create: `macos/desktop_updater/Sources/DesktopUpdaterKit/UpdateClient.swift`
- Create: `macos/desktop_updater/Sources/DesktopUpdaterKit/ArtifactVerifier.swift`
- Create: `macos/desktop_updater/Sources/DesktopUpdaterKit/SafeZipExtractor.swift`
- Test: `macos/desktop_updater/Tests/DesktopUpdaterKitTests/RuntimePreviewTests.swift`

- [ ] **Step 2.1: Implement Codable release models**

Add Swift `Codable` models for app archive items and release descriptors.

- [ ] **Step 2.2: Implement update selection**

Select only releases matching:

```text
platform == "macos"
channel == requested channel
version newer than current version
```

- [ ] **Step 2.3: Implement artifact verification**

Verify:

```text
file length equals descriptor artifact.length
SHA-256 equals descriptor artifact.sha256
```

- [ ] **Step 2.4: Implement safe staging**

For preview:

```text
download artifact to temp dir
verify artifact
extract to staging dir
write .desktop_updater_release_manifest.json sidecar for macOS
return staged app path
```

- [ ] **Step 2.5: Run Swift tests**

Run:

```sh
swift test
```

Expected: `DesktopUpdaterKitTests` pass.

## Task 3: Windows Runtime Preview With C ABI And .NET Wrapper

**Files:**
- Create: `windows/native/include/desktop_updater_runtime_c.h`
- Create: `windows/native/src/release_descriptor.cpp`
- Create: `windows/native/src/update_client.cpp`
- Create: `windows/native/src/artifact_verifier.cpp`
- Create: `windows/native/src/safe_zip_extractor.cpp`
- Create: `windows/native/src/desktop_updater_runtime_c.cpp`
- Create: `windows/native/dotnet/DesktopUpdater.Native/DesktopUpdaterClient.cs`
- Test: `windows/native/test/desktop_updater_runtime_test.cpp`
- Test: `windows/native/dotnet/DesktopUpdater.Native.Tests/DesktopUpdaterClientTests.cs`

- [ ] **Step 3.1: Add preview C ABI**

Expose only C-compatible request/result structs and free functions. Do not
expose C++ STL types.

- [ ] **Step 3.2: Add C++ runtime implementation**

Implement JSON parsing, selection, artifact verification, and staging behind
the C ABI.

- [ ] **Step 3.3: Add .NET wrapper**

Add `DesktopUpdaterClient` that P/Invokes the C ABI. Keep native DLL loading
and RID asset packaging explicit in the NuGet package plan.

- [ ] **Step 3.4: Run Windows native tests**

Run on Windows:

```sh
cmake -S windows/native -B windows/native/build -DDESKTOP_UPDATER_NATIVE_BUILD_TESTS=ON
cmake --build windows/native/build --config Debug
ctest --test-dir windows/native/build -C Debug --output-on-failure
dotnet test windows/native/dotnet/DesktopUpdater.Native.Tests/DesktopUpdater.Native.Tests.csproj
```

Expected: C++ tests and .NET wrapper tests pass.

## Task 4: Linux Runtime Preview

**Files:**
- Create: `linux/native/include/desktop_updater_runtime.h`
- Create: `linux/native/src/release_descriptor.cc`
- Create: `linux/native/src/update_client.cc`
- Create: `linux/native/src/artifact_verifier.cc`
- Create: `linux/native/src/safe_zip_extractor.cc`
- Test: `linux/native/test/desktop_updater_runtime_test.cc`

- [ ] **Step 4.1: Add C++ runtime API**

Expose an ergonomic C++ API for Linux native apps. Add C ABI only if a consumer
need appears; Linux package consumers can start with CMake C++ integration.

- [ ] **Step 4.2: Implement runtime preview**

Implement JSON parsing, selection, artifact verification, safe extraction, and
staging side effects matching the Dart runtime.

- [ ] **Step 4.3: Run Linux native tests**

Run on Linux:

```sh
cmake -S linux/native -B linux/native/build -DDESKTOP_UPDATER_NATIVE_BUILD_TESTS=ON
cmake --build linux/native/build
ctest --test-dir linux/native/build --output-on-failure
```

Expected: Linux native runtime tests pass.

## Task 5: Preview Documentation And Gating

**Files:**
- Modify: `docs/native-sdk.md`
- Modify: `docs/harness-engineering.md`
- Test: docs drift tests added by the master plan

- [ ] **Step 5.1: Document preview status**

Add:

```text
Native runtime APIs are preview surfaces until each platform has native sample
apps and update smoke evidence. Flutter apps continue to use the production
Dart runtime.
```

- [ ] **Step 5.2: Run docs tests**

Run:

```sh
flutter test --no-pub test/harness_engineering_docs_test.dart
```

Expected: plan links resolve.

## Final Gate

Run all available local checks:

```sh
flutter test --no-pub test/e2e/zip_first_update_flow_test.dart
swift test
```

Run Windows and Linux native runtime tests on target hosts or CI.
