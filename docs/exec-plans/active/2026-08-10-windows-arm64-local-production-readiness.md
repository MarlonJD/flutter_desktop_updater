# Windows ARM64 Local Production Readiness

## Goal

Establish fresh, exact-source Windows 11 ARM64 evidence for the complete
`desktop_updater` Windows surface, fix every locally reproducible defect, and
leave the isolated checkout in a state that is locally production-ready for
ARM64 mechanics, trust enforcement, installation, update, recovery,
diagnostics, cleanup, and package consumption.

The user explicitly accepts Windows ARM64 as the only architecture required by
this local qualification. AMD64 is outside this plan and is not a missing gate.
This local target-host claim does not replace the repository output contract's
provider-backed global `production-ready` attestation or a real publisher's
production Authenticode identity.

## Scope And Safety

- Work only in
  `C:/Users/burak/AppData/Local/Temp/codex-issue70-v311-b223b19-019fea31`.
- Never access or modify the old dirty checkout at
  `C:/Users/burak/Developer/library/flutter_desktop_updater`.
- Keep the current `main` branch. Do not create, switch, rename, or delete
  branches.
- Do not commit, push, publish, create a release, or write to GitHub in this
  task unless the user grants fresh authority.
- Preserve unrelated files and all existing evidence. Remove or stop only
  exact task-owned temporary paths and processes.
- Use the signed UAC bridge workflow for any elevated mutation. Never expose
  bridge secrets, signing private material, tokens, or passwords.
- Use focused RED/GREEN evidence before each source fix, then widen the
  relevant Windows and package gates.
- Temporary local trust may prove trust enforcement and handoff mechanics, but
  it must not be described as the publisher's production signing identity.

## Starting State

- Source branch: `main`.
- Source commit, `origin/main`, and dereferenced `v3.1.3`:
  `5b295cb68721038cb89a5cc1af6c4a2c55b94a1b`.
- Tracked working tree: clean before this plan was added.
- Host: Windows 11 ARM64 VM.
- Flutter: 3.44.4; Dart: 3.12.2.
- User-scoped LLVM-MinGW Clang: 22.1.8, target
  `aarch64-w64-windows-gnu`.
- PowerShell: 7.6.4.
- Issue #70 final local evidence already showed successful missing-marker
  adoption and matching-marker control on an earlier build; this plan must
  rerun the final source and retain fresh evidence.

## Progress

- [x] Read repository instructions, architecture, harness routes, the completed
  Windows local E2E plan, and the active Windows/Linux readiness plan.
- [x] Verify exact Git refs, host architecture, Flutter/Dart/Clang paths, and
  initial task-owned processes.
- [x] Inventory every configured Windows gate, local smoke script, prerequisite,
  and evidence output.
- [x] Run the secretless Dart/Flutter and release-tool baseline.
- [x] Run standalone Windows native Debug and Release builds and all registered
  CTests; retain the two elevated protected-locator cases for the UAC lane.
- [x] Run installed CMake, .NET P/Invoke, NuGet, helper, durable-state,
  Unicode, and redirect-target gates.
- [ ] Run signed native-runtime, recovery, and tamper gates after the local
  Authenticode trust prerequisite is explicitly authorized.
- [x] Run Flutter plugin Debug and Release builds, plugin CTest discovery,
  integration tests, and forged MethodChannel rejection.
- [x] Run Debug and Release direct-Flutter ZIP updates twice, including
  diagnostics, cleanup, and trust verification.
- [x] Rerun Issue #70 missing-marker and matching-marker control against the
  final source.
- [x] Run the unprivileged install-helper lane.
- [ ] Run protected Inno install/update/uninstall, recovery, tamper,
  cancel/failure, and cleanup lanes.
- [x] Promote the shared Windows persistent transaction record to schema 4
  with immutable `directoryReplace`/`windowsInno` dispatch and preserve the
  portable directory-only authority boundary.
- [ ] Run elevated/UAC and protected-install lanes when the signed bridge and
  exact local prerequisites are available.
- [x] Fix each reproduced defect with focused regression coverage and rerun its
  affected matrix.
- [x] Preserve the direct Windows PowerShell invocation RED, identify the
  PowerShell 5.1/7 entrypoint mismatch, and add a contract that the signed UAC
  launcher dispatches the final lanes through PowerShell 7.
- [x] Preserve the missing-Debug-artifact and MSVC shared-PDB REDs, add `/FS`
  only to the Windows helper-support MSVC target, pass its focused contract,
  rebuild Debug, and re-sign all four Flutter smoke artifacts with the current
  task certificate.
- [x] Preserve the fresh signed Debug run `4a57cfb58ca44d8db942dde461ba8ed2`
  RED where portable reservation preparation exceeded the first one-shot
  response deadline; retain the run-1 GREEN/run-2 RED evidence and identify
  synchronous Task Scheduler `RunEx` latency as the timing root cause.
- [x] Keep exact Task Scheduler registration/readback as the durable boundary,
  start the already-validated portable recovery host directly in the caller's
  exact token for the current session, and retain the bounded portable
  90-second versus protected 30-second startup budgets. Focused source,
  ARM64 Debug/Release helper builds, and 26/26 filtered CTest matrices pass in
  both configurations.
- [x] Preserve focused signed run
  `8fad5354c2c64ba2a87da046f9b59736` where source signer trust, disposable
  CurrentUser trust, download, install scheduling, and app exit passed, but
  the helper failed during backup rename after exhausting the original
  sharing retry budget. Retain its result, stdout/stderr, report, and bounded
  `_w` root as RED evidence.
- [x] Trace that RED to the bounded `ERROR_SHARING_VIOLATION`/
  `ERROR_LOCK_VIOLATION` rename retry window (about 5 seconds across the prior
  eight attempts), increase only that bounded budget from 8 to 32 attempts,
  and add a native regression that holds a target child handle for 6.5 seconds.
  The focused Dart layout contract is 24/24 and the affected ARM64 Debug and
  Release CTest matrices are 40/40 each.
- [x] Complete the fresh signed focused Debug rerun
  `41a972cb785b496ab5903b4aecb2ee35`: exit 0, checking/downloading/installing,
  backup success, move success, cleanup success, installed sentinel, and
  controller staging cleanup all passed. The GREEN evidence is
  `portable-backup-sharing-green-41a972cb785b496ab5903b4aecb2ee35.log`.
- [x] Preserve signed focused Inno run `16540e48ca824a2c8b00639225dc8852`
  as RED: package/signature/feed preparation passed, but the installed 3.1.2
  app remained in `installing` after the commit handoff, with no protected
  helper protocol events. Exact task residue was absent after bounded cleanup;
  the preserved runner root and pending transaction remain RED evidence.
- [x] Trace that RED to both protected `ShellExecuteExW(..., runas)` launches
  using `SW_HIDE`, which left the manual elevation consent invisible while the
  caller synchronously waited. Change only those protected launches to
  `SW_SHOWNORMAL` and add a source contract. The focused layout contract passes
  24/24, and the affected ARM64 Debug/Release native builds plus
  `WindowsOneShotTransport|WindowsHelperAuth` matrices pass 15/15 each.
- [x] Rerun the signed protected Inno smoke as
  `1b4823c66aba444385263004d2600fef` with the corrected launch mode. Both
  3.1.2 and 3.1.3 packaging, signing, feed publication, and update selection
  passed; the run reached `installing` and launched `consent.exe`, but no
  manual approval was possible because the secure-desktop consent UI was not
  visible. Preserve the result and pending transaction as bounded RED evidence.
- [ ] Complete the protected Inno execution and final elevated lanes after the
  VM exposes the genuine manual UAC consent UI; do not repeat an invisible
  consent wait or bypass the Windows security boundary.
- [x] Complete the final secretless post-fix ladder: bounded Dart format
  `278/278` with zero changes, fresh tracked-source analysis exit 0 with
  `0` errors/`0` warnings/`681` non-fatal infos, serial Flutter `838` passed/
  `17` skipped/`0` failed, structural harness `31/31`, tracked-source publish
  dry-run exit 0 with zero warnings, and `git diff --check`.
- [x] Preserve the full-suite Linux scope RED caused by stale retained Pub
  cache enumeration, narrow the test to canonical source roots, and rerun the
  focused regression `4/4` GREEN. The affected full Flutter suite then passed
  `838/838` with `17` expected skips and zero failures.
- [x] Re-run the post-fix ARM64 native and Flutter surface gates: serial Debug
  and Release native CTest each passed `192/192` with four expected skips,
  the regenerated native PE audit passed `60/60` at `0xAA64`, Debug and Release
  Flutter plugin CTest each passed `17/17`, the Windows integration matrix
  passed `3/3`, and the isolated forged MethodChannel regression passed `1/1`.
- [x] Re-run the final secretless source gates after the bounded Linux-scope
  fix: format passed `278/278` with zero changes, the focused Linux scope
  regression passed `4/4`, and `git diff --check` passed. The initial
  parallel native discovery/fixture invocations and the first separate forged
  test command-timeout remain preserved as harness RED evidence; corrected
  serial/fixture and extended-timeout runs are GREEN.
- [ ] Widen to the complete signed Debug/Release/helper/locator/protected-Inno
  matrix with a fresh UAC request.
- [ ] Run the final clean ARM64 validation ladder and audit task-owned residue.
- [x] Create and verify the replacement task-scoped non-exportable certificate
  in CurrentUser/My with public trust in CurrentUser/Root and
  CurrentUser/TrustedPublisher; export no private key.
- [ ] Complete the signed lanes under the replacement task-scoped certificate;
  fresh run `3758b573417e4bacbb52ee7a2d1a7d28` has all direct ZIP, helper, and
  protected-locator lanes green, while protected Inno remains open after a
  policy-authority RED. The current replacement identity is
  `B012539A7D55542BEDF3F9BC5C3D3F0CE3AA900E` with DER SHA-256
  `9d492f2e44ba40358d7cf80d19f9166d251b3e28bfd3241a57ac947140b0f0e4`.
