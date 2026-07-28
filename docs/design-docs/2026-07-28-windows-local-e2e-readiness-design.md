# Windows Local E2E Readiness Design

Status: implemented and verified locally on 2026-07-28.

## Goal

Make the Windows 11 ARM virtual machine a trustworthy local end-to-end test
host for `desktop_updater`. The completed workflow must prove the real
Windows Inno installer handoff, the native C ABI through .NET P/Invoke, and
the existing Flutter/native lanes without requiring the Inno smoke to run in
GitHub Actions.

## Scope

This work will:

- Install PowerShell 7 and Inno Setup 6 on the VM through the repository's
  signed UAC approval bridge.
- Replace the current Windows Inno smoke scaffold with a local, destructive
  test fixture that installs, updates, uninstalls, and cleans up a disposable
  application.
- Add a .NET test that loads the real architecture-matched native DLL and
  crosses the public C ABI.
- Correct the Windows CI `ctest` working directory so CI cannot report success
  after discovering zero plugin tests.
- Run the Windows debug and release validation lanes locally.
- Reconcile the working tree with `origin/main`, retain meaningful evidence,
  ignore local build/UAC artifacts, and commit the intended changes.

This work will not:

- Make the Inno smoke a required GitHub Actions job.
- Require production Authenticode credentials or assert publisher identity.
- Install the disposable smoke application into `Program Files`.
- Change package versions, changelog headings, or the package lock contract.

## Chosen Inno Test Topology

The smoke uses a per-user installation directory under a unique temporary
root and Inno `PrivilegesRequired=lowest`. PowerShell 7 and Inno Setup may be
installed machine-wide, but the application-under-test does not require UAC.

This topology is preferred over a `Program Files` fixture because it exercises
the updater's real Inno execution branch without coupling the test to a second
interactive UAC prompt initiated by the application. Protected-directory
detection and elevation selection remain covered by native tests.

The smoke must use the repository's release CLI to create the installers. A
handwritten installer-only smoke would bypass the publish configuration,
generated Inno script, release descriptor, and updater handoff that the test is
intended to protect.

## Inno Smoke Data Flow

`tool/windows_inno_smoke.ps1` will orchestrate one disposable run:

1. Verify Windows, PowerShell 7, `ISCC.exe`, Flutter/Dart, and the expected
   example build inputs. Missing prerequisites are failures, not successful
   skips, when the full smoke is requested.
2. Create a unique temporary root containing publish output, install root,
   staging root, markers, and logs.
3. Publish version 1 through
   `dart run desktop_updater:release publish --platform windows` using a
   generated temporary config with:
   - a stable smoke-only `AppId`;
   - `kind: inno`;
   - `mode: generated`;
   - `privilegesRequired: lowest`;
   - an explicit `isccPath`;
   - no Authenticode thumbprint requirement.
4. Install the version 1 installer silently into the disposable install root.
5. Assert the installed executable, Inno uninstall artifacts, and version 1
   sentinel exist.
6. Publish version 2 with the same `AppId` and install root contract.
7. Stage the version 2 installer as `installer.exe` with the exact
   `.desktop_updater_release_manifest.json` produced for the update.
8. Launch the installed example application with the existing direct-smoke
   environment contract so `DesktopUpdater.installUpdate` invokes the Windows
   native Inno branch.
9. Wait on marker files, process exit, diagnostics events, and filesystem
   state rather than fixed sleeps.
10. Assert version 2 replaced version 1, the staging directory was removed,
    and diagnostics contain at least:
    - `helper scheduled`;
    - `inno manifest loaded`;
    - `inno installer start`;
    - `inno installer success`.
11. Run the generated Inno uninstaller silently.
12. Assert files introduced by version 2 are removed and the install root no
    longer contains application payload.
13. Remove the disposable temporary root unless an explicit keep-on-failure
    switch is set.

The script writes
`reports/windows-inno-update-smoke-diagnostics.jsonl` as durable evidence and
prints the retained temporary path when cleanup is intentionally disabled.

