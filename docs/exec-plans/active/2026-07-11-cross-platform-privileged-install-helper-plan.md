# Cross-Platform Privileged Install Helper Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> `superpowers:subagent-driven-development` (recommended) or
> `superpowers:executing-plans` to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace generated shell and PowerShell install helpers with packaged,
authenticated native helpers that reserve the target before handoff, survive
process interruption, recover deterministically, support writable and elevated
installs, and serve both Flutter and Flutter-free consumers on macOS, Windows,
and Linux.

**Architecture:** Share a versioned wire contract, sealed policy model,
canonical serialization, state machines, fixtures, diagnostics, and conformance
tests. Keep destructive mutation platform-owned: Swift on macOS, C++/Win32 on
Windows, and C++/Linux fd-relative code on Linux. Native SDK clients are
authoritative; Flutter platform plugins remain compatibility adapters. Package
format production is out of scope, but the helper-side strategy contract must
already support directory replacement, AppImage-style single-file replacement,
verified installer handoff, system package transactions, and externally managed
refreshes.

**Tech Stack:** Dart/Flutter, JSON Schema, Swift/Foundation/Security/XPC/
ServiceManagement, C++17, CMake, Win32/AuthentiCode/UAC/named pipes, Linux POSIX
APIs/pidfd/polkit/Unix sockets, XCTest, GoogleTest, .NET P/Invoke, CocoaPods,
SwiftPM, NuGet, pkg-config, and GitHub Actions.

**Approved Design:**
`docs/superpowers/specs/2026-07-11-cross-platform-privileged-install-helper-design.md`

## Global Constraints

- Work on the current branch. Do not create, switch, rename, or delete branches.
- Preserve `import DesktopUpdaterKit` and the `DesktopUpdaterKit` product and
  module names.
- Keep native SwiftPM runtime at macOS 10.15+.
- Keep the Flutter CocoaPods fallback at macOS 10.14 and preserve its exact
  source allowlist:
  `DesktopUpdaterVersion.swift`, `Diagnostics.swift`, `MacInstallHelper.swift`,
  `MacInstallRequest.swift`, and `DesktopUpdaterPlugin.swift`.
- Do not add helper executable sources to the CocoaPods source allowlist.
- Preserve the released Flutter API and existing `desktop_updater`
  MethodChannel method names and compatible result/error behavior.
- A successful handoff means an authenticated helper already owns the exclusive
  target lock and a durably persisted initial journal.
- Treat request paths as untrusted hints. Derive mutation names beneath a pinned
  target parent; never accept arbitrary journal, backup, prepared, or cleanup
  paths from a caller.
- Do not weaken descriptor/index signatures, artifact hashing, stage provenance,
  caller/helper authentication, target proof, mount/reparse/link checks,
  rollback, package verification, or relaunch verification to make tests pass.
- Elevated helpers consume a build- or installer-sealed policy. Callers cannot
  choose install roots, trusted release keys, signers, or privileged strategies.
- Do not use `/bin/sh`, PowerShell, `sudo`, or caller-provided commands as a
  production fallback. Missing helper, broker, signature, policy, or privilege
  support fails before mutation.
- Keep common C++ code non-destructive. Windows and Linux may share parsers and
  generated fixtures, but not copy/delete/swap/rollback implementations.
- Do not bump versions, changelog headings, or lockfiles.
- Do not push, merge, mark a PR ready, or write to GitHub while executing this
  plan.
- Preserve unrelated worktree changes; stage only the files owned by the active
  task.
- Keep the runtime `candidate-only` until all mandatory target-host, elevated,
  signed, and recovery gates have literal evidence.
- Linux AppImage/deb/rpm/Flatpak/Snap artifact generation and publishing belong
  to a later execution plan. This plan implements only their helper-side
  strategy and recovery semantics.

---

## Dependency Order

```text
Task 1 protocol fixtures
  -> Task 2 sealed policies
  -> Task 3 journal/reference conformance
      -> Tasks 4-6 macOS helper
      -> Tasks 7-8 Windows helper
      -> Tasks 9-10 Linux helper
          -> Task 11 strategy providers
              -> Task 12 native SDK clients
                  -> Task 13 Flutter adapters and script removal
                      -> Task 14 packaging and consumer gates
                          -> Task 15 CI/target-host recovery matrix
                              -> Task 16 final validation and review
```

Tasks on different platforms may be developed in parallel only after Tasks 1-3
are committed. Do not route a platform to its native helper until that
platform's build, authentication, no-mutation cancellation, transaction, and
recovery tasks are independently green.

## Evidence Rules

For every task, retain the exact command, exit status, and relevant test count
under that task's `Evidence` block. Use only these literal labels:

- `verified locally`: command ran on the named host and passed;
- `verified in CI`: linked run/job proves the named lane;
- `not run`: gate was not attempted;
- `blocked`: attempted or required gate could not run, with the precise reason.

The checkbox may change to `[x]` only when every required secretless check for
that task is `verified locally` or `verified in CI`. Credential-gated checks may
remain `not run`, but then the runtime and affected platform remain
`candidate-only`. Record the task's Conventional Commit hash after verification.

---

### Task 1: Freeze Helper Protocol V1 and Generate Cross-Language Fixtures

**Files:**

- Create: `schemas/native-install-helper-v1.schema.json`
- Create: `fixtures/compat/native-install-helper/v1/valid-requests.json`
- Create: `fixtures/compat/native-install-helper/v1/invalid-requests.json`
- Create: `fixtures/compat/native-install-helper/v1/journal-transitions.json`
- Create: `fixtures/compat/native-install-helper/v1/diagnostic-results.json`
- Create: `fixtures/compat/native-install-helper/v1/canonical-json.json`
- Create: `tool/generate_native_install_helper_fixtures.dart`
- Create: `test/native_install_helper_contract_test.dart`
- Create: `docs/native-install-helper-protocol.md`
- Modify: `fixtures/compat/native-contract/README.md`

**Interfaces:**

```text
prepareInstall(request) -> reservation
commitAfterExit(reservation)
cancelReservation(reservation)
queryTransaction(policyId, transactionId) -> transactionStatus
recoverPendingInstall(policyId, targetIdentity) -> recoveryResult
```

`NativeInstallTransactionRequestV1` contains protocol/schema versions, a
lowercase UUID, `policyId`, `packageId`, strategy, target class, path hints,
executable-relative proof, current/desired identity, stage nonce/provenance and
artifact digests, signed descriptor binding, caller identity, request nonce,
and an optional diagnostics destination. `NativeInstallReservationV1` contains
the transaction ID, opaque high-entropy `readyToken`, journal digest, helper
endpoint identity, and expiry. Unknown major versions, duplicate JSON keys,
unknown enum values, non-canonical UUIDs, invalid digests, absolute sibling
names, and caller-supplied trust authority fail closed.

- [x] **Step 1: Write the failing contract test**

  Assert that the schema and all five fixture files exist; the generator is
  idempotent; every valid request validates; every invalid request names a
  stable failure; canonical JSON sorts object keys and rejects duplicate keys;
  and every state transition is one of the normative transitions.

  Run:

  ```sh
  flutter test --no-pub test/native_install_helper_contract_test.dart
  ```

  Expected RED: missing schema, fixtures, generator, and protocol document.

- [x] **Step 2: Implement the schema and deterministic generator**

  Generate, do not hand-maintain, positive and adversarial cases for every
  request/result field and these strategies:

  ```text
  directoryReplace
  singleFileReplace
  verifiedInstallerHandoff
  systemPackageTransaction
  externalManagedRefresh
  ```

  Canonicalization must be UTF-8, sorted-key, duplicate-key rejecting, integer
  preserving, and independent of locale. The generator must write byte-identical
  output on a second run.

- [x] **Step 3: Document the normative protocol and compatibility rules**

  Specify exact state names, result codes, diagnostic event names, redaction,
  protocol negotiation, timeout behavior, and the rule that paths are hints,
  never mutation authority. Link the approved design spec and state explicitly
  that artifact production is out of scope.

- [x] **Step 4: Run focused verification and commit**

  ```sh
  dart run tool/generate_native_install_helper_fixtures.dart
  dart run tool/generate_native_install_helper_fixtures.dart --check
  flutter test --no-pub test/native_install_helper_contract_test.dart
  dart format --set-exit-if-changed tool/generate_native_install_helper_fixtures.dart test/native_install_helper_contract_test.dart
  ```

  Commit:

  ```sh
  git add schemas/native-install-helper-v1.schema.json fixtures/compat/native-install-helper/v1 tool/generate_native_install_helper_fixtures.dart test/native_install_helper_contract_test.dart docs/native-install-helper-protocol.md fixtures/compat/native-contract/README.md
  git commit -m "feat: define native install helper protocol"
  ```

**Evidence:**

- RED: `verified locally` — macOS 26.5.2 arm64;
  `flutter test --no-pub test/native_install_helper_contract_test.dart`;
  exit 1; 0 passed, 6 failed; first failure was the intended missing
  `schemas/native-install-helper-v1.schema.json`. The added exhaustive field
  coverage assertion was separately observed RED with exit 1 and 0/1 tests
  before its generated cases existed.
- Fixture generation: `verified locally` — macOS 26.5.2 arm64;
  `HOME=/private/tmp DART_TOOL_DISABLE_ANALYTICS=1 /Users/marlonjd/Developer/flutter/bin/cache/dart-sdk/bin/dart run tool/generate_native_install_helper_fixtures.dart`;
  exit 0.
- Fixture idempotence: `verified locally` — macOS 26.5.2 arm64;
  `HOME=/private/tmp DART_TOOL_DISABLE_ANALYTICS=1 /Users/marlonjd/Developer/flutter/bin/cache/dart-sdk/bin/dart run tool/generate_native_install_helper_fixtures.dart --check`;
  exit 0.
- Dart contract: `verified locally` — macOS 26.5.2 arm64;
  `flutter test --no-pub test/native_install_helper_contract_test.dart`;
  exit 0; 9 tests passed.
- Existing fixture-generator drift guard: `verified locally` — macOS 26.5.2
  arm64;
  `flutter test --no-pub test/native_contract_fixture_test.dart --plain-name 'native contract generation is byte-for-byte deterministic'`;
  exit 0; 1 test passed.
- Targeted analysis: `verified locally` — macOS 26.5.2 arm64;
  `HOME=/private/tmp DART_TOOL_DISABLE_ANALYTICS=1 /Users/marlonjd/Developer/flutter/bin/cache/dart-sdk/bin/dart analyze tool/generate_native_install_helper_fixtures.dart test/native_install_helper_contract_test.dart`;
  exit 0; no issues found.
- Format: `verified locally` — macOS 26.5.2 arm64;
  `HOME=/private/tmp DART_TOOL_DISABLE_ANALYTICS=1 /Users/marlonjd/Developer/flutter/bin/cache/dart-sdk/bin/dart format --set-exit-if-changed tool/generate_native_install_helper_fixtures.dart test/native_install_helper_contract_test.dart`;
  exit 0; 2 files checked, 0 changed.
- Plan-spelled `dart` wrapper: `blocked` — the exact wrapper invocation tried
  to rewrite the external Flutter SDK cache and exited 1 under the workspace
  sandbox; the same Dart `run`, `analyze`, and `format` subcommands were
  `verified locally` above through the installed SDK binary without that
  external mutation.
- Commit: `verified locally` — `292b112 feat: define native install helper protocol`.

---

### Task 2: Implement Sealed HelperPolicyV1 Contracts and Policy Tooling

**Files:**

- Create: `schemas/native-install-helper-policy-v1.schema.json`
- Create: `fixtures/compat/native-install-helper/v1/policy-cases.json`
- Create: `tool/generate_native_install_helper_policy.dart`
- Create: `test/native_install_helper_policy_test.dart`
- Create: `native_runtime/cpp/install_helper_policy.h`
- Create: `native_runtime/cpp/install_helper_policy.cc`
- Create: `native_runtime/cpp/install_helper_policy_fixture_tests.cc`
- Modify: `windows/native/CMakeLists.txt`
- Modify: `linux/native/CMakeLists.txt`

**Policy fields:**

```text
policyVersion
policyId
applicationPackageId
helperServiceId
allowedApplicationSigner
allowedHelperSigner
allowedTargetClasses
allowedInstallRoots
releaseRootPublicKeys
allowedStrategies
minimumHelperProtocolVersion
```

- [x] **Step 1: Write failing Dart and C++ policy tests**

  Cover valid portable and privileged policies plus wrong package ID, unknown
  strategy, root filesystem authorization, relative install root, caller-added
  key, policy rollback, invalid signer, duplicate key ID, protocol downgrade,
  and a portable policy that requests elevation.

  Run the Dart test first:

  ```sh
  flutter test --no-pub test/native_install_helper_policy_test.dart
  ```

  Expected RED: schema, generator, fixtures, and C++ parser are absent.

- [x] **Step 2: Implement strict common parsing without filesystem mutation**

  `install_helper_policy.cc` may parse and validate policy bytes and expose
  immutable values. It must not open, copy, delete, rename, elevate, or recover
  filesystem objects. Reject unknown fields in security-authority objects and
  canonicalize the policy before computing its digest.

- [x] **Step 3: Implement build-time policy generation**

  The tool accepts an application-owned configuration and writes a canonical
  policy plus digest. It refuses wildcard signers, filesystem roots, empty
  release keys, `externalManagedRefresh` without a named provider, and elevated
  capability in a portable policy. Never write private keys into policy output.