- [x] Correct the protected Inno endpoint assertion for native `\\?\` final
  paths and make uninstall cleanup tolerate unrelated records; focused Windows
  and generated-Inno contracts pass 20/20, with the null-record regression at
  12/12.
- [x] Bind the protected Inno helper policy to both the exact application
  install root and the separate protected helper-generation root; the focused
  Windows Release smoke contract passes 13/13. A fresh signed protected-Inno
  rerun remains required.
- [x] Align the native protected policy reader with the signing hook's exact
  canonical LF contract; the focused ARM64 native auth matrix passes 12/12 and
  the focused Windows smoke contract passes 14/14.
- [x] Make generated Inno installers write the protected uninstall record's
  `DisplayVersion` explicitly from release metadata; the focused Inno packager
  plus Windows smoke regression matrix passes 19/19.
- [ ] Rerun the complete signed ARM64 matrix after the policy-LF and explicit
  `DisplayVersion` fixes, including protected Inno update/uninstall.
- [x] Under renewed user authority, create the current non-exportable
  CurrentUser-only certificate `325D896A5D17AC6FF5FBF591DD8F3060BFB1AF7C`
  (DER SHA-256
  `a528eaa6098a8af03cce9d02a8649b8dbb6bc34fa8969a0cc8b8100d9e54e61c`),
  manually trust its public certificate in CurrentUser Root and
  TrustedPublisher, and verify no LocalMachine installation.
- [x] Preserve the protected-Inno helper failure with fixed redacted stage
  diagnostics. Replay `b6ac642901c1414a9162360bec2a7f65` reached the real
  helper and emitted event IDs `1047` and `1051`, localizing the failure to
  protected installer payload preparation after signed request validation.
- [x] Add strict bounded protected-Inno replay support, including canonical
  signed-loopback feed-port reuse, short runtime roots, explicit child exit
  codes, classic Event Log querying, and bounded cleanup-race handling. The
  focused Windows smoke contract passes `23/23`.
- [x] Remove canonical-path reopens from protected Inno restaging and recovery;
  source, protected copy, and recovery cleanup now revalidate the exact retained
  file handles. ARM64 Debug helper/authorizer build passes and the focused
  native authorizer matrix passes `8/8`.
- [x] Preserve fresh signed protected-Inno RED
  `f29d3b46e1f04445a6aa87bf62f12163`, localize event `1050` to the staged
  manifest read, and reproduce it with an exact extended-length native test.
  The stage path was 230 characters and the manifest path was 269 characters;
  the raw `CreateFileW` call failed while provenance's `\\?\`-aware reads
  passed. The focused RED is retained, and the fixed ARM64 Debug/Release
  install-authorizer matrices pass `9/9` each.
- [x] Rebuild and sign fresh 3.1.2/3.1.3 artifacts containing the retained-handle
  and extended-length manifest fixes. Run
  `616f9c50f2764045b607f4340fd1e71b` passed package/feed validation and the
  prior helper stages, then failed cleanly at protected payload preparation
  with events `1000`/`1003`/`1051`/`1047`; bounded cleanup passed.
- [x] Preserve the `616f9c50f2764045b607f4340fd1e71b` parent-access RED,
  prove the staged installer still matched exact length, SHA-256, and
  Authenticode authority, and reproduce the `Program Files` ACL mismatch in an
  ARM64 native regression. The protected Inno parent now requests only child
  creation/traversal/read-attributes/synchronization rights; focused `1/1` and
  full Debug/Release authorizer matrices pass `10/10` each.
- [x] Preserve fresh signed run `adadb98949c1436893322059fd9aa6fc` after its
  3.1.2 build/package/install/feed checks passed but its second, 3.1.3
  production build failed in the plugin test target's five-second POST_BUILD
  GoogleTest discovery. The copied Flutter DLL matched exactly, no CTest list
  was produced at failure, and the same test binary and discovery command then
  passed in isolation.
- [x] Move only plugin test discovery to `DISCOVERY_MODE PRE_TEST`, retain
  focused contract RED `0/1` and GREEN `1/1`, rerun Debug in `186.3s` and the
  exact 3.1.3 Release build in `81.6s`, and prove that Debug/Release CTest still
  discovers and runs all `17/17` plugin tests in each configuration.
- [x] Start fresh signed run `4672616b26ab4c69962715955370537d` from the
  post-fix source. The user interrupted the task while its 3.1.2 Flutter build
  was still running, so the launcher retained `launcher-started`, no
  `result.json` was produced, and this run is neither a product RED nor
  promotion evidence. The 2026-08-15 continuation audit found no matching live
  process, port, account/profile, Program Files path, or registry residue.
- [x] After certificate expiry, remove exact SHA-1
  `325D896A5D17AC6FF5FBF591DD8F3060BFB1AF7C` from CurrentUser My, Root, and
  TrustedPublisher and verify `0/0/0` in both CurrentUser and LocalMachine
  views. A future signed continuation requires fresh explicit identity
  authority; no replacement identity was inferred.
- [ ] Rebuild and sign fresh artifacts containing both the parent-access and
  PRE_TEST fixes, complete protected install/update/relaunch/uninstall, then
  widen to the complete final elevated and secretless ladders. Do not replay
  preserved pre-fix helper binaries as proof of either source change.

## Milestones

### 1. Baseline And Prerequisites

Verify Visual Studio/MSVC/Windows SDK/CMake/CTest/MSBuild, PowerShell, Inno
Setup, .NET, signtool, Flutter desktop support, local certificate stores, the
UAC bridge, and exact task process/port state. Record presence and publisher
metadata without exposing secrets. Build a command matrix from the current
workflow and smoke scripts rather than relying on historical plan checkboxes.

Exit criterion: every required tool is present or has one precise actionable
remediation; no stale task process can affect a test.

### 2. Package And Secretless Gates

Run dependency resolution, focused Windows contract tests, format, analysis,
version sync, full serial Flutter tests in a Windows-compatible configuration,
structural harness validation, publish dry-run, and relevant release CLI tests.
Classify any OS-inapplicable test literally; fix tests that incorrectly fail on
their supported Windows host.

Exit criterion: all Windows-applicable package and release-tool gates pass.

### 3. Native SDK, Helper, Recovery, And Consumers

Configure and build the standalone native SDK for Debug and Release with the
runtime enabled. Run all registered CTests with `--no-tests=error`, verify test
inventory, install the SDK, build/run the installed CMake consumer, run real
.NET P/Invoke, pack and consume the NuGet package, verify durable-state
compatibility, and run helper/recovery/tamper/Unicode/relative-redirect gates.

Exit criterion: native and consumer inventories are non-zero, every test
passes, authorized recovery converges, hostile input fails closed, and cleanup
is exact.

### 4. Flutter Plugin And Direct ZIP Runtime

Build the example app in Debug and Release, build and run plugin GoogleTests,
run all Windows integration tests including the forged raw MethodChannel case,
then rebuild the normal runner. Sign local smoke binaries using an explicitly
scoped local trust identity when needed. Run the direct-Flutter ZIP smoke twice
per configuration and verify update selection, signed metadata, Authenticode
checks, native handoff, installation, relaunch behavior, diagnostics, and
staging cleanup.

Exit criterion: both configurations and repeated runs pass with bounded,
fresh evidence and no task residue.

### 5. Issue #70 And Installer Transactions

Rerun the exact missing-installed-marker reproduction and matching-marker
control on the final candidate. Then run unprivileged helper and full Inno
install -> updater-driven update -> uninstall. Exercise malformed/mismatched
identity, artifact, provenance, package ID, path, and transaction inputs, plus
crash/recovery and cancellation/failure paths.

Exit criterion: the former Issue #70 exception is absent only for the now
authorized missing-marker adoption path, the control remains unchanged,
invalid existing markers are never overwritten, and installer/recovery
transactions complete or fail closed with exact cleanup.

### 6. Elevated Local Target-Host Evidence

Use the signed UAC bridge and a fresh short-lived request for protected
installation tests. Verify the elevated executable's Authenticode publisher
before launch. Prove cancel/no-mutation where safely automatable, successful
protected install/update/recovery, policy/ACL integrity, fresh-process crash
recovery, and cleanup. Do not fabricate or expose production signing secrets.

Exit criterion: all locally applicable elevated ARM64 outcomes pass, or an
external production publisher identity remains explicitly outside the local
claim.

### 7. Final Convergence

Rerun every affected focused test, the full native/plugin/integration/smoke
matrix, format, analysis, full Windows-applicable Flutter suite, publish
dry-run, `git diff --check`, and source/residue audits. Review every diff for
trust, compatibility, failure, recovery, and cleanup impact.

Exit criterion: no reproducible Windows ARM64 defect remains; all applicable
local gates pass on the final source; all non-applicable or externally owned
boundaries are named literally; task-owned processes, ports, installs, trust,
and temp state are cleaned.

## Surprises & Discoveries

- Three historical `flutter_tester.exe` WMI entries remained tied to an older
  isolated test export even after Windows reported successful termination.
  Treat them as stale OS entries unless a live handle or new interference is
  observed; do not kill unrelated processes.
- The generic Dart executable reports `windows_x64` even though the Windows host
  and Clang toolchain are ARM64. Architecture evidence must therefore be bound
  to the host, produced PE binaries, and actual native execution, not that Dart
  label alone.
- Visual Studio 2022 has the ARM64 MSVC tools and Windows 11 SDK installed, so
  the standalone native matrix can produce and execute real ARM64 PE binaries
  with `-A ARM64`. The previously retained native and Flutter build directories
  were all configured for `x64` and are historical evidence only.
- Flutter 3.44.4 exposes no Windows target-platform switch and its local engine
  cache contains only `windows-x64`, `windows-x64-profile`, and
  `windows-x64-release`. The required Flutter plugin, integration, and direct
  ZIP lanes therefore exercise Flutter's x64 engine under Windows 11 ARM64
  emulation; they are target-host compatibility evidence, not ARM64-native PE
  evidence and not a separate AMD64 host qualification.
- The three formerly stale WMI PIDs `14460`, `16368`, and `17236` were absent
  during the fresh inventory. Ports `43891`, `43892`, and `43895` were free.
- Commands that invoke `flutter.bat` must run outside the workspace sandbox on
  this VM. The launcher takes an exclusive write handle on the Flutter SDK's
  `bin/cache/flutter.bat.lock`; inside the workspace-only sandbox it retries
  forever before spawning Dart. Three 60-second probes reproduced the stall,
  while the same `flutter --version` command exited successfully in 13.1
  seconds outside the sandbox.
- A prior task left PID 12828 running as `dart pub publish --force` from this
  isolated checkout. The current task has no publish authority, so the exact
  process was stopped before validation and a subsequent process query
  confirmed it no longer exists.
- `Win32_Process` still returns the three historical tester rows even though
  kernel-backed `Get-Process -Id 14460,16368,17236` reports every PID absent.
  They are WMI ghosts, own no live handle, and cannot be terminated again.
- The repository root retains older Issue #70 source exports, Pub caches, and
  test-listener trees as untracked evidence. The literal root-wide format and
  analysis commands traversed those third-party copies: root format returned
  65 after inspecting 3,912 files, and root analysis reported thousands of
  findings from the retained copies. A tracked-root format pass covered 277
  current files with zero changes. Run analysis from a fresh tracked-source
  copy so preserved evidence cannot pollute the current-source result.
- A second, externally started Flutter runner repeatedly appeared while the
  readiness worker was active. Its exact `_arm64_test_temp_retry2` single-test
  process tree was separated from the keeper's unique TEMP and log paths and
  stopped without touching the keeper. The parent orchestration thread then
  ended all command execution; this plan's dedicated worker is now the sole
  Windows ARM64 runner.
- The first captured three-file Windows regression run reproduced a real test
  harness defect: five valid helper requests needed about 31 seconds when each
  validator launched the x64 Dart runtime under Windows ARM64 emulation, just
  exceeding the framework's 30-second default timeout. The deterministic
  two-process fixture generator also consumed 25 seconds. Product assertions
  after the timeout continued to pass, including all release-key and updater
  recovery cases.
- The same focused run exposed three Windows-host assumptions independent of
  the subprocess timeout: child Dart output was decoded with the system code
  page instead of UTF-8, POSIX permission bits were asserted on Windows, and
  controller recovery tests supplied a query/recover strategy that production
  Windows correctly rejects in favor of atomic after-exit resolution. Focused
  RED logs were retained and all three corrected tests pass.
- The 46-case invalid-request matrix launches one Dart process per case. It
  passed unchanged with a five-minute test-specific budget; the default
  30-second budget and an initial two-minute retry were both insufficient on
  this ARM64 host running the x64 Dart SDK under emulation.
- Fresh ARM64 MSVC Debug and Release builds each produced 28 executable/DLL PE
  files, all with machine type `0xAA64`. Both configurations registered 177
  CTests and finished with zero failures. The non-elevated run skips two child
  orchestrator entries and the corresponding crash writer/reader entries; it
  also now explicitly skips the production-ACL locator orchestrator until the
  elevated lane rather than failing ambiguously.
- The protected-locator RED was Win32 status 1307 (`ERROR_INVALID_OWNER`): a
  medium-integrity process cannot assign the production Administrators owner
  to the HKCU-backed registry sandbox. The production ACL remains unchanged,
  the error now retains its Win32 status, and the exact test will be rerun under
  the signed UAC bridge.
- MSVC reported an implicit `wchar_t`-to-`char` narrowing in the helper's
  ASCII-only transaction-ID path. The validation and conversion now happen in
  the same loop with an explicit cast after rejecting every value above 0x7f.
- The .NET test project unconditionally replaced an explicitly supplied native
  DLL path, so the first ARM64 P/Invoke run loaded no ARM64 candidate. The
  project now supplies its x64 default only when `NativeDllPath` is empty; the
  real ARM64 VSTest lane passes 15/15 against the installed `0xAA64` DLL.
- The NuGet project hard-coded native assets under `runtimes/win-x64`, which
  would have mislabeled a real ARM64 package. Packing is now parameterized for
  `win-x64` or `win-arm64`, and the transitive target resolves an explicit
  asset RID before SDK runtime identifiers. This avoids requesting unrelated
  offline .NET runtime packs while selecting the correct native asset.
- A package-content test compared LF literals with CRLF file contents on
  Windows. Normalizing line endings in the test preserves the content contract
  without rewriting package sources.
- Creating and trusting an ephemeral Authenticode certificate mutates a
  security boundary. It was initially rejected without fresh authority. The
  user then explicitly authorized one task-scoped self-signed identity, now
  present only in `CurrentUser/My`, `CurrentUser/Root`, and
  `CurrentUser/TrustedPublisher`; its private key is non-exportable and the
  identity must be removed completely at task end. It is local trust evidence,
  never the package publisher's production identity.
- Flutter's x64 engine completed Debug and Release builds on the ARM64 host;
  both plugin matrices passed 17/17, the isolated forged MethodChannel test
  passed, and the full Windows integration matrix passed 3/3. These are
  x64-on-ARM64 target-host compatibility results, not native ARM64 PE claims.
- The configured Inno smoke still targeted a removed raw staging environment
  hook. The current controller already stages a signed `innoInstaller` and
  builds `verifiedInstallerHandoff/windowsInno`, but the Windows helper only
  authorized directory replacement, so the old smoke could not prove the
  current product path.
- Authenticode identity and an uninstall `DisplayVersion` alone cannot prove
  that a crash-recovered Inno transaction installed the desired build. The
  signed descriptor now freezes the exact installed executable relative path
  and SHA-256, and generated Inno packages write an exact build number into
  their protected uninstall record.
- A dedicated immutable protected-Inno journal now round-trips strict
  canonical authority and classifies live-owner, desired-only, old-only, and
  ambiguous recovery facts fail closed. Its ARM64 focused matrix passes 3/3;
  binding it into the shared persistent record awaits the explicitly reviewed
  schema transition.
- The signed descriptor accepted several Inno shapes that the protected helper
  correctly rejected: non-elevated authority, optional Authenticode, unsafe or
  duplicate switches, and missing inherited install-directory authority. The
  Dart, C++, and Swift readers plus publish configuration now enforce the same
  fail-closed protected contract; the affected Dart matrix passes 102/102.
- Adding the signer-certificate SHA-256 field to
  `VerifiedWindowsExecutable` exposed a stale incremental MSBuild object that
  still used the former aggregate layout. A focused resolver test rejected a
  successor despite every explicit identity value matching. Recompiling the
  support object made it pass, and a subsequent `--clean-first` ARM64 Release
  rebuild reproduced the 1/1 pass with no diagnostic-only API retained.
- A new local-smoke contract test preserved a focused RED showing that
  `tool/windows_inno_smoke.ps1` still used synthetic `9.9.8 -> 9.9.9` releases
  with `privilegesRequired: lowest` and `requiresElevation: never`. The
  corrected hook cannot be added or exercised until the task-scoped signing
  identity and trust-store mutation are explicitly authorized; the rejected
  patch performed no file or trust mutation.
- A second focused contract RED proves the manual signed native-runtime Inno
  workflow lane has the same authority drift: it compiles
  `PrivilegesRequired=lowest`, stages under runner temp, and supplies neither a
  protected helper nor its consumer policy. The RED is retained before changing
  the lane; credentials and unsigned bypasses were not used.
- The ordinary privileged test policy intentionally authorizes only directory
  replacement. A separate test-only protected-Inno policy factory now grants
  only `applicationDirectory/verifiedInstallerHandoff/windowsInno`; its focused
  ARM64 Release regression passes 1/1 and confirms that neither portable nor
  directory-replacement authority is inherited.
- Extending the production authorizer/classifier, even without executing an
  installer, was also rejected by the approval reviewer because it changes the
  shared privileged trust boundary. The unimplemented RED probe was removed
  from the source after its log was retained; production authorization remains
  unchanged until the same explicit approval is supplied.
- The authorized schema-4 focused ARM64 matrix first passed 29/30: an invalid
  `transactionKind` was correctly rejected, but the selected journal decoder's
  concrete exception escaped the persistent-record abstraction. The decoder
  failure is now normalized to `WindowsPersistentRecoveryError`; the complete
  persistent-recovery and portable-index matrix passes 30/30.
- The frozen Windows compatibility tree contains the schema-3 persistent
  record written by the published predecessor. A schema-4-only decoder would
  strand a prepared update. The production reader now accepts schema 3 only as
  strict `directoryReplace`, re-encodes those bytes exactly, rejects an Inno
  journal under schema 3, and upgrades the record to schema 4 on its first
  state mutation. New emission is named `persistent-record-schema4.json`.
- The workflow's existing Inno lane is a distinct low-privilege transport
  smoke and cannot attest the protected Program Files path. It is retained and
  named explicitly; the protected 3.1.2 -> 3.1.3 lane now lives in the
  dispatch-only self-hosted UAC job and invokes the same signed local harness.
  Focused workflow, fixture, and tool contracts pass 28/28.
- The first signed missing-marker reproductions exposed a Windows 11 ARM64 x64
  emulation edge: reopening an already verified helper's canonical DOS path
  could transiently return `ERROR_FILE_NOT_FOUND` even while the original
  retained handle and file identity remained valid. Bootstrap and portable
  recovery now consume the retained helper and policy handles. The focused
  layout RED, clean ARM64 build, and portable recovery matrix pass 1/1 and
  19/19.
- After the recovery-host fix, one signed run reached payload verification but
  failed while the verifier reopened the staged executable path. A diagnostic
  retry then passed, confirming a transient reopen rather than invalid bytes or
  trust. Authenticode publisher and leaf-certificate identity are now obtained
  from the same `WINTRUST_DATA` state that verified the retained file handle;
  payload hash, file ID, final path, and post-verification match remain bound to
  that handle. The focused Dart regression passes 1/1 and the clean ARM64
  native Authenticode matrix passes 12/12.
- The pre-UAC residue audit found 32 unloaded, non-special `duflutter*` and
  `duzip*` profiles whose exact local accounts had already been removed. Both
  standard-user smoke paths removed the account but never removed its
  `Win32_UserProfile`. A shared, SID- and path-bounded cleanup helper now rejects
  loaded, special, changed, or ambiguous profiles and is enforced by a focused
  contract test. The existing profiles remain preserved as RED evidence until
  the final authorized elevated cleanup lane removes only those exact profiles.
- The first fresh clean ARM64 native build exposed a test-only aggregate
  initializer that predated `signer_certificate_sha256`. The fixture now
  zero-initializes `VerifiedWindowsExecutable` and assigns every field by name;
  its focused 3/3 matrix and the final clean Debug/Release matrices pass. The
  bare Debug CTest retry also demonstrated that the native transport fixture
  server on port 43891 is a workflow prerequisite, not an optional test
  dependency.
- The final tracked-source analyzer successively exposed twelve stale callers
  of newly required authority fields: two macOS PKG smoke descriptor callers
  had not explicitly omitted the Inno-only executable fields, and eight Inno
  script-builder tests had not supplied the executable-relative path. Focused
  contract matrices pass 12/12 and 8/8 respectively; the final analyzer exits
  zero with zero errors, zero warnings, and 674 non-fatal infos.
- The first elevated final-lane wrapper stopped before mutation because a local
  `$matches` collection collided case-insensitively with PowerShell's automatic
  `$Matches` variable. Renaming it to `$profileMatches` restored the focused
  collection contract. The bridge accepts the signed Windows PowerShell host,
  which then starts the PowerShell 7 wrapper; attempts to label `pwsh.exe` as
  Windows PowerShell are correctly rejected by bridge visible-text checks.
- The first real direct-Flutter UAC retry exposed two distinct Windows path
  constraints. The original runner and smoke-root names could produce a
  298-character standard-user TEMP candidate; shortening those bounded names
  still left a 268-character staging path. Moving TEMP beside the repository
  avoided length pressure but correctly failed the native per-component ACL
  check because the disposable user's SID was absent from repository ancestors.
  The durable fix uses the standard user's own short
  `AppData/Local/Temp`, creates it during the profile probe, and keeps every
  staged component within that user's already authorized profile. The focused
  smoke contract passes 23/23; the real repeated run remains in the final UAC
  lane.
- The first complete serial Flutter suite reached 822 passes and 17 expected
  skips before one contract asserted a pre-schema-4 test label. Updating only
  that stale expected label produced a final 823-pass, 17-skip, zero-failure
  run.
- A repository-root publish dry-run enumerated retained untracked evidence and
  was stopped after producing a 5.9 MB pollution log. A fresh tracked-source
  export of the same candidate completed with zero warnings; no publication
  was attempted.
- Flutter's final application and helper binaries verify against the authorized
  temporary certificate but remain `0x8664`, as required by Flutter 3.44.4's
  only local Windows engine. They are ARM64-host compatibility evidence only;
  `final-arm64-pe-audit.json` remains the separate native proof with 60/60
  `0xAA64` binaries.
- Seven task-modified files had been mechanically rewritten with CRLF or mixed
  line endings by earlier Windows tooling, obscuring their substantive diffs
  and failing `git diff --check`. Normalizing only those seven changed text
  files back to the repository's LF convention preserved content and restored
  a clean diff check.
- The first final direct-Flutter attempt exposed three additional harness facts.
  Cleanup initially addressed the WMI `Id` property instead of
  `Win32_Process.ProcessId`; the Debug runner still contained integration-test
  assets until the workflow's required post-integration rebuild was repeated;
  and the disposable standard user did not inherit the operator's CurrentUser
  trust. Focused contract coverage now uses the exact process ID, provisions
  only the verified public signer certificate into the disposable user's
  CurrentUser stores, and rejects signer hash or publisher drift.
- Self-signed Root enrollment under the disposable standard user correctly
  opens the Windows `Güvenlik Uyarısı` consent dialog. The final elevated run
  `ecb73a9be2184a9fa942d18986160876` was intentionally stopped at that manual
  boundary on the user's request. The wrapper recorded the expected failed
  Debug-run-1 result and preserved `_w/ecb73a9b`; the exact certutil process was
  stopped, and the post-stop audit found zero matching disposable accounts,
  profiles, smoke children, or remaining task processes.
- The first continuation inventory falsely reported the original certificate
  absent because JavaScript string escaping removed separators from the
  PowerShell certificate-provider paths. A corrected `Cert:/CurrentUser/...`
  inventory showed the original `6020D3D7D056700CB2448817B74F5536D6D69E9E`
  identity still present and valid at that time; no signed lane used it.
- Fresh explicit authority then created replacement certificate
  `F9B899F1F333A3ECE2C54A9587D709A39277B49B` /
  `aa6ff363b376b2a63144b1517424f8741a86505a0adebd7a31114d69f24f4cc6` for
  publisher `Desktop Updater ARM64 Readiness 5895c3dd54d94178a14747f6834e485e`.
  Its CNG export policy is `None`; only public trust was added to Root and
  TrustedPublisher, the public staging `.cer` was removed, and Root consent
  was manually approved. The original and replacement task identities remain
  bounded cleanup targets for final completion.
- The prior continuation certificate `FCEA9027A916953E338E3E3476E2399C052B9F9B`
  expired at `2026-08-11T18:25:55Z` before the next signed lane. It was not
  reused. Under the user's renewed explicit authority, the current
  non-exportable certificate is `2DD3E73FF663ECE1BA78B9788E35192926A3823F`
  with DER SHA-256
  `314c0386c14de5a7c5b05c5442120eda2c2c71dfe26f2e18b604a1ede3b405bb`, and
  manual CurrentUser/Root consent was completed.
- The fresh signed run `a2321868631147f794b4f2450f87f985` passed all four
  direct ZIP repetitions, the elevated helper probe, and both ARM64 protected
  locator lanes. Its protected Inno lane retained RED evidence after signing
  the Release output; the packager's combined error also covers a missing
  executable-relative path, and the Flutter adapter intentionally left that
  optional field null because the local harness had not supplied its exact
  `desktop_updater_example.exe` path.
- The smallest durable fix was to pass the exact example executable path to
  both protected Inno publish calls. No packager validation was weakened and no
  executable name was inferred. The focused Windows release smoke contract now
  passes 11/11; the failed Inno result and transcript remain preserved under
  `inno-e2e-1b7ba7480a9a4894bc908b3d7386d75e/` and
  `protected-inno-elevated.log`.
- The normal sandbox shell runs as `marlonjd\\codexsandboxoffline`, whereas
  signed/UAC lanes run as `MARLONJD\\burak`. Empty certificate stores in the
  former are not cleanup evidence; elevated verification found both exact task
  identities in all three CurrentUser stores and no task-owned accounts or
  profiles.
- The first post-fix wrapper retry `52101272615d4221af9d544b676db899` stopped
  before a lane because the preceding Inno attempt had reset the shared
  `build/windows/x64` root and removed Debug output. Its missing-Debug RED is
  retained; a bounded pub-get plus fresh Debug/Release rebuild and four-file
  exact signing verification restored the required inputs. Fresh run
  `fb825987c397499f804620f03219bdb2` is now paused at the user-controlled
  `certutil` Root warning (PID 7900, `Güvenlik Uyarısı`) before lane 1.
- Fresh run `fb825987c397499f804620f03219bdb2` then passed all four direct
  ZIP lanes, the elevated helper, and both protected locators, but protected
  Inno still emitted the combined missing-directory/path error after signing.
  The exact CLI argument was present in `Publish-SmokeVersion`; the durable
  root cause was `FlutterProjectAdapter` dropping
  `overrides.executableRelativePath` when constructing `ProjectBuildResult`.
  The adapter now propagates that value, and the focused adapter plus Windows
  Inno contract matrix passes 28/28. The 8-lane RED result and transcript are
  retained for the required fresh rerun.
- Fresh signed rerun `d3fd2de90e74405ca9867752a98bb1b6` passed both Debug direct
  ZIP repetitions. Release run 1 completed the update, wrote the smoke
  sentinel, recorded helper cleanup success, and then exposed a bounded
  cleanup race: the helper emitted `relaunch attempt`, the relaunch path
  emitted the expected canonical-root failure after the external cleanup
  boundary, and `flutter_windows.dll` remained briefly undeletable. The
  preserved RED is `final-direct-release-run-1-d3fd2de90e74405ca9867752a98bb1b6/`
  with the wrapper result in `final-elevated-lanes-result.json`.
- The smallest durable harness fix adds a 24-attempt, 250 ms bounded retry
  around removal of the already task-owned and ACL-repaired smoke root. It
  does not broaden process matching, alter trust, or suppress cleanup errors.
  PowerShell parsing and the focused direct-smoke contract pass 24/24 after
  the fix; the remaining signed lanes must be rerun with a fresh UAC request.
- Fresh signed run `0869d97991424de8b365935494e8563d` passed all four direct
  ZIP repetitions, the elevated helper, and both protected locators (7/7).
  Protected Inno then reached ISCC compilation and exposed a new generated
  Pascal Script RED: Inno Setup 6.7.3 does not provide a bare
  `GetFileAttributes` identifier. The preserved result is
  `inno-e2e-7d734bd1645348cca55df8935e491d7a/result.json`; the transcript is
  `protected-inno-elevated.log` and the driver log records the exact ISCC
  line-71 failure.
- The smallest durable Inno fix declares the required Windows API explicitly
  as `GetFileAttributesW@kernel32.dll stdcall` and calls that named wrapper
  from the unchanged reparse-point fail-closed check. The focused generated
  script test passes 9/9. The failed run's elevated host became idle after
  its child exited; its exact RED evidence is retained and no unverified
  process was force-stopped when path/commandline inspection was unavailable.
- Fresh signed run `c8c6dfa99b004960879930f6bb97e529` passed all four direct
  ZIP lanes, the elevated helper, and both protected locators (7/7). It also
  passed Inno ISCC compilation, package signing, descriptor validation, and
  feed validation, then failed at the exact 3.1.2 endpoint assertion. The
  native helper records the retained `GetFinalPathNameByHandleW` DOS path with
  a `\\?\` prefix, while the harness compared it directly to a normal DOS
  path. Its cleanup also exposed an unrelated Inno uninstall key without the
  task-specific custom values. The RED result is
  `inno-e2e-6a89e342edbd4075946a979f4645eb53/result.json`; the transcript and
  driver logs are `protected-inno-elevated.log` and
  `final-protected-inno-driver.stderr.log`.
- The smallest durable fix adds bounded Windows path comparison that removes
  `\\?\`/`\\?\UNC\` prefixes before `GetFullPath`, applies it to both
  versioned endpoint assertions and uninstall matching, and reads optional
  uninstall values through `PSObject.Properties`. The focused Windows Release
  smoke plus generated Inno contract matrix passes 20/20; a fresh signed
  protected-Inno rerun is required.
- Fresh signed run `0b610ed67cfc4aff8f0e0c46d48b6756` passed all four direct
  ZIP lanes, the elevated helper, and both protected locators (7/7). Inno
  compiled, signed, and validated the 3.1.2 feed, then exposed a second
  cleanup-harness RED: unreadable or empty unrelated uninstall keys can make
  `Get-ItemProperty` return `$null`, so optional-property reflection was
  attempted on a null record. The exact result is the current
  `final-elevated-lanes-result.json` with `runnerTempPreserved=true`; the
  transcript and driver stderr retain the null-record and endpoint context.
- The smallest follow-up fix returns `$null` immediately for a null uninstall
  record before inspecting `PSObject.Properties`. PowerShell parsing and the
  focused Windows Release smoke contract pass 12/12; another fresh signed
  elevated run is required.
- Fresh signed run `3758b573417e4bacbb52ee7a2d1a7d28` passed all four direct ZIP
  lanes, the elevated helper, and both protected locators (7/7). Inno compiled,
  signed, and validated the 3.1.2 feed, but the protected helper registration
  returned exit code 5 and the exact 3.1.2 endpoint assertion remained RED.
  The retained result is `final-elevated-lanes-result.json`, with the run
  transcript in `protected-inno-elevated.log` and the bounded driver output in
  `final-protected-inno-driver.log`.
- A bounded signed registration probe retained
  `protected-endpoint-registry-view-probe.json`: the exact helper returned exit
  code 5 and no endpoint record appeared in Default, Registry64, or Registry32
  views. The policy then contained only the application install root, while
  the helper was intentionally installed in a separate protected
  `DesktopUpdaterHelperGenerationV1--...` root. The smallest fix adds that
  exact helper root to `allowedInstallRoots`; the focused smoke contract passes
  13/13.
- Fresh signed run `ddaa5d607e174cde819b7b26194641cb` passed all four direct ZIP
  lanes, the elevated helper, and both protected locators (7/7), but the
  protected Inno registration remained RED after the policy-root correction.
  The package-matched probe used the current `ab5d05994cfc4bc4b377e860d9391496`
  policy and still returned exit code 5 with no record in any registry view,
  ruling out the earlier probe's token mismatch and registry-view theory.
- The ACL/SDDL capture from the matching probe was structurally correct, but no
  registry key was created. Source inspection then identified the remaining
  mismatch: the signing hook deliberately emits one final LF while the native
  `ReadPolicy` path hashed and canonical-compared that LF as policy content.
  The durable fix strips exactly one final LF before canonical parsing and
  policy hashing; focused regressions and a fresh signed rerun remain required.
- Fresh signed run `56928080de93402fa62f443ebe947939` passed all four direct ZIP
  repetitions, the elevated helper probe, and both ARM64 protected locators
  (7/7). Its protected Inno lane compiled, signed, published, and validated the
  3.1.2 feed, then failed before the version assertion because the matched
  uninstall record had no `DisplayVersion` property. The failed wrapper result
  and Inno transcript are preserved as
  `final-elevated-lanes-result-red-56928080.json`,
  `final-protected-inno-driver-red-56928080.*`, and
  `protected-inno-elevated-red-56928080.log`; the bounded Inno result is
  `inno-e2e-6e9eb75cf7404e798ffff8ef4154d8e5/result.json`.
- The generated Inno script relied on implicit Inno uninstall metadata for
  `DisplayVersion` while explicitly writing only package, install-location, and
  build fields. The smallest durable fix adds an installer-owned explicit
  `DisplayVersion` registry value from `metadata.version`; the focused packager
  and Windows smoke regression matrix passes 19/19. A fresh signed rerun is
  required.
- The empty-marker RED `d08278de968b46b3a094f7bf1fc2f768` reproduced a race in
  `Invoke-InstalledAppUpdate`: an existing marker file could be observed before
  its `installing` content was written. The bounded content predicate now
  handles the empty read; the focused regression passed 15/15 and the widened
  Windows smoke contract currently passes 17/17.
- Fresh protected-Inno diagnostic run `223501aa221d4b618068c7b6c5046f34`
  passed packaging but exited from the installed 3.1.2 app with the protected
  uninstall-record error. A Shell.Application retry `fdd7bd8876bd4eab9a49c5f74780519c`
  and token-proof retry `0f20ce81c1bb442483b5052f991e8a4e` retained RED evidence;
  the proof showed the child still had `High Mandatory Level`, so Shell.Application
  was not an unelevated launch boundary.
- The durable launcher now selects the same-user, same-session Explorer token,
  verifies Limited/Medium integrity and the user SID, and starts the PowerShell 7
  launcher through `CreateProcessWithTokenW`. The first two post-fix diagnostics
  (`ca20841d95c14a3080196a835995a7bb` and `439376a3da824ce0ac8689c948d38e31`)
  retained RED evidence because the duplicated token lacked the Windows host's
  required `TOKEN_ADJUST_DEFAULT | TOKEN_ADJUST_SESSIONID` access. The minimal
  mask was proven with all process-creation variants in
  `elevated-create-process-stages.txt`; the source contract and focused
  regression are green in `focused-inno-token-access-mask-green.log` (17/17).
- The remaining source-level elevated probe is blocked at the manual UAC
  boundary: fresh requests `uac-20260811-165112-29c00668` and
  `uac-20260811-165414-9cbd11f2` were rejected by the bridge with `OCR: no text
  recognized`, and exact consent PIDs had no targetable visible window. No UAC
  button, Enter key, credential, or trust bypass was automated.
- The approved signed run `4a57cfb58ca44d8db942dde461ba8ed2` produced one
  direct Debug GREEN followed by a direct Debug RED. The RED was not a Root
  consent, download, signature, stale-profile, or named-pipe-authority defect:
  the request reached preparation, but the client timed out reading the first
  reservation while portable `PrepareDurableJournal` waited on synchronous
  Task Scheduler `RunEx` and its direct fallback. The preserved comparison
  shows approximately 24.1 seconds for the GREEN path and approximately 29.1
  seconds to recovery-host readiness for the RED path.
- A 90-second portable timeout alone would hide scheduler variance and leave
  the synchronous call on the critical path. The durable fix starts the
  exact-token direct recovery host immediately after exact task
  registration/readback, keeps the task armed for future logon recovery, and
  retains readiness-before-mutation plus fail-closed early-exit checks.
- Focused source, native, and layout regressions are retained in
  `portable-startup-timeout-red-4a57cfb58ca44d8db942dde461ba8ed2.log` and
  `portable-direct-start-green-4a57cfb58ca44d8db942dde461ba8ed2.log`.
- Focused signed run `8fad5354c2c64ba2a87da046f9b59736` passed signer
  validation, disposable-user CurrentUser Root/TrustedPublisher provisioning,
  download, install scheduling, and initial app shutdown, then failed at
  backup rename with a prepared journal and no target activation. The
  five-second backup-start-to-failure interval matches the former eight
  sharing/lock retries; the exact external handle was not overclaimed.
- The durable retry change is fail-closed for all non-sharing/non-lock errors,
  keeps the retry bounded at roughly 30 seconds, and is covered by a native
  6.5-second child-handle regression. The test-design RED and corrected
  evidence are retained in `retry-regression-test-red.log`; Debug and Release
  affected matrices both pass 40/40.
- Flutter rebuilds initially hit two execution-environment boundaries: a
  case-variant `Path`/`PATH` MSBuild process environment and the sandbox
  account's inability to open the Flutter SDK lockfile. Both are retained in
  `build-environment-red.log` and `flutter-sandbox-lock-red.log`; the real
  `MARLONJD\\burak` Flutter 3.44.4 Debug/Release rebuilds passed and all four
  runner artifacts were re-signed and verified.
- The focused signed Debug rerun `41a972cb785b496ab5903b4aecb2ee35` converted
  the backup-sharing RED to GREEN: helper diagnostics recorded backup success,
  move success, cleanup success, and the installed sentinel. No task-owned
  process remained after the wrapper completed; the full four-run matrix is
  still required.
- The fresh signed Inno run `16540e48ca824a2c8b00639225dc8852` reached the
  installed app's `checking`, `downloading`, and `installing` states, then
  remained open after the update commit. `helperEventIds=[]`, the marker stayed
  `installing`, and the pending transaction was preserved. A task-owned
  `consent.exe` was observed without a visible target window, while exact
  Program Files, endpoint, transaction, process, and profile residue audits
  were clean after the bounded stop.
- The absence of any helper protocol event localized the wait to the protected
  synchronous `ShellExecuteExW` elevation call rather than helper policy or
  installer mutation. Both protected launch paths now use `SW_SHOWNORMAL` so
  the user can manually approve the real consent UI; no trust, ACL, UAC, or
  credential bypass was introduced.
- The corrected rerun `1b4823c66aba444385263004d2600fef` proved that the
  `SW_SHOWNORMAL` source change is packaged and exercised: protected policy,
  3.1.2/3.1.3 signing, local feed publication, and update selection all passed,
  and `consent.exe` was live during the install handoff. The Windows secure
  desktop exposed no targetable visible window in this VM session, so the user
  could not perform the required manual approval; `helperEventIds=[]`, the
  marker remained `installing`, and the smoke timed out. This is an external
  interactive-UAC boundary, not evidence to weaken the product.
- The first final serial Flutter suite reached `835` passes, `17` skips, and
  one failure in `linux_helper_strategy_scope_test.dart`: its repository-wide
  artifact-name scan traversed a retained Inno Pub cache whose child path had
  already been removed. The focused RED is retained in
  `final-linux-helper-scope-red-20260812.log`. Bounding the scan to canonical
  source roots preserved the no-Linux-artifact assertion; the focused test
  passed `4/4`, and the full rerun passed `838/838` with `17` skips.
- The current ARM64 postfix native build initially exposed a parallel GoogleTest
  discovery timeout and the first CTest invocation lacked the workflow fixture
  environment. Those are retained as invocation/harness RED evidence; serial
  Debug and Release builds followed by fixture-backed CTest passed `192/192`
  with four expected skips in each configuration. The regenerated bounded PE
  audit found `60/60` native outputs at `0xAA64`.
- The separate forged MethodChannel run first hit the tool's default short shell
  timeout while building the cached Windows example; no test result was emitted
  and the child process was reconciled. With the explicit extended timeout it
  completed `1/1`, and the full integration run independently passed `3/3`.
- Final residue checks found no matching disposable account/profile, task-owned
  process, protected endpoint/transaction key, uninstall record, or current
  Inno Program Files root. One `DesktopUpdater-Portable-*` scheduled task and
  its user-local recovery-host path predated this continuation; ownership could
  not be proven from retained evidence, so it was not deleted.
- The first current-certificate protected-Inno build
  `cedb1bff487d45ddb8690f46b9e65ed0` produced valid signed 3.1.2/3.1.3
  installers and feed bytes. A manual-consent timeout was preserved without
  treating it as a product failure. Bounded replay then exposed two harness
  assumptions before reaching product code: long replay roots exceeded an
  Inno/path budget, and a new random server port could not satisfy absolute
  URLs frozen into the signed app archive.
- Replay now uses a short independent runtime root and accepts only the exact
  common port encoded by two canonical
  `http://127.0.0.1:<port>/releases/<version>/windows/release.json` entries.
  It does not rewrite signed metadata and refuses an occupied retained port.
  Parser validation and the focused replay contract are GREEN.