## .NET Native Boundary

The existing managed-only tests do not prove that the DLL can be found, loaded,
or marshalled. The .NET test project will copy the already-built
`desktop_updater_native.dll` for the active configuration into the test output
directory.

A new test will call
`DesktopUpdaterNative.ScheduleInstallAndRelaunch` with a guaranteed-missing
staging directory. The expected `DesktopUpdaterException` message comes from
the native C ABI. This is deliberately an error-path call: it proves DLL
loading, architecture compatibility, struct marshalling, native execution,
UTF-8 error decoding, and result freeing without scheduling a helper or
exiting the test process.

If the native DLL is missing, the build or test must fail with a precise
instruction to build `windows/native/build` first. It must not silently fall
back to managed-only coverage.

## CI Correction

The Windows workflow currently runs `ctest` from
`example/build/windows/x64`, while the generated `CTestTestfile.cmake` for the
Flutter plugin lives under
`example/build/windows/x64/plugins/desktop_updater`. The workflow will use the
real test directory for both Debug and Release.

The Inno smoke remains local-only. The workflow will not install Inno Setup or
PowerShell 7 as part of this change.

## UAC And Tool Installation

Commands requiring elevation must follow `AGENTS.md`:

- Use `C:\Users\burak\.codex\scripts\request-uac.ps1`.
- Pass `-BridgeDir '\\192.168.132.1\requests'` explicitly.
- Confirm the bridge is reachable.
- Verify the Authenticode signature and publisher of the elevated executable.
- Use a fresh request ID with an approximately 60-second expiry.
- Never expose or persist the bridge secret.

PowerShell 7 and Inno Setup will be installed from their official Winget
packages. After installation, the executable paths and Authenticode signatures
will be verified before they are used by the smoke.

## TDD And Verification Strategy

The implementation follows red-green-refactor:

1. Add the .NET native-call test and observe it fail because the native DLL is
   not present in the test output.
2. Add the minimal copy/build contract and observe the same test cross the C
   ABI successfully.
3. After Inno is installed, run the current smoke under a wrapper that requires
   final install/update/uninstall evidence and observe the missing evidence
   failure.
4. Implement the smallest full smoke flow and rerun it to green.
5. Reproduce the zero-test `ctest` command, change only the workflow directory,
   and verify the corrected directory discovers and passes the plugin test.

The final local gate is:

- Flutter Windows Debug build.
- Debug plugin native test with non-zero test discovery.
- Standalone Windows native build and all C++/C ABI tests.
- .NET test with real P/Invoke.
- Flutter Windows integration tests.
- Debug direct-zip update smoke.
- Full local Inno install/update/uninstall smoke.
- Flutter Windows Release build.
- Release plugin native test with non-zero test discovery.
- Release publish and direct-zip update smokes.
- Focused Dart tests for changed contracts.
- Format, analyze, full Flutter tests, and publish dry-run.

## Failure Handling And Cleanup

- A prerequisite absence fails before modifying the VM test fixture.
- Every external command checks its exit code and includes captured output in
  the failure.
- Each wait has a bounded deadline and reports the missing condition.
- The Inno uninstaller is attempted during cleanup whenever installation
  succeeded, even if update assertions fail.
- Temporary paths are unique and validated before recursive cleanup.
- User-owned source changes are never discarded to clean the worktree.
- Generated .NET `bin`/`obj` directories and the repository-local UAC bridge
  scratch directory are ignored or cleaned only after their exact paths are
  verified.

## Completion Criteria

The task is complete only when:

- `pwsh` and `ISCC.exe` are installed and signature-checked.
- The local Inno smoke proves install, updater-driven update, uninstall, and
  cleanup in one run.
- The .NET test demonstrably loads and calls the real native DLL.
- Debug and Release plugin `ctest` commands discover at least one test.
- The validation ladder passes with fresh output.
- `main` contains the intended conventional commits, matches the fetched
  `origin/main` history without losing local work, and `git status` is clean.