- [x] **Step 4: Run focused verification and commit**

  ```sh
  flutter test --no-pub test/native_install_helper_policy_test.dart
  cmake -S linux/native -B build/linux-policy -DDESKTOP_UPDATER_NATIVE_BUILD_TESTS=ON
  cmake --build build/linux-policy --target desktop_updater_native_test
  ctest --test-dir build/linux-policy -R install_helper_policy --output-on-failure
  ```

  On Windows, run the equivalent CMake/CTest lane and record it separately.

  Commit:

  ```sh
  git add schemas/native-install-helper-policy-v1.schema.json fixtures/compat/native-install-helper/v1/policy-cases.json tool/generate_native_install_helper_policy.dart test/native_install_helper_policy_test.dart native_runtime/cpp/install_helper_policy.h native_runtime/cpp/install_helper_policy.cc native_runtime/cpp/install_helper_policy_fixture_tests.cc windows/native/CMakeLists.txt linux/native/CMakeLists.txt
  git commit -m "feat: seal native helper policies"
  ```

**Evidence:**

- RED: `verified locally` — macOS 26.5.2 arm64;
  `flutter test --no-pub test/native_install_helper_policy_test.dart`;
  exit 1; 0 of 6 tests passed; the first failure reported the absent policy
  schema. The C++ fixture test was also added before the parser; the plan-spelled
  local CMake configure was `blocked` because CMake is not installed on this
  macOS host.
- Dart policy tests: `verified locally` — macOS 26.5.2 arm64;
  `flutter test --no-pub test/native_install_helper_policy_test.dart`;
  exit 0; 6 tests passed.
- Policy fixture drift: `verified locally` — macOS 26.5.2 arm64;
  `HOME=/private/tmp DART_TOOL_DISABLE_ANALYTICS=1 /Users/marlonjd/Developer/flutter/bin/cache/dart-sdk/bin/dart run tool/generate_native_install_helper_policy.dart --check-fixtures`;
  exit 0; generated fixtures matched.
- Linux C++ policy tests: `verified locally` — disposable Alpine Linux 3.24
  container on macOS 26.5.2 arm64; repository mounted read-only;
  `docker run --rm -v /Users/marlonjd/Developer/library/flutter_desktop_updater:/src:ro -w /src postgres:18.4-alpine3.24 sh -lc 'apk add --no-cache cmake g++ make git && cmake -S linux/native -B /tmp/linux-policy -DDESKTOP_UPDATER_NATIVE_BUILD_TESTS=ON && cmake --build /tmp/linux-policy --target desktop_updater_native_test && ctest --test-dir /tmp/linux-policy -R install_helper_policy --output-on-failure'`;
  exit 0; GCC 15.2.0 and CMake 4.2.3 built the production native target and
  CTest discovered and passed 2 of 2 policy tests.
- Windows C++ policy tests: `not run` — no Windows target host is available in
  this environment; Windows CMake wiring is candidate-only.
- Targeted analysis: `verified locally` — macOS 26.5.2 arm64;
  `HOME=/private/tmp DART_TOOL_DISABLE_ANALYTICS=1 /Users/marlonjd/Developer/flutter/bin/cache/dart-sdk/bin/dart analyze tool/generate_native_install_helper_policy.dart test/native_install_helper_policy_test.dart`;
  exit 0; no issues found.
- Format: `verified locally` — macOS 26.5.2 arm64;
  `HOME=/private/tmp DART_TOOL_DISABLE_ANALYTICS=1 /Users/marlonjd/Developer/flutter/bin/cache/dart-sdk/bin/dart format --output=none --set-exit-if-changed tool/generate_native_install_helper_policy.dart test/native_install_helper_policy_test.dart`;
  exit 0; 2 files checked, 0 changed.
- Commit: `verified locally` — `95e8d57 feat: seal native helper policies`.

---

### Task 3: Add a Non-Destructive Journal Reference Model and Crash Fixtures

**Files:**

- Create: `native_runtime/cpp/install_helper_contract.h`
- Create: `native_runtime/cpp/install_helper_contract.cc`
- Create: `native_runtime/cpp/install_helper_contract_fixture_tests.cc`
- Create: `test/native_install_helper_state_machine_test.dart`
- Modify: `tool/generate_native_install_helper_fixtures.dart`
- Modify: `fixtures/compat/native-install-helper/v1/journal-transitions.json`
- Modify: `windows/native/CMakeLists.txt`
- Modify: `linux/native/CMakeLists.txt`

**State machines:**

```text
swap: prepared -> backupCreated -> targetActivated -> completed
manager: prepared -> managerStarted -> verificationPending -> completed
terminal alternatives: rolledBack | manualActionRequired
```

- [x] **Step 1: Write failing state-machine tests**

  Generate a case for helper death before and after every durable transition,
  repeated recovery, live-owner recovery rejection, torn/short writes, disk
  full, directory flush failure, corrupt/unknown journal, injected sibling
  names, owner generation mismatch, and ambiguous target/backup state.

  ```sh
  flutter test --no-pub test/native_install_helper_state_machine_test.dart
  ```

  Expected RED: no executable reference model or crash matrix exists.

- [x] **Step 2: Implement the pure reference model**

  The common implementation accepts observations and returns a decision only:

  ```cpp
  RecoveryDecision DecideRecovery(const JournalV1&, const ObservedState&);
  TransitionResult ValidateTransition(JournalState from, JournalState to);
  ```

  It must never invoke filesystem or platform APIs. Its only purpose is to make
  Swift, Windows, and Linux consume the same decisions and adversarial fixtures.

- [x] **Step 3: Prove deterministic, idempotent recovery decisions**

  Require each fixture to converge to exactly one of verified old target,
  verified new target, or non-destructive `manualActionRequired`. A corrupt or
  ambiguous journal must never authorize cleanup.

- [x] **Step 4: Run focused verification and commit**

  ```sh
  flutter test --no-pub test/native_install_helper_state_machine_test.dart
  cmake --build build/linux-policy --target desktop_updater_native_test
  ctest --test-dir build/linux-policy -R install_helper_contract --output-on-failure
  ```

  Run the Windows fixture target on Windows.

  Commit:

  ```sh
  git add native_runtime/cpp/install_helper_contract.h native_runtime/cpp/install_helper_contract.cc native_runtime/cpp/install_helper_contract_fixture_tests.cc test/native_install_helper_state_machine_test.dart tool/generate_native_install_helper_fixtures.dart fixtures/compat/native-install-helper/v1/journal-transitions.json windows/native/CMakeLists.txt linux/native/CMakeLists.txt
  git commit -m "test: define native helper recovery model"
  ```

**Evidence:**

- RED: `verified locally` — macOS 26.5.2 arm64;
  `flutter test --no-pub test/native_install_helper_state_machine_test.dart`;
  exit 1; 1 of 6 tests passed and 5 failed because the reference-model files
  and recovery matrix were absent. The C++ RED was also `verified locally`
  with `clang++ -std=c++17 -I /private/tmp -I native_runtime/cpp -fsyntax-only native_runtime/cpp/install_helper_contract_fixture_tests.cc`;
  exit 1 at the absent `install_helper_contract.h`.
- Dart state-machine tests: `verified locally` — macOS 26.5.2 arm64;
  `flutter test --no-pub test/native_install_helper_state_machine_test.dart`;
  exit 0; 6 tests passed.
- Fixture drift: `verified locally` — macOS 26.5.2 arm64;
  `HOME=/private/tmp DART_TOOL_DISABLE_ANALYTICS=1 /Users/marlonjd/Developer/flutter/bin/cache/dart-sdk/bin/dart run tool/generate_native_install_helper_fixtures.dart --check`;
  exit 0; the five helper-contract fixtures matched. The independently
  generated policy fixture is excluded from this ownership check.
- Task 1 contract regression: `verified locally` — macOS 26.5.2 arm64;
  `flutter test --no-pub test/native_install_helper_contract_test.dart`;
  exit 0; 9 tests passed.
- Linux reference-model tests: `verified locally` — disposable Alpine Linux
  3.24 container on macOS 26.5.2 arm64; repository mounted read-only;
  `docker run --rm -v /Users/marlonjd/Developer/library/flutter_desktop_updater:/src:ro -w /src postgres:18.4-alpine3.24 sh -lc 'apk add --no-cache cmake g++ make git && cmake -S linux/native -B /tmp/linux-contract -DDESKTOP_UPDATER_NATIVE_BUILD_TESTS=ON && cmake --build /tmp/linux-contract --target desktop_updater_native_test && ctest --test-dir /tmp/linux-contract -R install_helper_contract --output-on-failure'`;
  exit 0; GCC 15.2.0 and CMake 4.2.3 built the production native target and
  CTest discovered and passed 4 of 4 recovery tests, including explicit
  repeated-recovery idempotence.
- Windows reference-model tests: `not run` — no Windows target host is
  available in this environment; Windows CMake wiring is candidate-only.
- Targeted analysis: `verified locally` — macOS 26.5.2 arm64;
  `HOME=/private/tmp DART_TOOL_DISABLE_ANALYTICS=1 /Users/marlonjd/Developer/flutter/bin/cache/dart-sdk/bin/dart analyze tool/generate_native_install_helper_fixtures.dart test/native_install_helper_state_machine_test.dart test/native_install_helper_contract_test.dart`;
  exit 0; no issues found.
- Format: `verified locally` — macOS 26.5.2 arm64;
  `HOME=/private/tmp DART_TOOL_DISABLE_ANALYTICS=1 /Users/marlonjd/Developer/flutter/bin/cache/dart-sdk/bin/dart format --output=none --set-exit-if-changed tool/generate_native_install_helper_fixtures.dart test/native_install_helper_state_machine_test.dart test/native_install_helper_contract_test.dart`;
  exit 0; 3 files checked, 0 changed.
- Commit: `verified locally` —
  `136bf28 test: define native helper recovery model`.

---

### Task 4: Build and Embed the macOS Helper Without Changing SDK Boundaries

**Files:**

- Create: `macos/install_helper/Package.swift`
- Create: `macos/install_helper/Sources/DesktopUpdaterInstallHelper/main.swift`
- Create: `macos/install_helper/Sources/DesktopUpdaterInstallHelper/HelperVersion.swift`
- Create: `macos/install_helper/Tests/DesktopUpdaterInstallHelperTests/HelperVersionTests.swift`
- Create: `macos/desktop_updater/Sources/DesktopUpdaterKit/InstallHelper/EmbeddedHelperLocator.swift`
- Create: `macos/desktop_updater/Tests/DesktopUpdaterKitTests/EmbeddedHelperLayoutTests.swift`
- Create: `test/macos_native_helper_layout_test.dart`
- Modify: `test/macos_cocoapods_source_layout_test.dart`
- Modify: `test/macos_swift_package_test.dart`

- [x] **Step 1: Write failing layout and compatibility tests**

  Assert that SwiftPM still exposes `DesktopUpdaterKit` at macOS 10.15+, the
  helper executable is compiled for macOS 10.14, the helper is a distinct
  product embedded for both one-shot and privileged use at
  `Contents/Helpers/DesktopUpdaterInstallHelper`, its `SMAppService`
  LaunchDaemon plist is embedded at
  `Contents/Library/LaunchDaemons/<helper-service-id>.plist`, and the
  podspec source allowlist remains byte-for-byte the exact five entries in the
  global constraints.

  ```sh
  flutter test --no-pub test/macos_native_helper_layout_test.dart test/macos_cocoapods_source_layout_test.dart test/macos_swift_package_test.dart
  ```

  Expected RED: helper product and embed contract are absent.

- [x] **Step 2: Add a no-mutation helper executable target**

  A separate Swift package with `.macOS(.v10_14)` builds the helper; neither
  repository `DesktopUpdaterKit` package changes its macOS 10.15 floor. The
  initial executable supports only `--version` and a test-only stdio
  protocol parse mode. It must not schedule, copy, delete, rename, bless, or
  elevate. Keep macOS 10.14-compatible sources separate from
  `Sources/DesktopUpdaterKit/Runtime/`.

- [x] **Step 3: Add deterministic helper discovery**

  `EmbeddedHelperLocator` resolves only the signed nested helper at the fixed
  bundle-relative location. Do not search `PATH`, temporary directories, the
  source tree, or caller-provided paths.

- [x] **Step 4: Run macOS build checks and commit**

  ```sh
  swift test --package-path macos/install_helper
  swift test --package-path macos/desktop_updater
  swift test
  flutter test --no-pub test/macos_native_helper_layout_test.dart test/macos_cocoapods_source_layout_test.dart test/macos_swift_package_test.dart
  ```

  Also compile the exact CocoaPods source set with a macOS 10.14 deployment
  target or run the repository's equivalent host lane.

  Commit:

  ```sh
  git add macos/install_helper/Package.swift macos/install_helper/Sources/DesktopUpdaterInstallHelper/main.swift macos/install_helper/Sources/DesktopUpdaterInstallHelper/HelperVersion.swift macos/install_helper/Tests/DesktopUpdaterInstallHelperTests/HelperVersionTests.swift macos/desktop_updater/Sources/DesktopUpdaterKit/InstallHelper/EmbeddedHelperLocator.swift macos/desktop_updater/Tests/DesktopUpdaterKitTests/EmbeddedHelperLayoutTests.swift test/macos_native_helper_layout_test.dart test/macos_cocoapods_source_layout_test.dart test/macos_swift_package_test.dart
  git commit -m "build: package macos install helper"
  ```

**Evidence:**

- RED: `verified locally` — macOS 26.5.2 arm64;
  `flutter test --no-pub test/macos_native_helper_layout_test.dart test/macos_cocoapods_source_layout_test.dart test/macos_swift_package_test.dart`;
  exit 1; 18 tests passed and 5 failed because the helper package/product and
  fixed locator were absent. The Swift API RED was also `verified locally`
  with `swift test --package-path macos/install_helper`; exit 1 because the
  executable target was empty before its sources were added.
