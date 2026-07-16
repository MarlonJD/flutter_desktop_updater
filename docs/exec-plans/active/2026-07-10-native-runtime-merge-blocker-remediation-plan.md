# Native Runtime Merge-Blocker Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> `superpowers:subagent-driven-development` (recommended) or
> `superpowers:executing-plans` to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove every validated PR #65 merge blocker while preserving the
released Flutter API surface, the `DesktopUpdaterKit` import, and the macOS
10.14 CocoaPods fallback.

**Architecture:** Keep the Dart runtime authoritative and make the preview
Swift/C++ runtimes consume the same generated behavior fixtures. Treat caller
paths as parents rather than disposable roots, bind each verified check and
stage to one client generation, carry an immutable provenance digest into the
helper, and perform installs through a canonical target transaction with
cross-process locking and durable recovery. Sign the normalized app archive so
fresh-install, mandatory, rollout, and support policy are authenticated before
selection. Keep SwiftPM native runtime sources at macOS 10.15+, while CocoaPods
compiles only the macOS 10.14-compatible helper and Flutter adapter source set.

**Tech Stack:** Dart/Flutter, Swift/Foundation/CryptoKit/AppKit, C++14/17,
CMake, Win32/WinHTTP/BCrypt, Linux POSIX APIs and libcurl, PowerShell and POSIX
helper scripts, XCTest, GoogleTest, .NET P/Invoke, CocoaPods, SwiftPM, NuGet,
pkg-config, and GitHub Actions.

## Global Constraints

- Do not create, switch, rename, or delete a branch while executing this plan.
- Do not merge or mark PR #65 ready until every non-credential merge gate in
  this plan passes.
- Keep the Flutter package's existing public method names and existing
  MethodChannel method names source-compatible.
- Keep `import DesktopUpdaterKit`, the `DesktopUpdaterKit` product name, and
  the existing Swift public symbol namespace.
- Set the native SwiftPM runtime floor to macOS 10.15.
- Keep the Flutter CocoaPods fallback at macOS 10.14.
- CocoaPods must not compile any file under
  `Sources/DesktopUpdaterKit/Runtime/`.
- Keep release schema version 3; add only an optional app-archive signature
  field that older parsers can ignore.
- Native preview configurations require both app-archive and descriptor
  signatures by default.
- Dart unsigned-index behavior remains available for compatibility, but the
  repository publisher emits signed app archives and the new native runtime
  never accepts unauthenticated fresh-install authority.
- Never recursively delete a caller-provided download or staging parent.
- Every helper install is one-shot, target-locked, provenance-checked, and
  recoverable after abrupt termination.
- Reject protected roots, user shared-bin roots, mount/bind-mount boundaries,
  Windows reparse points, and install/staging overlap before mutation.
- Keep the runtime `preview` and release assets `candidate-only` until all
  credential-gated signing/notarization lanes have actually run.
- Do not bump package versions, changelog headings, or lockfiles in this
  remediation.
- Do not weaken descriptor signatures, artifact hashes, platform signing,
  archive limits, or rollback behavior to preserve compatibility.

---

## Finding-to-Task Ledger

| Validated finding | Owning task |
| --- | --- |
| Native validation fixture is not consumed; fresh-install tests self-assert | Task 1 |
| Result fields, SemVer, build metadata, ISO-8601, rollout, minimumOS, Inno and delta parity | Task 1 |
| Native fresh-install skips descriptor verification | Task 2 |
| Fresh-install, mandatory, rollout and support policy are unsigned index authority | Task 2 |
| Swift checks/stages are forgeable and cross-client | Task 3 |
| Stale stage survives failed checks; install handoff is repeatable | Task 3 |
| Caller staging roots and macOS manifest parents are recursively deleted | Task 4 |
| Windows elevated helper trusts mutable manifest/artifact | Task 4 |
| Windows/Linux/macOS install target is not proven app-owned | Task 5 |
| Legacy Linux direct install omits package identity | Task 5 |
| MethodChannel subclass compatibility dispatch is bypassed | Task 5 |
| Linux mount boundary, Windows reparse boundary and abrupt-crash recovery are missing | Task 6 |
| Windows UTF-8 paths reach ANSI/narrow APIs | Task 7 |
| Windows relative Location redirects are rejected | Task 7 |
| CocoaPods includes Runtime and exact pod source set fails macOS 10.14 | Task 8 |
| Debug DLLs in Release NuGet, missing notices, pkg-config prefix, .NET self-root | Task 9 |
| PR body, active plan state, docs and CI evidence are stale or overbroad | Task 10 |

## File and Interface Map

New shared contract and safety units:

~~~text
lib/src/core/release_index_signature_verifier.dart
lib/src/core/staged_update_provenance.dart
native_runtime/cpp/stage_provenance.h
native_runtime/cpp/stage_provenance.cc
native_runtime/cpp/install_transaction.h
native_runtime/cpp/install_transaction.cc
macos/desktop_updater/Sources/DesktopUpdaterKit/Runtime/StageProvenance.swift
macos/desktop_updater/Sources/DesktopUpdaterKit/InstallTransaction.swift
test/native_runtime_merge_gate_contract_test.dart
test/release_index_signature_verifier_test.dart
test/staged_update_provenance_test.dart
test/native_runtime_merge_gate_docs_test.dart
~~~

The app archive gains one optional schema-v3 field:

~~~json
{
  "signature": {
    "algorithm": "ed25519",
    "publicKeyId": "release-key-2026",
    "value": "base64 Ed25519 signature"
  }
}
~~~

Index canonicalization parses every field through the normalized Dart model,
serializes sorted JSON, and replaces `signature.value` with an empty string.
The signature authenticates every selected item, fresh-install URL and message,
mandatory flag, rollout rule, support policy, and descriptor URL.

The stage marker is `.desktop_updater_stage_provenance.json`:

~~~json
{
  "schemaVersion": 1,
  "nonce": "lowercase UUID",
  "packageId": "com.example.app",
  "descriptorSha256": "64 lowercase hexadecimal characters",
  "artifactSha256": "64 lowercase hexadecimal characters",
  "entries": [
    {
      "path": "bin/example",
      "kind": "file",
      "length": 42,
      "sha256": "64 lowercase hexadecimal characters"
    }
  ]
}
~~~

Directories have kind `directory`, length 0, and no `sha256`. Symbolic links
have kind `symlink`, length 0, and a canonical relative `target`. Entries
are sorted by UTF-8 path bytes before canonical encoding.

The install transaction journal is
`.<target-name>.desktop_updater_transaction.json` in the target parent:

~~~json
{
  "schemaVersion": 1,
  "nonce": "lowercase UUID",
  "packageId": "com.example.app",
  "target": "/canonical/app/root",
  "prepared": "/canonical/app/.prepared-nonce",
  "backup": "/canonical/app/.backup-nonce",
  "stageProvenanceSha256": "64 lowercase hexadecimal characters",
  "state": "prepared"
}
~~~

Allowed states are `prepared`, `backupCreated`, `targetActivated`, and
`completed`.

---

### Task 1: Make Contract Fixtures Executable and Restore Dart/Native Parity

**Files:**

- Modify: `tool/generate_native_contract_fixtures.dart`
- Modify: `fixtures/compat/native-contract/selection-cases.json`
- Modify: `fixtures/compat/native-contract/descriptor-validation-cases.json`
- Modify: `native_runtime/cpp/release_contract.cc`
- Modify: `native_runtime/cpp/contract_fixture_tests.cc`
- Modify: `macos/desktop_updater/Sources/DesktopUpdaterKit/Runtime/ReleaseIndex.swift`
- Modify: `macos/desktop_updater/Sources/DesktopUpdaterKit/Runtime/ReleaseDescriptor.swift`
- Modify: `macos/desktop_updater/Sources/DesktopUpdaterKit/Runtime/VersionOrdering.swift`
- Modify: `macos/desktop_updater/Tests/DesktopUpdaterKitTests/NativeContractConformanceTests.swift`
- Modify: `windows/native/include/desktop_updater_runtime_c.h`
- Modify: `windows/native/src/runtime/desktop_updater_runtime_c.cpp`
- Modify: `windows/native/dotnet/DesktopUpdater.Native/DesktopUpdaterClient.cs`
- Modify: `linux/native/include/desktop_updater_runtime.h`
- Modify: `linux/native/src/runtime/update_client_linux.cc`
- Modify: `test/native_runtime_conformance_contract_test.dart`
- Create: `test/native_runtime_merge_gate_contract_test.dart`

**Interfaces:**

- Consumes: Dart `ReleaseIndex`, `ReleaseDescriptor`,
  `DesktopVersionInfo`, and generated schema-v3 fixtures.
- Produces: native parsers and result models with the same normalized values and
  outcomes as Dart.
- Produces result fields: `mandatory`, `freshInstallUrl`,
  `freshInstallMessage`, `selectedBuildNumber`, `selectedPlatform`, and
  `selectedChannel`.

- [x] **Step 1: Add failing Dart fixture-coverage assertions**

Add this list to `test/native_runtime_conformance_contract_test.dart` and
require both the Swift and C++ test sources to name every fixture:

~~~dart
for (final fixture in <String>[
  "selection-cases.json",
  "descriptor-validation-cases.json",
  "canonical-signature-cases.json",
]) {
  expect(swiftTests, contains(fixture));
  expect(cppTests, contains(fixture));
}
expect(cppTests, contains("ParseReleaseDescriptor"));
expect(cppTests, contains("CheckForUpdateCore"));
expect(swiftTests, contains("UpdateClient("));
~~~

- [x] **Step 2: Generate adversarial normalization cases**

Extend the generator with exact cases for:

~~~dart
const parityCases = <Map<String, Object?>>[
  {
    "name": "rollout identity trims surrounding whitespace",
    "identity": " fixture-device-0 ",
    "expectedNormalizedIdentity": "fixture-device-0",
  },
  {
    "name": "whitespace-only rollout identity is absent",
    "identity": " ",
    "expectedSelectedVersion": null,
  },
  {
    "name": "minimum OS keys and values are trimmed",
    "minimumOS": {" macos ": " 13.0 "},
    "expectedMinimumOS": {"macos": "13.0"},
  },
  {
    "name": "hyphen is valid inside prerelease identifier",
    "candidate": "2.8.0-beta-hotfix.1",
    "current": "2.8.0-beta.1",
  },
  {
    "name": "first numeric build metadata component is the build number",
    "candidate": "2.7.0+271.sha",
    "current": "2.7.0+270.sha",
  },
  {
    "name": "ISO offset and UTC deadline represent the same instant",
    "left": "2026-07-10T03:00:00+03:00",
    "right": "2026-07-10T00:00:00Z",
  },
];
~~~

Also generate negative descriptor cases for blank strings, unsafe Inno
`logFileName`, invalid elevation policy, missing Authenticode thumbprints,
invalid delta fields, and non-absolute URLs.

- [x] **Step 3: Run the focused tests and record the red failures**

Run:

~~~sh
dart run tool/generate_native_contract_fixtures.dart
flutter test --no-pub test/native_contract_fixture_test.dart test/native_runtime_contract_matrix_test.dart test/native_runtime_conformance_contract_test.dart test/native_runtime_merge_gate_contract_test.dart
~~~

Expected: FAIL because native runners do not consume
`descriptor-validation-cases.json`, fresh-install cases do not execute a
client, and native normalization differs.

- [x] **Step 4: Normalize and validate in Swift and C++**

Implement these exact rules in both native parsers:

~~~text
trim packageId, version, platform, channel, rollout identity,
minimumOS keys, and minimumOS values
reject a value that becomes empty
split SemVer prerelease at the first hyphen
split build metadata at plus, then use its first numeric dot component
parse support deadlines to an instant before comparison
validate every artifact-specific install and delta field that Dart validates
canonicalize from the typed normalized model, not raw input JSON
~~~

Do not make C++ accept a descriptor that Dart rejects.

- [x] **Step 5: Execute every fixture through real native behavior**

In C++, load `descriptor-validation-cases.json`, call
`ParseReleaseDescriptor`, and compare success/error to `expectedValid`.
Replace the fresh-install self-assertion with `CheckForUpdateCore` using a
fixture transport that counts descriptor and artifact requests.

In Swift, load the same validation fixture through `ReleaseDescriptor`.
Replace the fresh-install self-assertion with an `UpdateClient` and a fixture
transport; assert that the descriptor request occurs and artifact request does
not.

- [x] **Step 6: Complete public result fidelity**

Append the new fields to the preview Windows ABI v1 result struct before merge:

~~~c
int32_t mandatory;
int32_t has_selected_build_number;
int64_t selected_build_number;
const char* selected_platform_utf8;
const char* selected_channel_utf8;
const char* fresh_install_url_utf8;
const char* fresh_install_message_utf8;
~~~

Add the equivalent fields to Linux `RuntimeResult` and .NET
`DesktopUpdaterRuntimeResult`. Update result-free logic for every new owned
string and add repeated-free tests.

- [x] **Step 7: Run native conformance**

Run:

~~~sh
swift test
cmake -S linux/native -B /private/tmp/desktop-updater-linux-contract -DDESKTOP_UPDATER_NATIVE_RUNTIME=ON -DDESKTOP_UPDATER_NATIVE_BUILD_TESTS=ON
cmake --build /private/tmp/desktop-updater-linux-contract
ctest --test-dir /private/tmp/desktop-updater-linux-contract --output-on-failure
~~~

Expected on macOS: Swift PASS; Linux target-host commands are recorded as
`not run` locally and must pass in GitHub Actions.

Task 1 evidence (2026-07-10):

- RED verified locally: the exact focused command exited 1 with the three
  expected failures for absent parity fixtures, native fixture execution, and
  result fields; the pre-existing 11 fixture tests passed.
- GREEN verified locally: the exact focused command passed 15 tests; the full
  Flutter suite passed 537 tests with 3 environment-gated skips; deterministic
  fixture generation and repository formatting checks passed.
- Native verified locally: `swift test` passed 28 tests, and the portable C++
  contract runner compiled with Clang/OpenSSL and consumed the generated
  fixtures successfully.
- Managed wrapper verified locally: `dotnet build` completed for `net8.0` and
  `netstandard2.0` with 0 errors. `dotnet test` built the test assembly but did
  not execute tests because this macOS host has .NET 10 but not the required
  .NET 8 test host.
- Re-review 2 RED verified locally: Dart accepted a null Inno argument, Swift
  truncated six-digit canonical timestamps and accepted six non-string list
  cases, and the portable C++ runner accepted a present blank index channel.
- Re-review 2 GREEN verified locally: the exact focused command passed 15
  tests, full Flutter passed 537 tests with 3 environment-gated skips, Swift
  passed 28 tests, and the portable C++ runner and Windows C API syntax check
  exited 0.
- Post-review parity RED verified locally on 2026-07-13: the focused Flutter
  command exited 1 because Dart accepted a whitespace-only descriptor
  `appName` and the generated negative fixtures did not cover blank `appName`
  or rollout salt. After generating those cases, the strict portable C++
  runner exited 1 first for whitespace-only rollout salt and then for blank
  `appName`.
- Post-review parity GREEN verified locally on 2026-07-13: deterministic
  fixture generation was current; 35 focused Dart contract and merge-gate
  tests passed; the portable C++17 Clang/OpenSSL fixture runner compiled with
  `-Wall -Wextra -Werror` and exited 0; and root `swift test` passed 51/51,
  including all six native contract conformance tests.
- Linux and Windows target-host native builds/tests: not run locally on macOS;
  required in GitHub Actions.

- [x] **Step 8: Commit the independently reviewable contract fix**

~~~sh
git add tool fixtures/compat/native-contract native_runtime/cpp macos/desktop_updater windows/native linux/native test
git commit -m "fix: align native runtime contracts"
~~~

---

### Task 2: Sign and Verify the App Archive Before Selection

**Files:**

- Create: `lib/src/core/release_index_signature_verifier.dart`
- Modify: `lib/src/core/release_index.dart`
- Modify: `lib/src/core/update_client.dart`
- Modify: `lib/src/release_cli/release_publisher.dart`
- Modify: `lib/src/release_cli/sign_command.dart`
- Modify: `lib/src/release_cli/validate_command.dart`
- Modify: `macos/desktop_updater/Sources/DesktopUpdaterKit/Runtime/ReleaseIndex.swift`
- Modify: `native_runtime/cpp/release_contract.h`
- Modify: `native_runtime/cpp/release_contract.cc`
- Modify: `native_runtime/cpp/update_client_core.cc`
- Modify: native runtime configuration files on all three platforms
- Create: `test/release_index_signature_verifier_test.dart`
- Modify: native update-client tests on all three platforms

