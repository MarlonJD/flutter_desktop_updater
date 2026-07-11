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

- [ ] **Step 1: Write the failing contract test**

  Assert that the schema and all five fixture files exist; the generator is
  idempotent; every valid request validates; every invalid request names a
  stable failure; canonical JSON sorts object keys and rejects duplicate keys;
  and every state transition is one of the normative transitions.

  Run:

  ```sh
  flutter test --no-pub test/native_install_helper_contract_test.dart
  ```

  Expected RED: missing schema, fixtures, generator, and protocol document.

- [ ] **Step 2: Implement the schema and deterministic generator**

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

- [ ] **Step 3: Document the normative protocol and compatibility rules**

  Specify exact state names, result codes, diagnostic event names, redaction,
  protocol negotiation, timeout behavior, and the rule that paths are hints,
  never mutation authority. Link the approved design spec and state explicitly
  that artifact production is out of scope.

- [ ] **Step 4: Run focused verification and commit**

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

- RED: `not run`
- Fixture idempotence and Dart contract: `not run`
- Commit: `not run`

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

- [ ] **Step 1: Write failing Dart and C++ policy tests**

  Cover valid portable and privileged policies plus wrong package ID, unknown
  strategy, root filesystem authorization, relative install root, caller-added
  key, policy rollback, invalid signer, duplicate key ID, protocol downgrade,
  and a portable policy that requests elevation.

  Run the Dart test first:

  ```sh
  flutter test --no-pub test/native_install_helper_policy_test.dart
  ```

  Expected RED: schema, generator, fixtures, and C++ parser are absent.

- [ ] **Step 2: Implement strict common parsing without filesystem mutation**

  `install_helper_policy.cc` may parse and validate policy bytes and expose
  immutable values. It must not open, copy, delete, rename, elevate, or recover
  filesystem objects. Reject unknown fields in security-authority objects and
  canonicalize the policy before computing its digest.

- [ ] **Step 3: Implement build-time policy generation**

  The tool accepts an application-owned configuration and writes a canonical
  policy plus digest. It refuses wildcard signers, filesystem roots, empty
  release keys, `externalManagedRefresh` without a named provider, and elevated
  capability in a portable policy. Never write private keys into policy output.

- [ ] **Step 4: Run focused verification and commit**

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

- RED: `not run`
- Dart policy tests: `not run`
- Linux C++ policy tests: `not run`
- Windows C++ policy tests: `not run`
- Commit: `not run`

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

- [ ] **Step 1: Write failing state-machine tests**

  Generate a case for helper death before and after every durable transition,
  repeated recovery, live-owner recovery rejection, torn/short writes, disk
  full, directory flush failure, corrupt/unknown journal, injected sibling
  names, owner generation mismatch, and ambiguous target/backup state.

  ```sh
  flutter test --no-pub test/native_install_helper_state_machine_test.dart
  ```

  Expected RED: no executable reference model or crash matrix exists.

- [ ] **Step 2: Implement the pure reference model**

  The common implementation accepts observations and returns a decision only:

  ```cpp
  RecoveryDecision DecideRecovery(const JournalV1&, const ObservedState&);
  TransitionResult ValidateTransition(JournalState from, JournalState to);
  ```

  It must never invoke filesystem or platform APIs. Its only purpose is to make
  Swift, Windows, and Linux consume the same decisions and adversarial fixtures.

- [ ] **Step 3: Prove deterministic, idempotent recovery decisions**

  Require each fixture to converge to exactly one of verified old target,
  verified new target, or non-destructive `manualActionRequired`. A corrupt or
  ambiguous journal must never authorize cleanup.

- [ ] **Step 4: Run focused verification and commit**

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

- RED: `not run`
- Dart state-machine tests: `not run`
- Linux reference-model tests: `not run`
- Windows reference-model tests: `not run`
- Commit: `not run`

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

- [ ] **Step 1: Write failing layout and compatibility tests**

  Assert that SwiftPM still exposes `DesktopUpdaterKit` at macOS 10.15+, the
  helper executable is compiled for macOS 10.14, the helper is a distinct
  product embedded for one-shot use at
  `Contents/Helpers/DesktopUpdaterInstallHelper`, the identical signed build is
  staged for SMJobBless at
  `Contents/Library/LaunchServices/<helper-service-id>`, and the
  podspec source allowlist remains byte-for-byte the exact five entries in the
  global constraints.

  ```sh
  flutter test --no-pub test/macos_native_helper_layout_test.dart test/macos_cocoapods_source_layout_test.dart test/macos_swift_package_test.dart
  ```

  Expected RED: helper product and embed contract are absent.