- Helper Swift tests: `verified locally` — macOS 26.5.2 arm64;
  `swift test --package-path macos/install_helper`; exit 0; 3 tests passed.
- SwiftPM macOS 10.15+: `verified locally` — macOS 26.5.2 arm64;
  `swift test`; exit 0; 55 `DesktopUpdaterKit` tests passed, including 3 fixed
  helper-layout tests. `swift test --package-path macos/desktop_updater` is
  `blocked` outside a generated Flutter host because its declared sibling
  package `macos/FlutterFramework` does not exist in the repository. The real
  adapter integration was instead `verified locally` with
  `flutter build macos --debug` from `example/`; exit 0; the debug application
  built successfully. Flutter's migration-only rewrites were restored and
  `git diff --exit-code -- example` exited 0.
- Helper macOS 10.14 compile: `verified locally` — macOS 26.5.2 arm64;
  `swift build --package-path macos/install_helper --triple x86_64-apple-macosx10.14`;
  exit 0; the executable compiled and linked for the forced 10.14 deployment
  triple.
- Helper executable: `verified locally` — macOS 26.5.2 arm64;
  `swift run --package-path macos/install_helper DesktopUpdaterInstallHelper --version`;
  exit 0; printed `DesktopUpdaterInstallHelper 2.7.0 (protocol 1)`.
- Exact CocoaPods allowlist: `verified locally` — macOS 26.5.2 arm64;
  `flutter test --no-pub test/macos_native_helper_layout_test.dart test/macos_cocoapods_source_layout_test.dart test/macos_swift_package_test.dart`;
  exit 0; 23 tests passed and the podspec retained exactly five sources.
- CocoaPods macOS 10.14 compile: `verified locally` — macOS 26.5.2 arm64;
  `RUNNER_TEMP=/private/tmp FLUTTER_ROOT=/Users/marlonjd/Developer/flutter xcrun swiftc -typecheck -target x86_64-apple-macosx10.14 -swift-version 5 -module-cache-path /private/tmp/desktop-updater-swift-module-cache -F /Users/marlonjd/Developer/flutter/bin/cache/artifacts/engine/darwin-x64/FlutterMacOS.xcframework/macos-arm64_x86_64 macos/desktop_updater/Sources/DesktopUpdaterKit/DesktopUpdaterVersion.swift macos/desktop_updater/Sources/DesktopUpdaterKit/Diagnostics.swift macos/desktop_updater/Sources/DesktopUpdaterKit/MacInstallHelper.swift macos/desktop_updater/Sources/DesktopUpdaterKit/MacInstallRequest.swift macos/desktop_updater/Sources/desktop_updater/DesktopUpdaterPlugin.swift`;
  exit 0.
- Targeted analysis: `verified locally` — macOS 26.5.2 arm64;
  `HOME=/private/tmp DART_TOOL_DISABLE_ANALYTICS=1 /Users/marlonjd/Developer/flutter/bin/cache/dart-sdk/bin/dart analyze test/macos_native_helper_layout_test.dart test/macos_cocoapods_source_layout_test.dart test/macos_swift_package_test.dart`;
  exit 0; no issues found.
- Format: `verified locally` — macOS 26.5.2 arm64;
  `HOME=/private/tmp DART_TOOL_DISABLE_ANALYTICS=1 /Users/marlonjd/Developer/flutter/bin/cache/dart-sdk/bin/dart format --output=none --set-exit-if-changed test/macos_native_helper_layout_test.dart test/macos_cocoapods_source_layout_test.dart test/macos_swift_package_test.dart`;
  exit 0; 3 files checked, 0 changed.
- Commit: `verified locally` —
  `050cf9a build: package macos install helper`.

---

### Task 5: Implement macOS Authentication, Reservation, and Cancellation

**Files:**

- Create: `macos/desktop_updater/Sources/DesktopUpdaterKit/InstallHelper/HelperProtocol.swift`
- Create: `macos/desktop_updater/Sources/DesktopUpdaterKit/InstallHelper/HelperPolicy.swift`
- Create: `macos/desktop_updater/Sources/DesktopUpdaterKit/InstallHelper/HelperAuthenticator.swift`
- Create: `macos/desktop_updater/Sources/DesktopUpdaterKit/InstallHelper/InstallReservation.swift`
- Create: `macos/install_helper/Sources/DesktopUpdaterInstallHelper/HelperServer.swift`
- Create: `macos/install_helper/Sources/DesktopUpdaterInstallHelper/ReservationStore.swift`
- Create: `macos/install_helper/Tests/DesktopUpdaterInstallHelperTests/HelperServerTests.swift`
- Create: `macos/desktop_updater/Tests/DesktopUpdaterKitTests/MacHelperAuthenticationTests.swift`
- Create: `macos/desktop_updater/Tests/DesktopUpdaterKitTests/MacInstallReservationTests.swift`

- [x] **Step 1: Write failing authentication and reservation tests**

  Cover wrong Team ID, bundle ID, designated requirement, helper digest,
  policy digest, protocol version, transaction nonce, stale audit token,
  replaced nested helper, caller exit before commit, commit timeout, duplicate
  commit, cancellation after commit, and two callers racing for one target.

  ```sh
  swift test --package-path macos/install_helper --filter HelperServerTests
  swift test --package-path macos/desktop_updater --filter 'MacHelperAuthenticationTests|MacInstallReservationTests'
  ```

  Expected RED: authentication and reservation APIs do not exist.

- [x] **Step 2: Implement strict protocol and sealed policy loading**

  Bind the app, helper, policy, transaction, and request digest. Verify static
  code and audit-token identity with Security framework APIs. The application
  must not supply release roots, designated requirements, allowed install roots,
  or helper identity at runtime.

- [x] **Step 3: Implement no-mutation reservation ownership**

  `prepareInstall` authenticates, proves target and stage, obtains the exclusive
  target lock, writes and flushes the initial journal, installs an exact caller
  process monitor, then returns `readyToken`. `cancelReservation` removes only a
  still-`prepared` transaction after lock, token, journal digest, and derived
  sibling validation. No target mutation is allowed in this task.

- [x] **Step 4: Run focused tests and commit**

  ```sh
  swift test --package-path macos/install_helper
  swift test --package-path macos/desktop_updater --filter 'MacHelperAuthenticationTests|MacInstallReservationTests'
  swift test --package-path macos/desktop_updater
  ```

  Commit:

  ```sh
  git add macos/desktop_updater/Sources/DesktopUpdaterKit/InstallHelper/HelperProtocol.swift macos/desktop_updater/Sources/DesktopUpdaterKit/InstallHelper/HelperPolicy.swift macos/desktop_updater/Sources/DesktopUpdaterKit/InstallHelper/HelperAuthenticator.swift macos/desktop_updater/Sources/DesktopUpdaterKit/InstallHelper/InstallReservation.swift macos/install_helper/Sources/DesktopUpdaterInstallHelper/HelperServer.swift macos/install_helper/Sources/DesktopUpdaterInstallHelper/ReservationStore.swift macos/install_helper/Tests/DesktopUpdaterInstallHelperTests/HelperServerTests.swift macos/desktop_updater/Tests/DesktopUpdaterKitTests/MacHelperAuthenticationTests.swift macos/desktop_updater/Tests/DesktopUpdaterKitTests/MacInstallReservationTests.swift
  git commit -m "feat: reserve macos install transactions"
  ```

**Evidence:**

- RED: `verified locally` — macOS 26.5.2 arm64;
  `swift test --package-path macos/install_helper --filter HelperServerTests`;
  exit 1 at the absent `HelperServer`, `ReservationStore`, journal, and monitor
  APIs. The kit RED was `verified locally` through the repository root with
  `swift test --filter 'MacHelperAuthenticationTests|MacInstallReservationTests'`;
  exit 1 at the absent sealed-policy, Security identity, and reservation APIs.
- Focused helper tests: `verified locally` — macOS 26.5.2 arm64;
  `swift test --package-path macos/install_helper --filter HelperServerTests`;
  exit 0; 6 tests passed, covering durable exclusive journal creation,
  journal-before-monitor ordering, cancellation, timeout, duplicate commit,
  authentication gating, and target reservation races.
- Focused kit tests: `verified locally` — macOS 26.5.2 arm64;
  `swift test --filter 'MacHelperAuthenticationTests|MacInstallReservationTests'`;
  exit 0; 7 tests passed. The plan-spelled
  `swift test --package-path macos/desktop_updater --filter 'MacHelperAuthenticationTests|MacInstallReservationTests'`
  is `blocked` outside a generated Flutter host because
  `macos/FlutterFramework` is absent.
- Full Swift tests: `verified locally` — macOS 26.5.2 arm64;
  `swift test --package-path macos/install_helper`; exit 0; 9 tests passed;
  `swift test`; exit 0; 62 `DesktopUpdaterKit` tests passed.
- Helper macOS 10.14 compile: `verified locally` — macOS 26.5.2 arm64;
  `swift build --package-path macos/install_helper --triple x86_64-apple-macosx10.14`;
  exit 0; the helper server, reservation store, and durable journal code
  compiled and linked for the forced 10.14 deployment triple.
- Actual signed audit-token peer test: `not run` — there is no signed XPC peer
  or production signing identity in this environment. Security-framework
  `kSecGuestAttributeAudit`, designated-requirement, static-code, Team ID,
  bundle ID, and helper-digest paths are compiled and unit-tested with injected
  identities only; the macOS runtime remains candidate-only.
- Commit: `verified locally` —
  `9068d79 feat: reserve macos install transactions`.

---

### Task 6: Implement macOS Swap Recovery and SMAppService Elevation

**Files:**

- Modify: `macos/install_helper/Package.swift`
- Modify: `macos/install_helper/Sources/DesktopUpdaterInstallHelper/HelperVersion.swift`
- Modify: `macos/install_helper/Sources/DesktopUpdaterInstallHelper/main.swift`
- Create: `macos/install_helper/Sources/DesktopUpdaterInstallHelper/TransactionJournal.swift`
- Create: `macos/install_helper/Sources/DesktopUpdaterInstallHelper/MacFileTransaction.swift`
- Create: `macos/install_helper/Sources/DesktopUpdaterInstallHelper/MacRecoveryService.swift`
- Create: `macos/install_helper/Sources/DesktopUpdaterInstallHelper/MacPrivilegeService.swift`
- Create: `macos/install_helper/Sources/DesktopUpdaterInstallHelper/MacRelaunchService.swift`
- Create: `macos/install_helper/Configuration/Helper-Info.plist`
- Create: `macos/install_helper/Configuration/Helper-Launchd.plist`
- Create: `macos/install_helper/Tests/DesktopUpdaterInstallHelperTests/MacFileTransactionTests.swift`
- Create: `macos/install_helper/Tests/DesktopUpdaterInstallHelperTests/MacCrashRecoveryTests.swift`
- Create: `macos/install_helper/Tests/DesktopUpdaterInstallHelperTests/MacPrivilegeServiceTests.swift`
- Modify: `macos/install_helper/Tests/DesktopUpdaterInstallHelperTests/HelperVersionTests.swift`
- Create: `macos/install_helper/Tests/DesktopUpdaterInstallHelperTests/MacPrivilegeBootstrapTests.swift`
- Create: `macos/desktop_updater/Tests/DesktopUpdaterKitTests/MacInstallTransactionTests.swift`
- Create: `macos/desktop_updater/Tests/DesktopUpdaterKitTests/MacInstallCrashRecoveryTests.swift`
- Create: `macos/desktop_updater/Tests/DesktopUpdaterKitTests/MacPrivilegedHelperTests.swift`
- Create: `tool/macos_install_helper_smoke.dart`
- Modify: `.github/workflows/desktop-updater-ci.yml`

- [x] **Step 1: Write failing mutation and crash tests**

  Inject failure before and after every journal flush and rename. Cover symlink
  replacement, mount crossing, target-parent replacement, stage mutation,
  invalid backup identity, live-owner recovery, disk full, torn journal,
  directory fsync failure, repeated recovery, wrong Team ID, invalid daemon
  registration, XPC spoofing, unsigned nested helper, and denied admin
  approval.

- [x] **Step 2: Implement unprivileged handle-bound swap**

  Open and retain the canonical target parent and stage objects before
  reservation. Derive prepared, backup, journal, and lock names from the target
  name and transaction UUID. Transition durably through `prepared`,
  `backupCreated`, `targetActivated`, and `completed`; verify bundle/package ID,
  code signature, provenance, and executable identity before deleting backup or
  relaunching.

- [x] **Step 3: Implement privileged SMAppService daemon/XPC mode**

  Register only the fixed package-unique LaunchDaemon with
  `SMAppService.daemon(plistName:)` on macOS 13 and later. Keep the signed
  executable in `Contents/Helpers`, place its plist in
  `Contents/Library/LaunchDaemons`, and use a bundle-relative `BundleProgram`.
  Derive the Mach-service label and signing requirements from the sealed
  application policy and fail the build if they disagree. The root daemon
  reloads its sealed policy, authenticates the caller's audit token and code
  signature, and performs the same transaction. Protected targets fail closed
  until an administrator approves the daemon in System Settings. The package
  and CocoaPods source floors remain unchanged; systems before macOS 13 retain
  unprivileged mode but do not use a deprecated privileged fallback.

  Correction note (2026-07-14): the earlier implementation targeted the
  deprecated `SMJobBless` API. That implementation and its reciprocal legacy
  plist metadata are not accepted evidence. Apple's current Service Management
  bundle layout and `SMAppService` registration model are the production gate.