**Interfaces:**

- Adds nullable `ReleaseSignature? signature` and
  `canonicalSignatureBytes()` to Dart `ReleaseIndex`.
- Produces Dart `Ed25519ReleaseIndexSignatureVerifier`.
- Adds Dart `bool requireIndexSignature = false` for compatibility.
- Adds native `requireIndexSignature = true` defaults.
- Produces native outcome `signatureFailure` when strict index verification
  is absent or invalid.

- [x] **Step 1: Write failing Dart index-signature tests**

Cover valid signature, unknown key, missing signature in strict mode, and
single-field tampering of fresh-install URL, mandatory, rollout, support
deadline, and descriptor URL:

~~~dart
expect(await verifier.verify(index), isTrue);
expect(await verifier.verify(tamperedIndex), isFalse);
await expectLater(
  strictClient.checkForUpdate(),
  throwsA(isA<FormatException>()),
);
~~~

- [x] **Step 2: Implement normalized index canonical bytes**

Parse through `ReleaseIndex.fromJson`, serialize the typed model, blank
`signature.value`, recursively sort JSON keys, and encode UTF-8. Reject blank
key IDs, unsupported algorithms, malformed base64, unknown keys, and signatures
with the wrong length.

- [x] **Step 3: Sign app-archive.json immediately before publication**

Extend the signing implementation to accept a parsed app archive and the same
Ed25519 key material used for descriptors. The publisher builds the final
archive, inserts a blank signature envelope, signs its canonical bytes, writes
the signature, validates it, and publishes the signed archive last.

`release validate --require-signature` verifies both the archive and selected
descriptor. Keep descriptor signing unchanged.

- [x] **Step 4: Remove the native fresh-install short circuit**

In Swift and C++, always perform this order:

~~~text
download index
parse normalized index
verify app-archive signature when required
select authenticated discovery candidate
download descriptor
parse normalized descriptor
bind version/build/platform/channel/package ID
verify descriptor signature
apply minimum updater and minimum OS
return freshInstallRequired without downloading the artifact
~~~

No branch may select an unauthenticated index item or return
`freshInstallRequired` before descriptor verification.

- [x] **Step 5: Preserve Dart compatibility explicitly**

Keep `requireIndexSignature` false by default for the released Dart
`UpdateClient`. When an index signature and verifier are configured, verify it
even in compatibility mode. When true, reject a missing or invalid index
signature before selection. New repository publisher output is signed; native
preview clients default to strict index and descriptor signatures.

- [x] **Step 6: Run trust tests**

Run:

~~~sh
flutter test --no-pub test/release_index_signature_verifier_test.dart test/update_client_security_test.dart test/release_signature_verifier_test.dart test/release_cli/release_sign_command_test.dart test/release_cli/release_validate_test.dart
swift test
~~~

Expected: PASS; tampering any index policy field produces
`signatureFailure` before selection or descriptor download, and a valid
fresh-install outcome verifies its descriptor before returning.

Task 2 evidence:

- RED verified locally: the new Dart suite failed on the missing index
  verifier, canonical bytes, and strict client options; Swift failed on the
  missing strict configuration/canonical index API; the portable C++ runner
  failed to compile on the missing index verification contract.
- GREEN verified locally: the exact five-file Flutter trust command passed 39
  tests; the full Flutter suite passed 549 tests with 3 environment-gated
  skips; Swift passed 32 tests; the portable common C++ trust runner and the
  Windows C API syntax check exited 0.
- Publisher verified locally: the focused publisher/signing suites passed 19
  tests, including strict final descriptor verification with the configured
  archive-signing key before upload, final archive signing after hooks, and
  rejection of an upload provider that cannot guarantee app-archive-last
  ordering.
- Analysis and formatting verified locally: repository-wide Dart formatting
  reported 211 files unchanged, and `flutter analyze --no-fatal-infos`
  exited 0 with 378 pre-existing info-level diagnostics only.
- Managed Windows wrapper verified locally: `dotnet build` completed for
  `net8.0` and `netstandard2.0` with only NU1900 vulnerability-feed warnings.
- Post-review public-facade RED verified locally on 2026-07-13: the focused
  controller and `DesktopUpdater` tests failed to compile at three call sites
  because `trustedReleasePublicKeys` did not exist. The documentation contract
  then exited 1 because README, publishing, and migration guidance did not name
  a public strict metadata-trust path.
- Post-review public-facade GREEN verified locally on 2026-07-13:
  `DesktopUpdaterController`, `checkZipFirstUpdate`, and
  `downloadZipFirstUpdate` accept one pinned Ed25519 key map. A non-null map
  requires both app-archive and descriptor signatures; null preserves the
  released unsigned 2.x compatibility behavior from Step 5. Three real facade
  regressions reject unsigned metadata, all existing unsigned compatibility
  calls remain source-compatible, and the affected facade, low-level signature,
  2.2.0 compatibility, trust, and docs group passed 62/62. Focused analysis
  exited 0 with only six pre-existing info diagnostics. CI and target-host
  lanes were not run for this follow-up.
- Linux and Windows target-host CMake/CTest: not run locally on macOS.
- CI: not run for this task; no CI result is claimed.

- [x] **Step 7: Commit the trust-boundary fix**

~~~sh
git add lib tool fixtures macos/desktop_updater native_runtime windows/native linux/native test
git commit -m "fix: authenticate native release indexes"
~~~

---

### Task 3: Enforce Client-Bound Generations and One-Shot Handoff

**Files:**

- Modify: `macos/desktop_updater/Sources/DesktopUpdaterKit/Runtime/UpdateClient.swift`
- Modify: `macos/desktop_updater/Tests/DesktopUpdaterKitTests/UpdateClientTests.swift`
- Modify: `windows/native/src/runtime/desktop_updater_runtime_c.cpp`
- Modify: `windows/native/test/runtime/runtime_c_api_compile_test.cpp`
- Modify: `windows/native/dotnet/DesktopUpdater.Native.Tests/`
- Modify: `windows/native/CMakeLists.txt`
- Modify: `linux/native/src/runtime/update_client_linux.cc`
- Modify: `linux/native/test/runtime/`
- Modify: `linux/native/CMakeLists.txt`
- Create: `native_runtime/cpp/client_lifecycle.h`
- Create: `native_runtime/cpp/client_lifecycle.cc`
- Create: `native_runtime/cpp/client_lifecycle_tests.h`
- Create: `native_runtime/cpp/client_lifecycle_tests.cc`

**Interfaces:**

- Swift result initializers become internal.
- Swift results carry internal `clientID: UUID` and `generation: UInt64`.
- Windows/Linux client state carries
  `selection_generation`, `staged_generation`, and `install_in_progress`.
- A successful handoff consumes staged state before scheduling the helper.

- [x] **Step 1: Write failing lifecycle tests**

Add tests for a forged Swift check, a check from another client, a stage from
another generation, stage B failing after stage A, two install calls, and a new
check while install is scheduled.

The required outcomes are:

~~~text
forged/cross-client check -> invalidDescriptor
failed new stage -> no staged update remains
second install -> installHandoffFailure
new check after install starts -> installHandoffFailure
~~~

- [x] **Step 2: Make Swift values externally readable but not constructible**

Remove public initializers from `RuntimeUpdateCheck` and
`RuntimeStagedUpdate`. Add internal client ID and generation fields. Increment
the generation at the start of every check and invalidate active stage state
before any new check or stage attempt.

- [x] **Step 3: Consume staged state atomically**

Before helper scheduling:

~~~text
validate client ID and generation
set installInProgress
move staged state into a local handoff value
clear client staged state
schedule helper
restore staged state only when scheduling itself fails
keep state consumed after successful scheduling
~~~

Apply the same sequence to Windows and Linux stateful clients.

- [x] **Step 4: Make helper script names nonce-based**

Replace PID-only helper paths with a UUID nonce:

~~~text
desktop_updater_<pid>_<nonce>.ps1
desktop_updater_<pid>_<nonce>.sh
desktop_updater_<nonce>.command
~~~

Create scripts exclusively and fail if a path already exists.

- [x] **Step 5: Run lifecycle suites**

Run:

~~~sh
swift test
dotnet test windows/native/dotnet/DesktopUpdater.Native.Tests/DesktopUpdater.Native.Tests.csproj
flutter test --no-pub test/native_runtime_api_contract_test.dart
~~~

Expected: Swift and Dart PASS locally; Windows target-host test is required in
CI.

Task 3 evidence:

- RED verified locally: `swift test` failed to compile the lifecycle tests on
  the missing Swift client ID, generation, and injected scheduler state;
  `flutter test --no-pub test/native_runtime_api_contract_test.dart` failed
  four contract cases on the missing Swift/Windows/Linux generation state and
  nonce-exclusive helper creation.
- Review RED verified locally: the barrier-controlled Swift lifecycle run
  observed two helper scheduler calls, let slow stage A publish after later
  stage B failed, and let slow A replace a later successful B. The first
  portable native lifecycle compile failed on the intentionally missing
  `client_lifecycle.h` isolation contract.
- GREEN verified locally: focused Swift lifecycle tests passed 17 tests and
  full `swift test` passed 44 tests, including concurrent install, both
  overlapping-stage orderings, failed-check invalidation, scheduler-failure
  restore, confirmed one-shot scheduling, and exclusive helper collision
  coverage. Four focused Flutter native contract suites passed 15 tests; the
  API contract suite contributed 6 tests.
- Portable native checks verified locally: the shared behavioral lifecycle
  runner compiled with warnings-as-errors and executed successfully as both a
  C++14 Linux test source and C++17 Windows test source. Clang syntax checks
  exited 0 for the Linux helper, Linux runtime client, Linux runtime artifact
  test, and Windows public runtime C API compile test. The .NET 8 test project
  built with 0 errors and one NU1900 vulnerability-feed warning.
- Re-review 2 RED verified locally: both Swift gated scheduler tests restored
  the consumed stage after a rejected check or stage attempt, and the shared
  C++14 lifecycle runner failed independently with the same stale-restore
  outcome for each attempt. Portable Dart contracts also failed on Windows
  stage validation preceding `BeginStage`, invalidated checks returning the
  wrong outcome, and the installed Linux runtime config omitting Threads.
- Re-review 2 GREEN verified locally: focused Swift lifecycle tests passed 19
  tests and full `swift test` passed 46 tests. Shared lifecycle runners compiled
  with warnings-as-errors and executed successfully in C++14 and C++17. Six
  native Dart contract suites passed 27 tests, including Windows adapter
  ordering/outcome and installed Linux runtime consumer/config coverage. Four
  portable native syntax checks exited 0, and the .NET 8 test project built
  with 0 errors and one NU1900 vulnerability-feed warning.
- An actual installed external-consumer CMake configure was not run because
  `cmake` is not installed on this macOS host (`command not found`). The
  generated-config and consumer boundary received passing portable source
  coverage; no target-host configure pass is claimed.
- Windows and Linux target-host CMake/CTest: not run locally on macOS. .NET
  target-host test execution: not run locally on macOS.
- CI: not run for this task; no CI result is claimed.

- [x] **Step 6: Commit**

~~~sh
git add macos/desktop_updater windows/native linux/native test
git commit -m "fix: make native install handoff one shot"
~~~

---

### Task 4: Create Updater-Owned Staging and Immutable Provenance

**Files:**

- Create: `lib/src/core/staged_update_provenance.dart`
- Create: `native_runtime/cpp/stage_provenance.h`
- Create: `native_runtime/cpp/stage_provenance.cc`
- Create: `macos/desktop_updater/Sources/DesktopUpdaterKit/Runtime/StageProvenance.swift`
- Modify: `native_runtime/cpp/artifact_stager.cc`
- Modify: all platform artifact stagers
- Modify: all platform helper handoffs
- Create: `test/staged_update_provenance_test.dart`
- Modify: platform artifact and helper tests

**Interfaces:**

- Caller stage/download arguments become parent directories.
- Runtime creates `desktop_updater_stage_<nonce>` with exclusive semantics.
- Produces canonical provenance marker and its SHA-256.
- Helper receives the expected provenance SHA-256 from verified client state,
  not from caller input.

- [x] **Step 1: Write failing parent-preservation tests**

For every stager, place sentinel files beside the requested stage child. Assert
that successful staging, validation failure, and cleanup preserve the parent and
sentinels. Add a macOS helper test proving `/Applications` or any manifest
parent is never passed to recursive deletion.

- [x] **Step 2: Write failing tamper tests**

After staging and before helper execution, change:

~~~text
one ZIP file byte
the release manifest
the Inno installer
the PKG installer
one provenance inventory entry
one symbolic-link target
~~~

Expected: helper rejects before backup, deletion, elevation, or installer open.

- [x] **Step 3: Implement exclusive owned stage creation**

Create a nonce child under the caller parent. Reject parent/root overlap,
symlink parents, reparse parents, existing child names, and paths outside the
canonical parent. Cleanup accepts only a child whose valid marker nonce matches
the requested nonce.

Delete `RemoveTree(destination_path)` behavior for caller values.

- [x] **Step 4: Generate and verify provenance inventory**

Hash every regular file, record symlink targets without following them, sort
entries, write the canonical marker, and store its SHA-256 in the client stage
state. At helper time, verify marker digest and the complete inventory again.

- [x] **Step 5: Reverify platform trust at the last responsible moment**

Windows elevated Inno handoff rechecks artifact SHA-256, Authenticode status,
and allowed thumbprints from immutable script constants. macOS PKG handoff
reruns `pkgutil --check-signature`, `spctl --assess --type install`,
`xcrun stapler validate`, and package-ID checks. Linux verifies the full
inventory before target mutation.

- [x] **Step 6: Run staging and tamper suites**

Run:

~~~sh
flutter test --no-pub test/staged_update_provenance_test.dart test/staging_directory_cleanup_test.dart test/native_helper_script_test.dart
swift test
~~~

Expected: PASS and every tamper case records a validation failure before
`backup start`.

Task 4 local evidence (2026-07-10):

- RED: the focused provenance/helper suite first failed because
  `staged_update_provenance.dart` and its API did not exist; the cleanup suite
  also proved that forged-prefix and protected stage paths were deleted, and
  Swift tests failed because `StageProvenance` was absent.
- GREEN: the exact focused Flutter command passed 34 tests. It covers ZIP,
  release-manifest, Inno, PKG, inventory-entry, and symlink-target mutation;
  helper source-order assertions require provenance validation before
  `backup start`, target mutation, elevation, or installer open.
- GREEN: `swift test` passed 47 tests, including owned-parent preservation,
  file/symlink tamper rejection, and PKG trust ordering before backup/open.
- GREEN: the focused controller/platform/client regression command passed 49
  tests. `flutter analyze --no-fatal-infos` exited 0 with 391 info-only lints
  and no warning or error diagnostics. Portable C++14 `-Werror` syntax checks
  for shared provenance/lifecycle and Linux stager/client/helper sources, plus
  a Swift frontend parse of the plugin/runtime/helper sources, exited 0.
- Windows and Linux target-host CMake/CTest and target-host helper tamper
  execution were not run locally on macOS. The local claim is limited to
  portable provenance rejection tests and generated-helper ordering checks;
  no target-host execution or CI result is claimed.
- The additive Flutter method-channel fields carry only the verified stage
  digest, nonce, immutable inventory, artifact digest, and signer allowlist
  from `UpdateStageResult` through the existing install handoff. They do not
  add or prove Task 5 install-root, executable-relative-path, package-identity,
  PID, or bundle-target context; Task 5 remains separate.
- Fix wave RED/GREEN: the CocoaPods layout regression first failed because the
  broad helper glob still compiled `DesktopUpdaterKit/Runtime`, then passed 3
  tests after adding only the Runtime exclusion while retaining macOS 10.14
  and `DesktopUpdaterKit`.
- Fix wave RED/GREEN: the Linux native regression first proved a caller could
  provide a different nonce/inventory, then proved the intermediate helper
  lacked a digest gate for the parsed marker bytes. The final portable
  C++14/17 `-Werror` command compiled shared JSON/provenance and the Linux
  helper and passed 5 focused native tests. The plugin no longer reads caller
  nonce/inventory; helper checks are derived from a canonical marker whose
  embedded bytes and live bytes must both match the lifecycle digest.