- [ ] **Step 2: Add a no-mutation helper executable target**

  A separate Swift package with `.macOS(.v10_14)` builds the helper; neither
  repository `DesktopUpdaterKit` package changes its macOS 10.15 floor. The
  initial executable supports only `--version` and a test-only stdio
  protocol parse mode. It must not schedule, copy, delete, rename, bless, or
  elevate. Keep macOS 10.14-compatible sources separate from
  `Sources/DesktopUpdaterKit/Runtime/`.

- [ ] **Step 3: Add deterministic helper discovery**

  `EmbeddedHelperLocator` resolves only the signed nested helper at the fixed
  bundle-relative location. Do not search `PATH`, temporary directories, the
  source tree, or caller-provided paths.

- [ ] **Step 4: Run macOS build checks and commit**

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

- RED: `not run`
- SwiftPM macOS 10.15+: `not run`
- Helper macOS 10.14 compile: `not run`
- Exact CocoaPods allowlist: `not run`
- Commit: `not run`

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

- [ ] **Step 1: Write failing authentication and reservation tests**

  Cover wrong Team ID, bundle ID, designated requirement, helper digest,
  policy digest, protocol version, transaction nonce, stale audit token,
  replaced nested helper, caller exit before commit, commit timeout, duplicate
  commit, cancellation after commit, and two callers racing for one target.

  ```sh
  swift test --package-path macos/install_helper --filter HelperServerTests
  swift test --package-path macos/desktop_updater --filter 'MacHelperAuthenticationTests|MacInstallReservationTests'
  ```

  Expected RED: authentication and reservation APIs do not exist.

- [ ] **Step 2: Implement strict protocol and sealed policy loading**

  Bind the app, helper, policy, transaction, and request digest. Verify static
  code and audit-token identity with Security framework APIs. The application
  must not supply release roots, designated requirements, allowed install roots,
  or helper identity at runtime.

- [ ] **Step 3: Implement no-mutation reservation ownership**

  `prepareInstall` authenticates, proves target and stage, obtains the exclusive
  target lock, writes and flushes the initial journal, installs an exact caller
  process monitor, then returns `readyToken`. `cancelReservation` removes only a
  still-`prepared` transaction after lock, token, journal digest, and derived
  sibling validation. No target mutation is allowed in this task.

- [ ] **Step 4: Run focused tests and commit**

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

- RED: `not run`
- Swift unit/integration tests: `not run`
- Actual signed audit-token peer test: `not run`
- Commit: `not run`

---

### Task 6: Implement macOS Swap Recovery and SMJobBless Elevation

**Files:**

- Create: `macos/install_helper/Sources/DesktopUpdaterInstallHelper/TransactionJournal.swift`
- Create: `macos/install_helper/Sources/DesktopUpdaterInstallHelper/MacFileTransaction.swift`
- Create: `macos/install_helper/Sources/DesktopUpdaterInstallHelper/MacRecoveryService.swift`
- Create: `macos/install_helper/Sources/DesktopUpdaterInstallHelper/MacPrivilegeService.swift`
- Create: `macos/install_helper/Sources/DesktopUpdaterInstallHelper/MacRelaunchService.swift`
- Create: `macos/install_helper/Configuration/Helper-Info.plist`
- Create: `macos/install_helper/Configuration/Helper-Launchd.plist`
- Create: `macos/install_helper/Configuration/App-SMPrivilegedExecutables.plist`
- Create: `macos/install_helper/Tests/DesktopUpdaterInstallHelperTests/MacFileTransactionTests.swift`
- Create: `macos/install_helper/Tests/DesktopUpdaterInstallHelperTests/MacCrashRecoveryTests.swift`
- Create: `macos/install_helper/Tests/DesktopUpdaterInstallHelperTests/MacPrivilegeServiceTests.swift`
- Create: `macos/desktop_updater/Tests/DesktopUpdaterKitTests/MacInstallTransactionTests.swift`
- Create: `macos/desktop_updater/Tests/DesktopUpdaterKitTests/MacInstallCrashRecoveryTests.swift`
- Create: `macos/desktop_updater/Tests/DesktopUpdaterKitTests/MacPrivilegedHelperTests.swift`
- Create: `tool/macos_install_helper_smoke.dart`
- Modify: `.github/workflows/desktop-updater-ci.yml`