- Replay `b6ac642901c1414a9162360bec2a7f65` reached the helper and preserved the
  original one-shot failure with redacted event IDs `1047` and `1051`.
  Descriptor shape, artifact hash/length, and Authenticode identity independently
  matched. The remaining payload-preparation path reopened both the staged
  installer and its protected copy despite already retaining authoritative
  handles, repeating the ARM64-sensitive reopen/TOCTOU defect previously fixed
  in helper bootstrap and payload verification.
- Protected Inno restaging now obtains Authenticode, hash, file ID, final path,
  and post-verification identity from the exact retained source/copy/recovery
  handles. The textual regression is RED-to-GREEN, the focused Windows contract
  passes `23/23`, and the ARM64 Debug authorizer matrix passes `8/8`; a freshly
  rebuilt signed end-to-end run remains the promotion gate.
- The same diagnostic run exposed two independent harness cleanup/reporting
  defects after the product RED: Inno's self-delete briefly held `unins000.exe`,
  and the Windows PowerShell 5.1 dispatcher reported child exit `0`. Cleanup now
  retries only an already validated task-owned Program Files root for 15 seconds,
  and the dispatcher uses `Start-Process -Wait -PassThru`. The exact stale root
  was removed through a fresh signed UAC request after proving no live process
  and the intended Administrators-owned ACL.