- Fix wave RED/GREEN: the focused Swift test failed 8 assertions for `$()`
  command substitution, backticks, single quotes, and newlines in inventory
  paths, then passed after all staged paths were POSIX-quoted into a data-only
  variable and filesystem commands used only `"$candidate"`. Symlink targets
  remain POSIX-quoted data.
- Fix wave final verification: the required provenance/cleanup/helper/podspec
  Flutter command passed 37 tests; the focused controller/platform/client
  command passed 49 tests; full `swift test` passed 50 tests; and
  `git diff --check` passed.
- Fix wave target-host limits: Linux CMake/CTest, Flutter/GTK plugin compilation,
  and scheduled helper execution; Windows CMake/CTest/UAC execution; CocoaPods
  lint plus an actual macOS 10.14 build; CI; signing/notarization; and release
  smoke were not run locally.
- Re-review RED/GREEN: the exact Task 8 five-file source-set typecheck at
  `x86_64-apple-macosx10.14` first failed on undefined `StageProvenance*`
  symbols, then exposed the 10.15-only slash-canonicalization and NSWorkspace
  APIs. The final exact command exited 0 with the repository FlutterMacOS
  framework path and no diagnostics.
- Re-review resolution: the podspec now names exactly
  `DesktopUpdaterVersion.swift`, `Diagnostics.swift`, `MacInstallHelper.swift`,
  `MacInstallRequest.swift`, and `DesktopUpdaterPlugin.swift`; it contains no
  Runtime source or broad glob. Public provenance API and verification live in
  the already-allowed request source and use incremental CommonCrypto SHA-256;
  hostile paths remain data-only in the helper. SwiftPM keeps the
  `DesktopUpdaterKit` product/import and macOS 10.15 floor.
- Re-review verification: the focused Flutter provenance/helper/layout command
  passed 40 tests, full plugin `swift test` passed 51 tests, the root SwiftPM
  product build passed, three portable C++14 `-Werror` compilations and 5 Linux
  native tests passed, and `git diff --check` passed.
- Re-review target-host limits: CocoaPods lint and macOS 10.14 runtime execution,
  Linux/Windows target-host helpers, CI, signing/notarization, credentials, and
  release smoke were not run. Task 8 checkboxes remain open.

- [x] **Step 7: Commit**

~~~sh
git add lib/src/core native_runtime macos/desktop_updater windows/native linux/native test
git commit -m "fix: bind helpers to owned staging"
~~~

---

### Task 5: Prove Install Targets and Preserve Safe Flutter Compatibility

**Files:**

- Modify: `lib/desktop_updater.dart`
- Modify: `lib/desktop_updater_platform_interface.dart`
- Modify: `lib/desktop_updater_method_channel.dart`
- Modify: `lib/updater_controller.dart`
- Modify: `linux/desktop_updater_plugin.cc`
- Modify: `linux/native/include/desktop_updater_native.h`
- Modify: `linux/native/src/desktop_updater_native.cc`
- Modify: Windows helper ABI and plugin files
- Modify: `macos/desktop_updater/Sources/DesktopUpdaterKit/MacInstallRequest.swift`
- Modify: `macos/desktop_updater/Sources/DesktopUpdaterKit/MacInstallHelper.swift`
- Modify: `test/desktop_updater_test.dart`
- Modify: `test/desktop_updater_method_channel_test.dart`
- Modify: native helper tests

**Interfaces:**

- Adds optional Dart install context without removing existing arguments:
  `installRoot`, `executableRelativePath`, and `packageId`.
- Reads missing package identity from verified stage provenance.
- Introduces native `InstallTargetProof` with canonical root, relative
  executable, package ID, and proof source.
- macOS public request no longer accepts arbitrary PID or bundle path.

- [x] **Step 1: Write the Flutter compatibility matrix tests**

Cover:

~~~text
old DesktopUpdater.installUpdate(stagingPath: ...) with valid provenance
controller install with explicit descriptor package ID
custom DesktopUpdaterPlatform implementation overriding installUpdate
MethodChannelDesktopUpdater subclass overriding only legacy installUpdate
Linux self-contained Flutter bundle root
Linux shared ~/.local/bin root
Windows Program Files target with matching installed identity
macOS request attempting a different bundle target
~~~

Expected safe compatibility:

~~~text
old safe self-contained Flutter call succeeds
custom legacy override is invoked
shared-bin or arbitrary target is rejected before mutation
preview macOS caller cannot select another bundle or PID
~~~

- [x] **Step 2: Fix MethodChannel dispatch**

Use the context method only for the exact default implementation. A subclass
that overrides legacy `installUpdate` must receive that override. Add a
protected virtual context hook only if exact-type dispatch is not expressible
without mirrors.

- [x] **Step 3: Resolve missing context from verified provenance**

When public Dart callers omit `packageId`, load the provenance marker and use
its package ID. Pass explicit context to the default MethodChannel. Do not infer
identity from an unverified release manifest.

- [x] **Step 4: Add a strict self-contained Flutter bundle classifier**

Linux fallback may derive the current executable parent only when all are true:

~~~text
root is canonical and not a symlink
root is not /, /bin, /usr, /usr/local, /opt, /etc, /var, /home,
  $HOME, $HOME/bin, $HOME/.local/bin, Desktop, Downloads, or a temp root
root contains data/flutter_assets and lib/libflutter_linux_gtk.so
the requested executable exists at the same canonical relative path in target
  and staged inventory
stage provenance package identity is non-empty
root and stage do not overlap
~~~

Any other legacy layout fails with a migration message and no helper script.

- [x] **Step 5: Make native preview target context explicit**

Before the preview ABI is merged, append explicit install root, executable
relative path, and expected package identity to Windows install context. Linux
already exposes root/path parameters; remove fallback inference from the native
runtime route.

For Windows Program Files/Inno, require a registry uninstall record whose
`InstallLocation` equals the canonical target and whose app identity matches
the verified descriptor. For ZIP installs without a registry record, require an
installed `.desktop_updater_install_identity.json` marker created by the
repository publisher/installer.

- [x] **Step 6: Derive macOS target inside the helper**

Remove public `currentProcessIdentifier` and `bundlePath` inputs.
`MacInstallHelper` uses `ProcessInfo.processInfo.processIdentifier` and
`Bundle.main.bundleURL`. Tests may inject an internal target resolver, but
external clients cannot choose the target.

- [x] **Step 7: Run compatibility and helper tests**

Run:

~~~sh
flutter test --no-pub test/desktop_updater_test.dart test/desktop_updater_method_channel_test.dart test/updater_controller_test.dart test/native_helper_script_test.dart
swift test
~~~

Expected: PASS; old safe calls work, unsafe ambiguous roots fail without
filesystem mutation.

- [x] **Step 8: Commit**

~~~sh
git add lib linux windows macos test
git commit -m "fix: prove native install targets"
~~~

Task 5 evidence on 2026-07-10:

- RED evidence was preserved from the implementation session: the focused
  Flutter run exited 1 on subclass dispatch, omitted package identity, missing
  native target-proof/shared-root behavior, and public macOS PID/bundle
  selectors; Swift, ZIP publisher, Inno publisher, and Windows header checks
  also failed on their corresponding missing interfaces. The recovery audit
  additionally reproduced failures for stale SwiftPM samples, Linux temporary
  fallback roots, runtime C ABI prefix sizing, and the `netstandard2.0`
  `Environment.ProcessPath` build.
- The exact focused Flutter command passed 70 tests. Focused publisher tests
  passed 5 tests, and supplemental native API/helper/consumer contracts passed
  38 tests. `dart format --set-exit-if-changed .` checked 213 files unchanged;
  `flutter analyze --no-fatal-infos` exited 0 with info-only diagnostics.
- The full macOS plugin SwiftPM package passed 51 tests; the repository-root
  SwiftPM package passed 49 tests; both external macOS SwiftPM consumers built;
  and the exact five-file CocoaPods fallback source set typechecked for macOS
  10.14. The product remains `DesktopUpdaterKit`, the SwiftPM floor remains
  macOS 10.15, and no `Runtime/**` source was added to the pod source set.
- Three portable Linux C++14 `-Werror` translation units compiled, and the
  portable native helper suite passed all 10 tests on macOS, including actual
  rollback execution, outside-file preservation, temporary/shared-root
  rejection, and overlap rejection. The Windows native C ABI suite passed all
  10 portable tests, including legacy-size and appended target-context cases;
  the runtime and helper C ABI translation units passed portable syntax checks.
- The .NET wrapper built `net8.0` and `netstandard2.0` with 0 errors and two
  NU1900 vulnerability-feed warnings. Linux and Windows target-host helpers,
  Windows registry/UAC/Inno execution, CI, CocoaPods lint, macOS 10.14 runtime
  execution, signing/notarization, credentials, and release smoke were not run.

Task 5 post-commit review remediation evidence on 2026-07-10:

- RED: the task-supplied focused Flutter regressions failed on forged legacy
  stage acceptance, missing file-input identity markers, reserved marker
  acceptance, and missing native proof checks. The portable Linux suite built
  against `4993cda` reported failures for both explicit temporary roots and
  broad ancestor roots because each still produced a helper script. Native
  CMake RED was blocked because `cmake` is unavailable on this host.
- Resolution: legacy default-channel installs now require independently
  retained verified stage state populated only by successful `UpdateClient`
  finalization; explicit Linux installs require a matching root-level installed
  identity and reject temporary descendants; Windows Program Files proof uses
  only HKLM 64/32-bit uninstall views; Windows rejects a stage-root reparse
  point before proof or helper creation; ZIP directory/file packaging emits one
  reserved identity marker and rejects pre-existing collisions; and Linux real
  rollback asserts restored executable bytes and mode.
- GREEN: the exact Task 5 Flutter command passed 70 tests, publisher tests
  passed 7, supplemental native API/helper/consumer contracts passed 38, the
  portable Linux helper passed 12, and the portable Windows C ABI passed 10.
  The macOS plugin package passed 51 Swift tests and the exact five-file macOS
  10.14 CocoaPods source set typechecked. Formatting and analysis passed at the
  final handoff.
- Wider observation: optional full Flutter widening reached 572 passes, 3
  skips, and 3 failures from pre-existing `4993cda` contract mismatches (an
  unmarked stale-stage cleanup expectation, the existing
  Flutter-specific legacy proof enum name, and macOS helper source ordering).
  No unrelated compatibility behavior was changed to hide them. Target-host,
  CI, credential, signing, notarization, and release lanes remain not run.

Task 5 final re-review closure evidence on 2026-07-10:

- RED: focused source contracts rejected the Flutter-specific public Linux
  proof enum, missing Windows ancestor-component reparse walking, missing
  unsafe-root classification, and the unbounded literal Windows identity
  comparison. Portable Linux execution also proved that a matching plaintext
  marker could authorize an arbitrary writable ancestor. Follow-up RED then
  required Windows ProgramData, ALLUSERSPROFILE, and Public to be rejected as
  trees, the users container and user `.local/bin` to be exact rejects, and the
  staging root/share itself to participate in the reparse walk.
- Resolution: the Linux proof enum is now `kLegacySelfContainedBundle`.
  Explicit Linux installs and non-Program-Files Windows ZIP installs require
  the install root to be the exact parent of the running executable; nested
  Program Files apps remain supported only through matching HKLM 64/32-bit
  uninstall proof. Windows rejects drive roots, Windows/system/temp trees,
  ProgramData/shared profile trees, exact user/profile/bin/.local/bin/Desktop/
  Downloads roots, and component-safe shared-root matches before marker proof.
  The staging walk checks the path root/share and every relative component for
  reparse points before proof or helper creation. Installed identity parsing is
  bounded to 64 KiB and uses the shared strict JSON parser, including escaped
  control characters, Unicode, schema/type, duplicate-key, and exact-key
  validation.
- The stale cleanup tests now distinguish unmarked prefix directories, which
  are preserved, from valid marker-bound owned stages, which are deleted. The
  macOS source-order assertion uses the current stage-root manifest path, and
  the Linux header contract asserts the platform-neutral enum.
- GREEN: the exact Task 5 Flutter command passed 70 tests; publisher tests
  passed 7; supplemental native contracts passed 38; the focused stale/source
  bundle passed 38; portable Linux behavior passed 12; portable Windows C ABI
  passed 10; and the Windows runtime C++14 header consumer compiled with
  `-Werror`. The macOS package passed 51 Swift tests and the exact five-file
  macOS 10.14 CocoaPods source set typechecked. The full Flutter suite passed
  576 tests with 3 explicit environment-gated skips and 0 failures. Formatting
  checked 213 files unchanged at final handoff; analysis exited 0 with existing
  info-only diagnostics.
- Windows target-host CMake/CTest, registry/junction/UAC/PowerShell/ZIP/Inno
  execution, Linux target-host CMake/CTest, CI, credentials, signing,
  notarization, and release smoke remain literally not run on this macOS host.

Task 5 Windows metadata follow-up evidence on 2026-07-10:

- RED: the focused native source contract showed that
  `INVALID_FILE_ATTRIBUTES` was treated as “not a reparse point,” shared/profile
  roots came only from mutable environment aliases, and marker validation used
  a separate size query followed by an unbounded iterator read. Windows unit
  candidates also required explicit unavailable and ancestor-reparse component
  states. A second RED required Known Folder resolution itself to fail closed
  rather than allowing aliases to become authoritative when the APIs fail.
- Resolution: staging traversal now classifies the root/share and every path
  component as safe, unavailable, or reparse, and rejects both non-safe states
  before target proof or helper construction. ProgramData, Public, and Profile
  are resolved through `SHGetKnownFolderPath`; the users container is derived
  only from the authoritative Profile value, and environment values are added
  only as supplemental aliases. If any required authoritative root is
  unavailable, target proof fails closed. Known-folder allocations are freed
  with `CoTaskMemFree`, and the native targets link Ole32.
- Installed identity markers now use one `CreateFileW` handle opened with
  `FILE_FLAG_OPEN_REPARSE_POINT` and read sharing only, which blocks new
  write/delete opens during validation. Handle metadata rejects directories
  and reparse points. A fixed 64 KiB + 1 buffer bounds the sole `ReadFile` call;
  oversize input fails before exact bytes are passed to the strict JSON parser.
- GREEN: exact Task 5 Flutter passed 70 tests; supplemental native contracts
  passed 38; portable Windows C ABI passed 10 and its C++14 header consumer
  typechecked with `-Werror`; portable Linux behavior passed 12; macOS SwiftPM
  passed 51 and the exact macOS 10.14 source set typechecked. Full Flutter
  passed 576 tests with 3 explicit skips and 0 failures. Final formatting,
  analysis, and diff checks are recorded at commit handoff.
- The new Windows plugin tests are registered for target-host execution but
  were not run on macOS. Windows target-host CMake/CTest, unreadable ACL and
  junction behavior, registry/UAC/PowerShell/ZIP/Inno execution, CI, and
  external release lanes remain not run.

---

### Task 6: Add Mount/Reparse Safety, Target Locks, and Durable Recovery

**Files:**

- Create: `native_runtime/cpp/install_transaction.h`
- Create: `native_runtime/cpp/install_transaction.cc`
- Create: `macos/desktop_updater/Sources/DesktopUpdaterKit/InstallTransaction.swift`
- Modify: Windows and Linux native helpers
- Modify: macOS install helper
- Modify: `lib/src/core/update_recovery.dart`
- Modify: `docs/diagnostics-and-recovery.md`
- Modify: platform helper tests and update smokes

**Interfaces:**

- Produces per-target exclusive lock and journal state machine defined above.
- Produces `RecoverPendingInstall(target, packageId)` before a new handoff.
- Rejects nested filesystems and reparse points before backup.

- [ ] **Step 1: Write no-mutation boundary tests**

Add target-host tests for:

~~~text
Linux bind mount and different st_dev under install root
Linux mount under staging root
Windows junction/reparse entry in target and staging
two helpers targeting the same canonical root
SIGKILL/power-loss simulation after each journal state
missing staging after backup and removed-file processing
~~~

Each rejection asserts target, outside data, and staging parent remain
byte-for-byte unchanged.

- [ ] **Step 2: Implement Linux mount detection**

Before mutation, recursively compare `st_dev` to the root device and parse
`/proc/self/mountinfo` to catch same-device bind mounts. Reject any mountpoint
whose canonical path equals or descends from target or stage.

Use fd-relative traversal with `openat`, `O_NOFOLLOW`, `fstatat`, and
`unlinkat`; do not pass an unvalidated absolute child to `rm -rf`.

