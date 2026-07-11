# DesktopUpdater.Native

`DesktopUpdater.Native` provides the Windows staged-artifact install helper and
its versioned C ABI wrapper for .NET consumers. It also contains the opt-in
native runtime preview and both `desktop_updater_native.dll` and
`desktop_updater_runtime.dll`.

`DesktopUpdaterClient` provides `CheckForUpdate`, `DownloadVerifyAndStage`, and
`InstallAndRelaunch`. Helper-only consumers stage and verify artifacts, then
construct `DesktopUpdaterInstallRequest` with the retained provenance digest,
artifact digest, signer allowlist, canonical install root, executable-relative
path, package identity, and the signed `DesktopUpdaterElevationPolicy` value.
The legacy overload remains available for restart requests, but rejects
non-null staging paths before native helper launch. The runtime is
`candidate-only` and not production-ready until required target-host and
publisher-trust smoke gates pass.