- [ ] **Step 1: Write failing mutation and crash tests**

  Inject failure before and after every journal flush and rename. Cover symlink
  replacement, mount crossing, target-parent replacement, stage mutation,
  invalid backup identity, live-owner recovery, disk full, torn journal,
  directory fsync failure, repeated recovery, wrong Team ID, invalid blessing,
  XPC spoofing, unsigned nested helper, and authorization cancellation.

- [ ] **Step 2: Implement unprivileged handle-bound swap**

  Open and retain the canonical target parent and stage objects before
  reservation. Derive prepared, backup, journal, and lock names from the target
  name and transaction UUID. Transition durably through `prepared`,
  `backupCreated`, `targetActivated`, and `completed`; verify bundle/package ID,
  code signature, provenance, and executable identity before deleting backup or
  relaunching.

- [ ] **Step 3: Implement privileged SMJobBless/XPC mode**

  Bless only the fixed package-unique helper with reciprocal designated
  requirements. Generate `SMAuthorizedClients`, `SMPrivilegedExecutables`, and
  the launchd Mach-service label from the sealed application policy; fail the
  build if they disagree. The blessed service reloads its sealed policy,
  authenticates the audit token, and performs the same transaction. Writable
  targets use the signed one-shot helper under `Contents/Helpers`; the
  identically built and signed SMJobBless payload is embedded under
  `Contents/Library/LaunchServices`. Protected targets never run a
  user-writable helper as root.

- [ ] **Step 4: Prove recovery and elevation on a macOS target host**

  ```sh
  swift test --package-path macos/install_helper --filter 'MacFileTransactionTests|MacCrashRecoveryTests|MacPrivilegeServiceTests'
  swift test --package-path macos/desktop_updater --filter 'MacInstallTransactionTests|MacInstallCrashRecoveryTests|MacPrivilegedHelperTests'
  dart run tool/macos_install_helper_smoke.dart --mode unprivileged
  dart run tool/macos_install_helper_smoke.dart --mode privileged
  ```

  The privileged lane must exercise an actual blessed helper. Mocks may verify
  parser behavior but cannot satisfy the target-host gate.

- [ ] **Step 5: Run the macOS suite and commit**

  ```sh
  swift test --package-path macos/install_helper
  swift test --package-path macos/desktop_updater
  swift test
  ```

  Commit:

  ```sh
  git add macos/install_helper/Sources/DesktopUpdaterInstallHelper/TransactionJournal.swift macos/install_helper/Sources/DesktopUpdaterInstallHelper/MacFileTransaction.swift macos/install_helper/Sources/DesktopUpdaterInstallHelper/MacRecoveryService.swift macos/install_helper/Sources/DesktopUpdaterInstallHelper/MacPrivilegeService.swift macos/install_helper/Sources/DesktopUpdaterInstallHelper/MacRelaunchService.swift macos/install_helper/Configuration/Helper-Info.plist macos/install_helper/Configuration/Helper-Launchd.plist macos/install_helper/Configuration/App-SMPrivilegedExecutables.plist macos/install_helper/Tests/DesktopUpdaterInstallHelperTests/MacFileTransactionTests.swift macos/install_helper/Tests/DesktopUpdaterInstallHelperTests/MacCrashRecoveryTests.swift macos/install_helper/Tests/DesktopUpdaterInstallHelperTests/MacPrivilegeServiceTests.swift macos/desktop_updater/Tests/DesktopUpdaterKitTests/MacInstallTransactionTests.swift macos/desktop_updater/Tests/DesktopUpdaterKitTests/MacInstallCrashRecoveryTests.swift macos/desktop_updater/Tests/DesktopUpdaterKitTests/MacPrivilegedHelperTests.swift tool/macos_install_helper_smoke.dart .github/workflows/desktop-updater-ci.yml
  git commit -m "feat: recover macos install transactions"
  ```

**Evidence:**

- RED: `not run`
- Unprivileged crash/recovery tests: `not run`
- Signed SMJobBless/XPC test: `not run`
- Hardened runtime/notarized nested-helper test: `not run`
- Commit: `not run`

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