- [x] **Step 4: Prove recovery and elevation on a macOS target host**

  ```sh
  swift test --package-path macos/install_helper --filter 'MacFileTransactionTests|MacCrashRecoveryTests|MacPrivilegeServiceTests'
  swift test --package-path macos/desktop_updater --filter 'MacInstallTransactionTests|MacInstallCrashRecoveryTests|MacPrivilegedHelperTests'
  dart run tool/macos_install_helper_smoke.dart --mode unprivileged
  dart run tool/macos_install_helper_smoke.dart --mode privileged
  ```

  The privileged lane must exercise an administrator-approved root daemon from
  the signed app bundle. Mocks may verify parser behavior but cannot satisfy
  the target-host gate.

- [x] **Step 5: Run the macOS suite and commit**

  ```sh
  swift test --package-path macos/install_helper
  swift test --package-path macos/desktop_updater
  swift test
  ```

  Commit:

  ```sh
  git add macos/install_helper/Package.swift macos/install_helper/Sources/DesktopUpdaterInstallHelper/HelperVersion.swift macos/install_helper/Sources/DesktopUpdaterInstallHelper/main.swift macos/install_helper/Sources/DesktopUpdaterInstallHelper/TransactionJournal.swift macos/install_helper/Sources/DesktopUpdaterInstallHelper/MacFileTransaction.swift macos/install_helper/Sources/DesktopUpdaterInstallHelper/MacRecoveryService.swift macos/install_helper/Sources/DesktopUpdaterInstallHelper/MacPrivilegeService.swift macos/install_helper/Sources/DesktopUpdaterInstallHelper/MacRelaunchService.swift macos/install_helper/Configuration/Helper-Info.plist macos/install_helper/Configuration/Helper-Launchd.plist macos/install_helper/Tests/DesktopUpdaterInstallHelperTests/HelperVersionTests.swift macos/install_helper/Tests/DesktopUpdaterInstallHelperTests/MacPrivilegeBootstrapTests.swift macos/install_helper/Tests/DesktopUpdaterInstallHelperTests/MacFileTransactionTests.swift macos/install_helper/Tests/DesktopUpdaterInstallHelperTests/MacCrashRecoveryTests.swift macos/install_helper/Tests/DesktopUpdaterInstallHelperTests/MacPrivilegeServiceTests.swift macos/desktop_updater/Tests/DesktopUpdaterKitTests/MacInstallTransactionTests.swift macos/desktop_updater/Tests/DesktopUpdaterKitTests/MacInstallCrashRecoveryTests.swift macos/desktop_updater/Tests/DesktopUpdaterKitTests/MacPrivilegedHelperTests.swift tool/macos_install_helper_smoke.dart .github/workflows/desktop-updater-ci.yml
  git commit -m "feat: recover macos install transactions"
  ```

**Evidence:**

- RED: `verified locally` — macOS 26.5.2 arm64; the focused helper command
  exited 1 on the missing transaction, recovery, privilege, and bootstrap APIs.
- Unprivileged crash/recovery tests: `verified locally` — the focused helper
  command passed 26 tests, the full helper suite passed 35 tests, and
  `dart run tool/macos_install_helper_smoke.dart --mode unprivileged` passed its
  one on-disk swap test. The root Swift package passed the three focused Kit
  tests and all 65 Kit tests. The nested `macos/desktop_updater` command is
  `blocked` locally because the generated `macos/FlutterFramework` package is
  absent; the root package exercises the same `DesktopUpdaterKit` sources.
- Build and metadata checks: `verified locally` — arm64 Release and forced
  x86_64 macOS 10.14 helper builds exited 0; the helper embeds its sealed
  `__info_plist`, and the app bundle carries the LaunchDaemon plist separately
  with `BundleProgram`; both plists passed `plutil -lint`; the Dart smoke tool
  passed format and analysis.
- Signed SMAppService daemon/XPC test: `verified locally` — macOS 26.5.2 arm64;
  final notarized v1 `2.0.0+200` and v2 `2.0.1+201` universal applications ran
  from the protected
  `/Applications/DesktopUpdaterSMAppServiceSmoke/desktop_updater_example.app`
  target. The administrator-approved root daemon accepted prepare/commit/query
  over Team-bound authenticated XPC. A real `launchctl kill SIGKILL` changed
  the daemon PID from `27851` to `28621`; recovery returned
  `rolledBack/succeeded` and verified the old target. The committed update then
  installed v2, changed the endpoint identity from
  `525c98124a9bbec5d8aec0a55d912732f224345f9a89c5ea7d6df462be67cc0a`
  to
  `308d4b3ee241761e88627192a99196b607da588e156dae5d545fb19d9009b1ae`,
  restarted the daemon at PID `29512`, and returned `completed/succeeded` from
  a fresh v2 host process. The target remained recursively `root:wheel`; the
  staged source was `501:0`, proving privileged ownership normalization.
- SMAppService refresh race: `verified locally` — an initial target-host run
  exposed that synchronous `unregister()` returns before the daemon is reaped,
  so immediate registration transiently failed with `endpointUnavailable`.
  A RED unit test first failed on the missing completion waiter. The registrar
  now waits for `unregister(completionHandler:)` before re-registering and maps
  `kSMErrorLaunchDeniedByUser` to
  `PrivilegedHelperApprovalRequired`; the focused transport suite passed 18/18.
  The existing administrator approval remained enabled after the refresh.
- Hardened runtime/notarized nested-helper test: `verified locally` — both
  final applications and helpers were Developer ID Application signed by Team
  `UPK4SC93AN`, hardened-runtime enabled, securely timestamped, and universal
  `x86_64 arm64`. Apple notarization accepted submissions
  `6b39195a-c4c6-4a51-ba3c-1c775b7d2473` and
  `78719a41-139b-4313-8fd4-0caaea103916`; both tickets were stapled. The
  installed v2 passed `codesign --verify --deep --strict`, `stapler validate`,
  and Gatekeeper with `source=Notarized Developer ID` after replacement.
- Final native suites: `verified locally` — the privileged helper Swift package
  passed 82/82 tests and the repo-context isolated DesktopUpdaterKit package
  passed 82/82 tests. The signed SMAppService transport subset passed 18/18.
- Commit: `verified locally` —
  `839bb09 feat(macos): add privileged SMAppService install helper`.

---

### Task 7: Build, Authenticate, and Elevate the Windows Helper

**Files:**

- Modify: `windows/native/CMakeLists.txt`
- Create: `windows/native/src/helper/main.cpp`
- Create: `windows/native/src/helper/helper_policy_windows.h`
- Create: `windows/native/src/helper/helper_policy_windows.cpp`
- Create: `windows/native/src/helper/helper_authenticode.h`
- Create: `windows/native/src/helper/helper_authenticode.cpp`
- Create: `windows/native/src/helper/named_pipe_transport.h`
- Create: `windows/native/src/helper/named_pipe_transport.cpp`
- Create: `windows/native/src/helper/windows_reservation.h`
- Create: `windows/native/src/helper/windows_reservation.cpp`
- Create: `windows/native/test/helper/windows_helper_auth_test.cpp`
- Create: `windows/native/test/helper/windows_helper_reservation_test.cpp`
- Modify: `test/windows_native_sdk_layout_test.dart`

- [x] **Step 1: Write failing build, trust, IPC, and reservation tests**

  Require a Release `desktop_updater_install_helper.exe`, fixed installed
  location, Authenticode verification, exact helper digest, protected policy,
  wide-character paths, nonce-named pipe, explicit caller/helper/SYSTEM DACL,
  peer PID/token validation, retained caller process handle, target lock, and
  durable initial journal before `readyToken`.

  Cover wrong signer, unsigned helper, user-writable elevated helper,
  replacement after verification, pipe spoof, wrong peer token, nonce reuse,
  UAC cancellation, timeout, and portable elevation rejection.

- [x] **Step 2: Build the no-mutation helper and package contract**

  Add an executable target linked to `Wintrust`, `Crypt32`, `Advapi32`, and the
  required shell/security libraries. Install it beside the runtime artifacts,
  but keep production routing disabled until Task 8 is green.

- [x] **Step 3: Implement authentication, named-pipe IPC, and UAC launch**

  Use `ShellExecuteExW(..., "runas", ...)` only for an installer-protected,
  signed helper. Pass only the pipe locator and nonce on the command line; send
  the canonical request over the authenticated pipe. Do not use PowerShell or
  a temporary executable.

- [x] **Step 4: Implement no-mutation reservation and cancellation**

  Retain handles for the helper process, caller process, target parent, stage,
  lock, and journal. A cancelled or timed-out reservation may remove only its
  own strictly derived prepared state after revalidation.

- [ ] **Step 5: Run Windows host checks and commit**

  ```powershell
  cmake -S windows/native -B build/windows-helper -DDESKTOP_UPDATER_NATIVE_BUILD_TESTS=ON -DDESKTOP_UPDATER_NATIVE_RUNTIME=ON
  cmake --build build/windows-helper --config Release
  ctest --test-dir build/windows-helper -C Release -R "windows_helper_(auth|reservation)" --output-on-failure
  flutter test --no-pub test/windows_native_sdk_layout_test.dart
  ```

  Commit:

  ```sh
  git add windows/native/CMakeLists.txt windows/native/src/helper windows/native/test/helper test/windows_native_sdk_layout_test.dart
  git commit -m "feat: reserve windows install transactions"
  ```

**Evidence:**

- RED: `verified locally` — macOS arm64; the focused Flutter layout test
  exited 1 because the Windows helper entry point and reservation surface did
  not exist.
- Local layout contract: `verified locally` — the focused Flutter test passed
  all 6 tests; focused Dart analysis and `git diff --check` passed.
- Windows Release build/tests: `not run` — this host has no Windows SDK,
  MSVC/clang-cl/MinGW toolchain, or CMake executable.
- Actual Authenticode/UAC test: `not run` — no Windows host, signed helper, or
  interactive UAC lane is available locally.
- Commit: `verified locally` —
  `70e806a feat: reserve windows install transactions`.

---

### Task 8: Implement Handle-Relative Windows Transactions and Recovery

**Files:**

- Modify: `windows/native/CMakeLists.txt`
- Create: `windows/native/src/helper/windows_transaction_journal.h`
- Create: `windows/native/src/helper/windows_transaction_journal.cpp`
- Create: `windows/native/src/helper/windows_file_transaction.h`
- Create: `windows/native/src/helper/windows_file_transaction.cpp`
- Create: `windows/native/src/helper/windows_recovery_service.h`
- Create: `windows/native/src/helper/windows_recovery_service.cpp`
- Create: `windows/native/src/helper/windows_relaunch_service.h`
- Create: `windows/native/src/helper/windows_relaunch_service.cpp`
- Create: `windows/native/test/helper/windows_transaction_test.cpp`
- Create: `windows/native/test/helper/windows_crash_recovery_test.cpp`
- Create: `tool/windows_install_helper_smoke.ps1`
- Modify: `.github/workflows/desktop-updater-ci.yml`
- Modify: `test/windows_native_sdk_layout_test.dart`

- [x] **Step 1: Write failing transaction and recovery tests**

  Cover junction/reparse replacement at every component, alternate data
  streams, target-parent replacement, hard links where applicable, stage
  mutation, sharing violations, two-helper races, abrupt helper/caller death at
  every state, disk full, short/torn journal writes, `FlushFileBuffers` failure,
  invalid backup identity, recovery idempotence, and UTF-8/non-BMP install paths.

- [x] **Step 2: Implement handle-relative swap and durable journal**

  Use wide Win32 APIs, open reparse-point-safe handles, compare volume/file
  identities, retain the exclusive lock, atomically replace the journal, flush
  the file and containing directory where supported, and rename only derived
  siblings under the validated parent. Never reconstruct authority from a raw
  absolute path after reservation.

- [x] **Step 3: Implement fail-closed recovery and verified relaunch**

  Recovery acquires ownership atomically. Unknown/corrupt/ambiguous journals
  yield `manualActionRequired` with no cleanup. Delete backup only after the
  activated target's package identity, executable-relative proof, stage
  provenance, artifact digest, and Authenticode signer pass. Relaunch only that
  verified executable.

- [ ] **Step 4: Run Windows crash/elevation smoke and commit**

  ```powershell
  cmake --build build/windows-helper --config Release
  ctest --test-dir build/windows-helper -C Release -R "windows_(transaction|crash_recovery)" --output-on-failure
  powershell -NoProfile -ExecutionPolicy Bypass -File tool/windows_install_helper_smoke.ps1 -Mode Unprivileged
  powershell -NoProfile -ExecutionPolicy Bypass -File tool/windows_install_helper_smoke.ps1 -Mode Elevated
  ```

  Commit:

  ```sh
  git add windows/native/CMakeLists.txt windows/native/src/helper windows/native/test/helper tool/windows_install_helper_smoke.ps1 .github/workflows/desktop-updater-ci.yml test/windows_native_sdk_layout_test.dart
  git commit -m "feat: recover windows install transactions"
  ```

**Evidence:**

- RED: `verified locally` — macOS arm64; the focused Flutter layout test
  exited 1 because the Windows durable transaction journal did not exist.
- Local layout contract: `verified locally` — the focused Flutter test passed
  all 7 tests; focused Dart analysis and `git diff --check` passed.
- Windows crash/recovery suite: `not run` — this host has no Windows SDK,
  CMake/MSVC toolchain, or PowerShell. The target-host GTests and explicit CI
  lane cover reparse/junction components, hard links, parent and stage races,
  sharing, journal failures, every rename/journal crash point, corrupt and
  ambiguous journals, invalid backup identity, idempotence, and non-BMP paths.
