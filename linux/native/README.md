# Linux Native Helper And Runtime Preview

This package is distributed source-first. Build it with CMake and link the
`desktop_updater::native` target, or install it and use the generated CMake
export or `desktop_updater_native.pc` metadata.

Set `DESKTOP_UPDATER_NATIVE_RUNTIME=ON` to build the opt-in preview and link
`desktop_updater::runtime`. Its `UpdateClient` provides `CheckForUpdate`,
`DownloadVerifyAndStage`, and `InstallAndRelaunch` while preserving the
application-owned install-root checks in the helper. The preview requires
CMake 3.12 or later for its imported libcurl target; the helper-only build
retains the package's CMake 3.10 floor. Native tests require CMake 3.14 or
later. The preview is
`candidate-only` and not production-ready until required target-host smoke and
release gates pass.

Generic prebuilt Linux binaries are intentionally not published. A future
binary distribution must define and verify a compiler, glibc, architecture
matrix before advertising compatibility.