- [ ] **Step 1: Write failing build, trust, IPC, and reservation tests**

  Require a Release `desktop_updater_install_helper.exe`, fixed installed
  location, Authenticode verification, exact helper digest, protected policy,
  wide-character paths, nonce-named pipe, explicit caller/helper/SYSTEM DACL,
  peer PID/token validation, retained caller process handle, target lock, and
  durable initial journal before `readyToken`.

  Cover wrong signer, unsigned helper, user-writable elevated helper,
  replacement after verification, pipe spoof, wrong peer token, nonce reuse,
  UAC cancellation, timeout, and portable elevation rejection.

- [ ] **Step 2: Build the no-mutation helper and package contract**

  Add an executable target linked to `Wintrust`, `Crypt32`, `Advapi32`, and the
  required shell/security libraries. Install it beside the runtime artifacts,
  but keep production routing disabled until Task 8 is green.

- [ ] **Step 3: Implement authentication, named-pipe IPC, and UAC launch**

  Use `ShellExecuteExW(..., "runas", ...)` only for an installer-protected,
  signed helper. Pass only the pipe locator and nonce on the command line; send
  the canonical request over the authenticated pipe. Do not use PowerShell or
  a temporary executable.

- [ ] **Step 4: Implement no-mutation reservation and cancellation**

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

- RED: `not run`
- Windows Release build/tests: `not run`
- Actual Authenticode/UAC test: `not run`
- Commit: `not run`

---

### Task 8: Implement Handle-Relative Windows Transactions and Recovery

**Files:**

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

- [ ] **Step 1: Write failing transaction and recovery tests**

  Cover junction/reparse replacement at every component, alternate data
  streams, target-parent replacement, hard links where applicable, stage
  mutation, sharing violations, two-helper races, abrupt helper/caller death at
  every state, disk full, short/torn journal writes, `FlushFileBuffers` failure,
  invalid backup identity, recovery idempotence, and UTF-8/non-BMP install paths.

- [ ] **Step 2: Implement handle-relative swap and durable journal**

  Use wide Win32 APIs, open reparse-point-safe handles, compare volume/file
  identities, retain the exclusive lock, atomically replace the journal, flush
  the file and containing directory where supported, and rename only derived
  siblings under the validated parent. Never reconstruct authority from a raw
  absolute path after reservation.

- [ ] **Step 3: Implement fail-closed recovery and verified relaunch**

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
  git add windows/native/src/helper windows/native/test/helper tool/windows_install_helper_smoke.ps1 .github/workflows/desktop-updater-ci.yml
  git commit -m "feat: recover windows install transactions"
  ```

**Evidence:**

- RED: `not run`
- Windows crash/recovery suite: `not run`
- Signed elevated UAC smoke: `not run`
- Commit: `not run`

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

- [ ] **Step 1: Write failing layout, ownership, IPC, and reservation tests**

  Require install output at `/usr/libexec/desktop-updater-helper`, a polkit
  action, a root-owned `/etc/desktop-updater/policies/<package-id>.json`, strict
  non-writable owner/mode checks, Unix socket peer authentication with
  `SO_PEERCRED`, nonce binding, helper inode/digest checks, exact package policy,
  pidfd caller monitoring with PID/start-time fallback, target lock, and durable
  initial journal.

  Cover fake broker, caller-writable broker/policy, peer mismatch, socket path
  replacement, nonce replay, polkit cancellation, root-owned AppImage without a
  broker, and any attempt to pass a target path or command through `pkexec`.

- [ ] **Step 2: Build unprivileged and broker modes from one codebase**

  The helper selects its mode from a fixed invocation contract, not a caller
  command. The installed broker re-opens and validates itself and its policy
  after elevation. User-writable bundle/AppImage targets use one-shot mode;
  root-owned targets require the installed broker.

- [ ] **Step 3: Implement authenticated socket reservation**

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

- RED: `not run`
- Linux helper/broker tests: `not run`
- Actual polkit root-broker test: `not run`
- Commit: `not run`

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
- Modify: `.github/workflows/desktop-updater-ci.yml`

- [ ] **Step 1: Write failing namespace, mount, crash, and recovery tests**

  Run tests in user/mount namespaces where available. Cover symlink, bind mount,
  mount point, device change, target-parent replacement, stage replacement,
  permission/ownership changes after reservation, two-helper races, helper and
  caller death at every state, disk full, short/torn journal writes, file and
  directory fsync failure, corrupt journal, invalid backup, live-owner recovery,
  and repeated recovery.

- [ ] **Step 2: Implement fd-relative durable swap**

  Use pinned descriptors plus `openat`, `fstatat`, `O_NOFOLLOW`, `renameat` or
  `renameat2`, `unlinkat`, device/inode comparisons, `/proc/self/mountinfo`
  checks, and file/directory fsync. Every destructive operation is relative to
  a validated descriptor and strictly derived name.

- [ ] **Step 3: Implement fail-closed recovery and relaunch**

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
  git add linux/native/src/helper linux/native/test/helper tool/linux_install_helper_smoke.sh .github/workflows/desktop-updater-ci.yml
  git commit -m "feat: recover linux install transactions"
  ```