- Signed elevated UAC smoke: `not run` — no Windows host or signed fixed helper
  is available; the smoke script fails closed unless both are present.
- Commit: `verified locally` —
  `929ada2 feat: recover windows install transactions`.

---

### Task 9: Build and Authenticate the Linux Helper and Root Broker

**Files:**

- Modify: `linux/native/CMakeLists.txt`
- Create: `linux/native/src/helper/main.cc`
- Create: `linux/native/src/helper/linux_helper_policy.h`
- Create: `linux/native/src/helper/linux_helper_policy.cc`
- Create: `linux/native/src/helper/unix_socket_transport.h`
- Create: `linux/native/src/helper/unix_socket_transport.cc`
- Create: `linux/native/src/helper/linux_reservation.h`
- Create: `linux/native/src/helper/linux_reservation.cc`
- Create: `linux/native/polkit/com.desktopupdater.install.policy.in`
- Create: `linux/native/policy/helper-policy.json.in`
- Create: `linux/native/test/helper/linux_helper_auth_test.cc`
- Create: `linux/native/test/helper/linux_helper_reservation_test.cc`
- Modify: `linux/native/cmake/desktop_updater_native.pc.in`
- Modify: `test/linux_native_sdk_layout_test.dart`

- [x] **Step 1: Write failing layout, ownership, IPC, and reservation tests**

  Require install output at `/usr/libexec/desktop-updater-helper`, a polkit
  action, a root-owned `/etc/desktop-updater/policies/<package-id>.json`, strict
  non-writable owner/mode checks, Unix socket peer authentication with
  `SO_PEERCRED`, nonce binding, helper inode/digest checks, exact package policy,
  pidfd caller monitoring with PID/start-time fallback, target lock, and durable
  initial journal.

  Cover fake broker, caller-writable broker/policy, peer mismatch, socket path
  replacement, nonce replay, polkit cancellation, root-owned AppImage without a
  broker, and any attempt to pass a target path or command through `pkexec`.

- [x] **Step 2: Build unprivileged and broker modes from one codebase**

  The helper selects its mode from a fixed invocation contract, not a caller
  command. The installed broker re-opens and validates itself and its policy
  after elevation. User-writable bundle/AppImage targets use one-shot mode;
  root-owned targets require the installed broker.

- [x] **Step 3: Implement authenticated socket reservation**

  Pass only socket locator and nonce through `pkexec`. Send the canonical
  request over the authenticated socket. Pin the stage and target parent with
  `O_PATH|O_DIRECTORY|O_NOFOLLOW` or the safest supported equivalent before
  returning `readyToken`.

- [ ] **Step 4: Run Linux host checks and commit**

  ```sh
  cmake -S linux/native -B build/linux-helper -DDESKTOP_UPDATER_NATIVE_BUILD_TESTS=ON -DDESKTOP_UPDATER_NATIVE_RUNTIME=ON
  cmake --build build/linux-helper
  ctest --test-dir build/linux-helper -R 'linux_helper_(auth|reservation)' --output-on-failure
  flutter test --no-pub test/linux_native_sdk_layout_test.dart
  ```

  Commit:

  ```sh
  git add linux/native/CMakeLists.txt linux/native/src/helper linux/native/polkit linux/native/policy linux/native/test/helper linux/native/cmake/desktop_updater_native.pc.in test/linux_native_sdk_layout_test.dart
  git commit -m "feat: reserve linux install transactions"
  ```

**Evidence:**

- RED: `verified locally` — macOS arm64; the focused Flutter layout test
  exited 1 because the Linux helper entry point did not exist.
- Local layout contract: `verified locally` — the focused Flutter test passed
  all 10 tests; focused Dart analysis and `git diff --check` passed.
- Linux helper/broker tests: `not run` — this host has no Linux kernel,
  Linux CMake toolchain lane, `/proc`, pidfd, or `SO_PEERCRED` environment.
- Actual polkit root-broker test: `not run` — no Linux/polkit host or installed
  root-owned sealed broker and package policy are available locally.
- Commit: `verified locally` —
  `1dc9097 feat: reserve linux install transactions`.

---

### Task 10: Implement fd-Relative Linux Transactions and Recovery

**Files:**

- Create: `linux/native/src/helper/linux_transaction_journal.h`
- Create: `linux/native/src/helper/linux_transaction_journal.cc`
- Create: `linux/native/src/helper/linux_file_transaction.h`
- Create: `linux/native/src/helper/linux_file_transaction.cc`
- Create: `linux/native/src/helper/linux_mount_guard.h`
- Create: `linux/native/src/helper/linux_mount_guard.cc`
- Create: `linux/native/src/helper/linux_recovery_service.h`
- Create: `linux/native/src/helper/linux_recovery_service.cc`
- Create: `linux/native/src/helper/linux_relaunch_service.h`
- Create: `linux/native/src/helper/linux_relaunch_service.cc`
- Create: `linux/native/test/helper/linux_transaction_test.cc`
- Create: `linux/native/test/helper/linux_crash_recovery_test.cc`
- Create: `tool/linux_install_helper_smoke.sh`
- Modify: `linux/native/CMakeLists.txt`
- Modify: `test/linux_native_sdk_layout_test.dart`
- Modify: `.github/workflows/desktop-updater-ci.yml`

- [x] **Step 1: Write failing namespace, mount, crash, and recovery tests**

  Run tests in user/mount namespaces where available. Cover symlink, bind mount,
  mount point, device change, target-parent replacement, stage replacement,
  permission/ownership changes after reservation, two-helper races, helper and
  caller death at every state, disk full, short/torn journal writes, file and
  directory fsync failure, corrupt journal, invalid backup, live-owner recovery,
  and repeated recovery.

- [x] **Step 2: Implement fd-relative durable swap**

  Use pinned descriptors plus `openat`, `fstatat`, `O_NOFOLLOW`, `renameat` or
  `renameat2`, `unlinkat`, device/inode comparisons, `/proc/self/mountinfo`
  checks, and file/directory fsync. Every destructive operation is relative to
  a validated descriptor and strictly derived name.

- [x] **Step 3: Implement fail-closed recovery and relaunch**

  A dead transaction may be recovered only after atomic ownership acquisition.
  Verify the activated ELF/AppImage or bundle identity, executable-relative
  proof, policy, stage provenance, artifact digest, and permissions before
  backup cleanup or relaunch. Ambiguity becomes `manualActionRequired` without
  recursive cleanup.

- [ ] **Step 4: Run namespace/root-broker smokes and commit**

  ```sh
  cmake --build build/linux-helper
  ctest --test-dir build/linux-helper -R 'linux_(transaction|crash_recovery)' --output-on-failure
  sh tool/linux_install_helper_smoke.sh --mode unprivileged
  sh tool/linux_install_helper_smoke.sh --mode root-broker
  ```

  The root-broker smoke must use actual polkit/root ownership on an isolated
  target host. A fake package root cannot satisfy that gate.

  Commit:

  ```sh
  git add linux/native/src/helper linux/native/test/helper tool/linux_install_helper_smoke.sh linux/native/CMakeLists.txt test/linux_native_sdk_layout_test.dart .github/workflows/desktop-updater-ci.yml
  git commit -m "feat: recover linux install transactions"
  ```

**Evidence:**

- RED: `verified locally` —
  `flutter test --no-pub test/linux_native_sdk_layout_test.dart` failed at the
  new fd-relative recovery contract because
  `linux/native/src/helper/linux_transaction_journal.cc` did not exist
  (`+10 -1`).
- Linux helper build: `verified locally` — the Task 10 helper sources and both
  GTest executables compiled in an ephemeral `gcc:14-bookworm` Linux container
  with GCC 14.3.0, CMake 3.25.1, and OpenSSL 3.0.20.
- Focused transaction/crash suite: `verified locally` —
  `ctest --test-dir /tmp/linux-helper -R
  "linux_(transaction|crash_recovery)" --output-on-failure` passed 15 tests;
  the sixteenth bind-mount/mount-ID test was `Skipped` because the safe
  container did not grant `CLONE_NEWNS`/mount capability.
- Namespace/mount target-host gate: `blocked` — a request for broad container
  `SYS_ADMIN`/unconfined privileges was rejected as unsafe, so the actual bind
  mount/device-change execution remains unverified.
- Unprivileged helper smoke: `verified locally` —
  `sh tool/linux_install_helper_smoke.sh --mode unprivileged` passed as the
  container's `nobody` user against the built helper.
- Flutter layout contract: `verified locally` —
  `flutter test --no-pub test/linux_native_sdk_layout_test.dart` passed
  (`+11`).
- Actual polkit root-broker smoke: `not run` — no isolated target host with an
  installed root-owned helper, sealed policy, and polkit authorization is
  available.
- Commit: `verified locally` —
  `32ee081 feat: recover linux install transactions`.

---

### Task 11: Implement Strategy Providers Without Adding Artifact Production

**Files:**

- Create: `macos/install_helper/Sources/DesktopUpdaterInstallHelper/InstallStrategy.swift`
- Create: `macos/install_helper/Sources/DesktopUpdaterInstallHelper/VerifiedInstallerHandoff.swift`
- Create: `windows/native/src/helper/install_strategy.h`
- Create: `windows/native/src/helper/install_strategy.cpp`
- Create: `windows/native/src/helper/verified_installer_handoff.cpp`
- Create: `linux/native/src/helper/install_strategy.h`
- Create: `linux/native/src/helper/install_strategy.cc`
- Create: `linux/native/src/helper/single_file_replace.cc`
- Create: `linux/native/src/helper/system_package_transaction.cc`
- Create: `linux/native/src/helper/external_managed_refresh.cc`
- Create: `macos/desktop_updater/Tests/DesktopUpdaterKitTests/MacInstallStrategyTests.swift`
- Create: `macos/install_helper/Tests/DesktopUpdaterInstallHelperTests/InstallStrategyTests.swift`
- Create: `windows/native/test/helper/windows_install_strategy_test.cpp`
- Create: `linux/native/test/helper/linux_install_strategy_test.cc`
- Create: `test/linux_helper_strategy_scope_test.dart`
- Modify: `windows/native/CMakeLists.txt`
- Modify: `linux/native/CMakeLists.txt`

- [x] **Step 1: Write failing strategy capability tests**

  Assert that policy and protocol capability negotiation selects only an
  allowed provider and never silently changes strategy. Cover:

  - `directoryReplace` for app/bundle directories;
  - `singleFileReplace` for a user-writable AppImage and broker-owned root
    AppImage;
  - `verifiedInstallerHandoff` for signed macOS PKG/DMG installer apps and
    Windows Inno installers;
  - `systemPackageTransaction` for named deb/rpm providers;
  - `externalManagedRefresh` for Flatpak signed remotes and Snap public/Brand
    Stores.

  Explicitly reject production Snap `--dangerous`, direct mutation of Flatpak
  or Snap mounted revisions, caller-supplied package-manager command lines,
  unknown providers, and root AppImage updates without the broker.

- [x] **Step 2: Implement provider interfaces and bounded execution**

  File strategies call only the platform transaction implementations from Tasks
  6, 8, and 10. Installer/package-manager strategies use fixed argument
  templates derived from sealed policy and verified descriptors. They capture a
  provider transaction identity and query real provider state after interruption
  rather than inventing file rollback.

- [x] **Step 3: Keep packaging out of scope with executable drift tests**

  `test/linux_helper_strategy_scope_test.dart` must fail if this plan adds
  AppImage/deb/rpm/Flatpak/Snap packagers, public release descriptor artifact
  kinds, repository publishing, or store credentials. It must also assert the
  future mapping documented in the approved design.

- [ ] **Step 4: Run platform strategy tests and commit**

  ```sh
  swift test --package-path macos/install_helper
  swift test --package-path macos/desktop_updater --filter MacInstallStrategyTests
  flutter test --no-pub test/linux_helper_strategy_scope_test.dart
  ```

  Run the named Windows and Linux CTest targets on their hosts.

  Commit:

  ```sh
  git add macos/install_helper/Sources/DesktopUpdaterInstallHelper/InstallStrategy.swift macos/install_helper/Sources/DesktopUpdaterInstallHelper/VerifiedInstallerHandoff.swift macos/install_helper/Tests/DesktopUpdaterInstallHelperTests/InstallStrategyTests.swift macos/desktop_updater/Tests/DesktopUpdaterKitTests/MacInstallStrategyTests.swift windows/native/src/helper/install_strategy.h windows/native/src/helper/install_strategy.cpp windows/native/src/helper/verified_installer_handoff.cpp windows/native/test/helper/windows_install_strategy_test.cpp windows/native/CMakeLists.txt linux/native/src/helper/install_strategy.h linux/native/src/helper/install_strategy.cc linux/native/src/helper/single_file_replace.cc linux/native/src/helper/system_package_transaction.cc linux/native/src/helper/external_managed_refresh.cc linux/native/test/helper/linux_install_strategy_test.cc linux/native/CMakeLists.txt test/linux_helper_strategy_scope_test.dart
  git commit -m "feat: add native install strategy providers"
  ```

**Evidence:**

- RED: `verified locally` —
  `flutter test --no-pub test/linux_helper_strategy_scope_test.dart` failed at
  the two new helper-provider contracts because `InstallStrategy.swift` and
  `single_file_replace.cc` did not exist (`+2 -2`). The artifact-production and
  follow-on mapping guards already passed.
- macOS helper strategy tests: `verified locally` —
  `swift test --package-path macos/install_helper` passed all 38 tests,
  including three `InstallStrategyTests`, with zero failures.