- [ ] **Step 3: Implement Windows reparse-safe traversal**

Use wide Win32 paths and handles opened with
`FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS`. Reject any
reparse point under target, prepared tree, or stage before PowerShell starts.
The PowerShell script rechecks the same invariant immediately before mutation.

- [ ] **Step 4: Acquire a cross-process target lock**

Create the journal/lock file exclusively in the target parent. Record PID,
nonce, package ID, and canonical target. A live owner causes
`installHandoffFailure`. A dead owner triggers recovery before a new lock is
granted.

- [ ] **Step 5: Replace copy/prune with the journaled transaction**

Prepare a complete sibling tree first. Persist and fsync each journal state,
then execute:

~~~text
prepared: prepared tree and provenance verified
backupCreated: target renamed to unique backup
targetActivated: prepared tree renamed to target
completed: target verified and backup removed
~~~

On recovery, `backupCreated` restores backup; `targetActivated` verifies the
new target and either completes or restores backup. Cleanup never removes a
path absent from the journal.

- [ ] **Step 6: Integrate recovery with diagnostics**

Emit existing event names plus:

~~~text
transaction lock acquired
transaction journal persisted
recovery detected
recovery restored backup
recovery completed activation
~~~

Redact canonical user paths using the existing diagnostics policy.

- [ ] **Step 7: Run safety suites**

Run target-host native tests and update smokes. Expected: every injected
interruption reaches a deterministic restored or completed state, no test
crosses a mount/reparse boundary, and test discovery is nonzero.

- [ ] **Step 8: Commit**

~~~sh
git add native_runtime macos linux windows lib/src/core docs/diagnostics-and-recovery.md test
git commit -m "fix: make native installs recoverable"
~~~

Task 6 blocker evidence (2026-07-11):

- BLOCKED: a fresh adversarial review of candidate commit `1f29059` validated
  multiple P0 defects in the actual script-based helpers: no-backup Windows
  rollback deletion, journal sibling path injection, path-based mutation after
  validation, non-serialized dead-owner recovery, and torn Windows journal
  writes. The strict shared C++ and Swift transaction models were not consumed
  by the production helpers.
- BLOCKED architecture decision: satisfying pinned fd/handle-relative mutation
  and pre-handoff lock ownership requires packaged standalone helper products
  (including a signed/elevatable Windows executable and a signed macOS helper
  resource compatible with both SwiftPM and the exact five-file CocoaPods
  fallback), plus an explicit reservation-to-helper ownership transfer
  protocol. That product/signing/packaging architecture is not defined by the
  current repository or this task's file map.
- The unsafe candidate was removed by `2163243`. Verified locally after the
  revert: full Flutter passed 576 tests with 3 explicit environment-gated
  skips and 0 failures; macOS SwiftPM passed 51 tests. The source tree is back
  at the independently approved Task 5 behavior.
- Windows/Linux target-host transaction tests, privileged mount/junction
  injection, helper signing/packaging, CI, signing/notarization, and release
  smoke: not run. Steps 1-8 remain open and the runtime remains candidate-only.

Current standalone-helper implementation follow-up (2026-07-14):

- Privileged-helper plan Tasks 1-14, commits `292b112` through `d06d0c6`,
  replace the rejected script architecture with standalone macOS, Windows, and
  Linux helpers; reservation ownership transfer; sealed policies; per-target
  locks; durable native transaction journals; deterministic recovery; native
  strategy providers; Flutter routing; and retail packaging.
- Local macOS evidence is `verified locally`: the helper Swift package passed
  38 tests and root SwiftPM passed 62 tests. The nested helpers were
  byte-identical arm64 hardened-runtime binaries, but the outer debug app could
  not establish production trust because the host reported 0 valid
  code-signing identities.
- Local Linux container evidence is `verified locally`: 36 native tests passed,
  installed CMake and pkg-config consumers passed, and the portable retail
  candidate was staged. The suite reported one explicit mount-namespace skip,
  so the privileged boundary is not verified.
- Windows target-host execution, the privileged Linux mount-namespace lane,
  current-helper-head GitHub Actions, macOS SMAppService daemon/XPC, Windows
  Authenticode/UAC, Linux installed polkit, and signed/notarized release lanes
  are `not run`. The combined signed/elevated production boundary remains
  `blocked` and the runtime remains `candidate-only`.
- Steps 1-8 intentionally remain open: the implementation exists, but the
  mandatory current-head target-host evidence required by this task has not
  run. The 2026-07-11 statements above describe the historical reverted
  candidate, not the current implementation.

---

### Task 7: Make Windows Paths Unicode-Safe and Resolve Relative Redirects

**Files:**

- Modify: `native_runtime/cpp/artifact_stager.cc`
- Modify: `native_runtime/cpp/artifact_stager.h`
- Modify: `windows/native/src/runtime/update_transport_winhttp.cpp`
- Modify: `windows/native/src/runtime/artifact_stager_windows.cpp`
- Modify: Windows runtime tests
- Modify: `tool/native_transport_fixture_server.dart`
- Modify: `test/native_runtime_transport_contract_test.dart`

**Interfaces:**

- Windows filesystem operations use `std::filesystem::path` or UTF-16
  `std::wstring` end-to-end.
- Produces
  `std::string ResolveRedirectURL(const std::string& source, const std::string& location)`.

- [x] **Step 1: Add a non-ASCII Windows path smoke**

Use a temporary child named `güncelleme-日本`. Download, resume, hash, extract,
write provenance, cleanup, and finalize an artifact under that path.

Expected before implementation: FAIL in at least one narrow filesystem API.

- [x] **Step 2: Replace ANSI and narrow filesystem APIs**

Replace `_mkdir`, Win32 A APIs, narrow fstreams, `std::remove`, and
`std::rename` on Windows. Convert UTF-8 exactly once at the ABI boundary and
carry native paths through every filesystem operation. Use a miniz extraction
callback that writes to already opened wide-path file handles instead of
`mz_zip_reader_extract_to_file` with a narrow path.

- [x] **Step 3: Add relative redirect fixtures**

Serve all of:

~~~text
Location: /metadata
Location: ../metadata
Location: //127.0.0.1:<port>/metadata
HTTPS source to HTTP absolute target
redirect loop longer than five
~~~

- [x] **Step 4: Resolve before enforcing redirect policy**

Resolve `Location` against the current URL with the shared portable RFC 3986
resolver. Validate the resolved absolute URL, then reject HTTPS downgrade. Pass
the resolved URL to the WinHTTP adapter, headers provider, and next request.

- [x] **Step 5: Run Windows target-host tests**

Run in CI:

~~~powershell
cmake --build windows/native/build --config Debug
ctest --test-dir windows/native/build -C Debug --output-on-failure
dotnet test windows/native/dotnet/DesktopUpdater.Native.Tests/DesktopUpdater.Native.Tests.csproj
~~~

Expected: PASS for Unicode path, relative redirects, downgrade rejection,
resume, and cleanup.

- [x] **Step 6: Commit**

~~~sh
git add native_runtime windows/native tool/native_transport_fixture_server.dart test/native_runtime_transport_contract_test.dart
git commit -m "fix: harden Windows runtime transport paths"
~~~

Task 7 evidence on 2026-07-11:

- RED was recorded before production changes with
  `flutter test --no-pub test/native_runtime_transport_contract_test.dart`:
  the Windows transport contract failed at
  `test/native_runtime_transport_contract_test.dart:51` with
  `Expected: contains 'WinHttpCombineUrl'`; the run ended
  `+2 -1: Some tests failed.` The contract was then corrected to the actual
  WinHTTP `WinHttpCrackUrl`/`WinHttpCreateUrl` API pair before GREEN.
- Verified locally on macOS: the focused transport/source and live fixture
  server suite passed 4 tests; portable C++17 syntax checks passed for the
  shared artifact stager, provenance implementation, and transport fixture;
  a compiled portable archive-stager smoke passed the extraction, limit,
  cleanup, traversal, and duplicate-conflict cases;
  `flutter analyze --no-fatal-infos` completed with 395 existing info-level
  diagnostics and no fatal diagnostics; `dart format --set-exit-if-changed .`
  formatted 213 files with 0 changes; full Flutter passed 577 tests with 3
  explicit environment-gated skips and 0 failures; the banned Windows
  ANSI/narrow API scan and `git diff --check` passed.
- Windows Debug CMake build, CTest (including the non-ASCII path and redirect
  fixture tests), and .NET tests: not run on macOS. Step 5 and the final
  acceptance checkbox remain open until target-host evidence exists.
- Task 6 remains blocked and reverted. This task changes path encoding,
  archive I/O, and redirect handling only; it does not restore the rejected
  helper transaction candidate.
- Commit: `fix: harden Windows runtime transport paths` (this changeset).

Task 7 review follow-up evidence on 2026-07-11:

- Follow-up RED was recorded before the review-fix production changes. The
  portable resolver test failed to compile with
  `fatal error: 'redirect_url.h' file not found`; the portable native-path
  provenance test failed with
  `no member named 'FilesystemOwnedStage'`; and the focused Dart contract
  failed because `native_runtime/cpp/redirect_url.h` did not exist, ending
  `+3 -1: Some tests failed.` A later focused invalid-port test also failed
  with `Empty explicit port was accepted` before the parser fix.
- The production RFC 3986 resolver is now a portable shared C++ unit consumed
  directly by the WinHTTP adapter. Executable tests pass for empty,
  query-only, fragment-only, query-plus-fragment, root-relative,
  parent-relative, and scheme-relative references; repeated non-dot slashes;
  default and explicit ports; IPv6 literals; credential rejection; downgrade
  rejection; and fragment-free HTTP request targets.
- Windows staging now uses filesystem-path owned-stage, provenance,
  verification, and cleanup overloads after the ABI conversion. Inventory
  enumeration keeps native relative paths and converts names to UTF-8 only
  for canonical provenance JSON. Compatibility string wrappers remain for
  shared/Linux callers. The portable native-path executable passed Unicode
  staging, provenance verification, bounded owned-child cleanup, and caller
  sentinel preservation; Linux/macOS shared syntax checks passed.
- The Windows fixture contract now covers exactly five redirects succeeding,
  a sixth redirect failing, and cross-authority header-provider sequencing.
  The failed Inno test enumerates the Unicode caller-owned parent and requires
  that only `sentinel.txt` remains.
- Verified locally on macOS: focused transport/source and live fixture tests
  passed 4 tests; both portable C++ executables passed; repository format
  checked 213 files with 0 changes; analyze completed with 395 existing
  info-level diagnostics and no fatal diagnostics; full Flutter passed 577
  tests with 3 explicit environment-gated skips and 0 failures; banned API
  scans and `git diff --check` passed.
- Windows Debug CMake, CTest, and .NET tests: not run on macOS. Step 5 and the
  final acceptance checkbox remain open. Task 6 remains blocked/reverted.
- Follow-up commit:
  `6fa5c16 fix: complete Windows redirect and path handling`.

Task 7 second review follow-up evidence on 2026-07-11:

- RED was recorded before production changes. The portable lifecycle
  executable failed to compile with missing `PublishFilesystemStage` and
  `staged_filesystem_path` members; the portable provenance executable failed
  with missing `CanonicalStageDirectory`; the shared transport fixture syntax
  check failed with missing `destination_filesystem_path`; and the focused
  Dart contract ended `+3 -1: Some tests failed.` because
  `std::optional<std::wstring> QueryHeader` was absent.
- GREEN: the lifecycle executable passed with a native Unicode path retained
  through snapshot and install handoff; the provenance executable passed for a
  Unicode trailing-separator parent and filesystem-root semantics; the shared
  transport fixture syntax check passed; and the focused source/live fixture
  suite passed all 4 tests.
- The Windows C ABI converts the artifact destination once to a filesystem
  path, passes it through `ArtifactDownloadRequest` without a UTF-8 round trip,
  and publishes the staged filesystem path into lifecycle state. Provenance
  verification and helper handoff consume the native snapshot/handoff path;
  compatibility string state remains available for the unchanged public C ABI
  result and non-Windows shared callers.
- WinHTTP header queries now distinguish a missing header from a present empty
  value. A redirect without `Location` raises the literal non-retryable
  `Redirect response is missing a Location header.` diagnostic, while an empty
  `Location` remains a valid empty reference and reaches the redirect limit.
- Windows canonical directory normalization trims trailing non-root separators
  before containment equality while retaining filesystem roots. The portable
  executable covers Unicode, a trailing separator, and root semantics.
- Windows Debug CMake, CTest, and .NET tests were not run on macOS. Step 5 and
  the final acceptance checkbox remain open. Task 6 remains blocked/reverted.
- Verified locally on macOS: both portable lifecycle/provenance executables
  passed under `-Wall -Wextra -Werror`; shared and Linux syntax checks passed;
  the focused source/live fixture suite passed 4 tests; format checked 213
  files with 0 changes; analyze exited 0 with 395 pre-existing info-only
  diagnostics; full Flutter passed 577 tests with 3 explicit
  environment-gated skips and 0 failures; touched-source banned API and
  `git diff --check` scans passed.
- Second follow-up commit for this changeset:
  `fix: finish Windows native path boundary`.

Task 7 final build-contract follow-up evidence on 2026-07-11:

- RED was recorded before the CMake change with
  `flutter test --no-pub test/linux_native_sdk_layout_test.dart`. The new
  focused contract failed with
  `Expected: not contains 'cxx_std_14'` and the run ended
  `+5 -1: Some tests failed.`
- GREEN after the minimal CMake change: the focused Linux native SDK contract
  passed all 6 tests. It now enumerates both Linux production libraries and
  all five native/runtime test targets and requires a literal C++17 compile
  feature for each.
- `desktop_updater_native`, `desktop_updater_runtime`, and the lifecycle,
  contract, artifact, and transport runtime tests now declare `cxx_std_17`;
  the existing native test was already C++17. No filesystem type was hidden
  and no regression test was weakened.
- Matrix inspection found no repository-root CMake project. Windows native
  production/test targets already declare C++17. Linux installed-package and
  Flutter consumer targets retain their C++14 minimum declarations because
  the exported `PUBLIC cxx_std_17` feature raises the effective compile
  standard when they link the native target; no consumer source change was
  required.
- Direct C++17 syntax checks passed for the Linux native library and the full
  Linux/shared runtime source set. Portable lifecycle and provenance
  executables built with `-Wall -Wextra -Werror` and passed. A Linux native
  CMake configure/build was attempted but unavailable on this macOS host with
  the literal diagnostic `cmake: command not found`; it is not counted as
  target-host evidence.
- Final local verification: the focused Linux SDK suite passed 6 tests; format
  checked 213 files with 0 changes; analyze exited 0 with 395 pre-existing
  info-only diagnostics; full Flutter passed 578 tests with 3 explicit
  environment-gated skips and 0 failures; `git diff --check` passed.
- Windows Debug CMake, CTest, and .NET were not run on macOS. Task 7 Step 5
  and the final acceptance checkbox remain open. Task 6 remains
  blocked/reverted.
- Build-contract follow-up commit for this changeset:
  `build: align native runtime with C++17`.

---

### Task 8: Separate macOS 10.15 Runtime from the 10.14 CocoaPods Fallback

**Files:**

- Modify: `macos/desktop_updater.podspec`
- Modify: `macos/desktop_updater/Sources/desktop_updater/DesktopUpdaterPlugin.swift`
- Modify: `Package.swift`
- Modify: `macos/desktop_updater/Package.swift`
- Modify: `test/macos_cocoapods_source_layout_test.dart`
- Modify: `test/macos_swift_package_test.dart`
- Modify: `.github/workflows/desktop-updater-ci.yml`
- Modify: `docs/native-sdk.md`
- Modify: `docs/native-runtime-api.md`

**Interfaces:**

- SwiftPM product/import remains `DesktopUpdaterKit`, macOS 10.15+.
- CocoaPods exact source allowlist contains four helper files plus
  `DesktopUpdaterPlugin.swift`, macOS 10.14.
- Runtime directory is absent from the pod target.

- [x] **Step 1: Rewrite the layout tests to fail on broad globs**

Assert the podspec names these exact helper files:

~~~text
DesktopUpdaterVersion.swift
Diagnostics.swift
MacInstallHelper.swift
MacInstallRequest.swift
~~~

Assert it includes the Flutter adapter, excludes `Runtime/**`, keeps 10.14,
and both SwiftPM manifests keep 10.15 and `DesktopUpdaterKit`.

- [x] **Step 2: Replace the podspec Runtime glob with an allowlist**