**Evidence:**

- RED: `not run`
- Namespace/mount crash suite: `not run`
- Actual polkit root-broker smoke: `not run`
- Commit: `not run`

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
- Create: `windows/native/test/helper/windows_install_strategy_test.cpp`
- Create: `linux/native/test/helper/linux_install_strategy_test.cc`
- Create: `test/linux_helper_strategy_scope_test.dart`

- [ ] **Step 1: Write failing strategy capability tests**

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

- [ ] **Step 2: Implement provider interfaces and bounded execution**

  File strategies call only the platform transaction implementations from Tasks
  6, 8, and 10. Installer/package-manager strategies use fixed argument
  templates derived from sealed policy and verified descriptors. They capture a
  provider transaction identity and query real provider state after interruption
  rather than inventing file rollback.

- [ ] **Step 3: Keep packaging out of scope with executable drift tests**

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
  git add macos/install_helper/Sources/DesktopUpdaterInstallHelper/InstallStrategy.swift macos/install_helper/Sources/DesktopUpdaterInstallHelper/VerifiedInstallerHandoff.swift macos/desktop_updater/Tests/DesktopUpdaterKitTests/MacInstallStrategyTests.swift windows/native/src/helper/install_strategy.h windows/native/src/helper/install_strategy.cpp windows/native/src/helper/verified_installer_handoff.cpp windows/native/test/helper/windows_install_strategy_test.cpp linux/native/src/helper/install_strategy.h linux/native/src/helper/install_strategy.cc linux/native/src/helper/single_file_replace.cc linux/native/src/helper/system_package_transaction.cc linux/native/src/helper/external_managed_refresh.cc linux/native/test/helper/linux_install_strategy_test.cc test/linux_helper_strategy_scope_test.dart
  git commit -m "feat: add native install strategy providers"
  ```

**Evidence:**

- RED: `not run`
- macOS strategy tests: `not run`
- Windows strategy tests: `not run`
- Linux strategy tests: `not run`
- Scope drift test: `not run`
- Commit: `not run`

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

- [ ] **Step 1: Write failing ABI/API and external-consumer tests**

  Require Swift source compatibility, C ABI version/`struct_size` forward
  compatibility, .NET safe handles and deterministic disposal, Linux installed
  CMake/pkg-config consumption, explicit status/result enums, and startup
  `queryTransaction`/`recoverPendingInstall` examples. Tests must consume
  installed/package artifacts rather than source-tree relative libraries.

- [ ] **Step 2: Implement thin platform client APIs**

  Clients serialize the common request, authenticate the endpoint, validate the
  response digest/identity, and expose native result detail. They do not own the
  authoritative journal or recovery decision. Dispose/cancel abandoned
  reservations safely.

- [ ] **Step 3: Update Flutter-free examples and docs**

  Demonstrate Swift, Windows C++, .NET, and Linux C++ startup recovery and
  install handoff. State which helper/policy artifacts must be packaged and how
  elevated installation is provisioned on each platform.

- [ ] **Step 4: Run SDK and consumer checks and commit**

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

- RED: `not run`
- Swift external consumer: `not run`
- Windows C++ consumer: `not run`
- Isolated NuGet/.NET consumer: `not run`
- Linux CMake/pkg-config consumer: `not run`
- Commit: `not run`

---

### Task 13: Route Flutter Adapters to Native Clients and Remove Script Fallbacks

**Files:**

- Modify: `macos/desktop_updater/Sources/desktop_updater/DesktopUpdaterPlugin.swift`
- Modify: `windows/desktop_updater_plugin.cpp`
- Modify: `linux/desktop_updater_plugin.cc`
- Modify: `macos/desktop_updater/Sources/DesktopUpdaterKit/MacInstallHelper.swift`
- Modify: `windows/native/src/desktop_updater_native.cpp`
- Modify: `linux/native/src/desktop_updater_native.cc`
- Modify: `lib/desktop_updater_method_channel.dart`
- Modify: `lib/desktop_updater_platform_interface.dart`
- Modify: `lib/src/core/update_recovery.dart`
- Modify: `test/compat/flutter_220_channel_controller_contract_test.dart`
- Modify: `test/compat/flutter_220_public_api_test.dart`
- Modify: `test/desktop_updater_method_channel_test.dart`
- Modify: `test/native_helper_script_test.dart`
- Modify: `test/native_helper_events_220_contract_test.dart`
- Modify: `test/update_recovery_test.dart`
- Modify: `windows/test/desktop_updater_plugin_test.cpp`
- Modify: `linux/test/desktop_updater_plugin_test.cc`
- Modify: `macos/desktop_updater/Tests/desktop_updaterTests/DesktopUpdaterSwiftPMTests.swift`

- [ ] **Step 1: Write failing compatibility and no-script tests**

  Snapshot the released Dart signatures, MethodChannel name
  `desktop_updater`, existing methods including `restartApp` and
  `installUpdate`, argument names, subclass dispatch, and compatible error
  codes. Assert that production source contains no generated `.command`, `.sh`,
  PowerShell, `/bin/sh`, `powershell.exe`, `sudo`, or fallback mutation path.

- [ ] **Step 2: Route each plugin through its native SDK client**

  Translate the existing channel arguments to native requests. Return handoff
  success only after a validated reservation exists and commit has been
  accepted. Terminate the app only after that success. Map native detailed
  results into the existing compatible Flutter shapes and redacted diagnostics.

- [ ] **Step 3: Keep Dart recovery as optional UX evidence**

  `UpdateRecoveryStore` may display pending state but cannot decide rollback or
  authorize mutation. Startup recovery queries the native helper status and
  preserves behavior when no store is configured.

- [ ] **Step 4: Delete script generation only after platform routes are green**

  Remove the old macOS shell, Windows PowerShell, and Linux shell generator
  implementations. Do not leave a hidden compatibility fallback. A missing or
  untrusted helper returns a pre-mutation failure.

- [ ] **Step 5: Run focused compatibility tests and commit**

  ```sh
  flutter test --no-pub test/compat/flutter_220_channel_controller_contract_test.dart test/compat/flutter_220_public_api_test.dart test/desktop_updater_method_channel_test.dart test/native_helper_script_test.dart test/native_helper_events_220_contract_test.dart test/update_recovery_test.dart
  swift test --package-path macos/desktop_updater
  ```

  Run Windows and Linux plugin tests on their hosts.

  Commit:

  ```sh
  git add macos/desktop_updater/Sources/desktop_updater/DesktopUpdaterPlugin.swift macos/desktop_updater/Sources/DesktopUpdaterKit/MacInstallHelper.swift windows/desktop_updater_plugin.cpp windows/native/src/desktop_updater_native.cpp linux/desktop_updater_plugin.cc linux/native/src/desktop_updater_native.cc lib/desktop_updater_method_channel.dart lib/desktop_updater_platform_interface.dart lib/src/core/update_recovery.dart test/compat/flutter_220_channel_controller_contract_test.dart test/compat/flutter_220_public_api_test.dart test/desktop_updater_method_channel_test.dart test/native_helper_script_test.dart test/native_helper_events_220_contract_test.dart test/update_recovery_test.dart windows/test/desktop_updater_plugin_test.cpp linux/test/desktop_updater_plugin_test.cc macos/desktop_updater/Tests/desktop_updaterTests/DesktopUpdaterSwiftPMTests.swift
  git commit -m "refactor: route flutter installs through native helpers"
  ```

**Evidence:**

- RED: `not run`
- Flutter API/MethodChannel compatibility: `not run`
- No-script/no-fallback scan: `not run`
- macOS Flutter plugin tests: `not run`
- Windows Flutter plugin tests: `not run`
- Linux Flutter plugin tests: `not run`
- Commit: `not run`

---

### Task 14: Package Helpers in Flutter and Native Distribution Artifacts

**Files:**

- Modify: `macos/desktop_updater/Package.swift`
- Modify: `macos/desktop_updater.podspec`
- Create: `macos/install_helper/embed_install_helper.sh`
- Create: `macos/install_helper/verify_install_helper_layout.sh`
- Modify: `example/macos/Runner.xcodeproj/project.pbxproj`
- Modify: `windows/CMakeLists.txt`
- Modify: `windows/native/CMakeLists.txt`
- Modify: `windows/native/dotnet/DesktopUpdater.Native/DesktopUpdater.Native.csproj`
- Modify: `windows/native/dotnet/DesktopUpdater.Native/buildTransitive/DesktopUpdater.Native.targets`
- Modify: `linux/CMakeLists.txt`
- Modify: `linux/native/CMakeLists.txt`
- Modify: `test/macos_distribution_artifacts_test.dart`
- Modify: `test/windows_native_sdk_layout_test.dart`
- Modify: `test/linux_native_sdk_layout_test.dart`
- Modify: `test/native_package_retail_contract_test.dart`
- Modify: `test/native_sdk_consumer_package_test.dart`
- Modify: `docs/native-sdk.md`
- Modify: `docs/windows-linux-production-release.md`

- [ ] **Step 1: Write failing retail-layout tests**

  Require Release packages and Flutter host builds to contain the expected
  helper and policy metadata:

  - macOS one-shot helper at `Contents/Helpers` and the same signed SMJobBless
    payload at `Contents/Library/LaunchServices`, both signed before the outer
    app, with reciprocal requirement plists matching the sealed policy;
  - Windows helper beside runtime DLLs/NuGet runtime asset and installed in a
    protected location for elevated use;
  - Linux helper/broker, polkit action, and policy templates installed to their
    fixed prefixes, with portable packaging limited to unprivileged mode.

  Reassert the exact CocoaPods five-source allowlist and `DesktopUpdaterKit`
  module/product name.

- [ ] **Step 2: Implement build/embed/install rules**

  Avoid source-tree shortcuts and Debug artifacts in Release packages. The
  CocoaPods and SwiftPM integration invokes the dedicated helper build/embed
  tooling without adding helper sources to the pod source allowlist. It builds
  the consumer-specific sealed policy and reciprocal SMJobBless requirements,
  embeds both required locations, signs nested code before the app, and fails
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
  git add macos/desktop_updater/Package.swift macos/desktop_updater.podspec macos/install_helper/embed_install_helper.sh macos/install_helper/verify_install_helper_layout.sh example/macos/Runner.xcodeproj/project.pbxproj windows/CMakeLists.txt windows/native/CMakeLists.txt windows/native/dotnet/DesktopUpdater.Native/DesktopUpdater.Native.csproj windows/native/dotnet/DesktopUpdater.Native/buildTransitive/DesktopUpdater.Native.targets linux/CMakeLists.txt linux/native/CMakeLists.txt test/macos_distribution_artifacts_test.dart test/windows_native_sdk_layout_test.dart test/linux_native_sdk_layout_test.dart test/native_package_retail_contract_test.dart test/native_sdk_consumer_package_test.dart docs/native-sdk.md docs/windows-linux-production-release.md
  git commit -m "build: package native install helpers"
  ```