- Fresh signed run `f29d3b46e1f04445a6aa87bf62f12163` advanced beyond the
  retained-installer-handle defect and emitted `1047`/`1050`. Its preserved
  stage proved that the descriptor, provenance, and installer bytes were
  internally consistent. The stage directory was 230 characters, but
  `.desktop_updater_release_manifest.json` made the opened path 269 characters.
  `VerifyStageProvenance` already used an extended-length path and succeeded;
  the helper's immediately following raw `CreateFileW` did not. With
  `LongPathsEnabled=0`, the new native regression reproduced the exact
  `helper metadata file is unavailable` failure before the product fix.
- Fresh signed run `616f9c50f2764045b607f4340fd1e71b` advanced through that
  269-character manifest and emitted `1000`/`1003`/`1051`/`1047`. Its retained
  installer path was only 244 characters, and its length, SHA-256, certificate,
  and Authenticode publisher all matched the signed release. The next operation
  opened the TrustedInstaller-owned `C:\Program Files` parent with
  `WRITE_DAC`/`WRITE_OWNER`, while the directly applicable Administrators ACE
  grants only `Modify, Synchronize`; the exact old access mask failed against a
  Modify-only native fixture before the least-privilege fix.
- Fresh signed run `adadb98949c1436893322059fd9aa6fc` did not reach the new
  parent-access code: after the complete 3.1.2 build/package/install/feed phase,
  its 3.1.3 `flutter build windows` failed because the example's plugin test
  target ran GoogleTest discovery as a production-build POST_BUILD action with
  a five-second deadline. The DLL copy completed with identical SHA-256, the
  CTest list was absent, and the same x64 test binary plus generated discovery
  command immediately passed in isolation. Production packaging therefore had
  an unnecessary transient dependency on test-process startup; PRE_TEST keeps
  discovery mandatory at CTest execution while removing that coupling.
- Fresh run `4672616b26ab4c69962715955370537d` began from the post-fix source,
  generated a fresh DPAPI-backed key profile, and entered the 3.1.2 Flutter
  build. The task was then intentionally interrupted. Because the launcher
  marker never advanced and no result file exists, the preserved work root is
  incomplete evidence only; the later zero-residue audit prevents it from being
  misclassified as either a product failure or a completed gate.

## Decision Log

- 2026-08-15: Treat commit `main`/push authority as a checkpoint publication,
  not permission to create or switch branches or open a pull request. Exclude
  generated build/cache/evidence trees and DPAPI key material from Git.
- 2026-08-15: The latest self-signed identity expired before continuation.
  Remove it from all three authorized CurrentUser stores and require fresh user
  authority for any future signed lane; never silently substitute an identity.
- 2026-08-12: Keep the example's Windows plugin tests enabled, but use
  `gtest_discover_tests(... DISCOVERY_MODE PRE_TEST)`. A production Flutter
  build must compile the test target without executing it as a packaging
  post-build action; Debug/Release CTest remains the authority that discovers
  and runs the tests.
- 2026-08-10: The user accepted ARM64 as the sole architecture gate for this
  local qualification; AMD64 is intentionally not run.
- 2026-08-10: Keep global/provider-backed production attestation distinct from
  the requested local ARM64 production-readiness result.
- 2026-08-10: Work remains confined to the isolated v3.1.3-root checkout and
  may fix reproduced defects locally without branch, commit, push, release, or
  GitHub operations.
- 2026-08-10: Use real ARM64 MSVC output and execution for native architecture
  evidence. Run the repository-required Flutter surface on this ARM64 host with
  Flutter's only available x64 Windows engine, label it as emulated target-host
  compatibility, and do not add an AMD64 host or AMD64-only qualification lane.
- 2026-08-10: Run Flutter commands outside the workspace sandbox solely because
  the installed Flutter launcher needs its SDK-local cache lock. Keep every
  repository workdir and task output inside the isolated checkout.
- 2026-08-10: Preserve the literal root format/analyze RED as scope-pollution
  evidence, but qualify current tracked source with explicit canonical roots
  and a fresh tracked-source analysis copy rather than deleting historical
  evidence.
- 2026-08-10: Keep one dedicated Windows ARM64 worker and one uniquely named
  TEMP/LOCALAPPDATA/log set per Flutter invocation. Treat any other runner as a
  duplicate only after its full parent/child command ownership is verified.
- 2026-08-10: Give only the helper-contract tests that launch multiple Dart
  subprocesses explicit time budgets: two minutes for fixture generation,
  valid validation, and canonicalization, and five minutes for the 46-case
  invalid matrix. Assertions and security coverage remain unchanged.
- 2026-08-10: Do not relax the Administrators/SYSTEM-owned protected registry
  ACL to make a medium-integrity unit test pass. Mark the exact ACL-dependent
  orchestrator as elevation-required and require a separate signed-UAC run of
  the same ARM64 test before closing the elevated milestone.
- 2026-08-10: Parameterize only the NuGet native asset RID and keep `win-x64`
  as the existing default. Local ARM64 qualification passes `win-arm64`
  explicitly; no AMD64-specific gate is added.
- 2026-08-10: Do not mutate CurrentUser trust, fabricate a publisher identity,
  reuse an unrelated signing identity, or enable unsigned bypasses without
  fresh explicit authority. Continue every non-signing gate and report the
  exact signed-lane boundary separately.
- 2026-08-11: Keep same-user portable helper authority limited to directory
  and single-file replacement. The Inno installer handoff requires the
  protected helper, `requiresElevation: always`, a signed descriptor, a fixed
  certificate SHA-256 allowlist, exact safe arguments, and post-install
  executable plus uninstall-record verification.
- 2026-08-11: Treat installed executable SHA-256 and build number as signed
  Inno release authority. Do not infer a successful desired installation from
  publisher name and semantic version alone.
- 2026-08-11: Keep the test policy for protected Inno separate from the existing
  directory-replacement fixture. This makes the strategy/provider grant
  explicit and prevents a broad test-only helper authority from hiding product
  wiring defects.
- 2026-08-11: Do not partially land privileged authorizer or signing-hook
  behavior while approval is absent. Retain the focused evidence, keep the
  existing production boundary unchanged, and resume the coupled
  schema/authorizer/signing work only after explicit authority.
- 2026-08-11: The user explicitly authorized the persistent transaction schema
  transition from 3 to 4 and a task-scoped self-signed certificate in
  `CurrentUser/My`, `CurrentUser/Root`, and `CurrentUser/TrustedPublisher`, with
  complete removal at task end. This authority is limited to the isolated
  Windows ARM64 qualification and does not create a production publisher
  identity.
- 2026-08-11: Write only persistent schema 4, but retain strict read-only
  recovery of already durable schema-3 `directoryReplace` records. On the
  first required mutation, persist the normalized schema-4 form; never infer
  `windowsInno` authority from a schema-3 record.
- 2026-08-11: Keep the low-privilege Inno transport smoke as separate coverage
  instead of deleting it. Bind the production-style Inno claim to the
  dispatch-only self-hosted UAC job, signed hook, protected helper policy, and
  Program Files harness.
