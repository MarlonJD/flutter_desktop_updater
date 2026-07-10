# Native Helper SDKs And Standalone CLI

`desktop_updater` ships a Flutter/Dart update runtime plus small native helper
packages for applications that already own update discovery, download,
descriptor validation, artifact verification, and staging. The packages in
this guide are a helper SDK surface: they schedule installation and relaunch of
an application-owned staged artifact. They do not implement the complete
update client.

## Distribution Surfaces

| Surface | Integration | Contract |
| --- | --- | --- |
| Flutter | `desktop_updater` from pub.dev | Full Dart runtime with local platform helper sources |
| macOS helper | SwiftPM product `DesktopUpdaterKit` | Flutter-free Swift install and relaunch helper |
| Windows helper | Installed CMake target `desktop_updater::native` | Static/shared C++ helper and versioned C ABI |
| Windows .NET | `DesktopUpdater.Native` NuGet package | Managed wrapper plus the `win-x64` native DLL |
| Linux helper | Installed CMake target `desktop_updater::native` and pkg-config metadata | Source-first static C++ install helper |
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

## Windows: CMake, C ABI, And .NET

Build and install the native package on a Windows host:

```powershell
cmake -S windows/native -B windows/native/build -DDESKTOP_UPDATER_NATIVE_BUILD_TESTS=ON
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
wrappers, `buildTransitive` copy target, and
`runtimes/win-x64/native/desktop_updater_native.dll`. Repository CI packs it to
a local feed and runs an external consumer against the real DLL. It is not a
public NuGet release until an approved release workflow publishes that exact
verified package.

## Linux: Source-First CMake Package

Build, test, and install the Linux helper from source on the target host:

```sh
cmake -S linux/native -B linux/native/build \
  -DDESKTOP_UPDATER_NATIVE_BUILD_TESTS=ON
cmake --build linux/native/build
ctest --test-dir linux/native/build --output-on-failure
cmake --install linux/native/build --prefix linux/native/install
```

Use the installed CMake package:

```cmake
find_package(desktop_updater_native 2.7.0 EXACT CONFIG REQUIRED)
target_link_libraries(my_app PRIVATE desktop_updater::native)
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

## Full Native Runtime Boundary

Full native runtime discovery, HTTP transport, canonical descriptor and
signature verification, rollout selection, staging, and lifecycle APIs are
unavailable in these helper packages. That work belongs to the separately
gated preview child plan and must not be documented as production-ready until
its platform gates pass. Applications using only the helper SDK must own those
runtime responsibilities themselves.