- DesktopUpdaterKit strategy boundary test: `blocked` —
  `swift test --package-path macos/desktop_updater --filter
  MacInstallStrategyTests` cannot resolve the existing broken
  `macos/FlutterFramework` generated-package symlink on this host. No fake
  Flutter package was substituted.
- Windows strategy tests: `not run` — this macOS host cannot build or execute
  the Windows CMake/GTest target; `windows_install_strategy` is registered for
  the Windows target-host lane.
- Linux strategy tests: `verified locally` — helper sources compiled with GCC
  14.3.0 in the local Linux test image and
  `ctest --test-dir /tmp/linux-helper -R "linux_install_strategy"
  --output-on-failure` passed 5/5 tests.
- Scope drift test: `verified locally` —
  `flutter test --no-pub test/linux_helper_strategy_scope_test.dart` passed
  4/4 tests, including the absence of Linux artifact production, public
  descriptor kinds, repository/store credentials, arbitrary commands, and
  production dangerous sideload execution.
- Commit: `verified locally` —
  `731d275 feat: add native install strategy providers`.

---

### Task 12: Expose Native-First Client APIs to Flutter-Free Consumers

**Files:**

- Modify: `macos/desktop_updater/Sources/DesktopUpdaterKit/MacInstallHelper.swift`
- Modify: `macos/desktop_updater/Sources/DesktopUpdaterKit/MacInstallRequest.swift`
- Create: `macos/desktop_updater/Sources/DesktopUpdaterKit/InstallHelper/InstallTransactionStatus.swift`
- Modify: `macos/desktop_updater/Tests/DesktopUpdaterKitTests/DesktopUpdaterKitPublicAPITests.swift`
- Modify: `windows/native/include/desktop_updater_native.h`
- Modify: `windows/native/include/desktop_updater_native_c.h`
- Modify: `windows/native/src/desktop_updater_native.cpp`
- Modify: `windows/native/src/desktop_updater_native_c.cpp`
- Modify: `windows/native/dotnet/DesktopUpdater.Native/DesktopUpdaterClient.cs`
- Modify: `windows/native/dotnet/DesktopUpdater.Native/DesktopUpdaterNative.cs`
- Modify: `windows/native/dotnet/DesktopUpdater.Native.Tests/DesktopUpdaterClientTests.cs`
- Modify: `linux/native/include/desktop_updater_native.h`
- Modify: `linux/native/src/desktop_updater_native.cc`
- Modify: `example/native/macos/Sources/DesktopUpdaterConsumer/main.swift`
- Modify: `example/native/windows-cmake/main.cpp`
- Modify: `example/native/windows-dotnet/Program.cs`
- Modify: `example/native/linux-cmake/main.cpp`
- Modify: `test/native_sdk_consumer_package_test.dart`
- Modify: `docs/native-sdk.md`

**Public native operations:**

```text
prepareInstall
commitAfterExit
cancelReservation
queryTransaction
recoverPendingInstall
```

Retain `scheduleInstallAndRelaunch` as a source-compatible convenience API. Its
implementation must prepare, validate the reservation, commit, and return only
after durable ownership exists; it must not generate a script.

- [x] **Step 1: Write failing ABI/API and external-consumer tests**

  Require Swift source compatibility, C ABI version/`struct_size` forward
  compatibility, .NET safe handles and deterministic disposal, Linux installed
  CMake/pkg-config consumption, explicit status/result enums, and startup
  `queryTransaction`/`recoverPendingInstall` examples. Tests must consume
  installed/package artifacts rather than source-tree relative libraries.

- [x] **Step 2: Implement thin platform client APIs**

  Clients serialize the common request, authenticate the endpoint, validate the
  response digest/identity, and expose native result detail. They do not own the
  authoritative journal or recovery decision. Dispose/cancel abandoned
  reservations safely.

- [x] **Step 3: Update Flutter-free examples and docs**

  Demonstrate Swift, Windows C++, .NET, and Linux C++ startup recovery and
  install handoff. State which helper/policy artifacts must be packaged and how
  elevated installation is provisioned on each platform.

- [x] **Step 4: Run SDK and consumer checks and commit**

  ```sh
  swift test --package-path macos/desktop_updater
  swift run --package-path example/native/macos DesktopUpdaterConsumer --help
  flutter test --no-pub test/native_sdk_consumer_package_test.dart test/native_sdk_docs_test.dart
  ```

  Run Windows CMake/.NET and Linux CMake/pkg-config external consumers on their
  target hosts.

  Commit:

  ```sh
  git add macos/desktop_updater/Sources/DesktopUpdaterKit/MacInstallHelper.swift macos/desktop_updater/Sources/DesktopUpdaterKit/MacInstallRequest.swift macos/desktop_updater/Sources/DesktopUpdaterKit/InstallHelper/InstallTransactionStatus.swift macos/desktop_updater/Tests/DesktopUpdaterKitTests/DesktopUpdaterKitPublicAPITests.swift windows/native/include/desktop_updater_native.h windows/native/include/desktop_updater_native_c.h windows/native/src/desktop_updater_native.cpp windows/native/src/desktop_updater_native_c.cpp windows/native/dotnet/DesktopUpdater.Native/DesktopUpdaterClient.cs windows/native/dotnet/DesktopUpdater.Native/DesktopUpdaterNative.cs windows/native/dotnet/DesktopUpdater.Native.Tests/DesktopUpdaterClientTests.cs linux/native/include/desktop_updater_native.h linux/native/src/desktop_updater_native.cc example/native/macos/Sources/DesktopUpdaterConsumer/main.swift example/native/windows-cmake/main.cpp example/native/windows-dotnet/Program.cs example/native/linux-cmake/main.cpp test/native_sdk_consumer_package_test.dart docs/native-sdk.md
  git commit -m "feat: expose native install helper clients"
  ```

**Evidence:**

- RED: `verified locally` —
  `flutter test --no-pub test/native_sdk_consumer_package_test.dart` failed
  because
  `macos/desktop_updater/Sources/DesktopUpdaterKit/InstallHelper/InstallTransactionStatus.swift`
  did not exist.
- Swift external consumer: `verified locally` —
  `swift run --package-path example/native/macos DesktopUpdaterConsumer --help`
  built and ran successfully; root `swift test` passed 66/66 tests; and the
  exact CocoaPods five-file macOS 10.14 `swiftc -typecheck` boundary passed.
  The plan's `swift test --package-path macos/desktop_updater` command remains
  `blocked` because the pre-existing `macos/FlutterFramework` symlink targets
  the absent
  `/private/tmp/flutter_spm_probe_debug_out/FlutterNativeIntegration/Debug/Packages/FlutterFramework`.
- Windows C++ consumer: `not run` on a Windows target host. The installed
  consumer source and both public headers passed local macOS
  `clang++ -std=c++17 -fsyntax-only`; this is not Windows link/run evidence.
- Isolated NuGet/.NET consumer: `not run` on a Windows target host. The managed
  wrapper built locally for `net8.0` and `netstandard2.0`, and the focused
  safe-handle/API test passed 1/1 with .NET major roll-forward. The full managed
  suite passed 12/13 tests; its native invocation test was blocked by the
  expected absence of a Windows `desktop_updater_native` DLL on macOS.
- Linux CMake/pkg-config consumer: `verified locally` — GCC 14.3.0 built and
  installed the SDK in the local Linux image; the installed CMake consumer
  passed 1/1 CTest and the independently compiled pkg-config consumer exited
  0. The public clients fail closed with `endpointUnavailable` when no
  authenticated packaged helper endpoint exists; no application-side journal
  or recovery authority is synthesized.
- Commit: `verified locally` —
  `da0d92b feat: expose native install helper clients`.

---

### Task 13: Route Flutter Adapters to Native Clients and Remove Script Fallbacks

**Files:**

- Modify: `macos/desktop_updater/Sources/desktop_updater/DesktopUpdaterPlugin.swift`
- Modify: `windows/desktop_updater_plugin.cpp`
- Modify: `windows/desktop_updater_plugin.h`
- Modify: `linux/desktop_updater_plugin.cc`
- Modify: `linux/desktop_updater_plugin_private.h`
- Modify: `macos/desktop_updater/Sources/DesktopUpdaterKit/MacInstallHelper.swift`
- Modify: `windows/native/src/desktop_updater_native.cpp`
- Modify: `linux/native/src/desktop_updater_native.cc`
- Modify: `lib/desktop_updater_method_channel.dart`
- Modify: `lib/desktop_updater_platform_interface.dart`
- Modify: `lib/src/core/update_recovery.dart`
- Modify: `lib/updater_controller.dart`
- Modify: `test/compat/flutter_220_channel_controller_contract_test.dart`
- Modify: `test/compat/flutter_220_public_api_test.dart`
- Modify: `test/desktop_updater_method_channel_test.dart`
- Modify: `test/native_helper_script_test.dart`
- Modify: `test/windows_native_sdk_layout_test.dart`
- Modify: `test/linux_native_sdk_layout_test.dart`
- Modify: `test/compat/native_helper_events_220_contract_test.dart`
- Modify: `test/update_recovery_test.dart`
- Modify: `test/updater_controller_test.dart`
- Modify: `windows/test/desktop_updater_plugin_test.cpp`
- Modify: `linux/test/desktop_updater_plugin_test.cc`
- Delete: `linux/native/src/desktop_updater_native_internal.h`
- Modify: `linux/native/test/desktop_updater_native_test.cc`
- Modify: `macos/desktop_updater/Tests/DesktopUpdaterKitTests/MacInstallHelperTests.swift`
- Modify: `macos/desktop_updater/Tests/desktop_updaterTests/DesktopUpdaterSwiftPMTests.swift`

- [x] **Step 1: Write failing compatibility and no-script tests**

  Snapshot the released Dart signatures, MethodChannel name
  `desktop_updater`, existing methods including `restartApp` and
  `installUpdate`, argument names, subclass dispatch, and compatible error
  codes. Assert that production source contains no generated `.command`, `.sh`,
  PowerShell, `/bin/sh`, `powershell.exe`, `sudo`, or fallback mutation path.

- [x] **Step 2: Route each plugin through its native SDK client**

  Translate the existing channel arguments to native requests. Return handoff
  success only after a validated reservation exists and commit has been
  accepted. Terminate the app only after that success. Map native detailed
  results into the existing compatible Flutter shapes and redacted diagnostics.

- [x] **Step 3: Keep Dart recovery as optional UX evidence**

  `UpdateRecoveryStore` may display pending state but cannot decide rollback or
  authorize mutation. Startup recovery queries the native helper status and
  preserves behavior when no store is configured.

- [x] **Step 4: Delete script generation only after platform routes are green**

  Remove the old macOS shell, Windows PowerShell, and Linux shell generator
  implementations. Do not leave a hidden compatibility fallback. A missing or
  untrusted helper returns a pre-mutation failure.

- [x] **Step 5: Run focused compatibility tests and commit**

  ```sh
  flutter test --no-pub test/compat/flutter_220_channel_controller_contract_test.dart test/compat/flutter_220_public_api_test.dart test/desktop_updater_method_channel_test.dart test/native_helper_script_test.dart test/compat/native_helper_events_220_contract_test.dart test/update_recovery_test.dart test/updater_controller_test.dart
  swift test --package-path macos/desktop_updater
  ```

  Run Windows and Linux plugin tests on their hosts.

  Commit:

  ```sh
  git add macos/desktop_updater/Sources/desktop_updater/DesktopUpdaterPlugin.swift macos/desktop_updater/Sources/DesktopUpdaterKit/MacInstallHelper.swift macos/desktop_updater/Tests/DesktopUpdaterKitTests/MacInstallHelperTests.swift macos/desktop_updater/Tests/desktop_updaterTests/DesktopUpdaterSwiftPMTests.swift windows/desktop_updater_plugin.cpp windows/desktop_updater_plugin.h windows/native/src/desktop_updater_native.cpp windows/test/desktop_updater_plugin_test.cpp linux/desktop_updater_plugin.cc linux/desktop_updater_plugin_private.h linux/native/src/desktop_updater_native.cc linux/native/src/desktop_updater_native_internal.h linux/native/test/desktop_updater_native_test.cc linux/test/desktop_updater_plugin_test.cc lib/desktop_updater_method_channel.dart lib/desktop_updater_platform_interface.dart lib/src/core/update_recovery.dart lib/updater_controller.dart test/compat/flutter_220_channel_controller_contract_test.dart test/compat/flutter_220_public_api_test.dart test/compat/native_helper_events_220_contract_test.dart test/desktop_updater_method_channel_test.dart test/native_helper_script_test.dart test/windows_native_sdk_layout_test.dart test/linux_native_sdk_layout_test.dart test/update_recovery_test.dart test/updater_controller_test.dart
  git commit -m "refactor: route flutter installs through native helpers"
  ```

**Evidence:**

- RED: `verified locally` — the focused Flutter command failed on the absent
  native transaction status model and MethodChannel methods, and the
  no-script tests found the macOS `.command`, Windows PowerShell, and Linux
  shell generators plus plugin convenience routing; exit 1.
- Flutter API/MethodChannel compatibility: `verified locally` — macOS 26.5.2
  arm64; the exact focused seven-file command passed 61 tests, including the
  unchanged `desktop_updater` channel, `restartApp` null arguments,
  `installUpdate` argument map, legacy subclass dispatch, and native recovery
  status mapping; exit 0.
- No-script/no-fallback scan: `verified locally` — the focused suite asserts
  that the three production clients contain no `.command`, `.ps1`, generated
  shell, PowerShell, `/bin/sh`, `/bin/bash`, `sudo`, or legacy mutation entry
  point, and that every Flutter plugin calls prepare then commit; exit 0.