- 2026-08-11: Treat a canonical path as diagnostic metadata, not a replacement
  for an already authorized open file handle. Bootstrap, recovery copying, and
  staged-payload Authenticode verification must retain and revalidate the same
  handle so ARM64 emulation cannot turn a transient path reopen failure into a
  false trust failure or TOCTOU window.
- 2026-08-11: Keep `signedDescriptor`'s nullable Inno executable arguments
  required at every call site. Non-Inno callers must pass explicit `null`, so a
  future artifact-kind change cannot silently inherit ambiguous authority.
- 2026-08-11: Keep the direct-smoke control root short, but place a disposable
  standard user's TEMP under its own `AppData/Local/Temp`. Do not solve path
  length by granting that SID access to repository ancestors, because the
  product's component-by-component staged-path authorization must remain
  fail-closed.
- 2026-08-11: Run package validation from a fresh tracked-source export when
  preserved untracked evidence would enter the archive. This proves the actual
  candidate without deleting evidence or weakening the publish validator.
- 2026-08-11: Audit Flutter runner signatures and ARM64-host execution separately
  from native PE architecture. Expect `0x8664` only for Flutter's supplied
  Windows engine and require `0xAA64` for the explicit native ARM64 matrix.
- 2026-08-11: Provision temporary trust for each disposable direct-smoke user
  only after verifying both source signatures, the exact certificate SHA-256,
  and the exact publisher. Keep the trust in that disposable user's
  CurrentUser Root/TrustedPublisher stores, require the real Windows consent
  dialog for the self-signed Root, and never bypass or automate that consent.
- 2026-08-11: At the user's request, stop the waiting run and hand off to a new
  thread. Preserve its RED evidence and the still-task-scoped operator
  certificate; the next thread must create a fresh UAC request, never reuse the
  completed/expired request, and remove the certificate from all three operator
  CurrentUser stores only after the entire task is complete.
- 2026-08-11: Corrected the continuation certificate inventory after finding a
  PowerShell provider-path escaping error; the original task certificate was
  still present, so no signed lane had used a falsely absent identity.
- 2026-08-11: The user explicitly authorized a replacement non-exportable
  CurrentUser-only signing identity. The replacement was installed in My,
  Root, and TrustedPublisher with manual Root consent; its public staging file
  was removed and no private key was exported.
- 2026-08-11: Keep protected Inno's exact executable-relative-path requirement
  fail-closed. The local example harness must pass its known
  `desktop_updater_example.exe` path explicitly; do not infer a Windows binary
  name from Dart metadata or weaken the packager's validation.
- 2026-08-11: Keep the direct-smoke Root enrollment a real manual consent
  boundary. The exact warning may be focused for visibility, but no Enter,
  button click, credential, LocalMachine trust, or policy bypass is allowed.
- 2026-08-11: Preserve the protected Inno executable-path requirement through
  every adapter boundary. An explicit CLI override is authoritative for a
  Flutter project; do not infer the binary name or relax the packager guard.
- 2026-08-11: Treat a post-relaunch Windows smoke DLL deletion race as a
  harness cleanup timing defect only after the update sentinel, helper event
  sequence, and process cleanup evidence pass. Retry removal only inside the
  exact task-owned root for a bounded interval; never weaken relaunch identity
  matching or convert cleanup failure into success.
- 2026-08-11: Keep the generated Inno script compatible with the installed
  Inno Setup compiler by declaring `GetFileAttributesW` explicitly through
  the Windows kernel32 external-function boundary. Preserve the existing
  reparse-point rejection and test the emitted declaration; never remove the
  path safety check to make ISCC compile.
- 2026-08-11: Compare protected endpoint and uninstall paths using the same
  bounded `\\?\`-aware normalization as the native final-path identity. Do not
  weaken endpoint binding; only normalize representation before exact equality.
  Treat unrelated uninstall records as non-matches when their optional custom
  values are absent, while retaining exact matching and removal for the task's
  own record.
- 2026-08-11: Treat a null result from reading an unrelated uninstall key as a
  non-match before reflecting optional task-specific values. Keep exact
  matching/removal fail-closed for records that are readable and carry the
  task's package ID and install root.
- 2026-08-11: Keep the protected Inno policy explicit about both trusted
  application and helper-generation roots. The helper is installed outside
  the application directory by design; adding its exact protected Program
  Files root preserves the sealed-root check and fixes registration exit 5
  without broadening authority to a parent directory.
- 2026-08-11: Keep the protected policy's one final LF as a transport
  terminator, but exclude it from canonical policy parsing, digest binding, and
  endpoint identity. The native reader must strip exactly that terminator so it
  agrees with the signing hook's LF-aware digest contract; no arbitrary
  whitespace is accepted.
- 2026-08-11: Treat the generated Inno uninstall record's `DisplayVersion` as
  installer-owned authority. Write the exact release metadata version in the
  generated `[Registry]` section instead of relying on implicit Inno uninstall
  metadata, and retain the native/smoke exact-version assertions.
- 2026-08-11: Do not use Shell.Application as an unelevated boundary from an
  elevated caller. The retained token proof showed the child remained High
  integrity. Use the same-user Explorer token only after verifying session,
  Limited elevation type, Medium integrity, and SID equality.
- 2026-08-11: Keep the duplicated token access mask minimal for
  `CreateProcessWithTokenW`: `TOKEN_ASSIGN_PRIMARY | TOKEN_DUPLICATE |
  TOKEN_QUERY | TOKEN_ADJUST_DEFAULT | TOKEN_ADJUST_SESSIONID`. The ARM64 host
  rejected the narrower mask with access denied and accepted this exact mask;
  do not broaden it to `TOKEN_ALL_ACCESS`.
- 2026-08-11: Treat `OCR: no text recognized` from a fresh UAC bridge request as
  an external manual-consent/UI boundary. Do not reuse the rejected request,
  automate consent, or claim the elevated source probe passed until a visible
  exact UAC prompt is manually approved.
- 2026-08-11: Treat direct execution of `run-final-elevated-lanes.ps1` by
  Windows PowerShell 5.1 as a harness entrypoint error: the wrapper uses
  PowerShell 7/.NET APIs such as `SHA256.HashData`, while the signed UAC host
  must remain Windows PowerShell. Use the bounded
  `start-final-elevated-pwsh.ps1` dispatcher and keep a contract test for that
  boundary; do not make the final wrapper silently downgrade its runtime.
- 2026-08-11: Keep the `/FS` build workaround scoped to
  `desktop_updater_install_helper_support` after the isolated Debug Flutter
  rebuild reproduced MSBuild C1041 on its shared PDB. The focused Windows SDK
  contract passes, and no security or runtime policy was changed.
- 2026-08-11: Preserve the signed Debug run
  `4a57cfb58ca44d8db942dde461ba8ed2` portable reservation-timeout RED and
  trace it to synchronous Task Scheduler `RunEx` latency racing the first
  reservation response deadline. Keep exact task registration/readback and
  durable recovery authority, move current-session startup to the already
  validated exact-token direct host, separate the bounded portable 90-second
  budget from the protected 30-second budget, and require a fresh signed
  direct ZIP rerun before promoting the source to end-to-end GREEN.
- 2026-08-11: Do not reuse the expired continuation certificate
  `FCEA9027A916953E338E3E3476E2399C052B9F9B`. After the user's renewed
  authority, create the new non-exportable CurrentUser-only identity
  `2DD3E73FF663ECE1BA78B9788E35192926A3823F`, require manual Root consent,
  and bind all new signed lanes to its exact publisher and DER SHA-256.
- 2026-08-11: Keep the portable backup-rename retry fail-closed and bounded;
  increase only the sharing/lock retry budget from 8 to 32 after the focused
  signed RED showed a transient target-child handle lasting beyond the old
  five-second window. Require the native delayed-handle regression in both
  ARM64 configurations before rerunning signed lanes.
- 2026-08-11: Treat focused signed run
  `41a972cb785b496ab5903b4aecb2ee35` as the required post-fix promotion gate;
  its backup/move/cleanup GREEN permits widening, but does not by itself
  attest the complete Debug/Release, helper, locator, or protected-Inno lanes.
- 2026-08-12: Treat signed focused Inno run
  `16540e48ca824a2c8b00639225dc8852` as a preserved harness/UI RED, not a
  policy or transaction-authority failure: no helper protocol event was
  emitted, the app remained in `installing`, and exact task residue was absent.
  Keep manual consent mandatory and make the two protected `runas` launch
  windows visible with `SW_SHOWNORMAL`; do not weaken trust, ACL, or UAC
  boundaries.
- 2026-08-12: After the `SW_SHOWNORMAL` fix, run
  `1b4823c66aba444385263004d2600fef` confirmed that the protected consent
  process starts and all package/feed/signing preparation passes, but the VM
  still does not expose the secure-desktop UI for manual approval. Stop this
  repetition loop at the genuine interactive-UAC boundary; require a visible
  user-approved consent before promoting protected Inno or final elevated lanes.
- 2026-08-12: Treat the serial/fixture-backed ARM64 postfix matrix as the
  authoritative native result (`192/192` Debug and Release, four expected
  skips each, `60/60` native `0xAA64` PE audit) and the refreshed Flutter
  surface as GREEN (`17/17` plugin CTest per mode, `3/3` integration, `1/1`
  forged payload). Do not infer protected-lane success from package/feed
  preparation when manual secure-desktop consent remains unavailable.
- 2026-08-12: Reuse retained signed Inno artifacts only through a bounded replay
  that validates every artifact/release byte and preserves the absolute
  loopback port frozen into signed metadata. Never rewrite the signed archive,
  borrow another port, or stop an unrelated process occupying that port.
- 2026-08-12: Apply the repository's retained-handle trust rule to protected
  Inno restaging and recovery cleanup. A canonical path remains diagnostic
  metadata; it must not replace an already opened, identity-bound installer
  handle for Authenticode or post-verification checks.
- 2026-08-12: Treat Inno uninstaller self-delete as a cleanup race only inside
  an exact prevalidated task root and with a bounded retry. Preserve cleanup
  failure after the budget, and require the signed Windows PowerShell dispatcher
  to propagate the PowerShell 7 child exit code explicitly.
- 2026-08-12: Apply the existing shared Windows extended-length path conversion
  to helper metadata reads without weakening reparse, file-type, size, or
  sharing checks. Keep the 269-character stage-marker regression in the native
  authorizer suite so long retained evidence roots cannot reintroduce a hidden
  `MAX_PATH` dependency.
- 2026-08-12: Treat the protected Inno parent directory as a retained container
  handle, not as a security-descriptor mutation target. Request only
  `FILE_LIST_DIRECTORY`, `FILE_ADD_FILE`, `FILE_TRAVERSE`,
  `FILE_READ_ATTRIBUTES`, and `SYNCHRONIZE`; preserve the exact child ACL,
  reparse rejection, retained-handle Authenticode, digest, and identity checks.

## Command And Evidence Ledger

The source boundary was verified with:

```powershell
git status --short --branch
git rev-parse HEAD
git rev-parse origin/main
git rev-parse 'v3.1.3^{}'
```

All three revisions were
`5b295cb68721038cb89a5cc1af6c4a2c55b94a1b`; only this plan, its index link,
and task evidence were present. The current executable matrix starts with:

```powershell
flutter pub get
dart run tool/harness_gate.dart --structural
dart format --output=none --set-exit-if-changed .
flutter analyze --no-fatal-infos
flutter test --no-pub --concurrency=1
dart pub publish --dry-run

cmake -S windows/native -B <arm64-debug-build> -A ARM64 -DDESKTOP_UPDATER_NATIVE_BUILD_TESTS=ON -DDESKTOP_UPDATER_NATIVE_RUNTIME=ON
cmake --build <arm64-debug-build> --config Debug
ctest --test-dir <arm64-debug-build> -C Debug --output-on-failure --no-tests=error
cmake -S windows/native -B <arm64-release-build> -A ARM64 -DDESKTOP_UPDATER_NATIVE_BUILD_TESTS=ON -DDESKTOP_UPDATER_NATIVE_RUNTIME=ON
cmake --build <arm64-release-build> --config Release
ctest --test-dir <arm64-release-build> -C Release --output-on-failure --no-tests=error
cmake --install <arm64-release-build> --config Release --prefix <arm64-install>
```

Run-specific installed CMake, .NET/NuGet, durable-state, transport,
Flutter/plugin/integration, ZIP, Issue #70, helper, Inno, and UAC commands and
their counts are appended here as the lanes execute. Fresh retained evidence
belongs under `_windows_arm64_readiness_evidence/` and the scripts' bounded
`reports/` paths.

Fresh secretless evidence recorded so far:

```text
flutter pub get                                      PASS (13.0 s combined with structural gate)
dart run tool/harness_gate.dart --structural         PASS (31/31 canonical rows)
dart format --output=none --set-exit-if-changed .    RED  (exit 65; retained untracked copies)
dart format --output=none --set-exit-if-changed
  bin example/lib example/integration_test
  example/tool lib test tool                         PASS (277 files, zero changes; 1.06 s)
flutter analyze --no-fatal-infos                     RED  (478.5 s; retained untracked copies)
flutter test --no-pub --concurrency=1
  test/native_install_helper_contract_test.dart
  test/release_cli/release_key_management_test.dart
  test/updater_controller_test.dart                  RED  (exit 1; 255.043 s; valid helper timeout)