List the four helper files and adapter glob explicitly. Do not rename the Swift
module, product, target, or public imports.

- [x] **Step 3: Add a macOS 10.14 launch fallback**

Keep the 10.15 `NSWorkspace.OpenConfiguration` path behind
`if #available(macOS 10.15, *)`. On 10.14 use
`NSWorkspace.shared.launchApplication(destinationURL.path)`; return the same
Flutter error shape when launch fails.

- [x] **Step 4: Typecheck the exact pod source set**

Add the exact CI command:

~~~sh
xcrun swiftc -typecheck -target x86_64-apple-macosx10.14 -swift-version 5 -module-cache-path "$RUNNER_TEMP/desktop-updater-swift-module-cache" -F "$FLUTTER_ROOT/bin/cache/artifacts/engine/darwin-x64/FlutterMacOS.xcframework/macos-arm64_x86_64" macos/desktop_updater/Sources/DesktopUpdaterKit/DesktopUpdaterVersion.swift macos/desktop_updater/Sources/DesktopUpdaterKit/Diagnostics.swift macos/desktop_updater/Sources/DesktopUpdaterKit/MacInstallHelper.swift macos/desktop_updater/Sources/DesktopUpdaterKit/MacInstallRequest.swift macos/desktop_updater/Sources/desktop_updater/DesktopUpdaterPlugin.swift
~~~

Expected: exit 0. Keep the current CocoaPods Flutter integration build and
SwiftPM external consumer as separate gates.

- [x] **Step 5: Run macOS verification**

Run:

~~~sh
flutter test --no-pub test/macos_cocoapods_source_layout_test.dart test/macos_swift_package_test.dart
swift test
~~~

Expected: PASS; exact 10.14 typecheck exit 0; SwiftPM runtime tests remain
macOS 10.15+.

- [x] **Step 6: Commit**

~~~sh
git add macos Package.swift test .github/workflows/desktop-updater-ci.yml docs/native-sdk.md docs/native-runtime-api.md
git commit -m "fix: preserve macOS CocoaPods compatibility"
~~~

Task 8 evidence on 2026-07-11:

- RED: the stricter exact-source, CI-command, fallback, and documentation tests
  ran before the Task 8 implementation. Seven tests passed and two failed for
  the intended missing behavior: the workflow did not contain the exact macOS
  10.14 `xcrun swiftc` command, and the native SDK/runtime documentation did
  not state the 10.15 SwiftPM versus 10.14 CocoaPods boundary.
- The podspec exact five-file allowlist, `Runtime/**` exclusion, macOS 10.14
  floor, both macOS 10.15 SwiftPM manifests, `DesktopUpdaterKit` product and
  import, and the availability-gated legacy launch fallback were already
  correct from the earlier Task 4 remediation. Their stricter tests passed in
  the RED run, so those production files were not churned to manufacture a
  failure. No Flutter MethodChannel, signing, provenance, or trust behavior
  changed in this task.
- GREEN, verified locally: the focused Flutter command passed all 9 tests. The
  exact five-file `xcrun swiftc -typecheck` command targeting
  `x86_64-apple-macosx10.14` exited 0. Root SwiftPM passed 49 tests and the
  plugin SwiftPM package passed 51 tests; the latter emitted only its existing
  unhandled `PrivacyInfo.xcprivacy` warning.
- Wider verification, verified locally: formatting checked 213 files with no
  changes; analysis exited 0 with 395 existing info-only diagnostics; the full
  Flutter suite passed 581 tests with 3 explicit environment-gated skips and
  0 failures; `git diff --check` passed.
- CI, the CocoaPods Flutter integration build, `pod lib lint`, and actual
  macOS 10.14 runtime launch execution were not run. The local host has no
  `pod` executable. Signed/notarized and credential-gated release lanes remain
  not run, and the native runtime remains candidate-only.

Task 8 post-commit review remediation evidence on 2026-07-11:

- Review RED, verified locally: bad fixtures reproduced every permissive
  matcher gap before the strict helpers existed. The combined focused run had
  9 passes and 5 expected failures for an ignored literal pod source plus a
  commented 10.14 floor, an exact CI-command prefix with an extra source, a
  commented-only CI command, launch APIs in the wrong availability branches,
  and SwiftPM declarations present only in comments. A sixth focused RED
  independently proved that a multiline `Runtime/*.swift` entry was ignored.
- Resolution: the podspec validator now strips Ruby comments, parses the one
  active `s.source_files` array in full, normalizes every literal `File.join`
  entry, and compares exact five-file order while anchoring the active platform
  and Swift assignments. The workflow validator extracts the named step's
  active `run:` scalar at the correct YAML indentation, requires exact command
  equality, and separately verifies the SwiftPM consumer and CocoaPods Flutter
  matrix/build/integration gates.
- The launch validator uses brace-aware extraction of the macOS 10.15 and
  fallback branches, confines each workspace API to its branch, and compares
  the shared modern completion and legacy `FlutterError` code, message, and
  details shape. SwiftPM validation strips comments and binds active macOS
  10.15, product, module, dependency, and target-path declarations. Repository
  assertions and bad-fixture meta-tests use the same validators.
- GREEN, verified locally: the focused Flutter suite passed all 15 tests; the
  exact macOS 10.14 five-file typecheck exited 0; root SwiftPM passed 49 tests;
  and plugin SwiftPM passed 51 tests with only its existing privacy-resource
  warning. Formatting checked 213 files unchanged, analysis exited 0 with the
  existing 395 info-only diagnostics, and full Flutter passed 587 tests with
  3 explicit environment-gated skips and 0 failures.
- Final-review RED, verified locally: the focused two-file run failed 6 tests
  for an accepted post-allowlist pod mutation, native gates accepted in the
  wrong YAML job, launch API/error tokens accepted from strings or comments,
  an unrelated availability check rejected, SwiftPM declarations accepted
  outside `Package(...)` fields, and the Flutter product dependency accepted
  from the wrong target. These failures preceded the final helper rewrite.
- Final-review resolution: the test contract now uses a 63-line shared lexical
  source helper plus narrow podspec, job-scoped workflow, launch-body, and
  `Package(...)` field checks. Bad fixtures cover `replace`, append, shift,
  multiline extra sources, commented floors, missing job/condition/enable/
  working-directory gates, comment/string decoys, unrelated availability,
  declarations outside `Package(...)`, and a Flutter product dependency on a
  decoy target. The formatted test-only diff adds 594 lines over the Task 8
  implementation commit, below the 600-line review ceiling.
- Final-review GREEN, verified locally: `flutter test --no-pub
  test/macos_cocoapods_source_layout_test.dart
  test/macos_swift_package_test.dart` passed all 14 tests; direct Dart format
  reported all three touched test files formatted; and `git diff --check`
  passed. Analysis, the full Flutter suite, SwiftPM suites, and the exact
  macOS 10.14 typecheck were not rerun after this final test-helper rewrite;
  the earlier results above remain evidence for the preceding test revision,
  not for this final diff.
- Targeted final-review RED, verified locally: the combined focused run passed
  14 tests and failed 2 because the pod validator accepted `.push`/`+` tokens
  after the exact array and the launch validator accepted a legacy workspace
  API in the modern branch. After correcting an older synthetic workflow
  fixture to mutate the real green workflow, its isolated run also failed as
  expected with `Actual: []` because an exact native gate embedded in the job's
  multiline `name: |` scalar was accepted outside the real `steps:` sequence.
- Targeted final-review resolution: the pod validator now requires the active
  assignment RHS to terminate after the parsed array; the workflow validator
  extracts the job's one `steps:` sequence and compares each named step through
  its next same-indent step/end, rejecting block-scalar decoys and extra fields
  such as `continue-on-error`; and launch validation explicitly rejects the
  legacy API in the modern branch and both modern APIs in the fallback branch.
  The additional fixtures and structural checks increase the formatted
  test-only addition from 594 to 684 lines over the Task 8 implementation
  commit; no production source is part of that delta.
- Targeted final-review GREEN, verified locally: the same focused two-file
  command passed all 16 tests; direct Dart format checked the three touched
  test files with 0 changes; and `git diff --check` passed. Analysis, full
  Flutter, SwiftPM, and the macOS 10.14 typecheck were not run in this targeted
  review wave.
- Final Ruby-continuation RED/GREEN, verified locally: independent review
  demonstrated that Ruby accepts a leading-dot `.push(...)` on the line after
  the exact source array. A matching fixture was added before the validator
  inspected the first active token on the following line. The focused
  two-file command then passed all 16 tests, direct Dart format reported 0
  changes, and `git diff --check` passed. The final test-only addition is 694
  lines over the Task 8 implementation commit. Wider suites were not rerun in
  this last focused wave.
- Commit-gate verification after the final lint cleanup, verified locally:
  the exact five-file macOS 10.14 `xcrun swiftc -typecheck` command exited 0
  with a fresh module cache; root SwiftPM passed 49 tests; plugin SwiftPM
  passed 51 tests with only its existing privacy-resource warning; analysis
  returned to the existing 395 info-only diagnostics; the focused contract
  suite passed all 16 tests; full Flutter passed 588 tests with 3 explicit
  environment-gated skips and 0 failures; and `git diff --check` passed. The
  formatted lint-clean test/support addition is 734 lines over the Task 8
  implementation commit. The first typecheck attempt hit a duplicate module
  cache path (`/tmp` versus `/private/tmp`) and Swift frontend signal 11; that
  environmental attempt is not counted as a pass. CI, CocoaPods consumer/lint,
  real macOS 10.14 launch, and signed/notarized lanes remain not run.
- No production source, podspec, manifest, public Flutter/MethodChannel API,
  signing, provenance, or trust behavior changed in this review remediation.
  CI, CocoaPods consumer/lint, real macOS 10.14 runtime launch,
  signing/notarization, credentials, and release smoke remain not run; the
  native runtime remains candidate-only.

---

### Task 9: Make Native Packages Retail-Consumable

**Files:**

- Modify: `.github/workflows/desktop-updater-ci.yml`
- Modify: `windows/native/CMakeLists.txt`
- Modify: `windows/native/dotnet/DesktopUpdater.Native/DesktopUpdater.Native.csproj`
- Modify: `windows/native/dotnet/DesktopUpdater.Native/DesktopUpdaterClient.cs`
- Modify: `windows/native/dotnet/DesktopUpdater.Native.Tests/`
- Modify: `linux/native/CMakeLists.txt`
- Modify: `linux/native/cmake/desktop_updater_native.pc.in`
- Modify: `third_party/README.md`
- Create: `windows/native/THIRD_PARTY_NOTICES.md`
- Create: `linux/native/THIRD_PARTY_NOTICES.md`

**Interfaces:**

- NuGet contains Release native DLLs and third-party notices.
- Installed CMake trees contain notices.
- pkg-config uses configure-time absolute prefix/libdir/includedir values that
  survive Debian multiarch layouts.
- .NET client uses a finalizable SafeHandle-based native owner and no
  self-rooting `GCHandle`.

- [x] **Step 1: Add failing package-content and clean-host tests**

Require Release DLL paths, reject a DLL linked to Debug CRT, require notices in
NuGet/install trees, compile/link/run pkg-config from a
`lib/<multiarch>/pkgconfig` prefix, and force GC without calling Dispose to
prove the native client is released.

- [x] **Step 2: Build retail native DLLs**

Configure/build/install Windows native targets with `--config Release`.
Set `CMAKE_MSVC_RUNTIME_LIBRARY` explicitly to
`MultiThreaded$<$<CONFIG:Debug>:Debug>DLL`. Pack only
`windows/native/build/Release/*.dll`.

- [x] **Step 3: Package third-party notices**

Include miniz MIT and Monocypher CC0/BSD-2-Clause texts in NuGet and both CMake
install trees. Extend package verification to require the notice entry.

- [x] **Step 4: Fix pkg-config relocation**

Use configured `CMAKE_INSTALL_PREFIX`, `CMAKE_INSTALL_FULL_LIBDIR`, and
`CMAKE_INSTALL_FULL_INCLUDEDIR` rather than deriving prefix from
`pcfiledir/../..`. Test both `lib/pkgconfig` and
`lib/x86_64-linux-gnu/pkgconfig`.

- [x] **Step 5: Replace the .NET self-root**

Wrap the native client in `SafeHandle`. Keep delegates rooted by the managed
client without allocating a `GCHandle` that points back to the same object.
If native callbacks require context, allocate a separate callback-state object
owned by the SafeHandle and release it in `ReleaseHandle`.

- [x] **Step 6: Run package consumers**

Run target-host:

~~~text
Windows Release cmake --install + external find_package consumer
Release NuGet pack + isolated restore/build/run P/Invoke smoke
Linux install + external find_package consumer
Linux pkg-config compile/link/run from multiarch prefix
~~~

Expected: every consumer uses installed/package files, not source-tree paths.

- [x] **Step 7: Commit**

~~~sh
git add .github/workflows/desktop-updater-ci.yml windows/native linux/native third_party/README.md
git commit -m "fix: make native packages retail consumable"
~~~

Task 9 evidence on 2026-07-11:

- RED, verified locally: `flutter test --no-pub
  test/native_package_retail_contract_test.dart` ran four focused contract
  tests and all four failed for the intended missing behavior: no explicit
  retail MSVC runtime/Release package paths, missing platform notice files,
  `pcfiledir/../..` pkg-config derivation, and no finalizable SafeHandle owner.
  The managed RED `dotnet test ... --no-restore` failed at compile time with
  `CS0117` because the GC-without-Dispose test seam did not yet exist.
- GREEN, verified locally: the focused Flutter package/layout suite passed 17
  tests. Its portable clean-prefix probe generated configured `.pc` files in
  both `lib/pkgconfig` and `lib/x86_64-linux-gnu/pkgconfig`, then used the host
  `pkg-config --cflags --libs` output to compile, link, and run a consumer for
  each layout.
- GREEN, verified locally: `dotnet build` in Release mode compiled both
  `net8.0` and `netstandard2.0` with 0 errors. The seven portable
  `DesktopUpdaterClientTests` passed under the locally installed .NET 10 host
  with major roll-forward, including forced GC without `Dispose`; the fake
  native release callback ran exactly once for handle `0x42`. NuGet packing
  with portable placeholder DLL inputs succeeded and the archive contained
  both managed TFMs, both exact `runtimes/win-x64/native` DLL entries, the
  build-transitive target, and root `THIRD_PARTY_NOTICES.md`. The placeholder
  pack proves package layout only, not Windows binary validity.
- The managed runtime now passes its finalizable SafeHandle directly to every
  client P/Invoke, so the marshaller holds a reference across each native
  call. The handle owns the callback delegates and a separate `CallbackState`
  GCHandle, calls native client free before releasing callback state, and no
  longer allocates a GCHandle pointing back to `DesktopUpdaterClient`.
- The Windows CMake source explicitly selects
  `MultiThreaded$<$<CONFIG:Debug>:Debug>DLL`; CI builds, tests, installs, and
  packs Release DLLs, locates `dumpbin.exe`, and rejects Debug UCRT,
  VCRUNTIME, or MSVCP imports before packing. NuGet and both installed CMake
  trees require notices reproducing the pinned miniz MIT and Monocypher
  BSD-2-Clause/CC0 texts.
- Wider verification, verified locally: workflow YAML parsed successfully;
  formatting checked 215 files with 0 changes; focused analysis reported no
  issues in the new test; repository analysis exited 0 with 395 info-only
  diagnostics; full Flutter passed 593 tests with 3 explicit
  environment-gated skips and 0 failures; `git diff --check` passed.
- Task 9 Step 6 remains open. Windows Release CMake build/install,
  `dumpbin` CRT inspection, installed `find_package`, real-DLL NuGet isolated
  restore/P/Invoke smoke, and Linux installed CMake/pkg-config consumers were
  not run on this macOS host. `cmake` is unavailable locally. These target-host
  lanes are configured in CI but are not claimed as verified in CI. Task 6
  remains blocked/reverted, signed/notarized credential lanes remain not run,
  and the runtime remains candidate-only.
- Post-commit independent review found two P1 lifetime/package-proof gaps in
  the first Task 9 changeset. A strong callback-state `GCHandle` could still
  root a client when an application callback captured that client, and the
  Windows packaged-consumer jobs could reuse a stale global NuGet cache entry
  for the canonical package version. The first seven-test finalizer seam also
  bypassed production callback state and did not prove that cycle.