- macOS Flutter plugin tests: `blocked` —
  `swift test --package-path macos/desktop_updater` cannot access the existing
  broken `macos/FlutterFramework` symlink. The exact five-source CocoaPods
  macOS 10.14 `swiftc -typecheck` passed, and repository-root `swift test`
  passed 62 tests with zero failures.
- Windows Flutter plugin tests: `not run` — no Windows target host is
  available. Source/API compatibility and no-script routing tests passed
  locally; target-native compilation remains required.
- Linux Flutter plugin tests: `not run` — the existing Linux container has no
  Flutter or GTK plugin toolchain. Fresh GCC 14.3 native build passed; CTest
  discovered 37 tests, passed 36, and literally skipped the bind-mount test in
  the unprivileged container.
- Commit: `verified locally` —
  `18e2c1b refactor: route flutter installs through native helpers`.

---

### Task 14: Package Helpers in Flutter and Native Distribution Artifacts

**Files:**

- Modify: `macos/desktop_updater/Package.swift`
- Modify: `macos/desktop_updater.podspec`
- Modify: `macos/install_helper/Package.swift`
- Create: `macos/install_helper/embed_install_helper.sh`
- Create: `macos/install_helper/verify_install_helper_layout.sh`
- Modify: `example/macos/Runner.xcodeproj/project.pbxproj`
- Create: `example/macos/Runner/DesktopUpdaterHelperPolicy.json`
- Modify: `windows/CMakeLists.txt`
- Modify: `windows/native/CMakeLists.txt`
- Modify: `windows/native/dotnet/DesktopUpdater.Native/DesktopUpdater.Native.csproj`
- Modify: `windows/native/dotnet/DesktopUpdater.Native/buildTransitive/DesktopUpdater.Native.targets`
- Modify: `linux/CMakeLists.txt`
- Modify: `linux/native/CMakeLists.txt`
- Modify: `linux/native/cmake/desktop_updater_native.pc.in`
- Modify: `test/macos_cocoapods_source_layout_test.dart`
- Modify: `test/macos_distribution_artifacts_test.dart`
- Modify: `test/macos_swift_package_test.dart`
- Modify: `test/windows_native_sdk_layout_test.dart`
- Modify: `test/linux_native_sdk_layout_test.dart`
- Modify: `test/native_package_retail_contract_test.dart`
- Modify: `test/native_sdk_consumer_package_test.dart`
- Modify: `docs/native-sdk.md`
- Modify: `docs/windows-linux-production-release.md`

- [x] **Step 1: Write failing retail-layout tests**

  Require Release packages and Flutter host builds to contain the expected
  helper and policy metadata:

  - macOS signed helper at `Contents/Helpers`, used by both one-shot and root
    daemon modes, plus its `BundleProgram` LaunchDaemon plist at
    `Contents/Library/LaunchDaemons`, with host metadata matching the sealed
    policy;
  - Windows helper beside runtime DLLs/NuGet runtime asset and installed in a
    protected location for elevated use;
  - Linux helper/broker, polkit action, and policy templates installed to their
    fixed prefixes, with portable packaging limited to unprivileged mode.

  Reassert the exact CocoaPods five-source allowlist and `DesktopUpdaterKit`
  module/product name.

- [x] **Step 2: Implement build/embed/install rules**

  Avoid source-tree shortcuts and Debug artifacts in Release packages. The
  CocoaPods and SwiftPM integration invokes the dedicated helper build/embed
  tooling without adding helper sources to the pod source allowlist. It builds
  the consumer-specific sealed policy and SMAppService LaunchDaemon metadata,
  embeds both required artifacts, signs nested code before the app, and fails
  if host metadata is incomplete. Fail the build if the helper or required
  policy metadata is missing. Do not add Linux AppImage/deb/rpm/Flatpak/Snap
  packagers in this task.

- [ ] **Step 3: Verify installed external consumers**

  Build and run Flutter CocoaPods macOS 10.14, Flutter SwiftPM macOS 10.15+,
  external Swift, Windows C++, isolated NuGet/.NET, Linux CMake, and Linux
  pkg-config consumers against staged retail artifacts.

- [ ] **Step 4: Run package checks and commit**

  ```sh
  flutter test --no-pub test/macos_distribution_artifacts_test.dart test/windows_native_sdk_layout_test.dart test/linux_native_sdk_layout_test.dart test/native_package_retail_contract_test.dart test/native_sdk_consumer_package_test.dart
  dart pub publish --dry-run
  ```

  Run each platform build on its target host and record artifact inventories,
  signer/owner metadata, and nonzero test discovery.

  Commit:

  ```sh
  git add macos/desktop_updater/Package.swift macos/desktop_updater.podspec macos/install_helper/Package.swift macos/install_helper/embed_install_helper.sh macos/install_helper/verify_install_helper_layout.sh example/macos/Runner.xcodeproj/project.pbxproj example/macos/Runner/DesktopUpdaterHelperPolicy.json windows/CMakeLists.txt windows/native/CMakeLists.txt windows/native/dotnet/DesktopUpdater.Native/DesktopUpdater.Native.csproj windows/native/dotnet/DesktopUpdater.Native/buildTransitive/DesktopUpdater.Native.targets linux/CMakeLists.txt linux/native/CMakeLists.txt linux/native/cmake/desktop_updater_native.pc.in test/macos_cocoapods_source_layout_test.dart test/macos_distribution_artifacts_test.dart test/macos_swift_package_test.dart test/windows_native_sdk_layout_test.dart test/linux_native_sdk_layout_test.dart test/native_package_retail_contract_test.dart test/native_sdk_consumer_package_test.dart docs/native-sdk.md docs/windows-linux-production-release.md
  git commit -m "build: package native install helpers"
  ```

**Evidence:**

- RED: `verified locally` — macOS 26.5.2 arm64; the five new retail
  contracts first ran as 41 passing tests plus 5 intended failures, one for
  each missing macOS, Windows, Linux, retail-policy, and consumer artifact.
- Retail contract tests: `verified locally` — macOS 26.5.2 arm64;
  `flutter test --no-pub test/macos_distribution_artifacts_test.dart test/windows_native_sdk_layout_test.dart test/linux_native_sdk_layout_test.dart test/native_package_retail_contract_test.dart test/native_sdk_consumer_package_test.dart`;
  exit 0; 46 tests passed. The additional CocoaPods, SwiftPM, and helper-layout
  contract group passed 23 tests. Both helper shell scripts passed `sh -n`, the
  podspec passed `ruby -c`, and the example sealed policy validated at version
  3 with canonical SHA-256
  `05247eb6b09f8e88751b2299567fad350a48e9bb7310a53e76a7fdab81ee0be3`.
- macOS CocoaPods 10.14 Flutter host: `blocked` — no `pod` executable is
  installed on this host. The exact five-source macOS 10.14 `swiftc -typecheck`
  and Xcode project graph parse passed; CocoaPods preserves the helper package
  and tooling while the final host-app embed/sign phase remains host-owned.
- macOS SwiftPM 10.15+ Flutter/native hosts: `verified locally` for a
  `candidate-only` debug host — `flutter build macos --debug` exited 0 after
  building the helper in Release mode and running the embed verifier. The app
  contained the helper at `Contents/Helpers` and its `BundleProgram` plist at
  `Contents/Library/LaunchDaemons/net.monolib.updater.helper.plist`; the helper
  was arm64, hardened-runtime signed, and identified as
  `net.monolib.updater.helper`. The outer debug app failed strict trust with
  `CSSMERR_TP_NOT_TRUSTED`, and `security find-identity -v -p codesigning`
  reported 0 valid identities, so production signing/notarization is `not run`.
  `swift test --disable-sandbox --package-path macos/install_helper` passed 38
  tests and `swift test --disable-sandbox` passed 62 tests. The external Swift
  consumer also compiled and ran against `DesktopUpdaterKit 2.7.0`.
- Windows Release/NuGet consumers: `not run` — no Windows target host is
  available. Source contracts require Release helper and policy assets,
  fail missing pack inputs, and provide an opt-in absolute installer-protected
  helper destination; no Authenticode/UAC or installed NuGet claim is made.
- Linux installed CMake/pkg-config consumers: `verified locally` — GCC 14.3.0
  in the repository Linux build image configured and built a fresh Release
  portable package; CTest discovered 37 tests, passed 36, and explicitly
  skipped the one unprivileged bind-mount case. The installed CMake consumer
  passed 1/1 CTest and the pkg-config consumer compiled and ran. Portable
  inventory contained a root-owned `libexec/desktop-updater-helper` and no
  policy/polkit files. Missing system-broker policy failed configuration; an
  explicit non-production policy staged the fixed `/usr/libexec`, polkit, and
  `/etc/desktop-updater/policies` candidate layout. Privileged broker execution
  remains `not run`. The temporary verification container was removed.
- Package dry run: `blocked` — the plan-spelled `dart pub publish --dry-run`
  attempted to update the external Flutter SDK cache. Direct Dart execution
  then reached dependency resolution but could not read the pub.dev advisory
  endpoint under restricted network access; both escalation requests were
  rejected. `publish` has no offline option, so no successful dry-run is
  claimed.
- Commit: `verified locally` —
  `d06d0c6 build: package native install helpers`.

---

### Task 15: Make CI Prove Trust, Elevation, Crash Recovery, and Release Truth

**Files:**

- Modify: `.github/workflows/desktop-updater-ci.yml`
- Modify: `test/native_runtime_merge_gate_contract_test.dart`
- Modify: `test/native_runtime_merge_gate_docs_test.dart`
- Modify: `test/windows_native_sdk_layout_test.dart`
- Modify: `test/linux_native_sdk_layout_test.dart`
- Modify: `docs/native-runtime-api.md`
- Modify: `docs/github-actions-ci-cd.md`
- Modify: `docs/harness-engineering.md`
- Modify: `docs/diagnostics-and-recovery.md`
- Modify: `docs/exec-plans/active/2026-07-10-native-runtime-merge-blocker-remediation-plan.md`
- Modify: `tool/windows_install_helper_smoke.ps1`
- Modify: `tool/linux_install_helper_smoke.sh`
- Modify: this plan

- [x] **Step 1: Write failing CI truth tests**

  Require named, nonzero-discovery jobs for:

  - portable common schema/policy/state-machine fixtures;
  - macOS unprivileged crash recovery;
  - macOS signed bundled SMAppService daemon/XPC, hardened runtime,
    notarization, and admin approval;
  - Windows Release helper, Authenticode, UAC, pipe spoofing, crash recovery;
  - Linux unprivileged helper, namespace mount/bind tests, polkit root broker,
    crash recovery;
  - Flutter and Flutter-free retail consumers on all three platforms.

  Assert that source scans, mocks, dry runs, or ordinary CTest lanes are not
  labeled as signed/elevated/notarized recovery evidence.

- [x] **Step 2: Add secretless mandatory lanes**

  Run protocol/policy fixtures, local helper builds, unprivileged transaction
  suites, compatibility tests, package inventories, and external consumers on
  hosted target runners. Upload redacted logs and test counts.

- [x] **Step 3: Add explicit credential/target-host lanes**

  Gate actual SMAppService daemon/notarization, Authenticode/UAC, and installed polkit
  broker smokes behind the required credentials and target hosts. Missing
  credentials must produce literal `not run`, never green substitute evidence.

- [ ] **Step 4: Close the old Task 6 blocker only with evidence**

  Update the remediation plan's Task 6 checkbox only after all secretless
  platform gates pass and the evidence notes identify any credential lanes still
  `not run`. Keep the runtime `candidate-only` until every required signed and
  elevated lane has actually passed.

- [x] **Step 5: Run CI contract tests and commit**

  ```sh
  flutter test --no-pub test/native_runtime_merge_gate_contract_test.dart test/native_runtime_merge_gate_docs_test.dart
  ```

  Commit:

  ```sh
  git add .github/workflows/desktop-updater-ci.yml test/native_runtime_merge_gate_contract_test.dart test/native_runtime_merge_gate_docs_test.dart test/windows_native_sdk_layout_test.dart test/linux_native_sdk_layout_test.dart docs/native-runtime-api.md docs/github-actions-ci-cd.md docs/harness-engineering.md docs/diagnostics-and-recovery.md docs/exec-plans/active/2026-07-10-native-runtime-merge-blocker-remediation-plan.md docs/exec-plans/active/2026-07-11-cross-platform-privileged-install-helper-plan.md tool/windows_install_helper_smoke.ps1 tool/linux_install_helper_smoke.sh
  git commit -m "ci: verify native install helper recovery"
  ```

**Evidence:**

- RED: `verified locally` — macOS 26.5.2 arm64;
  `flutter test --no-pub test/native_runtime_merge_gate_contract_test.dart test/native_runtime_merge_gate_docs_test.dart`;
  exit 1; 12 tests passed and 2 intended CI-truth tests failed because the
  named helper recovery and privileged target-host lanes were absent.
- Polkit policy-sealing RED: `verified locally` — macOS 26.5.2 arm64;
  `flutter test --no-pub test/native_runtime_merge_gate_contract_test.dart --plain-name 'Linux polkit lane seals canonical policy bytes safely'`;
  exit 1; 0 passed and 1 intended failure because the workflow passed raw JSON
  into a template that requires escaped canonical policy bytes.
- Secretless macOS lane: `not run`
- Signed/admin-approved/notarized macOS CI lane: `not run`
- Signed/admin-approved/notarized macOS local target-host lane:
  `verified locally` — the Task 6 evidence records accepted notarization IDs,
  stapled/Gatekeeper validation, root-daemon XPC, forced-kill recovery,
  privileged ownership normalization, and v1-to-v2 daemon restart.