```

The corresponding logs are
`_windows_arm64_readiness_evidence/01-flutter-pub-get.log`,
`02-harness-structural.log`, `03-dart-format-check.log`,
`03b-dart-format-tracked-roots.log`, `04-flutter-analyze.log`, and
`05b-focused-windows-regressions-rerun.log`. The interrupted `05` attempt is
retained but is not a test result.

Focused Windows fixes and standalone ARM64 native evidence:

```text
canonical JSON UTF-8 focused test                    RED -> PASS
Windows release-key local-store test                 RED -> PASS
Windows terminal recovery-marker test                RED -> PASS
invalid-request 46-process matrix                     PASS (5 min budget)
ARM64 Debug build                                     PASS (28 PE, all 0xAA64)
ARM64 Debug CTest                                     PASS (177/177, 4 skipped)
ARM64 Release build                                   PASS (28 PE, all 0xAA64)
ARM64 Release CTest                                   PASS (177/177, 4 skipped)
protected locator, medium integrity                   RED  (Win32 1307)
protected locator, explicit elevation prerequisite    PASS (skipped locally)
```

The focused RED/GREEN logs and native build/test inventories are under
`reports/windows-arm64-production-readiness/`, notably
`red-canonical-json.log`, `green-canonical-json.log`,
`red-release-key-permissions.log`, `green-release-key-permissions.log`,
`red-recovery-terminal-marker.log`, `green-recovery-terminal-marker.log`,
`green-invalid-request-matrix.log`, `red-arm64-protected-helper-status.log`,
`green-arm64-protected-helper-non-elevated.log`,
`native-arm64-debug-ctest-confirmed.log`,
`native-arm64-release-build.log`, `native-arm64-release-pe.txt`, and
`native-arm64-release-ctest.log`.

Installed consumers, package layout, helper, transport, and Flutter evidence:

```text
installed ARM64 CMake consumer CTest                 PASS (1/1; all PE 0xAA64)
.NET ARM64 P/Invoke VSTest                           RED -> PASS (15/15)
NuGet ARM64 runtime layout                           RED -> PASS (win-arm64 only)
NuGet regular/runtime consumers                      PASS (hash exact; PE 0xAA64)
durable-state cross-reader SHA-256                    PASS (5/5 exact)
unprivileged helper smoke                             PASS (47/47; 2 child skips)
Unicode/non-ASCII helper argument rejection           PASS (Win32 160)
native transport Debug and Release                    PASS (Unicode/redirect)
Flutter Windows Debug build/plugin CTest              PASS (17/17)
Flutter Windows Release build/plugin CTest            PASS (17/17)
forged raw MethodChannel test                         PASS (1/1)
full Windows integration matrix                       PASS (3/3)
local loopback release publish smoke                  PASS
v3 removed ARM64 C/C++ and .NET consumers             PASS (rejected)
```

Key retained logs include `native-arm64-installed-consumer-ctest.log`,
`dotnet-arm64-pinvoke-tests-final.log`,
`green-nuget-arm64-regular-consumer-verify-final.log`,
`green-nuget-arm64-runtime-consumer-verify-final.log`,
`native-arm64-durable-sha256.txt`,
`native-arm64-helper-unprivileged-smoke-ascii-final.log`,
`flutter-plugin-debug-ctest.log`, `flutter-plugin-release-ctest.log`,
`flutter-windows-forged-methodchannel-final.log`,
`flutter-windows-full-integration-final.log`,
`release-publish-smoke-windows-final.log`, and the two
`v3-removed-api-*-final.log` files under
`reports/windows-arm64-production-readiness/`.

Protected Inno, schema evolution, and workflow evidence added on the final
candidate:

```text
protected Inno local script contract                 PASS (8/8)
schema-3 frozen reader / schema-4 writer              PASS (22/22 ARM64)
current schema-4 fixture emit + verify                PASS (5 files)
workflow + protected Inno + frozen fixture contracts PASS (28/28)
```

The corresponding GREEN logs are
`protected-inno-smoke-contract-green.log`,
`schema4-legacy-reader-tests.log`,
`schema4-legacy-reader-tests.json`, and
`protected-inno-workflow-contract-green.log`. Focused RED evidence remains in
`protected-inno-smoke-contract-structure-red.log`,
`protected-inno-smoke-release-key-structure-red.log`, and
`protected-inno-workflow-boundaries-red.log`.

Signed Issue #70 retained-handle diagnosis and focused correction evidence:

```text
portable recovery retained-handle contract           RED -> PASS (1/1)
portable recovery ARM64 Debug matrix                  PASS (19/19)
signed missing-marker diagnostic after bootstrap fix PASS (attempt 31)
payload retained-handle Authenticode contract         RED -> PASS (1/1)
ARM64 Debug Authenticode native matrix                PASS (12/12)
diagnostic-free layout and native affected matrix     PASS (2/2, 31/31)
final exact missing-marker and matching-marker lanes  PASS (attempt 34)
```

The focused logs are
`issue70-retained-source-handle-red.log`,
`issue70-retained-source-handle-green-final.log`,
`issue70-retained-handle-arm64-debug-clean-build.log`,
`issue70-retained-handle-arm64-debug-ctest-clean-green.log`,
`issue70-helper-exit-attempt31.json`,
`issue70-retained-payload-handle-red.log`,
`issue70-retained-payload-handle-green.log`,
`issue70-retained-payload-handle-arm64-debug-build.log`, and
`issue70-retained-payload-handle-arm64-debug-ctest.log`. All temporary stage
instrumentation was then removed. The diagnostic-free proof is in
`issue70-post-diagnostics-layout-green-final.log`,
`issue70-post-diagnostics-arm64-debug-build.log`, and
`issue70-post-diagnostics-arm64-debug-ctest.log`; the exact final signed control
is `_issue70_evidence/issue70-e2e-attempt34-result.json`, with the driver in
`final-issue70-exact-attempt34-driver.log`, all under
`reports/windows-arm64-production-readiness/`.

The standard-user profile cleanup defect is preserved in
`direct-smoke-user-profile-residue-red.json` and
`direct-smoke-user-profile-cleanup-contract-red.log`; the focused contract
GREEN is `direct-smoke-user-profile-cleanup-contract-green.log`. Elevated
removal of the exact orphaned task profiles and repeated real-smoke proof remain
part of the final UAC lane.

Fresh clean-build and tracked-source quality evidence:

```text
ARM64 Debug clean build / CTest                     PASS (30 PE; 189/189, 4 skips)
ARM64 Release clean build / CTest                   PASS (30 PE; 189/189, 4 skips)
combined clean native PE audit                      PASS (60/60 at 0xAA64)
one-shot aggregate initializer regression           RED -> PASS (3/3)
tracked Dart format                                 PASS (278 files, zero changes)
macOS PKG descriptor caller contract                RED -> PASS (12/12)
Inno builder required executable-path contract      RED -> PASS (8/8)
fresh tracked-source Flutter analyze                PASS (0 errors, 0 warnings,
                                                          674 non-fatal infos)
```

The retained logs are `windows-one-shot-aggregate-clean-build-red.log`,
`windows-one-shot-aggregate-focused-build-green.log`,
`windows-one-shot-aggregate-focused-ctest-green.log`,
`desktop-runtime-transport-focused-red.log`, `final-arm64-debug-clean-build.log`,
`final-arm64-debug-ctest.log`, `final-arm64-release-clean-build.log`,
`final-arm64-release-ctest.log`, `final-arm64-pe-audit.json`,
`final-dart-format.log`, `final-flutter-analyze-macos-descriptor-red.log`,
`macos-pkg-descriptor-contract-green.log`,
`final-flutter-analyze-inno-builder-red.log`,
`inno-script-builder-required-path-green.log`, and
`final-flutter-analyze.log` under
`reports/windows-arm64-production-readiness/`.

Final package, plugin, integration, and target-host evidence now recorded:

```text
full serial Flutter suite                           RED -> PASS (823 pass,
                                                           17 expected skips)
