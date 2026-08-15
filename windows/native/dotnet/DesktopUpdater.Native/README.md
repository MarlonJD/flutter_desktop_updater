# DesktopUpdater.Native

`DesktopUpdater.Native` provides the Windows staged-artifact install helper and
its versioned C ABI wrapper for .NET consumers. It also contains the opt-in
native runtime preview and both `desktop_updater_native.dll` and
`desktop_updater_runtime.dll`.

Set `NativeRuntimeIdentifier` to `win-x64` (the default) or `win-arm64` when
packing native assets. Consumers can set the matching `RuntimeIdentifier`; when
it is omitted, the build target uses the .NET SDK host RID when available.

`DesktopUpdaterNative` exposes explicit-ID `PrepareInstall`,
`CommitAfterExit`, `CancelReservation`, read-only `QueryTransaction`, and the
atomic `ResolvePendingInstallAfterExit` operation. The old `InstallAndRelaunch`,
schedule, and mutating-recover APIs are removed.

Helper-only consumers stage and verify artifacts, persist the transaction ID,
then construct `DesktopUpdaterInstallRequest` with the retained provenance and
artifact digests, canonical install-root/executable hints, and package
identity. The native boundary derives authority from the authenticated staged
metadata and sealed helper policy; caller-supplied signer and elevation
overrides do not exist in 3.0.

The package carries the native DLL, runtime DLL, helper executable, and sealed
policy as discovery assets. Those assets do not provision a protected helper
endpoint; protected installs require an installer-owned immutable signed
helper/policy generation. The runtime remains `candidate-only` until the
required target-host and publisher-trust smoke gates pass.