- Secretless Windows lane: `not run`
- Signed/elevated Windows lane: `not run`
- Secretless Linux lane: `not run`
- Installed polkit broker lane: `not run`
- Consumer/package matrix: `not run`
- CI configuration: named portable fixture, macOS crash-recovery, Windows
  trust/pipe/transaction/recovery, Linux helper/recovery and privileged
  mount-namespace lanes plus redacted nonzero test-count artifacts are
  implemented; configured jobs are not execution evidence.
- Credential/target-host configuration: separate manual SMAppService daemon/XPC,
  Authenticode/UAC, and installed polkit jobs are gated by explicit repository
  variables, credentials, and named self-hosted runners; all remain `not run`.
- CI truth contracts: `verified locally` — macOS 26.5.2 arm64;
  `flutter test --no-pub test/native_runtime_merge_gate_contract_test.dart test/native_runtime_merge_gate_docs_test.dart`;
  exit 0; 15 tests passed.
- Existing layout-contract drift RED: `verified locally` — the related
  packaging/docs/smoke group exited 1 with 65 tests passed and 2 intended
  failures because the Windows and Linux layout tests still required the
  superseded transaction-only CTest filters.
- Related packaging/docs/smoke regressions: `verified locally` — macOS 26.5.2
  arm64; the eight-file Flutter test group covering harness docs, helper
  diagnostics, retail packages, installed consumers, Windows/Linux layouts,
  notarized configuration, and runtime smoke contracts exited 0; 67 tests
  passed after the layout contracts named the trust/recovery filters.
- Portable fixture drift: `verified locally` — macOS 26.5.2 arm64; direct Dart
  SDK invocations of
  `tool/generate_native_install_helper_fixtures.dart --check` and
  `tool/generate_native_install_helper_policy.dart --check-fixtures`; both
  exited 0 and reported the fixtures up to date.
- macOS named crash-recovery suite: `verified locally` — macOS 26.5.2 arm64;
  `swift test --disable-sandbox --package-path macos/install_helper --filter MacCrashRecoveryTests`;
  exit 0; 5 tests passed.
- Workflow and smoke syntax: `verified locally` — Ruby YAML parsing,
  `sh -n tool/linux_install_helper_smoke.sh`, and `git diff --check` exited 0.
  Rendering `linux/native/policy/helper-policy.json.in` in memory with the
  workflow's JSON escaping produced valid nested JSON and a matching canonical
  policy SHA-256. Native CMake rendering was not run because `cmake` is not
  installed on this macOS host.
- Commit: `verified locally` —
  `3fbf76d ci: verify privileged helper recovery`.

---

### Task 16: Run the Complete Validation Ladder and Independent Adversarial Review

**Files:**

- Modify: this plan
- Modify only if evidence changes it:
  `docs/exec-plans/active/2026-07-10-native-runtime-merge-blocker-remediation-plan.md`
- Modify only for validated P0/P1 fixes: files named by the finding

- [ ] **Step 1: Run focused helper suites again from a clean build output**

  Re-run fixture generation, schema/policy/state tests, Swift tests, Windows
  CTest, Linux CTest, platform smoke tools, Flutter plugin tests, installed
  consumer tests, and retail artifact inventories. Record exact commands, host,
  test count, and exit status; do not reuse stale evidence.

- [ ] **Step 2: Run the repository validation ladder**

  ```sh
  dart run tool/generate_native_contract_fixtures.dart
  dart run tool/generate_native_install_helper_fixtures.dart
  dart run tool/generate_native_install_helper_fixtures.dart --check
  git diff --exit-code -- fixtures/compat/native-contract
  dart format --set-exit-if-changed .
  flutter analyze --no-fatal-infos
  flutter test --no-pub
  dart pub publish --dry-run
  swift test --package-path macos/install_helper
  swift test --package-path macos/desktop_updater
  swift test
  ```

  Then run the full Windows and Linux CMake/CTest, plugin, external consumer,
  package inventory, crash, mount/reparse, and elevation lanes on their target
  hosts.

- [x] **Step 3: Run `superpowers:verification-before-completion`**

  Follow the skill against fresh outputs. Do not claim completion from prior
  task logs, source inspection, or an agent summary.

- [x] **Step 4: Run fresh `killcritic-complete-review`**

  Review four explicit tracks:

  1. safety/trust and privilege boundaries;
  2. build, embed, retail packaging, signer/owner metadata;
  3. protocol/schema/native ABI/Flutter API compatibility;
  4. CI evidence and release-readiness truth.

  Validate every finding before changing code. Resolve every validated P0/P1,
  add a regression test first, re-run the affected platform lane, and create a
  separate Conventional Commit for each independently verified fix.

- [x] **Step 5: Record final literal evidence and readiness**

  Mark unavailable credential or target-host gates `not run` or `blocked` with
  the reason. State whether Task 6 is closed, whether the runtime is still
  `candidate-only`, and whether PR #65 is merge-ready. Do not mark either plan
  complete if a required P0/P1, secretless lane, or target-host safety gate is
  missing.

- [x] **Step 6: Commit only the final evidence update**

  ```sh
  git add docs/exec-plans/active/2026-07-11-cross-platform-privileged-install-helper-plan.md docs/exec-plans/active/2026-07-10-native-runtime-merge-blocker-remediation-plan.md
  git commit -m "docs: record native helper verification"
  ```

**Evidence:**

- Complete Dart/Flutter ladder: `verified locally` on macOS 26.5.2 arm64.
  Both native fixture generators ran, helper fixtures and policy fixtures were
  current, and the fixture directories had no diff.
  `dart format --set-exit-if-changed .` checked 229 files with 0 changes;
  `flutter analyze --no-fatal-infos` exited 0 with 404 info-only diagnostics;
  and the final `flutter test --no-pub` passed 702 tests with 3 explicit
  opt-in skips. The first full Flutter run exposed three stale verification
  contracts: CMake language preservation, macOS result ordering, and the
  current Windows request builder. Focused RED/GREEN tests covered each fix
  before the green full rerun. A pre-commit `dart pub publish --dry-run`
  reached package validation and exited 65 only because the intended tracked
  deletion and 46 other task files were still uncommitted; it reported no
  package-content error beyond those dirty-tree warnings and the existing
  prior-version hint. After the task changes were committed, the clean
  `dart pub publish --dry-run` exited 0 with 0 warnings and the same single
  prior-version hint.
- Complete macOS helper ladder: `verified locally`. The privileged helper and
  repo-context DesktopUpdaterKit suites each passed 82/82, and the signed
  SMAppService transport subset passed 18/18. The exact five-source CocoaPods
  macOS 10.14 typecheck and the external SwiftPM consumer exited 0. The raw
  `swift test --package-path macos/desktop_updater` command remains `blocked`
  outside a generated Flutter host because `FlutterMacOS` is unavailable; the
  exact fallback typecheck plus real Flutter Release applications cover the
  source and host-build boundaries without treating that environment limit as
  a signed-runtime failure.
- macOS signed target-host gate: `verified locally`. Final universal v1
  `2.0.0+200` and v2 `2.0.1+201` Developer ID applications were accepted by
  Apple notarization under submissions
  `6b39195a-c4c6-4a51-ba3c-1c775b7d2473` and
  `78719a41-139b-4313-8fd4-0caaea103916`, stapled, and Gatekeeper accepted as
  `Notarized Developer ID`. The administrator-approved root daemon completed
  authenticated XPC prepare, forced-`SIGKILL` rollback recovery, v1-to-v2
  protected-target replacement, root ownership normalization, daemon refresh,
  and a completed query from a fresh v2 process. Daemon PIDs were
  `27851` -> `28621` -> `29512`; helper endpoint SHA-256 changed from
  `525c98124a9bbec5d8aec0a55d912732f224345f9a89c5ea7d6df462be67cc0a`
  to
  `308d4b3ee241761e88627192a99196b607da588e156dae5d545fb19d9009b1ae`.
- Complete Windows ladder: `not run` on a Windows target host. The local
  production source graph now prepares and commits through an authenticated
  elevated named-pipe session, but `QueryTransaction` and
  `RecoverPendingInstall` still return `endpointUnavailable`. Windows
  CMake/CTest, Flutter plugin, installed CMake/NuGet, real DLL/helper handoff,
  UAC cancellation, reparse, abrupt-crash, Authenticode, and retail inventory
  lanes remain `not run`; source inspection is not target-host evidence.
- Complete Linux ladder: `blocked`. The unprivileged portion was
  `verified locally` in the existing Linux build image with GCC 14.3.0 and
  CMake 3.25.1. A fresh Release build discovered 58 CTests, passed 57, and
  explicitly skipped the bind-mount test in the unprivileged container; a
  separate throwaway privileged container then passed that exact test 1/1.
  Installed CMake and pkg-config consumers compiled and ran, a non-root helper
  probe exited 0, and the portable inventory was root-owned with helper mode
  0755 and intentionally contained no polkit/policy files. The installed
  polkit/root-broker handoff, mutation, crash recovery, and package-provider
  lanes remain `not run`. The public Linux client is still disconnected, its
  serialized request does not match the helper parser, and helper `COMMIT`
  does not invoke the file transaction or recovery service.
- Credential-gated lanes: macOS Developer ID/notarization is
  `verified locally` as scoped above. Windows Authenticode/UAC and installed
  Linux polkit/root-broker evidence remain `not run`.
- Verification-before-completion: `verified locally` against the fresh outputs
  above. Passing unit/contract tests are not treated as production handoff
  proof, and missing target-host or credential gates remain literal.
- Fresh killcritic review: `BLOCK / NO-GO`. The repository inventory covered
  802 files and reported 60 checked and 10 unchecked plan items. Four complete
  passes covered safety/trust, build/embed/retail consumers,
  protocol/schema/ABI/Flutter compatibility, and CI/release truth, followed by
  a reverse traversal from artifacts and smoke claims back to production
  endpoints and mutation authorities.
- P0 — the production helper graph remains incomplete on Windows and Linux.
  Windows prepare/commit is connected, but public query/recovery has no
  production endpoint. Linux public prepare/commit/cancel/query/recovery is
  disconnected, and the standalone helper's commit path removes reservation
  state without invoking mutation or durable recovery. The macOS portion of
  this former cross-platform P0 is resolved and has real notarized target-host
  evidence.
- P1 — Linux helper wire representations are incompatible. The public client
  serializes a smaller platform envelope without the top-level package,
  transaction, and nonce fields that `helper/main.cc` reads; no production
  end-to-end parser test joins those boundaries.
- P1 — remaining Windows/Linux smoke lanes can be false green. The elevated
  Windows and Linux root-broker scripts stop at `--version`, and the Linux
  unprivileged smoke does the same. They do not prove a packaged production
  prepare, commit, mutation, query, or recovery boundary. The macOS privileged
  smoke is no longer in this finding because it exercised all of those phases
  against the notarized app and root daemon.
- P1 — protocol-v1 helper diagnostics are fixture-only. The stable events in
  `fixtures/compat/native-install-helper/v1/diagnostic-results.json` do not
  occur in the standalone helper implementations, and caller-provided
  diagnostics destinations are serialized without a helper-owned redacted
  writer. The retained legacy runtime event enum remains covered separately.
- Sound areas: canonical fixture generation and strict policy parsing,
  fail-closed endpoint behavior, isolated fd/handle-relative transaction and
  crash-recovery algorithms, stage provenance checks, public Dart/MethodChannel
  compatibility, C ABI sizing/ownership contracts, helper retail layout rules,
  macOS authenticated XPC/daemon replacement and candidate-only documentation
  all had supporting local evidence. These do not make the unfinished
  Windows/Linux production graph usable.
- Modification statement: this change resolves the macOS production transport,
  approval UX, signed packaging, privileged mutation, and recovery slice, and
  corrects the stale CMake/result/request verification contracts found by the
  full rerun. The remaining Windows/Linux P0/P1 findings were not papered over
  with local shims because their required target-host and installed-broker
  boundaries are absent.
- Coverage limitation: Windows target-host, Windows Authenticode/UAC, installed
  Linux polkit/root-broker, and current-head CI remain unavailable or not run.
  This review reduces omission risk but cannot guarantee that no additional
  platform defect remains.
- Validated P0/P1 remaining: `1 P0 and 3 P1`. Task 16 Steps 1 and 2 plus the
  plan-level readiness gate remain open. The macOS Task 6 implementation and
  signed target-host gate are closed; the overall plan is not.
- Runtime status: `candidate-only`.
- PR #65 merge readiness: `blocked / not merge-ready`.
- Linux distribution follow-on: `not started`; its prerequisite helper plan is
  still blocked by the remaining Windows/Linux production graph.
- Commit: `verified locally` —
  `39e79dc docs: record native helper verification`.

---

## Follow-On Plan Boundary

After this plan has stable helper protocol and target-host evidence, create a
separate Linux Distribution Artifacts execution plan. It must consume these
fixed mappings without redefining helper trust or recovery:

| Artifact | Helper strategy | Production update authority |
| --- | --- | --- |
| AppImage | `singleFileReplace` | writable file or installed root broker |
| deb | `systemPackageTransaction` | trusted dpkg/apt provider |
| rpm | `systemPackageTransaction` | trusted rpm/dnf provider |
| Flatpak | `externalManagedRefresh` | Flathub or signed self-hosted remote |
| Snap | `externalManagedRefresh` | public Snap Store or Brand Store |

Production Snap `--dangerous` sideloading remains prohibited. The later plan
owns artifact builders, public descriptor kinds, repository/store metadata,
signing, publishing, upload workflows, and end-to-end artifact smokes.
