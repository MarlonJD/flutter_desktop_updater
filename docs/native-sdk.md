# Native Helper SDKs And Standalone CLI

`desktop_updater` ships the stable Flutter/Dart update runtime, small native
helper SDK packages, and an opt-in Native Runtime Preview for non-Flutter host
applications. Helper-only consumers continue to own discovery, download,
descriptor validation, artifact verification, and staging; the helper surface
only schedules installation and relaunch of an application-owned staged
artifact. The preview adds those earlier lifecycle stages without changing the
Flutter runtime or the independently consumable helper boundary.

## Distribution Surfaces

| Surface | Integration | Contract |
| --- | --- | --- |
| Flutter | `desktop_updater` from pub.dev | Full Dart runtime with local platform helper sources |
| macOS helper | SwiftPM product `DesktopUpdaterKit` | Flutter-free Swift install and relaunch helper |
| macOS runtime preview | SwiftPM product `DesktopUpdaterKit` | Stateful Swift update client plus helper handoff |
| Windows helper | Installed CMake target `desktop_updater::native` | Static/shared C++ helper and versioned C ABI |
| Windows runtime preview | `DesktopUpdater.Native` NuGet package | Managed client, versioned runtime C ABI, and both `win-x64` native DLLs |
| Linux helper | Installed CMake target `desktop_updater::native` and pkg-config metadata | Source-first static C++ install helper |
| Linux runtime preview | Installed CMake target `desktop_updater::runtime` | Source-first C++ update client; no prebuilt ABI promise |
| CLI | Dart entrypoints or native-host standalone executable | Release, package, verify, and app-archive commands |

The canonical version is the root `pubspec.yaml` version. Maintainers run:

```sh
dart run tool/sync_versions.dart
dart run tool/version_check.dart
```

The sync command updates checked Dart, Swift, C/C++, CMake, pkg-config, and
NuGet version surfaces. It never changes `pubspec.yaml`, the changelog, or Git
tags.

## macOS: DesktopUpdaterKit

Add this repository as a Swift package at an approved tag and link the
`DesktopUpdaterKit` product. For a repository checkout, a local package
dependency can point at the repository root; the package itself has no Flutter
dependency.

```swift
import Darwin
import DesktopUpdaterKit

let request = MacInstallRequest(
    stagingPath: stagedApp.path,
    allowUnsignedUpdates: false,
    diagnosticsLogPath: diagnosticsPath,
    currentProcessIdentifier: getpid(),
    bundlePath: Bundle.main.bundlePath
)
try MacInstallHelper().scheduleInstallAndRelaunch(request)
```

Pass a complete verified `.app` staging path. Production signing gates remain
enabled unless `allowUnsignedUpdates` is explicitly enabled for a controlled
debug/test flow. The helper rechecks the staged bundle identity and publisher
trust before replacement. `DesktopUpdaterVersion.string` exposes the helper
package version.

The Flutter plugin uses the same helper sources through SwiftPM. Its
`macos/desktop_updater.podspec` keeps CocoaPods as a separately tested fallback
for Flutter hosts that disable SwiftPM.

The same SwiftPM product now includes the preview `UpdateClient`. Its
`checkForUpdate`, `downloadVerifyAndStage`, and `installAndRelaunch` operations
are exercised by the external `example/native/macos-runtime` consumer. Linking
the helper directly does not require a Flutter engine.

## Windows: CMake, C ABI, And .NET

Build and install the native package on a Windows host:

```powershell
cmake -S windows/native -B windows/native/build \
  -DDESKTOP_UPDATER_NATIVE_BUILD_TESTS=ON \
  -DDESKTOP_UPDATER_NATIVE_RUNTIME=ON
cmake --build windows/native/build --config Release
ctest --test-dir windows/native/build -C Release --output-on-failure
cmake --install windows/native/build --config Release --prefix windows/native/install
```

An external CMake consumer requests the exact package version and links the
installed shared target:

```cmake
find_package(desktop_updater_native 2.7.0 EXACT CONFIG REQUIRED)
target_link_libraries(my_app PRIVATE desktop_updater::native)
```

Include `desktop_updater_native.h` for the C++ helper or
`desktop_updater_native_c.h` for the versioned C ABI. Set
`DESKTOP_UPDATER_NATIVE_ABI_VERSION`, `struct_size`, every staged path, and the
complete `removed_files` array before calling
`desktop_updater_schedule_install_and_relaunch_v1`. The installed header also
exposes `DESKTOP_UPDATER_NATIVE_VERSION_STRING`.

