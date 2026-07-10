# DesktopUpdater.Native

`DesktopUpdater.Native` provides the Windows staged-artifact install helper and
its versioned C ABI wrapper for .NET consumers. It also contains the opt-in
native runtime preview and both `desktop_updater_native.dll` and
`desktop_updater_runtime.dll`.

`DesktopUpdaterClient` provides `CheckForUpdate`, `DownloadVerifyAndStage`, and
`InstallAndRelaunch`. Helper-only consumers can continue to stage artifacts
themselves and call the existing helper wrapper. The runtime is
`candidate-only` and not production-ready until required target-host and
publisher-trust smoke gates pass.