**Evidence:**

- RED: `not run`
- macOS CocoaPods 10.14 Flutter host: `not run`
- macOS SwiftPM 10.15+ Flutter/native hosts: `not run`
- Windows Release/NuGet consumers: `not run`
- Linux installed CMake/pkg-config consumers: `not run`
- Package dry run: `not run`
- Commit: `not run`

---

### Task 15: Make CI Prove Trust, Elevation, Crash Recovery, and Release Truth

**Files:**

- Modify: `.github/workflows/desktop-updater-ci.yml`
- Modify: `test/native_runtime_merge_gate_contract_test.dart`
- Modify: `test/native_runtime_merge_gate_docs_test.dart`
- Modify: `docs/github-actions-ci-cd.md`
- Modify: `docs/harness-engineering.md`
- Modify: `docs/diagnostics-and-recovery.md`
- Modify: `docs/exec-plans/active/2026-07-10-native-runtime-merge-blocker-remediation-plan.md`
- Modify: this plan

- [ ] **Step 1: Write failing CI truth tests**

  Require named, nonzero-discovery jobs for:

  - portable common schema/policy/state-machine fixtures;
  - macOS unprivileged crash recovery;
  - macOS signed nested helper, SMJobBless/XPC, hardened runtime, notarization;
  - Windows Release helper, Authenticode, UAC, pipe spoofing, crash recovery;
  - Linux unprivileged helper, namespace mount/bind tests, polkit root broker,
    crash recovery;
  - Flutter and Flutter-free retail consumers on all three platforms.

  Assert that source scans, mocks, dry runs, or ordinary CTest lanes are not
  labeled as signed/elevated/notarized recovery evidence.