- Follow-up RED, verified locally: the focused Flutter package contract failed
  two assertions for the strong callback token and missing isolated verifier;
  the managed tests failed to compile after requiring the production-shaped
  callback-state release seam; and a capture-cycle finalizer test reproduced
  the lifetime gap. A short weak token allowed collection but was cleared
  before `ReleaseHandle` could observe callback state, so that intermediate
  attempt is not counted as GREEN.
- Follow-up resolution: `NativeClientHandle` strongly owns the managed
  callback state and callback delegates, while its native context is a
  non-rooting `WeakTrackResurrection` token. SafeHandle marshalling retains the
  owner during every P/Invoke. Native/fake release runs while callback state is
  still available, then the weak token is freed and the state reference is
  cleared. The private test seam uses the same callback-state constructor as
  production. Eight managed tests now include GC without `Dispose`, an
  application delegate/client capture cycle, exactly-once release, and state
  visibility during release.
- Windows packaged consumers now call
  `tool/verify_windows_nuget_consumer.ps1` in three distinct runner-temp lanes
  (ordinary consumer, ZIP smoke, and credential-gated Inno smoke). The script
  removes lane and project `obj`/`bin` state, uses lane-local package,
  intermediate, assets, and output paths with `--no-cache` and the explicit
  candidate version, then compares SHA-256 for both exact NuGet runtime DLL
  entries against the isolated cache and consumer output. This PowerShell path
  was source-reviewed and contract-tested but not executed on macOS because
  `pwsh`/Windows native DLL execution is unavailable; Step 6 remains open.
- Final verifier-contract RED/GREEN, verified locally: mutation assertions
  initially passed incorrectly when package-version/no-cache/cleanup/digest or
  candidate-to-cache/output comparison proof was removed. The strengthened
  validator now rejects each mutation. The focused package/docs/layout command
  passed all 22 tests; the broader follow-up verification is recorded below.
- Follow-up commit gate, verified locally: Release `dotnet build` compiled
  `net8.0` and `netstandard2.0` with 0 errors (only offline `NU1900` audit
  warnings); the eight `DesktopUpdaterClientTests` passed with 0 failures;
  formatting checked 215 files with 0 changes; repository analysis exited 0
  with the existing 395 info-only diagnostics; full Flutter passed 595 tests
  with 3 explicit environment-gated skips and 0 failures; and
  `git diff --check` passed. The first managed test attempt was stopped because
  the sandbox denied the VSTest localhost socket; the identical permitted run
  passed 8/8 and is the counted evidence. Windows PowerShell/real DLL and Linux
  CMake target-host lanes remain not run, so Step 6 stays open.
- Unsupported-RID follow-up RED/GREEN, verified locally on 2026-07-13: the
  focused NuGet target contract first exited 1 because the `buildTransitive`
  target had no RID guard, then passed after an explicit non-empty RID other
  than `win-x64` was rejected before asset existence checks or copying. A real
  host-independent `dotnet msbuild` probe with `RuntimeIdentifier=linux-x64`
  exited 1 with the exact supported-RID diagnostic. A packaged `win-x64`
  consumer with real Windows DLLs remains part of open Step 6 and is `not run`
  on this macOS host.
- Published-README follow-up RED verified locally on 2026-07-13: the focused
  archive-link contract exited 1 because `README.md` linked
  `docs/native-sdk.md` while `.pubignore` excluded all of `docs/`. An initial
  attempt to package the public `docs/` subtree made the contract pass but the
  real publication dry run exited 65 with Pub's plural top-level `docs`
  directory warning; that attempt is not counted as GREEN.
- Published-README follow-up GREEN verified locally on 2026-07-13: every
  remaining relative Markdown link in the archived README exists and is not
  pub-ignored, while repository-only `docs/` links use absolute `main` URLs.
  `docs/` remains excluded. A clean temporary working-tree copy ran
  `dart pub publish --dry-run` with exit 0, 0 warnings, and the existing single
  version hint; no version or lockfile changed.

---

### Task 10: Synchronize CI, Documentation, Plans, and the Final Merge Gate

**Files:**

- Modify: `.github/workflows/desktop-updater-ci.yml`
- Modify: `README.md`
- Modify: `docs/native-sdk.md`
- Modify: `docs/native-runtime-api.md`
- Modify: `docs/github-actions-ci-cd.md`
- Modify: `docs/diagnostics-and-recovery.md`
- Modify: `docs/migration/1.x-to-2.0.md`
- Modify: `docs/exec-plans/active/2026-07-05-full-native-runtime-preview-plan.md`
- Modify: this plan
- Create: `test/native_runtime_merge_gate_docs_test.dart`

**Interfaces:**

- Produces one literal merge-gate ledger with
  `verified locally`, `verified in CI`, `not run`, or `blocked` per lane.
- Keeps signed/notarized smokes separate from ordinary merge gates while the
  runtime remains candidate-only.

- [x] **Step 1: Add failing docs/CI drift tests**

Require documentation and workflow text for:

~~~text
native SwiftPM macOS 10.15
Flutter CocoaPods macOS 10.14 exact source set
DesktopUpdaterKit import unchanged
signed app-archive authority
owned stage provenance
explicit install target proof
mount/reparse rejection
one-shot handoff and recovery journal
Windows Unicode and relative redirect fixtures
Release NuGet and notices
~~~

Reject claims that signed/notarized DMG, PKG, or Inno passed when their
credential lane did not run.

- [ ] **Step 2: Add target-host merge-gate jobs**

Required non-credential gates:

~~~text
Dart format/analyze/full tests/pub dry-run
SwiftPM tests and external consumer
exact CocoaPods 10.14 source-set typecheck
current Flutter CocoaPods and SwiftPM builds
Windows Unicode path/relative redirect/tamper/reparse/recovery tests
Windows Release NuGet isolated P/Invoke smoke
Linux mount/bind/tamper/recovery tests
Linux CMake and multiarch pkg-config consumers
nonzero test discovery in every CTest lane
normal ZIP update smoke on macOS, Windows, and Linux
~~~

Credential-gated signed/notarized DMG, PKG, and Inno lanes remain
`not run` without secrets and keep the runtime candidate-only.

- [x] **Step 3: Run the complete local ladder**

Run:

~~~sh
dart run tool/generate_native_contract_fixtures.dart --check
dart format --set-exit-if-changed .
flutter analyze --no-fatal-infos
flutter test --no-pub
dart pub publish --dry-run
swift test
git diff --check
~~~

Expected: all commands exit 0; skipped external-service tests retain their
explicit opt-in labels.

- [x] **Step 4: Reconcile plan state and PR text**

Mark a checkbox complete only with command/run evidence. Keep open or
credential-dependent rows literal. Update the parent runtime plan to reference
this remediation plan and remove claims contradicted by current implementation.
Draft the corrected PR body for the user; do not post it through a connector.

#### Corrected PR #65 body draft (not posted)

~~~markdown
## Summary

- Aligns the native preview with the generated Dart schema-v3 behavior and
  authenticates signed app-archive policy before selection.
- Binds checks, stages, provenance, and explicit install-target proof without
  changing the released Flutter API/MethodChannel surface or the
  `DesktopUpdaterKit` product/import.
- Keeps the SwiftPM runtime at macOS 10.15+ and the exact six-source Flutter
  CocoaPods fallback at macOS 10.14.
- Makes Windows transport paths Unicode-safe, resolves bounded relative
  redirects, and packages Release NuGet DLLs with isolated-consumer hash proof
  and third-party notices.

## Verification

- Task 10 complete local ladder: `verified locally`; generated fixtures,
  repository format, analysis, 660 Flutter tests with 3 explicit skips, pub
  dry-run with 0 warnings and 1 hint, 52 SwiftPM tests, the exact macOS 10.14
  six-source typecheck, the external SwiftPM consumer, and diff check exited
  0.
- Current-head macOS, Windows, and Linux target-host CI: `verified in CI` in
  successful push run `29291937840` for commit `87a2adf`. The run includes both
  Flutter macOS integrations, native ZIP smokes on all three platforms,
  Windows CTest/Release NuGet/P/Invoke consumers, and Linux installed
  CMake/pkg-config consumers.
- Signed/notarized DMG, PKG, and signed Inno lanes: `not run` because their
  explicit credential gates were not dispatched.

## Remaining blocker

Durable native transaction recovery remains `blocked`. The reviewed
script-helper candidate was reverted because it could not provide safe
fd/handle-relative mutation, serialized recovery, and crash-safe journal
ownership. The approved packaged standalone-helper design is recorded in
`docs/superpowers/specs/2026-07-11-cross-platform-privileged-install-helper-design.md`,
but its implementation and target-host evidence are pending. The runtime
therefore remains `candidate-only`, and PR #65 is not merge-ready.
~~~

- [x] **Step 5: Perform the final adversarial review**

Run `killcritic-complete-review` again from a fresh finding list. Required
independent passes:

~~~text
safety/trust/destructive operations
build/link/package/external consumers
behavior/schema/API/compatibility
CI/release/tracker truth
~~~

The verdict may become GO only when no P0/P1 remains and no high-risk domain is
`NOT_VERIFIED`.

- [x] **Step 6: Record final evidence and commit documentation**

~~~sh
git add README.md docs test/native_runtime_merge_gate_docs_test.dart .github/workflows/desktop-updater-ci.yml
git commit -m "docs: record native runtime merge gates"
~~~

Task 10 evidence on 2026-07-11:

- RED, verified locally: `flutter test --no-pub
  test/native_runtime_merge_gate_docs_test.dart` ran five tests; four failed
  for the intended missing behavior (canonical macOS integration-floor text,
  current trust/safety and blocked-recovery language, target-host workflow
  gates, and one literal ledger/PR draft). The signed-lane mutation validator
  passed independently.
- GREEN, verified locally: the focused docs/CI suite passed 5/5. The combined
  docs, smoke, retail-package, CocoaPods-layout, and SwiftPM-layout command
  passed 36/36. The exact six-source macOS 10.14 `swiftc -typecheck` command
  exited 0, workflow YAML parsed successfully, and every existing macOS docs
  compatibility assertion remained green.
- Workflow configuration, not execution evidence: the Dart job now checks
  generated fixtures; target-host jobs retain nonzero CTest guards, packaged
  consumers, both current Flutter macOS integrations, and normal ZIP smokes.
  Windows names its Unicode/relative-redirect gate and isolated Release NuGet
  P/Invoke consumer; Linux names its native tamper gate and multiarch
  pkg-config consumer. Comments explicitly forbid treating these lanes as
  native transaction recovery evidence.
- Complete local ladder, verified locally: fixture generation reported
  `Native contract fixtures are up to date`; formatting checked 216 files with
  0 changes; repository analysis exited 0 with 395 pre-existing info-only
  diagnostics; full Flutter passed 600 tests with 3 explicit environment-gated
  skips and 0 failures; pub publish dry-run exited 0 with the expected dirty
  README warning and prior-version hint; SwiftPM passed 49 tests with 0
  failures; and `git diff --check` exited 0.
- Current-head macOS, Windows, and Linux target-host jobs: not run. GitHub
  Actions: not run; no `verified in CI` result is claimed. Signed/notarized DMG
  and PKG plus signed Inno credential lanes: not run.
- BLOCKED: Task 6 remains reverted. Cross-process target locking, durable
  transaction journal states, privileged Linux mount/bind recovery, complete
  Windows reparse-safe transaction mutation, and abrupt-crash recovery are not
  implemented or claimed. Task 10 Step 2 therefore remains open even though
  all safely configurable non-recovery jobs are present. The runtime remains
  candidate-only and PR #65 is not merge-ready.
- Review RED, verified locally: after validator false positives were removed,
  the six-test structural docs suite had exactly one failure: the repository
  lacked the required atomic `Current-Head Merge-Gate Ledger`. Five validator
  tests passed and proved rejection of duplicate/stale/deleted/status-swapped
  rows, commands hidden in YAML comments or moved to unrelated jobs, and
  backtick-free signed DMG/PKG/Inno promotion prose.
- Review GREEN, verified locally: the structural suite passed 6/6. The single
  ledger now separates locally verified macOS root SwiftPM and exact 10.14
  source-set evidence from the external consumer, both Flutter integration
  modes, and ZIP smoke that remain not run. Windows source-contract
  target/reparse evidence is separate from target-host CTest and from the
  blocked junction/reparse transaction; Linux target-host consumers are
  separate from the blocked mount/bind transaction. No current-head CI or
  credential-gated pass is claimed.
- Review verification, verified locally: the affected docs/package/macOS
  command passed 37 tests; workflow YAML parsed; formatting checked 216 files
  with 0 changes; focused analysis of the rewritten structural test reported
  no issues; repository analysis exited 0 with the existing 395 info-only
  diagnostics; full Flutter passed 601 tests with 3 explicit environment-gated
  skips and 0 failures; and `git diff --check` exited 0. Target-host, CI, and
  credential lanes remain not run, and Task 6 remains blocked.
- Final-truth RED, verified locally: after the validator-only mutations were
  green, the focused six-test structural suite had exactly one failure: the
  atomic ledger omitted the cross-platform/macOS packaged signed helper
  ownership-transfer, cross-process target-lock, durable-journal, and crash
  recovery blocker. The other five tests independently rejected duplicate
  ledgers, workflow false greens, and credential-lane promotion prose.
- Final-truth GREEN, verified locally: the focused structural suite passed 6/6
  after the missing blocker became its own atomic ledger row. Windows
  junction/reparse transaction mutation and Linux mount/bind transaction
  mutation remain separate blocked rows rather than being folded into the
  cross-platform/macOS architecture blocker.
- Final-truth verification, verified locally: the affected contract set passed
  45/45; workflow YAML parsed; formatting checked 216 files with 0 changes;
  focused analysis reported no issues; repository analysis exited 0 with the
  existing 395 info-only diagnostics; full Flutter passed 601 tests with 3
  explicit environment-gated skips and 0 failures; generated fixtures were up
  to date; and SwiftPM passed 49/49. Target-host, current-head CI, and
  credential lanes remain not run, and Task 6 remains blocked.
- Post-commit package verification, verified locally: `dart pub publish
  --dry-run` exited 0 with 0 warnings and the existing prior-version hint. No
  version, changelog heading, or lockfile changed.
- Final scanner RED/GREEN, verified locally: the structural workflow mutation
  initially accepted `flutter test --no-pub || true`, and credential prose
  initially allowed cross-artifact `passed`/`not run` clauses plus a
  contradictory `blocked but successful` claim. The validator now rejects
  shell-level failure suppression and evaluates artifact clauses separately
  for `passed`, `succeeded`, `successful`, `green`, `verified locally`, and
  `verified in CI`. Plain diagnostic `signature verified` text and explicit
  repository-style `RED, verified locally:` evidence remain non-promotional.
  The focused structural suite passed 6/6 and `git diff --check` passed; final
  independent targeted review reported no Critical, Important, or Minor
  finding in this false-green class. Wider suites were not rerun after this
  test-only scanner refinement; the preceding current-head ladder remains the
  latest broad evidence.

### Fresh Killcritic Remediation After Task 10

- [x] Reject incomplete macOS helper-only staged requests synchronously and
  expose a complete verified-stage handoff value without changing the
  `DesktopUpdaterKit` product or import.
- [x] Expose and marshal the complete .NET helper-only provenance handoff and
  reject incomplete staged calls before native scheduling.
- [ ] Run the Windows target-host C ABI test and a positive packaged .NET
  helper-only install smoke against the real DLL/helper.
- [x] Preserve the signed Inno `requiresElevation` policy through the native
  helper and compatible C/.NET boundaries.
- [ ] Run Windows target-host `auto`, `always`, `never`, UAC-cancel, protected
  target, and real packaged helper elevation tests.
- [x] Bound stable Flutter metadata downloads and archive expansion.
- [x] Remove elevated Windows diagnostics authority from caller-provided paths.
- [x] Keep Linux pkg-config metadata relocatable across documented install-time
  prefixes.
- [x] Declare the Linux preview runtime's CMake 3.12 floor without raising the
  helper-only CMake 3.10 floor.
- [x] Bound stable Flutter artifact transfer and keep Dart ZIP decoding
  file-backed.
- [x] Freeze the Windows runtime v1 by-value result layout and require exact
  scalar ABI/size preflight before .NET calls.
- [x] Resolve the stable Flutter metadata-authenticity default through an
  explicit public compatibility decision.
- [ ] Implement and prove the approved cross-platform privileged helper design.

Fresh-review evidence on 2026-07-11:

- Mac helper-only RED, verified locally: `swift test --filter
  MacInstallHelperTests` failed to compile because `MacVerifiedStage`, its
  request initializer, and synchronous complete-handoff validation did not
  exist. `flutter test --no-pub test/native_sdk_consumer_package_test.dart`
  failed because the external SwiftPM consumer did not construct verified
  provenance or use a verified-stage request.
- Mac helper-only GREEN, verified locally: the focused Swift suite passed 10/10;
  the full SwiftPM suite passed 51/51;
  the external SwiftPM consumer built and ran against the packaged
  `DesktopUpdaterKit` product; the Dart consumer and SwiftPM contract suites
  passed 12/12; and the exact six-source CocoaPods fallback typechecked at
  `x86_64-apple-macosx10.14`. The public legacy request initializer remains
  source-compatible, while any non-nil staged request lacking the complete
  provenance tuple now fails before helper-script creation.
- Task 6 architecture: `blocked / implementation pending`. The approved design
  is
  `docs/superpowers/specs/2026-07-11-cross-platform-privileged-install-helper-design.md`.
  Per user direction it is not implemented in this execution pass. Until its
  reservation, packaged helper, lock, durable journal, fd/handle-relative
  mutation, recovery, and target-host gates exist, the runtime remains
  `candidate-only` and PR #65 remains not merge-ready.
- .NET helper-only RED, verified locally: the focused managed test project
  failed to compile because `DesktopUpdaterInstallRequest` did not exist. The
  focused Dart package/layout suite failed because the wrapper did not marshal
  provenance, artifact, or signer fields and the isolated consumer still used
  the incomplete legacy staged overload.
- .NET helper-only GREEN, verified locally: both `net8.0` and `netstandard2.0`
  wrapper targets compiled; the three new platform-independent managed tests
  passed under the locally installed .NET 10 runtime with major roll-forward;
  and the focused Dart layout/package suite passed 11/11. The C ABI parser now
  rejects a non-empty stage with missing provenance or target proof before the
  scheduler callback, with a source-level GTest covering the boundary.
- Windows C ABI GTest, isolated Release NuGet consumer, and a positive packaged
  helper-only install: not run on a Windows target host. The local full managed
  suite ran 11/12 tests; its sole failure was the pre-existing real-DLL P/Invoke
  test because a Windows DLL cannot load on macOS. These target-host gates stay
  open and are not promoted to `verified locally`.
- Windows elevation-policy RED, verified locally: the focused Dart suite failed
  to
  compile because the internal compatible MethodChannel handoff had no
  `innoRequiresElevation` value; the native structural tests failed because the
  C ABI, managed wrapper, and helper had no typed elevation policy; and the
  focused managed tests failed to compile because
  `DesktopUpdaterElevationPolicy` did not exist.
- Windows elevation-policy GREEN, verified locally: the focused Dart
  MethodChannel, helper, Windows layout, and package suites passed 46/46; both
  managed wrapper target frameworks compiled; and the focused managed request
  tests passed 2/2. `auto`, `always`, and `never` now cross the verified Dart
  descriptor, compatible MethodChannel arguments, Windows adapter, appended C ABI field,
  managed request, and native runtime handoff. The helper binds the requested
  value back to the provenance-protected release manifest before installer
  execution, `always` requests elevation, and `never` rejects an unwritable
  target rather than silently elevating. Legacy C ABI struct sizes default to
  `auto`, and restart-only calls remain non-elevating.
- Windows UAC/elevation target-host suite: not run. Source-level GTests cover
  policy parsing, invalid-value rejection before scheduler invocation, and the
  pure launch decision, but actual UAC and real helper execution remain open.
- Elevated Windows diagnostics RED on 2026-07-13, verified locally: `flutter
  test --no-pub test/native_helper_script_test.dart
  test/native_helper_diagnostics_docs_test.dart` exited 1 after 32 tests with
  exactly the two expected failures. The native source still interpolated
  `request.diagnostics_log_path` directly, and the diagnostics guide still
  claimed elevated helper file events instead of the required containment.
- Elevated Windows diagnostics GREEN on 2026-07-13, verified locally: the same
  focused command passed 34/34. Native scheduling now selects an empty helper
  diagnostics path from the resolved `PowerShellLaunchMode::kElevated` before
  PowerShell quoting and script construction, while the normal branch retains
  `request.diagnostics_log_path`. Source contracts reject direct caller-path
  interpolation in the generated script, and diagnostics documentation states
  the elevated-versus-normal boundary literally.
- Windows UAC and real helper execution for the diagnostics containment on
  2026-07-13: `not run`. The separate Windows target-host elevation checkbox
  remains open.
- Elevated Windows diagnostics independent-review RED on 2026-07-13, verified
  locally: the original scanner inspected only the generated-script tail and
  could miss a pre-script caller-path alias, alternate PowerShell sink, second
  `Add-Content`, or another write primitive. After the mutation fixtures were
  added first, `flutter test --no-pub test/native_helper_script_test.dart`
  compile-failed solely because the wished-for
  `_windowsDiagnosticsContainmentViolations` helper was missing at five call
  sites.
- Elevated Windows diagnostics independent-review GREEN on 2026-07-13,
  verified locally: the reusable real-source invariant scopes checks to
  `ScheduleInstallAndRelaunch`, and mutation fixtures reject a pre-script
  caller-path alias, generic alternate `Set-Content` sink, and second
  `Add-Content` sink. The focused helper suite passed 28/28 and the affected
  helper, docs, Windows layout, diagnostics, MethodChannel, and runtime API set
  passed 64/64. Formatting and `git diff --check` were clean; scoped analysis
  exited 0 with only five pre-existing info diagnostics. The production
  implementation and diagnostics checkbox are unchanged. Windows target-host
  UAC and real helper execution: `not run`.
- Stable Flutter resource-limit RED, verified locally: `flutter test --no-pub
  test/native_runtime_resource_limits_test.dart` failed because the optional
  bounded transport capability, 4 MiB metadata limit, and configurable ZIP
  limits did not exist. A second focused RED proved the file and composite
  built-in transports did not yet expose the compatible bounded path.
- Stable Flutter resource-limit GREEN, verified locally: the focused suite
  passed 14/14 and the affected transport, extractor, client-security, and ZIP
  compatibility set passed 45/45. Built-in HTTP rejects declared and streamed
  overruns without retry and cleans partial/destination files; `UpdateClient`
  bounds both stable metadata files while retaining a checked legacy custom
  transport fallback. ZIP and ZIP64 central-directory metadata is preflighted
  before Dart extraction or macOS `ditto`, with decoded-size rechecks and exact
  100,000-entry, 8 GiB cumulative, and 4 GiB single-entry defaults.
- Stable Flutter resource-limit verification, verified locally: formatting
  checked 218 files with 0 changes; focused analysis reported no issues;
  repository analysis exited 0 with the existing info-only diagnostics; and
  `git diff --check` passed. The full Flutter suite reached 616 passes and 3
  explicit environment-gated skips with only the existing unrelated
  harness-doc failure caused by the user-owned dirty
  `docs/exec-plans/index.md`, which remains unmodified and unstaged. Target-host
  and CI lanes were not run.
- Stable Flutter local-header review RED, verified locally: the focused suite
  reached 15 passes and 4 failures because conflicting, missing, and truncated
  local ZIP/ZIP64 metadata still reached macOS `ditto`, while a valid legacy
  flag-clear non-UTF8 filename was rejected by unconditional UTF-8 decoding. A
  separate overflow RED proved signed ZIP64 overflow needed explicit handling.
- Stable Flutter local-header review GREEN, verified locally: the resource-limit
  suite passed 20/20 and the affected transport, extractor, client-security,
  and ZIP compatibility set passed 51/51. Preflight now reconciles local flags,
  compression, CRC, 32-bit sizes, and required ZIP64 values with central
  metadata before `ditto`, permits valid data-descriptor placeholders, rejects
  signed overflow, and decodes filenames according to the ZIP UTF-8 flag.
  Focused analysis reported no issues; formatting changed 0 files; and
  `git diff --check` passed.
- Stable Flutter data-descriptor review RED, verified locally: the focused suite
  reached 21 passes and 3 failures because conflicting, truncated, and
  signed-range-overflowing ZIP64 data descriptors still reached macOS `ditto`.
  Valid signed and unsigned descriptors, including an unsigned descriptor whose
  CRC equals the optional signature, remained accepted.
- Stable Flutter data-descriptor review GREEN, verified locally: the
  resource-limit suite passed 24/24 and the affected transport, extractor,
  client-security, and ZIP compatibility set passed 55/55. Preflight now parses
  signed and unsigned classic and ZIP64 descriptors at the compressed-data
  boundary, reconciles CRC and sizes with central metadata, rejects truncated
  ranges before the next ZIP structure, and rejects signed ZIP64 overflow before
  `ditto`. Focused analysis reported no issues and `git diff --check` passed.
- RED, verified locally: the Linux pkg-config relocation suite failed 2 tests
  on 2026-07-13 because the template embedded
  configure-time absolute install directories and could not compile through
  the documented install-time `cmake --install --prefix` layout.
- Linux installed-metadata relocation GREEN on 2026-07-13, verified locally: the
  `.pc` template now derives its prefix from `pcfiledir`, including the standard
  and multiarch library layouts. Standard and multiarch CI configuration now
  installs with an explicit install-time prefix, and the native retail,
  Linux-layout, native-SDK docs, and merge-gate docs set passed 23/23. An
  independent build/package review found the fix coherent. Linux target-host
  CMake execution and current-head CI remain `not run` on this macOS host;
  Task 9 Step 6 remains open.
- RED, verified locally: the Linux layout suite failed 1 test on 2026-07-13
  because the opt-in runtime linked the CMake 3.12-era imported libcurl target
  while the only declared project floor was CMake 3.10.
- Linux runtime CMake-floor GREEN on 2026-07-13, verified locally: runtime
  configuration now fails clearly below CMake 3.12, while the runtime-off
  helper retains CMake 3.10 compatibility. The Linux README and native SDK guide
  state the split literally, and the affected Linux layout, native SDK docs,
  native retail, and merge-gate docs set passed 24/24. CMake 3.10/3.11
  target-host configuration and current-head CI remain `not run` on this host.
- Stable Flutter artifact-bound RED on 2026-07-13, verified locally: the
  resource-limit suite reached 24 passes and 2 failures because artifact
  transfer still used the unbounded transport path and Dart ZIP decoding read
  the complete compressed archive into memory.
- Stable Flutter artifact-bound GREEN on 2026-07-13, verified locally: built-in
  transports now enforce the descriptor artifact length in flight, compatible
  legacy custom transports reject an overrun immediately after download, and
  Dart extraction decodes from a file-backed input retained through lazy entry
  writes. Focused review found no Critical or Important issue. Added cleanup
  regressions prove built-in and legacy overruns remove partial/owned stages,
  and successful extraction closes the archive input and removes scratch. The
  focused suite passed 29/29; the affected transport, extractor, client-trust,
  ZIP compatibility, and end-to-end set passed 67/67; focused analysis reported
  no issues; formatting and `git diff --check` passed. Target-host and CI lanes
  remain `not run`.
- Windows runtime ABI RED on 2026-07-13, verified locally: the eight-test
  runtime API contract suite reached 7 passes and 1 failure because no scalar
  ABI/result-size probes or pre-call .NET layout verification existed. The
  Windows C ABI compile smoke was extended first to call both missing probes.
- Windows runtime ABI GREEN on 2026-07-13, verified locally: additive C exports
  report ABI v1 and the exact architecture-specific result size; the .NET
  wrapper verifies both before allocating or making a by-value call and checks
  the returned ABI fields before reading the result. The v1 result layout is
  documented as frozen, with any future change requiring new versioned types
  and entry points. The Dart contract suite passed 8/8, the C++14 header
  consumer passed strict syntax checking, both `net8.0` and `netstandard2.0`
  wrapper builds completed with 0 errors, and the platform-independent managed
  client set passed 8/8.
- Windows runtime ABI review RED/GREEN on 2026-07-13, verified locally:
  independent review found that a per-result mismatch after native client
  creation could leak the untransferred client handle. The cleanup invariant
  failed 1 focused test before the constructor `finally` began freeing and
  clearing any residual client before result-string cleanup; the focused suite
  then passed 8/8. The full managed set reached 11 passes and 1 target-native
  failure because a Windows DLL cannot load on this macOS host. Real Windows
  probe/mismatch execution and the positive packaged DLL test remain `not run`,
  so the target-host checkbox above remains open. The affected runtime API,
  Windows layout, external-consumer, and merge-gate docs set passed 25/25;
  independent re-review found no remaining Critical or Important issue.
- Pause handoff on 2026-07-11: `flutter analyze --no-fatal-infos` exited 0 with
  the repository's existing info-only diagnostics; the focused affected Dart
  and docs suites passed 52/52; both managed targets compiled; and the focused
  managed tests passed 2/2. A full Flutter run reached 601 passes and 3 explicit
  skips with two docs failures. The credential-claim failure was resolved and
  its focused suite passed; the remaining harness failure is unrelated to this
  task and requires the user-owned dirty `docs/exec-plans/index.md` to index the
  already-present Linux distribution plan. That user change remains unmodified
  and unstaged. Windows UAC/real-DLL execution remains `not run`.

### Fresh completion verification and adversarial review on 2026-07-13

- Windows runtime ABI task: verified locally and committed as `e04fe90`. The
  focused Dart contract passed 8/8, the C++14 header consumer passed strict
  syntax checking, and the `net8.0` and `netstandard2.0` Release builds each
  completed with 0 errors. Real Windows ABI probe execution remains `not run`.
- Complete Task 10 ladder: blocked. Fixture generation was current; formatting
  checked 218 files with 0 changes; analysis exited 0 with 385 info-only
  diagnostics; the publication dry run reported 0 warnings and 1 version hint;
  SwiftPM passed 51/51; the exact macOS 10.14 six-source typecheck and
  `swift run --package-path example/native/macos` passed; and
  `git diff --check` exited 0. The full Flutter run reached 647 passes and 3
  explicit skips with 1 failure in
  `test/harness_engineering_docs_test.dart`: the user-owned dirty plan index
  omits both active 2026-07-11 plans. That file remains unmodified and unstaged,
  so Task 10 Step 3 remains open.
- Focused cross-domain review suites: verified locally. The affected Flutter
  facade/trust group passed 62/62; the schema/API/MethodChannel group passed
  57/57; the corrected merge-gate docs suite passed 9/9; and the strict
  portable C++17 Clang/OpenSSL fixture runner compiled with
  `-Wall -Wextra -Werror` and exited 0. The exact five-file CocoaPods fallback
  source set typechecked for `x86_64-apple-macosx10.14`, and the external
  SwiftPM consumer built and executed. The `DesktopUpdaterKit` product/import
  and macOS 10.15 runtime floor remain unchanged.
- `superpowers:verification-before-completion`: performed. Its fresh-evidence
  gate rejects a completion claim because the complete Flutter command exited
  1 and the required target-host, credential, and Task 6 evidence is absent.
- `killcritic-complete-review`: performed serially from a fresh finding list
  across safety/trust/destructive operations, build/link/package/consumers,
  behavior/schema/API/compatibility, and CI/release/tracker truth. Verdict:
  `BLOCK / NO-GO`.

Validated blockers and major findings:

- Resolved P0 metadata-authenticity facade gap: the released
  `DesktopUpdaterController` and `DesktopUpdater` facade now accept
  `trustedReleasePublicKeys` and bind the same pinned Ed25519 map to strict
  app-archive and descriptor verification. Null retains the Step 5 unsigned
  2.x compatibility default and is documented as not production-authenticated;
  production callers have an explicit fail-closed path without a source or
  MethodChannel break.
- P0 transaction safety: current macOS, Windows, and Linux helpers mutate the
  live install through generated shell or PowerShell scripts without one
  cross-process target lock, a durable write-ahead journal, or restartable
  crash recovery. Process termination or power loss can leave a partial target
  and an unowned backup. The approved privileged-helper implementation plan is
  present but intentionally not implemented in this remediation run.
- P0 mount/reparse race safety: path, identity, provenance, and reparse checks
  occur before later path-string `mv`, `rm -rf`, `Remove-Item`, `Copy-Item`, and
  `cp` operations. No fd/handle-relative mutation or stable mount/reparse
  boundary ownership survives the validation-to-mutation interval. Task 6 must
  provide the packaged broker/helper and target-host adversarial evidence.