`DesktopUpdater.Native` packages the `net8.0` and `netstandard2.0` managed
wrappers, `buildTransitive` copy target, and both
`runtimes/win-x64/native/desktop_updater_native.dll` and
`runtimes/win-x64/native/desktop_updater_runtime.dll`. The preview wrapper
exposes `CheckForUpdate`, `DownloadVerifyAndStage`, and `InstallAndRelaunch`;
the lower-level C ABI uses the corresponding versioned `_v1` functions.
Repository CI packs the package to a local feed and runs external consumers
against the real DLLs. It is not a public NuGet release until an approved
release workflow publishes that exact verified package.

## Linux: Source-First CMake Package

Build, test, and install the Linux helper from source on the target host:

```sh
cmake -S linux/native -B linux/native/build \
  -DDESKTOP_UPDATER_NATIVE_BUILD_TESTS=ON \
  -DDESKTOP_UPDATER_NATIVE_RUNTIME=ON
cmake --build linux/native/build
ctest --test-dir linux/native/build --output-on-failure
cmake --install linux/native/build --prefix linux/native/install
```

Use the installed CMake package:

```cmake
find_package(desktop_updater_native 2.7.0 EXACT CONFIG REQUIRED)
target_link_libraries(my_app PRIVATE desktop_updater::native)
```

Runtime consumers also link the source-built preview target:

```cmake
target_link_libraries(my_app
  PRIVATE desktop_updater::runtime desktop_updater::native)
```

The install tree also generates `desktop_updater_native.pc` with the canonical
package version. The helper requires an explicit application-owned
`install_root` and canonical `executable_relative_path`. It rejects `/`, shared
system prefixes, traversal, symlink escapes, and destructive work outside that
root before it writes a helper script.

## Standalone CLI

The package entrypoints remain available everywhere Dart is installed:

```sh
dart run desktop_updater --help
dart run desktop_updater release publish --help
dart run desktop_updater package --help
dart run desktop_updater verify --help
dart run desktop_updater app-archive --help
```

`package` keeps the existing `--input` flag. Native publish adapters use
`--project-type`, `--artifact-root`, the explicit Xcode flags, and the explicit
CMake source/build/target flags documented in
[Publishing desktop updates](publishing.md).

Native-host CI builds these candidate names and generates a `SHA256SUMS` file
beside each binary:

```text
desktop-updater-macos-arm64
desktop-updater-macos-x64
desktop-updater-windows-x64.exe
desktop-updater-linux-x64
```

Those CI artifacts are `candidate-only`. Production distribution would require
an approved workflow that produces signed standalone release assets: macOS
assets must be signed/notarized as required by policy, Windows assets must pass
the approved signing gate, and every published checksum must match the final
bytes. This plan does not publish those production CLI assets. An unsigned
candidate is not a production release.

## Verification And Evidence Labels

Native packages are released only after their target-host tests and external
consumers pass. The repository uses literal evidence labels:

- `verified locally` or `verified in CI` means the named command passed on the
  required host;
- `candidate-only` means an unsigned/non-production artifact was built and
  checked;
- `not run` means the target host or gate was not exercised;
- `blocked` means a required external dependency or credential prevented the
  gate;
- `production-ready` requires every applicable target-host, signing, package,
  checksum, and consumer gate.

The Windows/Linux release and update smoke lanes remain mandatory. The macOS
Developer ID/notary smoke stays separately gated by explicit credentials and
approved workflow dispatch.

## Native Runtime Preview

The opt-in preview implements the same three-stage lifecycle on every platform:

```text
checkForUpdate
downloadVerifyAndStage
installAndRelaunch
```

It covers HTTP transport, rollout and fresh-install selection, support policy,
index-to-descriptor binding, canonical descriptor signature verification,
artifact integrity, bounded safe staging, diagnostics, and existing helper
handoff. Applications still own configuration, pinned keys, package identity,
minimum-OS policy, request headers, UI, and release approval.

The API is `preview` and `candidate-only`, not `production-ready`. The macOS
ZIP flow is `verified locally`; Windows and Linux target-host package smokes
remain pending final CI, and the signed DMG, PKG, and Inno lanes are `not run`
without explicit credentials. See [Native Runtime Preview API](native-runtime-api.md)
for compiling examples, packaging boundaries, exact evidence, and trust rules.