- [ ] **Step 2: Add secretless mandatory lanes**

  Run protocol/policy fixtures, local helper builds, unprivileged transaction
  suites, compatibility tests, package inventories, and external consumers on
  hosted target runners. Upload redacted logs and test counts.

- [ ] **Step 3: Add explicit credential/target-host lanes**

  Gate actual SMJobBless/notarization, Authenticode/UAC, and installed polkit
  broker smokes behind the required credentials and target hosts. Missing
  credentials must produce literal `not run`, never green substitute evidence.

- [ ] **Step 4: Close the old Task 6 blocker only with evidence**

  Update the remediation plan's Task 6 checkbox only after all secretless
  platform gates pass and the evidence notes identify any credential lanes still
  `not run`. Keep the runtime `candidate-only` until every required signed and
  elevated lane has actually passed.

- [ ] **Step 5: Run CI contract tests and commit**

  ```sh
  flutter test --no-pub test/native_runtime_merge_gate_contract_test.dart test/native_runtime_merge_gate_docs_test.dart
  ```

  Commit:

  ```sh
  git add .github/workflows/desktop-updater-ci.yml test/native_runtime_merge_gate_contract_test.dart test/native_runtime_merge_gate_docs_test.dart docs/github-actions-ci-cd.md docs/harness-engineering.md docs/diagnostics-and-recovery.md docs/exec-plans/active/2026-07-10-native-runtime-merge-blocker-remediation-plan.md docs/exec-plans/active/2026-07-11-cross-platform-privileged-install-helper-plan.md
  git commit -m "ci: verify native install helper recovery"
  ```