- P1 ordinary merge gate: the current full Flutter command exits 1 because the
  execution-plan index omits both
  `active/2026-07-11-linux-distribution-artifacts-plan.md` and
  `active/2026-07-11-cross-platform-privileged-install-helper-plan.md`. The
  overlapping file belongs to the user and was not edited or staged; ordinary
  CI cannot be claimed until that index state is reconciled and the full
  command is rerun.
- Resolved P1 evidence-truth gap: the canonical current-head ledger still
  promoted the complete Task 10 ladder and retained stale 601/49 counts while
  marking the now-executed external SwiftPM consumer `not run`. Test-first
  status and literal-evidence assertions failed on the stale ledger, then the
  focused docs suite passed 9/9 after recording the blocked ladder, 51 SwiftPM
  tests, external consumer execution, and both missing index links.
- Resolved P2 public-doc omission: the native configuration list claimed every
  platform field but omitted `requireIndexSignature`. A focused RED failed on
  the missing field, and the same 9/9 GREEN run now requires both index and
  descriptor signature controls.

Coverage ledger:

- Baseline and scope — `FINDING`: package version 2.7.0 and candidate-only
  runtime scope are identifiable, but Task 6 is intentionally incomplete.
- Behavior and schema parity — `VERIFIED_NO_BLOCKER`: generated negative
  fixtures now reject whitespace-only descriptor `appName` and rollout salt
  consistently in Dart, Swift, and portable C++ behavior.
- Cross-language data fidelity — `VERIFIED_NO_BLOCKER`: the Windows v1 result
  layout is frozen and preflighted, and the previously missing validation
  differences are now exercised by generated cross-language fixtures.
- Build graph and filesystem paths — `VERIFIED_NO_BLOCKER`: source target types,
  install/export paths, the Linux CMake-floor split, and relocatable metadata
  are coherent in the inspected graph and local contract checks.
- ABI and runtime loading — `NOT_VERIFIED`: portable ABI and managed builds are
  green, but a real packaged Windows DLL has not executed the new scalar probes
  or mismatch path.
- Package consumability — `NOT_VERIFIED`: local package contracts and macOS
  consumers are green; installed Windows and Linux consumers on their target
  hosts and the isolated runtime load remain not run.
- Platform integration and fallback paths — `NOT_VERIFIED`: macOS SwiftPM and
  the exact CocoaPods fallback are verified locally, while current-head Windows
  and Linux Flutter/native lanes remain not run.
- Trust and authenticity — `VERIFIED_NO_BLOCKER`: the released compatibility
  default remains unsigned as required by Task 2, while every public Flutter
  facade exposes one pinned-key option that requires both metadata signatures
  before selection or artifact download.
- Destructive and privileged safety — `FINDING`: target locks, durable recovery,
  and fd/handle-relative mount/reparse-safe mutation remain unimplemented.
- CI and test truth — `FINDING`: focused suites prove nonzero discovery, but the
  complete local Flutter command fails on the user-owned index, which omits two
  active plans, and current-head CI has not run. The canonical lane ledger now
  records this as `blocked` instead of promoting stale evidence.
- Release and publication — `NOT_VERIFIED`: signed/notarized artifact lanes are
  not run; the runtime and uploaded assets remain candidate-only.
- Public API, CLI, and documentation reality — `VERIFIED_NO_BLOCKER`: released
  Flutter and MethodChannel compatibility tests pass, published README links no
  longer target excluded local paths, and production pinned-key metadata trust
  is documented across README, publishing, and migration guidance. Native
  runtime documentation enumerates both metadata-signature controls.
- Migration and compatibility — `VERIFIED_NO_BLOCKER`: safe retained-provenance
  legacy calls and custom platform overrides pass; the stable trust default is
  explicitly compatibility-only and strict trust is additive.
- Plan consistency and completion gates — `FINDING`: open checkboxes and the
  canonical ledger accurately expose Task 6, target-host, credential, and
  full-ladder gaps, but the user-owned plan index remains incomplete; therefore
  final acceptance and merge readiness remain open.

The three earlier moderate follow-ups, the fresh public-doc P2, and the fresh
canonical-ledger P1 are resolved. They do not replace or reduce the remaining
P0/P1 blockers above.

The current-head CI and local-ladder statements in that review are superseded
by the target-host completion follow-up below. Credential-gated release lanes
remain `not run`. Runtime status: `candidate-only`. PR #65: not merge-ready.
This workflow reduces omission risk but cannot guarantee that no defect remains.

### Target-host completion follow-up on 2026-07-13

- Windows provenance target-host RED, verified in CI: push run `29288618726`
  reached the real helper after the parent exited, failed closed at
  `marker-digest`, and performed no target mutation. After the marker digest
  used explicit raw-byte SHA-256, push run `29289315492` passed the marker and
  failed closed at `inventory-entry`, again before backup or mutation.
- Windows provenance GREEN, verified locally: the helper now uses one
  streaming `File.OpenRead` plus SHA-256 function for marker, staged-file, and
  Inno artifact hashing. The stream and hash are disposed in `finally`; the
  existing diagnostics-containment scanner remains unchanged and green. The
  combined helper, smoke, and diagnostics command passed 41/41, the helper
  suite passed 28/28, scoped analysis exited 0 with only the five existing
  info diagnostics, and `git diff --check` passed.
- Windows provenance GREEN, verified in CI: push run `29290035977` for commit
  `423e29a` completed successfully. The Windows job passed nonzero CTest with
  Unicode/relative-redirect, provenance, lifecycle, and C ABI coverage; the
  installed CMake consumer; real Release DLL managed tests; Debug-CRT
  rejection; NuGet contents; isolated restore/hash/PInvoke execution; the
  packaged .NET runtime ZIP install/helper/cleanup smoke; and normal Flutter
  debug and release integration, publish, Inno, and ZIP update smokes.
- macOS and Linux target-host GREEN, verified in CI in the same run: both
  Flutter macOS integrations passed; the exact macOS 10.14 fallback typecheck,
  10.15+ `DesktopUpdaterKit` SwiftPM tests/external consumer, and normal ZIP
  smoke passed; Linux native tamper CTest, installed CMake, standard and
  multiarch pkg-config, normal ZIP, and Flutter debug/release lanes passed.
- Task 7 Step 5 and Task 9 Step 6 now have target-host evidence and are checked.
  Task 10 Step 2 remains open because Task 6's mount/bind/junction transaction
  mutation and durable recovery jobs cannot exist before the approved
  privileged-helper design is implemented. Signed/notarized DMG and PKG plus
  signed Inno credential lanes remain `not run`.
- The earlier execution-plan-index P1 is resolved in the current tree. No
  version, changelog heading, or lockfile changed.
- Final Task 10 ladder, verified locally: generated fixtures were current;
  formatting checked 218 files with 0 changes; repository analysis exited 0
  with 387 info-only diagnostics; full Flutter passed 659 tests with 3
  explicit opt-in skips; root SwiftPM passed 52/52; and `git diff --check`
  exited 0. The first repository publication dry run exited 65 solely because
  the in-progress tracked docs test was modified; it is not counted as GREEN.
  The identical current contents in a clean temporary copy exited 0 with 0
  warnings and 1 prior-version hint.
- Final macOS boundary checks, verified locally: the exact six-source
  CocoaPods fallback typechecked for `x86_64-apple-macosx10.14`, and
  `swift run --package-path example/native/macos` built and ran the external
  `DesktopUpdaterKit` consumer. A first typecheck attempt hit a stale
  `/tmp`/`/private/tmp` module-cache alias and Swift frontend signal 11; a fresh
  canonical cache passed. The consumer's first sandboxed attempt could not
  write the user Clang module cache; the identical permitted run passed.

### Final verification and fresh adversarial review on 2026-07-13

- `superpowers:verification-before-completion`: performed against the final
  implementation and evidence state. The complete Task 10 ladder above is
  fresh. In addition, the clean repository `dart pub publish --dry-run`
  exited 0 with 0 warnings and 1 hint, and the focused safety/trust,
  build/package, API/schema, and merge-gate group passed 57/57.
- Safety and trust pass: `killcritic-complete-review` re-inspected metadata
  signatures, package identity, owned staging and provenance, one-shot
  handoff, destructive operations, rollback, and the final Windows streaming
  hashes. The new hashes stream read-only bytes and dispose both resources;
  they do not weaken digest, signer, containment, or no-mutation checks.
  No additional P0 or P1 was validated. The existing Task 6 P0s remain: there is
  no cross-process target lock or durable journal/recovery, and helper
  mutation is not fd/handle-relative across the validation-to-mutation
  interval.
- Build and package pass: the `DesktopUpdaterKit` product/import and macOS
  10.15+ SwiftPM floor are unchanged; the CocoaPods fallback remains macOS
  10.14 with its exact six-source allowlist. Installed Windows and Linux
  CMake consumers, isolated NuGet P/Invoke, standard and multiarch pkg-config,
  third-party notices, and ordinary ZIP smokes retain target-host evidence.
  No version, changelog heading, or lockfile changed.
- Schema and API compatibility pass: the released Flutter facade,
  `DesktopUpdaterController`, legacy install compatibility, custom platform
  overrides, and MethodChannel surface remain covered. The focused facade,
  MethodChannel, controller, generated fixture, and conformance group passed
  61/61; no schema-v3 or native result-field incompatibility was found.
- CI and release-truth pass: GitHub Actions run `29291937840` was queried again
  and reports `success` for implementation commit `87a2adf`, including its
  macOS, Windows, Linux, Dart, package-consumer, and candidate CLI jobs. The
  Windows signed Inno and macOS signed/notarized DMG and PKG credential lanes
  remain `not run`. Runtime and CI artifacts remain `candidate-only`.
- Fresh `killcritic-complete-review` verdict: `BLOCK / NO-GO`. The target-host
  and locally executable remediation work is green, but the validated Task 6
  P0s are intentionally owned by the approved follow-up implementation plan.
  PR #65: not merge-ready.

### Final CI race remediation follow-up on 2026-07-14

- macOS ZIP smoke RED, verified in CI: push run `29291639192` reached
  `installAndRelaunch scheduled 2.7.1`, then the workflow asserted asynchronous
  helper cleanup evidence immediately after the version changed. The exact
  macOS 10.14 fallback typecheck, root SwiftPM tests, and external consumer had
  already passed; the failure was isolated to evidence synchronization.
- Source-contract RED, verified locally: the new smoke contract test failed
  because the workflow did not wait for the complete owned-staging and helper
  diagnostics evidence set.
- GREEN, verified locally: the bounded poll now requires version `2.7.1`, the
  owned staging directory to be empty, move and cleanup diagnostics, and a
  nonempty runtime diagnostics file before continuing. The final strict
  assertions remain unchanged. The focused smoke and merge-gate group passed
  21/21; formatting and diff checks were clean; scoped analysis exited 0 with
  the two existing info-only diagnostics.
- GREEN, verified in CI: push run `29291937840` for commit `87a2adf` completed
  successfully across all ordinary macOS, Windows, Linux, Dart, package
  consumer, and candidate CLI jobs. The macOS native runtime ZIP smoke passed.
  Credential-gated signed/notarized artifact lanes remain `not run`.
- Final local Flutter suite after the regression test: 660 passes with 3
  explicit skips.
- Post-fix four-pass `killcritic-complete-review` delta found no additional P0
  or P1. The known Task 6 P0s remain unchanged: no cross-process target lock or
  durable journal/recovery, and no fd/handle-relative mutation stable across
  the validation-to-mutation interval. Verdict: `BLOCK / NO-GO`; runtime status:
  `candidate-only`; PR #65: not merge-ready.

### Privileged-helper Task 16 review follow-up on 2026-07-14

- The macOS production graph is now joined and verified; the remaining P0 is
  scoped to Windows and Linux. Windows production prepare/commit owns an
  authenticated elevated named-pipe session, but its public query and recovery
  operations still return `endpointUnavailable`. Linux public helper operations
  remain disconnected; its serializer does not match the helper parser, and
  the helper's `COMMIT` path marks the reservation complete without invoking
  `LinuxFileTransaction` or `LinuxRecoveryService`.
- The remaining P1 findings are likewise scoped: the Linux client/helper wire
  shapes are incompatible, the Windows/Linux smoke scripts can pass at a
  version probe without a production mutation/recovery boundary, and the
  protocol-v1 diagnostic event set remains fixture-only.
- Fresh local evidence remains useful but scoped: the final Flutter suite
  passed 702 tests with 3 explicit skips; the macOS helper and repo-context
  DesktopUpdaterKit suites each passed 82/82; the signed transport subset
  passed 18/18; and a fresh Linux Release build passed 57/58 CTests with the
  bind-mount test explicitly skipped before that exact test passed 1/1 in a
  separate privileged container. Installed CMake and pkg-config consumers ran
  successfully. A clean `dart pub publish --dry-run` exited 0 with 0 warnings
  and the existing single prior-version hint. Windows target-host, installed
  Linux polkit/root-broker, and current-head CI remain `not run`.
- The macOS Task 6 slice is closed with the notarized target-host evidence
  below. The cross-platform plan remains open, the runtime remains
  `candidate-only`, and PR #65 remains `blocked / not merge-ready`.

### macOS privileged-helper correction evidence on 2026-07-14

- The macOS portion of the disconnected-helper P0 is resolved and
  `verified locally`. `PackagedMacInstallHelperTransport` now routes protected
  prepare/commit/cancel/query/recovery through the installed authenticated XPC
  daemon, while writable targets retain the one-shot unprivileged path. The
  daemon reloads sealed policy, authenticates the connection audit token and
  caller signature, owns the durable transaction, and exits after a completed
  replacement so launchd resolves the newly installed bundled helper.
- The privileged helper package passed 82/82 tests and the repo-context
  DesktopUpdaterKit package passed 82/82. The focused SMAppService transport
  suite passed 18/18, including RED/GREEN coverage for forced fresh-process XPC
  queries and asynchronous unregister completion before re-registration.
- The actual protected-target gate is `verified locally`: notarized universal
  v1/v2 Developer ID applications ran from a recursively `root:wheel`
  `/Applications` fixture. An administrator-approved root daemon completed XPC
  prepare, survived a real `SIGKILL` through verified rollback recovery, then
  installed v2 and restarted from endpoint `308d4b3e…`; daemon PIDs were
  `27851`, `28621`, and `29512`. The installed v2 passed strict code-signing,
  stapler, and Gatekeeper assessment as `Notarized Developer ID`.
- Apple notarization accepted the final current-source submissions
  `6b39195a-c4c6-4a51-ba3c-1c775b7d2473` and
  `78719a41-139b-4313-8fd4-0caaea103916`. A prior RED submission correctly
  rejected Xcode's injected `get-task-allow`; the Runner Release configuration
  now fixes `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO` under a regression
  contract.
- The macOS Task 6 implementation and signed target-host gate are closed.
  Windows Authenticode/UAC target-host execution, installed Linux polkit
  execution, and current-head CI are still `not run`, so the cross-platform
  plan and runtime remain `candidate-only`; no Windows/Linux or overall
  production-ready claim is inferred from the closed macOS slice.

## Final Acceptance Checklist

- [ ] No caller-provided parent can be recursively deleted.
- [ ] No install crosses a protected root, mount, bind mount, symlink, junction,
  or reparse boundary.
- [ ] A helper cannot execute a stage whose provenance changed after staging.
- [ ] A stage/check cannot cross clients or generations.
- [ ] A successful handoff cannot be scheduled twice.
- [ ] Abrupt interruption resolves to the old or new complete target.
- [ ] Fresh-install authority is app-archive-signed and its selected descriptor
  is verified for native preview clients.
- [ ] Every generated validation fixture executes in Dart, Swift, and C++.
- [ ] Native result fields preserve the full selected policy.
- [x] Windows non-ASCII paths and relative redirects pass target-host tests.
- [x] SwiftPM runtime remains macOS 10.15+ with
  `import DesktopUpdaterKit`.
- [x] Exact CocoaPods helper + adapter source set typechecks for macOS 10.14.
- [x] Safe legacy Flutter install calls and custom platform overrides pass.
- [x] Unsafe ambiguous legacy roots fail before mutation with migration text.
- [x] NuGet contains Release DLLs and third-party notices.
- [x] CMake and pkg-config external consumers use installed artifacts.
- [ ] Ordinary CI gates pass with nonzero test discovery.
- [x] Signed/notarized lanes are reported literally as passed or not run.
- [x] PR body and execution-plan state match repository evidence.
