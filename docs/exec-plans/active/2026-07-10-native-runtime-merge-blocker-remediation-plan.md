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

Resolve `Location` against the current URL with WinHTTP URL APIs. Validate the
resolved absolute URL, then reject HTTPS downgrade. Pass the resolved URL to the
headers provider and the next request.

- [ ] **Step 5: Run Windows target-host tests**

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
- Follow-up commit: `fix: complete Windows redirect and path handling`
  (this changeset).

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

- [ ] **Step 1: Rewrite the layout tests to fail on broad globs**

Assert the podspec names these exact helper files:

~~~text
DesktopUpdaterVersion.swift
Diagnostics.swift
MacInstallHelper.swift
MacInstallRequest.swift
~~~

Assert it includes the Flutter adapter, excludes `Runtime/**`, keeps 10.14,
and both SwiftPM manifests keep 10.15 and `DesktopUpdaterKit`.

- [ ] **Step 2: Replace the podspec Runtime glob with an allowlist**

List the four helper files and adapter glob explicitly. Do not rename the Swift
module, product, target, or public imports.

- [ ] **Step 3: Add a macOS 10.14 launch fallback**

Keep the 10.15 `NSWorkspace.OpenConfiguration` path behind
`if #available(macOS 10.15, *)`. On 10.14 use
`NSWorkspace.shared.launchApplication(destinationURL.path)`; return the same
Flutter error shape when launch fails.

- [ ] **Step 4: Typecheck the exact pod source set**

Add the exact CI command:

~~~sh
xcrun swiftc -typecheck -target x86_64-apple-macosx10.14 -swift-version 5 -module-cache-path "$RUNNER_TEMP/desktop-updater-swift-module-cache" -F "$FLUTTER_ROOT/bin/cache/artifacts/engine/darwin-x64/FlutterMacOS.xcframework/macos-arm64_x86_64" macos/desktop_updater/Sources/DesktopUpdaterKit/DesktopUpdaterVersion.swift macos/desktop_updater/Sources/DesktopUpdaterKit/Diagnostics.swift macos/desktop_updater/Sources/DesktopUpdaterKit/MacInstallHelper.swift macos/desktop_updater/Sources/DesktopUpdaterKit/MacInstallRequest.swift macos/desktop_updater/Sources/desktop_updater/DesktopUpdaterPlugin.swift
~~~

Expected: exit 0. Keep the current CocoaPods Flutter integration build and
SwiftPM external consumer as separate gates.

- [ ] **Step 5: Run macOS verification**

Run:

~~~sh
flutter test --no-pub test/macos_cocoapods_source_layout_test.dart test/macos_swift_package_test.dart
swift test
~~~

Expected: PASS; exact 10.14 typecheck exit 0; SwiftPM runtime tests remain
macOS 10.15+.

- [ ] **Step 6: Commit**

~~~sh
git add macos Package.swift test .github/workflows/desktop-updater-ci.yml docs/native-sdk.md docs/native-runtime-api.md
git commit -m "fix: preserve macOS CocoaPods compatibility"
~~~

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

- [ ] **Step 1: Add failing package-content and clean-host tests**

Require Release DLL paths, reject a DLL linked to Debug CRT, require notices in
NuGet/install trees, compile/link/run pkg-config from a
`lib/<multiarch>/pkgconfig` prefix, and force GC without calling Dispose to
prove the native client is released.

- [ ] **Step 2: Build retail native DLLs**

Configure/build/install Windows native targets with `--config Release`.
Set `CMAKE_MSVC_RUNTIME_LIBRARY` explicitly to
`MultiThreaded$<$<CONFIG:Debug>:Debug>DLL`. Pack only
`windows/native/build/Release/*.dll`.

- [ ] **Step 3: Package third-party notices**

Include miniz MIT and Monocypher CC0/BSD-2-Clause texts in NuGet and both CMake
install trees. Extend package verification to require the notice entry.

- [ ] **Step 4: Fix pkg-config relocation**

Use configured `CMAKE_INSTALL_PREFIX`, `CMAKE_INSTALL_FULL_LIBDIR`, and
`CMAKE_INSTALL_FULL_INCLUDEDIR` rather than deriving prefix from
`pcfiledir/../..`. Test both `lib/pkgconfig` and
`lib/x86_64-linux-gnu/pkgconfig`.

- [ ] **Step 5: Replace the .NET self-root**

Wrap the native client in `SafeHandle`. Keep delegates rooted by the managed
client without allocating a `GCHandle` that points back to the same object.
If native callbacks require context, allocate a separate callback-state object
owned by the SafeHandle and release it in `ReleaseHandle`.

- [ ] **Step 6: Run package consumers**

Run target-host:

~~~text
Windows Release cmake --install + external find_package consumer
Release NuGet pack + isolated restore/build/run P/Invoke smoke
Linux install + external find_package consumer
Linux pkg-config compile/link/run from multiarch prefix
~~~

Expected: every consumer uses installed/package files, not source-tree paths.

- [ ] **Step 7: Commit**

~~~sh
git add .github/workflows/desktop-updater-ci.yml windows/native linux/native third_party/README.md
git commit -m "fix: make native packages retail consumable"
~~~

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

- [ ] **Step 1: Add failing docs/CI drift tests**

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

- [ ] **Step 3: Run the complete local ladder**

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

- [ ] **Step 4: Reconcile plan state and PR text**

Mark a checkbox complete only with command/run evidence. Keep open or
credential-dependent rows literal. Update the parent runtime plan to reference
this remediation plan and remove claims contradicted by current implementation.
Draft the corrected PR body for the user; do not post it through a connector.

- [ ] **Step 5: Perform the final adversarial review**

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

- [ ] **Step 6: Record final evidence and commit documentation**

~~~sh
git add README.md docs test/native_runtime_merge_gate_docs_test.dart .github/workflows/desktop-updater-ci.yml
git commit -m "docs: record native runtime merge gates"
~~~

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
- [ ] Windows non-ASCII paths and relative redirects pass target-host tests.
- [ ] SwiftPM runtime remains macOS 10.15+ with
  `import DesktopUpdaterKit`.
- [ ] Exact CocoaPods helper + adapter source set typechecks for macOS 10.14.
- [ ] Safe legacy Flutter install calls and custom platform overrides pass.
- [ ] Unsafe ambiguous legacy roots fail before mutation with migration text.
- [ ] NuGet contains Release DLLs and third-party notices.
- [ ] CMake and pkg-config external consumers use installed artifacts.
- [ ] Ordinary CI gates pass with nonzero test discovery.
- [ ] Signed/notarized lanes are reported literally as passed or not run.
- [ ] PR body and execution-plan state match repository evidence.