**Evidence:**

- RED: `not run`
- Secretless macOS lane: `not run`
- Signed/blessed/notarized macOS lane: `not run`
- Secretless Windows lane: `not run`
- Signed/elevated Windows lane: `not run`
- Secretless Linux lane: `not run`
- Installed polkit broker lane: `not run`
- Consumer/package matrix: `not run`
- Commit: `not run`

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

- [ ] **Step 3: Run `superpowers:verification-before-completion`**

  Follow the skill against fresh outputs. Do not claim completion from prior
  task logs, source inspection, or an agent summary.

- [ ] **Step 4: Run fresh `killcritic-complete-review`**

  Review four explicit tracks:

  1. safety/trust and privilege boundaries;
  2. build, embed, retail packaging, signer/owner metadata;
  3. protocol/schema/native ABI/Flutter API compatibility;
  4. CI evidence and release-readiness truth.

  Validate every finding before changing code. Resolve every validated P0/P1,
  add a regression test first, re-run the affected platform lane, and create a
  separate Conventional Commit for each independently verified fix.

- [ ] **Step 5: Record final literal evidence and readiness**

  Mark unavailable credential or target-host gates `not run` or `blocked` with
  the reason. State whether Task 6 is closed, whether the runtime is still
  `candidate-only`, and whether PR #65 is merge-ready. Do not mark either plan
  complete if a required P0/P1, secretless lane, or target-host safety gate is
  missing.

- [ ] **Step 6: Commit only the final evidence update**

  ```sh
  git add docs/exec-plans/active/2026-07-11-cross-platform-privileged-install-helper-plan.md docs/exec-plans/active/2026-07-10-native-runtime-merge-blocker-remediation-plan.md
  git commit -m "docs: record native helper verification"
  ```

**Evidence:**

- Complete Dart/Flutter ladder: `not run`
- Complete macOS ladder: `not run`
- Complete Windows ladder: `not run`
- Complete Linux ladder: `not run`
- Credential-gated lanes: `not run`
- Verification-before-completion: `not run`
- Fresh killcritic review: `not run`
- Validated P0/P1 remaining: `not run`
- Runtime status: `candidate-only`
- PR #65 merge readiness: `blocked`
- Commit: `not run`

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