structural harness                                  PASS (31/31 rows)
tracked-source publish dry-run                      PASS (0 warnings; no publish)
Flutter plugin Debug CTest                          PASS (17/17)
Flutter plugin Release CTest                        PASS (17/17)
Windows integration matrix                          PASS (3/3)
forged MethodChannel focused integration            PASS (1/1)
Flutter Windows Release build                       PASS
temporary Authenticode signature audit              PASS (4/4 valid)
Flutter runner execution on ARM64 host              PASS (4 x 0x8664 artifacts)
native ARM64 architecture audit                     PASS (60/60 x 0xAA64)
git diff --check after bounded LF normalization     PASS
```

The fresh signed rerun before the cleanup retry is recorded separately:

```text
direct Flutter ZIP Debug run 1                    PASS (exit 0)
direct Flutter ZIP Debug run 2                    PASS (exit 0)
direct Flutter ZIP Release run 1                  RED (exit 1; cleanup-only)
focused cleanup regression after RED              PASS (24/24)
```

The Release RED log is
`final-direct-release-run-1-d3fd2de90e74405ca9867752a98bb1b6/final-direct-release-run-1.log`;
its helper diagnostics and report show the update sentinel and helper
`cleanup success` before the bounded `flutter_windows.dll` deletion failure.

The subsequent signed run reached the next independent protected-Inno RED:

```text
fresh signed direct/helper/locator lanes           PASS (7/7)
protected Inno ISCC compile                       RED (`GetFileAttributes` unknown)
generated Inno declaration regression              PASS (9/9)
```

Its exact ISCC output is retained in
`final-protected-inno-driver.stdout.log` and
`protected-inno-elevated.log`; the bounded Inno result is
`inno-e2e-7d734bd1645348cca55df8935e491d7a/result.json`.

The corresponding retained files are
`final-full-flutter-tests-merge-label-red.log`,
`native-runtime-merge-label-green.log`,
`final-full-flutter-tests-green.log`, `final-harness-structural.log`,
`final-publish-dry-run-root-pollution-red.log`,
`final-publish-dry-run.log`, `final-flutter-plugin-debug-ctest.log`,
`final-flutter-plugin-release-ctest.log`,
`final-windows-integration-debug.log`,
`final-windows-forged-methodchannel.log`,
`final-flutter-windows-release-build.log`,
`final-authenticode-signing.log`, and
`final-flutter-authenticode-audit.json` under
`reports/windows-arm64-production-readiness/`.

The direct-Flutter UAC path investigation is retained without weakening trust:
`final-elevated-lanes-long-path-red.json`,
`final-elevated-lanes-staging-path-red.json`,
`final-elevated-lanes-ancestor-acl-red.json`, their run-specific logs, and
`direct-smoke-profile-temp-contract-green.log`. Two expired consent dialogs
must be manually rejected before issuing a fresh signed request; no expired or
rejected bridge request will be reused.

The next fresh signed run exposed and then received the following focused
contract correction:

```text
fresh signed direct/helper/locator lanes           PASS (7/7)
protected Inno ISCC/package/feed validation       PASS
protected Inno endpoint assertion                  RED (\\?\ path form)
Windows/Inno path and cleanup contracts             PASS (20/20)
```

The bounded RED result is
`inno-e2e-6a89e342edbd4075946a979f4645eb53/result.json`; the exact transcript
is `protected-inno-elevated.log`, and the signed driver logs are
`final-protected-inno-driver.stdout.log` and
`final-protected-inno-driver.stderr.log` under
`reports/windows-arm64-production-readiness/`. The replacement path and
optional-registry-value fixes are source/test changes; no trust bypass or
LocalMachine certificate installation was used.

The follow-up signed run `0b610ed67cfc4aff8f0e0c46d48b6756` retained the same
7/7 direct/helper/locator GREEN and Inno package/feed GREEN before the null
uninstall-record RED. Its bounded runner root is preserved under `_w/` for
focused evidence; no task process was force-stopped.

Fresh signed run `3758b573417e4bacbb52ee7a2d1a7d28` retained 7/7 direct,
helper, and protected-locator GREEN, then reproduced the protected Inno
registration RED. The bounded registry-view probe recorded helper registration
exit 5 and no endpoint records in all three .NET registry views; its exact
Program Files probe path and registry records were cleaned in the same
elevated process. The policy-root correction is covered by the 13/13 focused
Windows smoke contract; the full signed Inno matrix must be rerun after a
fresh Debug/Release rebuild and fresh UAC request.

Portable startup timeout investigation and focused fix:

```text
signed Debug direct run 1                         PASS
signed Debug direct run 2                         RED (first reservation read timeout)
portable timeout root-cause evidence              retained RED
windows_native_sdk_layout_test                    PASS (23/23)
ARM64 Debug focused native CTest                  PASS (26/26)
ARM64 Release focused native CTest                PASS (26/26)
ARM64 Debug helper build                          PASS
ARM64 Release helper build                        PASS
```

The bounded RED/GREEN records are
`portable-startup-timeout-red-4a57cfb58ca44d8db942dde461ba8ed2.log` and
`portable-direct-start-green-4a57cfb58ca44d8db942dde461ba8ed2.log`.
The signed direct ZIP matrix has not yet been rerun against the new helper.

Current post-fix local evidence:

```text
ARM64 Debug native CTest with fixture              PASS (192/192; 4 skips)
ARM64 Release native CTest with fixture            PASS (192/192; 4 skips)
native PE audit                                    PASS (60/60 at 0xAA64)
Flutter Windows Debug plugin CTest                PASS (17/17)
Flutter Windows Release plugin CTest              PASS (17/17)
Windows integration matrix                        PASS (3/3)
forged MethodChannel focused integration          PASS (1/1)
bounded source format                             PASS (278 files; 0 changes)
focused Linux scope regression                    PASS (4/4)
full serial Flutter suite                         PASS (838; 17 skips; 0 failures)
fresh tracked-source analyzer                     PASS (0 errors; 0 warnings; 681 infos)
tracked-source publish dry-run                    PASS (0 warnings; no publish)
structural harness                                PASS (31/31)
git diff --check                                  PASS
```

The current evidence is retained in
`final-arm64-debug-ctest-with-transport-20260812.log`,
`final-arm64-release-ctest-with-transport-20260812.log`,
`final-arm64-pe-audit-postfix-20260812.json`,
`final-flutter-plugin-debug-ctest-postfix-20260812.log`,
`final-flutter-plugin-release-ctest-postfix-20260812.log`,
`final-windows-integration-postfix-20260812.log`,
`final-forged-methodchannel-postfix-20260812.log`,
`final-format-source-post-comment-20260812.log`,
`linux-helper-scope-focused-post-comment-20260812.log`,
`final-flutter-test-serial-20260812-rerun.log`,
`final-flutter-analyze-tracked-final4.log`,
`final-publish-dry-run-20260812.log`, and
`final-harness-structural-20260812.log` under
`reports/windows-arm64-production-readiness/`.

## Outcomes & Retrospective

Local non-UAC Windows ARM64 qualification is verified for the runnable gates;
the protected Inno and final elevated claim remains blocked at the genuine
manual secure-desktop UAC boundary. This is not a global/provider-backed
production attestation.

- The fresh signed run `4a57cfb58ca44d8db942dde461ba8ed2` is retained as
  Debug direct run 1 GREEN and Debug direct run 2 RED. The failure is isolated
  to the first portable reservation response deadline: synchronous Task
  Scheduler `RunEx` delayed the already-authorized direct recovery host on a
  credential-created standard user. No certificate, consent, download,
  policy, or stale-residue cause was found.
- The durable fix keeps the exact task registration/readback for future logon
  recovery, starts the validated exact-token direct host immediately for the
  current session, and preserves readiness-before-mutation plus fail-closed
  child-exit/timeout handling. Focused verification is 23/23 Dart layout
  contracts, 26/26 ARM64 Debug CTests, 26/26 ARM64 Release CTests, and
  successful ARM64 Debug/Release helper builds. Signed end-to-end verification
  remains pending.
- Inventory verified Windows 11 ARM64, PowerShell 7.6.4, Flutter 3.44.4, Dart
  3.12.2, Visual Studio 2022 17.14 with ARM64 and x64 C++ tools, Windows 11 SDK
  10.0.26100, CMake 3.31.6, Ninja 1.12.1, .NET SDK 9.0.315 with ARM64 host,
  Inno Setup 6, ARM64 and x64 SignTool, and user-scoped LLVM-MinGW Clang 22.1.8
  targeting `aarch64-w64-windows-gnu`.
- Current workflow and scripts were inventoried from
  `.github/workflows/desktop-updater-ci.yml`,
  `tool/windows_install_helper_smoke.ps1`,
  `tool/windows_direct_flutter_smoke.ps1`,
  `tool/windows_inno_smoke.ps1`, the NuGet consumer verifier, native runtime
  and transport servers, and the example update and publish smoke tools.
- Three Windows test portability defects and one emulation-sensitive timeout
  were corrected with focused RED/GREEN evidence. The production protected
  registry ACL was not weakened; its medium-integrity limitation is now an
  explicit prerequisite pending the signed-UAC proof.
- Standalone native Debug and Release ARM64 builds and CTest matrices pass on
  the final clean source: 30 PE files per configuration are `0xAA64`, and both
  189-test inventories complete with zero failures and four expected child or
  elevation skips.
- Installed CMake, .NET P/Invoke, ARM64 NuGet packaging/consumption, durable
  state, unprivileged helper, Unicode/redirect transport, Flutter build/plugin,
  integration, local publish, and removed-API lanes all pass on final source.
- Signed Authenticode authority is now explicit and the protected schema,
  authorizer, recovery, signing hook, local 3.1.3 harness, and workflow
  contracts are implemented. The authorized temporary identity is installed
  in the three CurrentUser stores and has already proven a complete diagnostic
  missing-marker update. Final clean direct ZIP/Issue #70 reruns, Inno, and
  elevated protected-install execution remain pending; no unsigned-policy
  bypass has been applied.
- Exact command results, fixes, evidence paths, residual boundaries, and final
  cleanup status remain to be recorded before this plan can complete.
- The latest protected Inno RED was rooted in policy authority rather than
  registry-view representation: the signed helper returned exit 5 because its
  separate protected helper-generation directory was absent from
  `allowedInstallRoots`. The signing hook now emits both exact roots, with the
  focused regression green; a fresh signed end-to-end rerun is still pending.
- The subsequent matching-policy probe ruled out stale-token, registry-view,
  and ACL-shape explanations: with the current package ID and both exact policy
  roots, registration still returned exit 5 in all three views, while the
  captured Program Files ACLs matched the intended SYSTEM/Administrators full
  and Users read-only policy. The native reader now strips the single final LF;
  focused regressions and a fresh ARM64 rebuild/sign/UAC/Inno rerun are required.
- Tracked Dart format covers 278 files with zero changes. Fresh tracked-source
  Flutter analysis exits zero with zero errors and warnings; its 674 infos are
  non-fatal under the repository's configured `--no-fatal-infos` gate.
- Focused Inno contract work now passes: Dart descriptor validation 21/21,
  Dart baseline/validate/packager 21/21, native ARM64 contract 1/1, protected
  Inno policy 3/3, and strict protected Inno journal 3/3. The helper execution
  and UAC lanes remain open.
- The widened protected-Inno descriptor/publish/validate/doctor matrix passes
  102/102. The clean ARM64 support rebuild and portable-successor regression
  pass 1/1. Evidence is retained in
  `reports/windows-arm64-production-readiness/inno-protected-contract-matrix-green.log`,
  `native-arm64-portable-successor-clean-rebuild.log`, and
  `native-arm64-portable-successor-clean-green.log`; the preceding stale-object
  failure remains in `native-arm64-portable-successor-diagnostic.log`.
- The focused protected-Inno policy authority test passes 1/1 on ARM64 Release.
  Its RED/GREEN evidence is retained in
  `red-protected-inno-policy-authority-build.log`,
  `protected-inno-policy-authority-build-green.log`, and
  `protected-inno-policy-authority-green.log`. The stale local smoke contract
  REDs are retained in `red-protected-inno-smoke-contract.log` and
  `red-protected-inno-workflow-contract.log` pending explicit signing/trust
  authority.
- Shared Windows persistent records are now strict schema 4 with an immutable
  transaction kind, journal-specific authority binding, and signed Inno
  relaunch semantics. ARM64 Release build evidence is in
  `schema4-focused-build-green.log`; the 30/30 GREEN and its preceding 29/30
  error-boundary RED are in `schema4-focused-tests-green.log` and
  `schema4-journal-error-boundary-red.log`.
- The Issue #70 helper failure was traced through signed end-to-end runs to
  canonical-path reopen calls on x64 Flutter/helper binaries under the ARM64
  host. Retaining the original helper/policy handles removed the recovery-host
  failure; retaining the staged executable handle through WinVerifyTrust and
  signer extraction removed the second reopen dependency. After all temporary
  diagnostic instrumentation was removed, the affected Dart/native matrices
  passed 2/2 and 31/31. The exact final signed attempt 34 then passed both the
  missing-marker adoption and matching-marker control, with verified handoff,
  exact artifact identity, and zero remaining task applications.
- The final serial Flutter suite passes 823 tests with 17 expected skips, the
  structural harness declares all 31 canonical rows, and a fresh tracked-source
  package dry-run reports zero warnings. Final Debug/Release plugin CTests pass
  17/17 each; the Windows integration matrix passes 3/3 and its isolated forged
  payload control passes 1/1.
- All four final Flutter application/helper artifacts are validly signed by the
  authorized temporary identity and run on the Windows ARM64 host. Their
  `0x8664` machine type is explicitly scoped to Flutter target-host
  compatibility; native architecture remains proven independently by 60/60
  `0xAA64` outputs.
- Work remains in progress. Fresh signed run
  `56928080de93402fa62f443ebe947939` passed the four direct ZIP repetitions,
  elevated helper, and both ARM64 protected-locator tests (7/7), then exposed
  the missing explicit Inno `DisplayVersion` field. The generated installer now
  writes that field and the focused 19/19 regression is green; the complete
  signed ARM64 matrix, protected Inno update/uninstall, final ladder, residue
  audit, and certificate removal remained at that checkpoint. All RED evidence
  is retained as bounded files. The task certificates
  `6020D3D7D056700CB2448817B74F5536D6D69E9E`,
  `F9B899F1F333A3ECE2C54A9587D709A39277B49B`,
  `FCEA9027A916953E338E3E3476E2399C052B9F9B`,
  `2DD3E73FF663ECE1BA78B9788E35192926A3823F`, and
  `B012539A7D55542BEDF3F9BC5C3D3F0CE3AA900E` were subsequently removed from
  all three CurrentUser stores; no LocalMachine trust was part of this task.
- Work remains in progress under the later user-authorized certificate
  `325D896A5D17AC6FF5FBF591DD8F3060BFB1AF7C`. The protected-Inno helper RED is
  now localized to and fixed at retained installer-handle restaging, with
  focused Dart `23/23` and ARM64 Debug native `8/8` GREEN. The identity expired
  on 2026-08-14 and was removed from CurrentUser My/Root/TrustedPublisher on
  2026-08-15, with all corresponding CurrentUser and LocalMachine counts
  verified zero. A fresh authorized identity, signed build containing the C++
  fix, protected install/update/relaunch/uninstall, and final matrix remain open.
- Fresh signed build/run `f29d3b46e1f04445a6aa87bf62f12163` then exposed the
  next real product RED at protected stage event `1050`. The retained 269-byte
  path-length case now has focused RED/GREEN evidence, and the helper uses the
  shared extended-length path representation before `CreateFileW`. ARM64 Debug
  and Release install-authorizer tests pass `9/9`; signed end-to-end promotion
  remains open.
- Fresh signed build/run `616f9c50f2764045b607f4340fd1e71b` passed the prior
  long-path stage and exposed the next real product RED at protected payload
  preparation. `protected-inno-parent-access-root-cause-red.json` retains the
  exact stage, installer, event, Authenticode, and `Program Files` ACL proof;
  `protected-inno-parent-access-arm64-red.log` reproduces the old mask failure.
  The least-privilege parent-handle fix passes focused `1/1` plus full ARM64
  Debug/Release `10/10` authorizer matrices. Fresh signed-build promotion
  remains open; replaying the preserved pre-fix helper would not test this
  source change.
- Fresh run `adadb98949c1436893322059fd9aa6fc` retained a separate pre-runtime
  RED: 3.1.2 completed, but the 3.1.3 production build was aborted by transient
  POST_BUILD plugin-test discovery before it could package the fixed helper.
  `protected-inno-plugin-test-discovery-root-cause-red.json` records the missing
  test list, matching Flutter-DLL hashes, and successful isolated rediscovery.
  The PRE_TEST contract passes focused `1/1`; Debug/Release builds now pass in
  `186.3s`/`81.6s`, followed by genuine plugin CTest `17/17` in each
  configuration. A new signed end-to-end run is still required to promote the
  protected Inno source fixes.
- Fresh run `4672616b26ab4c69962715955370537d` started that promotion from the
  post-fix source but was user-interrupted during the 3.1.2 build. It produced
  no result and is retained only as incomplete build evidence. The later audit
  found zero exact process/port/account/profile/Program Files/registry residue.
  The source changes are being checkpoint-committed and pushed with local ARM64
  production-readiness still explicitly incomplete.
- The continuation residue audit found no matching `duflutter`/`duzip`
  account/profile, live task-owned process, readiness port, or task-specific
  Program Files directory. A pre-existing `DesktopUpdater-Portable-*` scheduled
  task was observed but not removed because ownership by this exact continuation
  was not established.
- The latest source changes and evidence are still pending the final signed
  protected-Inno rerun: `tool/windows_inno_smoke.ps1` uses the minimal Explorer
  token mask, PowerShell parser and focused smoke config are green, and the
  standalone elevated stage proof passed. The actual source-level UAC probe has
  not been promoted to GREEN because the bridge could not OCR the consent UI.
- A fresh approved request `uac-20260811-170859-cc24f1d1` initially invoked
  `run-final-elevated-lanes.ps1` directly under Windows PowerShell 5.1 and
  failed before the first lane because `.NET Framework` lacks
  `SHA256.HashData`; the RED is preserved in
  `reports/windows-arm64-production-readiness/final-elevated-lanes-result-red-b55d9ddd74704efbb75816d031f94794.json`.
  The source-level launcher probe had already passed, and the durable fix is
  to use the existing signed UAC-to-PowerShell-7 dispatcher, now guarded by a
  focused contract test. No product lane result is inferred from this
  invocation error.
- The corrected dispatcher request `uac-20260811-171359-6cbfdef8` was rejected
  before elevation with `OCR: no text recognized`; it produced no lane or
  product evidence. A further fresh request requires the VM/UAC consent UI to
  be visible for the user's manual approval.
- Approved dispatcher run `uac-20260811-171607-d9b8cc9c` reached the first
  final lane, but `06f2ae72836c4292beea3e7095d74bf8` stopped before product
  execution because the Debug Flutter app artifact was absent. After that
  precondition was restored, the Debug rebuild reproduced MSBuild C1041 on
  `desktop_updater_install_helper_support.pdb`; the focused RED is retained in
  `debug-runner-rebuild-c1041-red.log`. Adding `/FS` to that MSVC target made
  the rebuild pass, and all four Debug/Release Flutter artifacts were
  re-signed and verified with the current certificate.
- The current focused rerun request is `uac-20260811-192020-ccfcfa8b`, with
  result `focused-direct-debug-41a972cb785b496ab5903b4aecb2ee35-result.json`.
  After the user manually approved the exact Root consent, it completed with
  exit code 0. Diagnostics recorded backup success, move success, cleanup
  success, and the installed sentinel; no task-owned process remained.
- The post-fix focused GREEN does not close the task: the four direct ZIP
  repetitions plus elevated helper, protected locators, protected Inno, final
  ladder, residue audit, and CurrentUser certificate removal remain pending.
- The focused Inno RED `16540e48ca824a2c8b00639225dc8852` is retained under
  `reports/windows-arm64-production-readiness/inno-e2e-16540e48ca824a2c8b00639225dc8852/`.
  Its result records the app-exit timeout, while `marker.txt`,
  `pending-install.json`, controller diagnostics, and the preserved work root
  show the exact `installing` handoff state. The source fix is
  `windows/native/src/helper/named_pipe_transport.cpp`; its focused contract
  is in `test/windows_native_sdk_layout_test.dart`. ARM64 Debug/Release build
  and 15/15 helper-auth/one-shot CTest evidence are retained in the
 `uac-visible-helper-*` logs.
- The corrected protected-Inno rerun is retained under
  `reports/windows-arm64-production-readiness/inno-e2e-1b4823c66aba444385263004d2600fef/`
  with its bounded work root at
  `reports/windows-arm64-production-readiness/work/inno-1b4823c66aba444385263004d2600fef/`.
  The result records successful 3.1.2/3.1.3 packaging, signing, feed
  validation, and `helperEventIds=[]` after the unavailable manual consent;
  exact app/helper/consent cleanup was completed by the smoke's bounded path.
- Final secretless evidence is retained in
  `reports/windows-arm64-production-readiness/final-flutter-analyze-tracked-final4.log`,
  `final-flutter-test-serial-20260812-rerun.log`,
  `final-harness-structural-20260812.log`,
  `final-publish-dry-run-20260812.log`,
  `final-linux-helper-scope-red-20260812.log`, and
  `linux-helper-scope-focused-green-20260812.log`. The fresh analyzer export
  is `_windows_arm64_analysis_src_final4`; the fresh publish export is
  `_windows_arm64_publish_src_final4`.
- The final post-fix ARM64/native/plugin/integration evidence is retained in
  the current postfix logs listed in the command ledger. Native Debug and
  Release CTest each passed `192/192` with four expected skips, and the
  authoritative native PE audit passed `60/60` at `0xAA64`.
- The exact current task certificate and four prior task identities were
  verified in CurrentUser/My, Root, and TrustedPublisher only; no exact task
  identity was found in LocalMachine. After the final audit, all five exact
  identities were removed from the three CurrentUser stores and rechecked
  absent. No private key was exported.
- The only residue intentionally retained outside the isolated evidence root
  is the ownership-unproven pre-existing `DesktopUpdater-Portable-*` task and
  its user-local recovery-host directory. It was not deleted because the task
  scope requires exact ownership before destructive cleanup.

## Retry And Recovery

- Preserve the first failing output before modifying code.
- Stop duplicate test runners before retrying a stateful lane.
- Reuse no expired UAC request and no prior temporary trust identity.
- Keep failed hostile/ambiguous recovery state until it is inspected; remove it
  only through the lane's verified bounded cleanup path.
- If a command changes tracked generated files, inspect exact diffs and restore
  only task-generated bytes with an explicit patch or command-specific cleanup.

## Revision History

- 2026-08-10: Created from exact `v3.1.3`/`main` baseline for the user-approved
  Windows ARM64 local production-readiness qualification.
- 2026-08-10: Recorded the complete Windows gate inventory, prerequisite
  versions, stale-process/port state, and the Flutter x64-on-ARM64 evidence
  boundary before executing fresh gates.
- 2026-08-10: Recorded the sandbox-only Flutter launcher stall, stopped the
  unauthorized stale publish process, reconciled the historical WMI ghosts,
  and added the initial exact command/evidence ledger.
- 2026-08-10: Recorded root-scope format/analyze pollution, duplicate-runner
  reconciliation, the captured Windows helper timeout RED, and the narrow
  subprocess-test timeout decision before focused reruns.
- 2026-08-10: Recorded the three focused Windows portability fixes, the
  invalid-request timeout proof, the protected-locator status-1307 elevation
  boundary, and passing 28-file/177-test ARM64 Debug and Release native lanes.
- 2026-08-10: Recorded installed ARM64 CMake/.NET/NuGet consumers, helper and
  durable-state results, NuGet RID and argument-conversion fixes, Flutter
  Debug/Release and integration evidence, local publish/removed-API gates, and
  the explicitly unauthorized Authenticode trust-store boundary.
- 2026-08-11: Replaced the stale Inno staging assumption with signed
  descriptor/feed coverage, added exact desired-executable and build identity
  to the release contract, and recorded passing focused Dart and ARM64 native
  policy/journal evidence before persistent-helper integration.
- 2026-08-11: Unified protected-Inno validation across Dart, C++, Swift, and
  publish configuration; recorded the 102/102 affected matrix and the clean
  ARM64 rebuild that eliminated a stale aggregate-layout object.
- 2026-08-11: Preserved the stale local Inno smoke RED and added the narrow
  protected-Inno test policy authority with a passing ARM64 1/1 regression;
  recorded that signing-hook preparation itself remains approval-gated.
- 2026-08-11: Recorded the reviewer-rejected production authorizer extension
  and removed its unimplemented test probe so no partial privileged behavior
  was left behind while approval remains pending.
- 2026-08-11: Recorded explicit user authority for schema 4 and the bounded
  CurrentUser test-signing identity; resumed the coupled protected-Inno
  implementation and signed local qualification.
- 2026-08-11: Implemented strict schema-4 transaction-kind dispatch, retained
  the portable directory-only boundary, normalized nested journal failures,
  and recorded the passing 30/30 ARM64 focused matrix.
- 2026-08-11: Added strict byte-exact schema-3 directory-record recovery with
  schema-4-on-mutation normalization, corrected current fixture naming, and
  recorded the passing 22/22 ARM64 reader plus current/legacy emitter proof.
- 2026-08-11: Added the environment-only Inno signing hook and bounded local
  3.1.2 -> 3.1.3 protected harness; separated the retained unprivileged CI
  transport smoke from the dispatch-only UAC lane and recorded 8/8 plus 28/28
  focused contract passes.
- 2026-08-11: Recorded the signed Issue #70 helper/recovery and staged-payload
  path-reopen failures, changed both trust-sensitive flows to consume retained
  handles, and captured focused 1/1 Dart, 19/19 portable-recovery, and 12/12
  ARM64 Authenticode GREEN evidence before removing diagnostic instrumentation.
- 2026-08-11: Removed all temporary Issue #70 stage instrumentation, rebuilt and
  re-signed the final candidate, and recorded the diagnostic-free 2/2 Dart,
  31/31 ARM64 native, and exact signed attempt-34 missing/control GREEN proof.
- 2026-08-11: Preserved the 32-profile standard-user smoke cleanup RED, added a
  shared SID/path-bounded `Win32_UserProfile` remover to both smoke paths, and
  recorded its focused contract GREEN before the final elevated cleanup run.
- 2026-08-11: Recorded the fresh clean 189/189 Debug and Release native
  matrices and 60/60 ARM64 PE audit; fixed the stale one-shot aggregate test
  initializer, the two explicit macOS PKG descriptor omissions, and eight Inno
  builder test callers; retained both analyzer REDs and the final zero-error,
  zero-warning analyzer GREEN.
- 2026-08-11: Recorded the direct-Flutter path-length and ancestor-ACL REDs,
  moved disposable TEMP into the standard user's bounded profile, and retained
  the 23/23 focused contract GREEN pending the fresh UAC run.
- 2026-08-11: Recorded the final 823-pass serial suite, 31/31 structural harness,
  zero-warning tracked-source publish dry-run, Debug/Release 17/17 plugin
  matrices, 3/3 integration plus 1/1 forged-payload proof, four valid local
  signatures, and bounded LF normalization with a clean diff check.
- 2026-08-11: Recorded the direct-smoke process-ID cleanup fix, mandatory normal
  Debug rebuild after integration assets, exact disposable-user CurrentUser
  trust bootstrap, manual self-signed Root warning boundary, and the
  user-requested stop of run `ecb73a9be2184a9fa942d18986160876`
  with zero disposable account/profile/process residue and preserved RED work.
- 2026-08-11: Corrected the post-handoff certificate inventory’s provider-path
  escaping error and recorded that the original identity remained present.
- 2026-08-11: After fresh user authority, created and verified the replacement
  non-exportable certificate, manually approved CurrentUser Root enrollment,
  updated the elevated wrappers to its identity, and preserved the public-only
  certificate metadata under `reports/windows-arm64-production-readiness/`.
- 2026-08-11: Recorded fresh signed run `a2321868631147f794b4f2450f87f985`
  with direct/helper/locator GREEN and protected-Inno RED. Root-caused the
  Inno failure to the harness omitting the required exact executable-relative
  path, added the explicit example path, and recorded the focused 11/11
  regression before the required fresh elevated rerun.
- 2026-08-11: Preserved the preflight missing-Debug retry RED caused by the
  prior Inno build-root reset, rebuilt and re-signed all four Flutter artifacts,
  and started fresh run `fb825987c397499f804620f03219bdb2`. It is waiting at
  the exact manual `Güvenlik Uyarısı` Root consent; no automated input was sent.
- 2026-08-11: Recorded the fresh run's 7/7 direct/helper/locator GREEN and
  protected-Inno RED, traced the remaining path failure to Flutter adapter
  override propagation, added the smallest adapter fix and focused 28/28
  regression, and preserved the failed run for the next signed rerun.
- 2026-08-11: Recorded fresh signed rerun `d3fd2de90e74405ca9867752a98bb1b6`:
  Debug direct repetitions passed, Release update behavior passed through
  helper cleanup but exposed a transient task-root DLL deletion race. Added a
  bounded exact-root cleanup retry with focused 24/24 contract GREEN; fresh
  signed rerun and remaining Inno/UAC lanes are still required.
- 2026-08-11: Recorded fresh signed run `0869d97991424de8b365935494e8563d`:
  7/7 direct/helper/locator lanes passed, then ISCC exposed the generated
  Inno `GetFileAttributes` compile RED. Added the explicit kernel32 external
  declaration with focused 9/9 generated-script GREEN; a fresh signed rerun
  is required after the Inno lane reset the shared Flutter build root.
- 2026-08-11: Recorded fresh signed run `c8c6dfa99b004960879930f6bb97e529`:
  7/7 direct/helper/locator lanes and Inno compilation/package/feed checks
  passed, then the 3.1.2 endpoint assertion exposed a `\\?\` final-path
  representation mismatch and cleanup found unrelated uninstall records with
  missing custom values. Added bounded path normalization and optional-value
  access with focused 20/20 Windows/Inno contract GREEN; a fresh signed
  protected-Inno rerun remains required.
- 2026-08-11: Recorded fresh signed run `0b610ed67cfc4aff8f0e0c46d48b6756`:
  all 7 direct/helper/locator lanes and Inno compile/feed checks passed, then
  null uninstall records exposed the remaining cleanup RED. Added the null
  guard with focused 12/12 Windows smoke GREEN; preserve the failed runner and
  issue a fresh signed UAC request for the final protected-Inno rerun.
- 2026-08-11: Recorded fresh signed run `3758b573417e4bacbb52ee7a2d1a7d28`:
  all 7 direct/helper/locator lanes and Inno compile/feed checks passed, then
  helper registration returned exit 5 because the separately protected helper
  generation root was absent from policy `allowedInstallRoots`. Retained the
  exact RED and a signed all-view registry probe, added the exact second root
  to the signing hook, and recorded focused 13/13 GREEN evidence; a fresh
  signed end-to-end rerun is required.
- 2026-08-11: Recorded fresh signed run `ddaa5d607e174cde819b7b26194641cb`:
  all 7 direct/helper/locator lanes passed, but protected Inno registration
  still returned exit 5. A package-matched all-view probe and ACL/SDDL capture
  reproduced the RED with no registry key; source inspection found the native
  reader included the signing hook's final LF in the canonical policy bytes.
  Strip exactly that LF, rerun focused regressions, then rebuild, re-sign, and
  repeat the full signed ARM64 matrix.
- 2026-08-11: Recorded fresh signed run `56928080de93402fa62f443ebe947939`:
  all 7 direct/helper/locator lanes passed, but protected Inno failed because
  the matched uninstall record lacked `DisplayVersion`. Preserved the RED,
  added the explicit generated-Inno registry value with a 19/19 focused
  regression, and began the next fresh signed rerun.
- 2026-08-11: Recorded the empty-marker RED and the 15/15 focused guard, then
  preserved the Shell.Application and High-integrity token-proof REDs. Added
  the Explorer-token launcher contract and captured the two post-fix Inno REDs
  before isolating the minimal token access mask.
- 2026-08-11: Added the minimal `CreateProcessWithTokenW` token mask and its
  17/17 focused regression; the ARM64 elevated stage probe passed all process
  creation variants. Fresh UAC requests were then rejected with `OCR: no text
  recognized`, so the final protected-Inno lane remains manual-consent blocked.
- 2026-08-11: Preserved the approved direct-wrapper RED caused by running the
  PowerShell-7-only final lane script under Windows PowerShell 5.1. Added the
  final UAC dispatcher contract and will rerun the complete signed matrix
  through `start-final-elevated-pwsh.ps1` with a fresh request.
- 2026-08-11: Recorded corrected dispatcher request
  `uac-20260811-171359-6cbfdef8` rejected by the bridge with
  `OCR: no text recognized` before elevation; no lane was started and no
  request will be reused.
- 2026-08-11: Preserved dispatcher run `uac-20260811-171607-d9b8cc9c` stopping
  at the missing Debug artifact, reproduced and fixed the MSVC shared-PDB
  C1041 with a scoped `/FS` option and focused contract, rebuilt Debug, and
  re-signed all four Flutter smoke artifacts under the current certificate.
- 2026-08-11: Preserved signed run `4a57cfb58ca44d8db942dde461ba8ed2` with
  direct Debug run 1 GREEN and direct Debug run 2 RED, traced the first
  reservation timeout to synchronous portable Task Scheduler `RunEx` latency,
  and implemented immediate exact-token direct recovery after exact task
  registration/readback. Added the bounded portable timeout contract and
  retained RED/GREEN evidence; 23/23 layout, 26/26 Debug, and 26/26 Release
  focused regressions pass, while a fresh signed end-to-end rerun remains.
- 2026-08-11: The previous continuation certificate expired before the next
  signed lane. Under renewed user authority, created the non-exportable
  CurrentUser-only certificate `2DD3E73FF663ECE1BA78B9788E35192926A3823F`,
  manually completed its CurrentUser/Root consent, updated the active signed
  wrappers and current public identity metadata, and preserved all prior
  certificate identities as final cleanup targets.
- 2026-08-11: Preserved focused signed RED
  `8fad5354c2c64ba2a87da046f9b59736`, increased the bounded portable rename
  sharing retry with native regression coverage, recorded 24/24 layout and
  40/40 Debug/Release affected matrices, rebuilt and re-signed the four
  Flutter runner artifacts, and started fresh UAC request
  `uac-20260811-192020-ccfcfa8b` for focused rerun
  `41a972cb785b496ab5903b4aecb2ee35`.
- 2026-08-11: Recorded focused post-fix signed Debug GREEN
  `41a972cb785b496ab5903b4aecb2ee35`: exit 0 with backup/move/cleanup success,
  installed sentinel, and controller staging cleanup. The complete signed
  matrix and final cleanup remain open.
- 2026-08-12: Reran the signed protected Inno lane as
  `1b4823c66aba444385263004d2600fef` after the visible-launch fix. Packaging,
  signing, feed publication, and update selection passed; the smoke reached a
  live `consent.exe` but the VM exposed no secure-desktop UI for manual user
  approval, so the app remained `installing` and the bounded RED was retained.
- 2026-08-12: Preserved the final serial-suite Linux scope RED caused by a
  retained, partially removed Pub cache; bounded the production-scope scan to
  canonical source roots, recorded focused `4/4` GREEN, and reran the full
  suite to `838` passed, `17` skipped, and zero failed. Recorded fresh-source
  analyzer `0/0/681`, format `278/278`, structural `31/31`, publish dry-run
  zero-warning, and diff-check GREEN evidence.
- 2026-08-12: Completed the post-fix ARM64/plugin/integration ladder with
  serial/fixture-backed native Debug and Release `192/192` CTest GREEN,
  `60/60` native `0xAA64` PE audit, `17/17` Debug and Release plugin CTest,
  `3/3` integration, and `1/1` forged payload GREEN evidence. Stopped the
  protected-lane retry loop at the unavailable secure-desktop consent UI,
  audited bounded residue, removed all five task identities from CurrentUser
  My/Root/TrustedPublisher, and verified them absent; no LocalMachine store was
  modified and no commit, push, publish, release, or GitHub write occurred.
- 2026-08-12: Under renewed explicit authority, created current non-exportable
  CurrentUser certificate `325D896A5D17AC6FF5FBF591DD8F3060BFB1AF7C`,
  preserved protected-Inno build/replay RED evidence, added fixed redacted
  helper-stage diagnostics, and localized the real failure to protected payload
  preparation (`1047`/`1051`). Added strict replay port/path validation,
  retained-handle Inno restaging, bounded uninstaller cleanup retry, and reliable
  dispatcher exit propagation. Focused Windows contracts pass `23/23`; ARM64
  Debug authorizer tests pass `8/8`. Fresh signed end-to-end promotion and final
  certificate cleanup remain pending.
- 2026-08-12: Preserved fresh signed run
  `f29d3b46e1f04445a6aa87bf62f12163` at `1047`/`1050`, measured its stage and
  manifest paths at 230/269 characters, and reproduced the raw-`CreateFileW`
  failure in an ARM64 native test with `LongPathsEnabled=0`. Switched only the
  helper metadata open to the shared `\\?\` representation; focused RED/GREEN
  and full Debug/Release install-authorizer `9/9` evidence are retained before
  the next signed protected-Inno promotion run.
- 2026-08-12: Preserved fresh signed run
  `616f9c50f2764045b607f4340fd1e71b` at `1047`/`1051`, proved the staged
  installer's exact signed identity, and localized the failure to an
  overprivileged `Program Files` parent open. Added a Modify-only parent
  regression, reduced only the parent access mask, and retained focused `1/1`
  plus ARM64 Debug/Release authorizer `10/10` GREEN evidence before a fresh
  signed build/run.
- 2026-08-12: Preserved fresh signed run
  `adadb98949c1436893322059fd9aa6fc` after its 3.1.2 phase passed and the 3.1.3
  build exposed transient POST_BUILD plugin-test discovery as an unrelated
  production-build gate. Added the PRE_TEST contract with focused RED/GREEN,
  reran Debug/Release builds successfully in `186.3s`/`81.6s`, and verified
  genuine Debug/Release CTest discovery/execution at `17/17` each before the
  next signed run.
- 2026-08-15: Reconciled interrupted run
  `4672616b26ab4c69962715955370537d`: it stopped during the 3.1.2 build with a
  stale launcher marker and no result, so it is not product RED/GREEN evidence.
  Verified zero exact system residue, removed expired certificate
  `325D896A5D17AC6FF5FBF591DD8F3060BFB1AF7C` from CurrentUser My, Root, and
  TrustedPublisher, and rechecked all CurrentUser/LocalMachine counts as zero.
  Recorded the user-authorized `main` commit/push as an incomplete-gate
  checkpoint; no branch operation, PR, release, or package publication is part
  of this checkpoint.
