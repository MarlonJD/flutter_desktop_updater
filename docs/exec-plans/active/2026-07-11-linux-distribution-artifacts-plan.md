# Linux Distribution Artifacts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> `superpowers:subagent-driven-development` (recommended) or
> `superpowers:executing-plans` to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add production-grade AppImage, deb, rpm, Flatpak, and Snap build,
signing, publication, validation, and update-channel support while reusing the
native helper trust and recovery system instead of creating package-specific
privileged mutation paths.

**Architecture:** Extend schema-v3 release metadata as a tagged, additive Linux
distribution contract. Direct AppImage replacement uses the helper's
`singleFileReplace`; deb/rpm updates use `systemPackageTransaction`; Flatpak and
Snap use `externalManagedRefresh` against signed repositories or stores. Build
each artifact through a focused Dart packager, retain one common publish
orchestrator and manifest, and require real Linux target-host smoke evidence for
every production channel.

**Tech Stack:** Dart/Flutter, JSON schema-v3 fixtures, C++17 native runtime,
CMake/pkg-config, AppImage/AppDir/appimagetool, dpkg-deb/APT, rpmbuild/RPM/DNF,
Flatpak/OSTree/GPG, Snapcraft/Snap Store, Ed25519 release metadata, GPG
repository signing, Docker/Podman or isolated Linux runners, Flutter test,
GoogleTest, and GitHub Actions.

## Execution Status

`blocked` as of 2026-07-14. The hard prerequisite check found 13 unchecked
steps in the privileged-helper plan, including target-host/elevation gates and
Task 16's final validation steps. Its fresh adversarial review also records one
validated P0 and three validated P1 findings, reports Task 6 open, and retains
the runtime as `candidate-only`. Therefore Task 1 was not started, no Linux
distribution implementation or RED test was written, and no prerequisite
checkbox was bypassed. Re-run the prerequisite only after the helper plan has
working packaged prepare/commit/mutation/query/recovery paths and all mandatory
secretless target-host gates.

## Global Constraints

- **Hard execution dependency:** Do not start Task 1 until
  `docs/exec-plans/active/2026-07-11-cross-platform-privileged-install-helper-plan.md`
  has all Tasks 1-16 checked, all mandatory secretless and target-host gates are
  `verified locally` or `verified in CI`, no validated P0/P1 remains, and its
  final evidence no longer reports the helper runtime as blocked. If any of
  those conditions is missing, record this plan as `blocked` and stop.
- Consume helper protocol v1 and `HelperPolicyV1`; do not redefine helper trust,
  journal, locking, recovery, elevation, or mutation authority.
- Map AppImage to `singleFileReplace`, deb/rpm to
  `systemPackageTransaction`, and Flatpak/Snap to
  `externalManagedRefresh` exactly.
- Preserve existing Linux zip plus `wholeDirectoryReplace` compatibility.
- Preserve the released Flutter API and `desktop_updater` MethodChannel surface.
- Support both Flutter Linux builds and Flutter-free installed CMake/pkg-config
  application trees.
- Keep release descriptor schema version 3. Add tagged artifact/install cases;
  do not bump the schema, package version, changelog heading, or lockfiles.
- For every new non-zip artifact, set `minimumUpdaterVersion` from the existing
  `desktopUpdaterPackageVersion` constant; do not invent or hardcode a future
  version.
- A signed descriptor may select a provider operation, but it cannot replace
  helper policy. Package names, repository origins, signing fingerprints,
  Flatpak remotes, Snap stores/channels, and allowed install targets must also
  match sealed helper policy.
- Do not download or execute unpinned build tools at runtime. CI toolchains must
  come from a digest-pinned container image or an explicit executable path plus
  verified SHA-256.
- Do not embed repository private keys, Snap credentials, store tokens, or
  signing passphrases in artifacts, descriptors, logs, fixtures, or committed
  configuration.
- AppImage production updates are full-file verified replacements; AppImage
  delta/zsync support is out of scope.
- deb and rpm application updates must be performed by the trusted system
  package provider. Never unpack a package directly over an installed root.
- Flatpak mounted revisions are immutable and must never be mutated directly.
  Support Flathub and GPG-signed self-hosted remotes.
- Snap production updates must use the public Snap Store or a private Brand
  Store. `snap install --dangerous`, local unsigned sideload, and direct mounted
  revision mutation are test/debug-only and forbidden in production flows.
- Flathub submission/review and store approvals are external gates. Do not write
  to GitHub or store APIs without the user's explicit authorization at execution
  time.
- Do not create, switch, rename, or delete branches. Do not push, merge, mark a
  PR ready, or write to GitHub.
- Preserve unrelated worktree changes and stage only the active task's files.
- Keep every format `candidate-only` until its real artifact, signature,
  installation, update, interruption/recovery, and repository/store validation
  lanes have passed.

---

## Dependency and Artifact Map

```text
Cross-platform privileged helper plan Task 16
  -> Task 1 Linux schema and fixtures
  -> Task 2 Linux release configuration and toolchain doctor
  -> Task 3 common Linux payload and policy assembly
      -> Task 4 AppImage
      -> Task 5 deb/APT
      -> Task 6 rpm/DNF
      -> Task 7 Flatpak
      -> Task 8 Snap
          -> Task 9 publisher/upload orchestration
          -> Task 10 runtime/helper routing
              -> Task 11 target-host CI matrix
                  -> Task 12 final validation and adversarial review
```

| Output | Descriptor kind | Helper strategy | Production authority |
| --- | --- | --- | --- |
| `.AppImage` | `appImage` | `singleFileReplace` | verified file transaction or installed root broker |
| `.deb` | `debPackage` | `systemPackageTransaction` | APT/dpkg with signed repository policy |
| `.rpm` | `rpmPackage` | `systemPackageTransaction` | DNF/RPM with signed repository policy |
| Flatpak bundle/repo | `flatpakBundle` | `externalManagedRefresh` | Flathub or GPG-signed self-hosted remote |
| `.snap` | `snapPackage` | `externalManagedRefresh` | public Snap Store or Brand Store |

## Evidence Rules

Each task records the exact command, host, exit status, and test count. Use only
`verified locally`, `verified in CI`, `not run`, or `blocked`. Check a task only
when all required secretless checks exist. Credential/store/review gates may
remain `not run`, but that format stays `candidate-only`. Create the listed
Conventional Commit after each independently verified task.

---

### Task 1: Add Linux Distribution Schema-v3 Contracts and Native Fixtures

**Files:**

- Modify: `lib/src/core/release_descriptor.dart`
- Modify: `fixtures/compat/release.schema-v3.json`
- Modify: `tool/generate_native_contract_fixtures.dart`
- Modify: `fixtures/compat/native-contract/release-contract/matrix.json`
- Create: `fixtures/compat/native-contract/release-contract/release-linux-appimage.json`
- Create: `fixtures/compat/native-contract/release-contract/release-linux-deb.json`
- Create: `fixtures/compat/native-contract/release-contract/release-linux-rpm.json`
- Create: `fixtures/compat/native-contract/release-contract/release-linux-flatpak.json`
- Create: `fixtures/compat/native-contract/release-contract/release-linux-snap.json`
- Modify: `native_runtime/cpp/release_contract.h`
- Modify: `native_runtime/cpp/release_contract.cc`
- Modify: `native_runtime/cpp/contract_fixture_tests.cc`
- Modify: `macos/desktop_updater/Sources/DesktopUpdaterKit/Runtime/ReleaseDescriptor.swift`
- Modify: `macos/desktop_updater/Tests/DesktopUpdaterKitTests/NativeContractConformanceTests.swift`
- Create: `test/linux_distribution_contract_test.dart`
- Modify: `test/native_runtime_conformance_contract_test.dart`

**Interfaces:**

Add one optional tagged object without changing existing constructors:

```dart
enum ReleaseLinuxProvider { direct, apt, dnf, flatpak, snap }

class ReleaseLinuxInstall {
  const ReleaseLinuxInstall({
    required this.provider,
    required this.packageName,
    this.architecture,
    this.repositoryOrigin,
    this.signingKeyFingerprint,
    this.appId,
    this.branch,
    this.remoteName,
    this.remoteUrl,
    this.expectedCommit,
    this.channel,
    this.expectedRevision,
    this.targetFileName,
  });
}
```

`ReleaseInstall` gains `ReleaseLinuxInstall? linux`. Existing `zip`,
`wholeDirectoryReplace`, and non-Linux parsing remain unchanged.

- [ ] **Step 1: Verify the prerequisite plan before writing tests**

  ```sh
  if rg -n '^- \[ \]' docs/exec-plans/active/2026-07-11-cross-platform-privileged-install-helper-plan.md; then
    echo 'BLOCKED: privileged helper plan is incomplete' >&2
    exit 1
  fi
  ```

  Expected before this plan is executable: nonzero exit and literal `blocked`
  evidence. Do not bypass this guard by editing the prerequisite checkboxes.

- [ ] **Step 2: Write failing Dart schema tests**

  Add exact positive cases:

  ```dart
  const cases = <(String, String, String)>[
    ("appImage", "singleFileReplace", "direct"),
    ("debPackage", "systemPackageTransaction", "apt"),
    ("rpmPackage", "systemPackageTransaction", "dnf"),
    ("flatpakBundle", "externalManagedRefresh", "flatpak"),
    ("snapPackage", "externalManagedRefresh", "snap"),
  ];
  ```

  Assert rejection of cross-platform use, wrong strategy/provider mapping,
  empty package name, absolute AppImage target filename, non-HTTPS remote,
  malformed uppercase/spaced fingerprint, missing Flatpak app ID/branch/commit,
  missing Snap channel/revision, and production dangerous sideload metadata.

- [ ] **Step 3: Run the test and confirm RED**

  ```sh
  flutter test --no-pub test/linux_distribution_contract_test.dart
  ```

  Expected: FAIL because the new kinds and `ReleaseLinuxInstall` do not exist.

- [ ] **Step 4: Implement the minimal tagged validation**

  Keep `ReleaseArtifact.sha256` and `length` mandatory for all five kinds. For
  Flatpak/Snap they describe the exact built package uploaded to the provider;
  runtime routing in Task 10 will not treat them as a direct-install payload.
  Validate these exact mappings:

  ```dart
  const linuxKindStrategyProvider = {
    "appImage": ("singleFileReplace", "direct"),
    "debPackage": ("systemPackageTransaction", "apt"),
    "rpmPackage": ("systemPackageTransaction", "dnf"),
    "flatpakBundle": ("externalManagedRefresh", "flatpak"),
    "snapPackage": ("externalManagedRefresh", "snap"),
  };
  ```

- [ ] **Step 5: Generate and consume cross-language fixtures**

  Extend the deterministic generator so Dart, Swift, and C++ parse every new
  descriptor and preserve the provider fields. Invalid fixtures must return the
  same stable category in all languages. Run:

  ```sh
  dart run tool/generate_native_contract_fixtures.dart
  dart run tool/generate_native_contract_fixtures.dart --check
  flutter test --no-pub test/linux_distribution_contract_test.dart test/native_runtime_conformance_contract_test.dart
  swift test --package-path macos/desktop_updater --filter NativeContractConformanceTests
  ```

  Run Windows and Linux native contract CTests on their target hosts.

- [ ] **Step 6: Commit**

  ```sh
  git add lib/src/core/release_descriptor.dart fixtures/compat/release.schema-v3.json tool/generate_native_contract_fixtures.dart fixtures/compat/native-contract/release-contract native_runtime/cpp/release_contract.h native_runtime/cpp/release_contract.cc native_runtime/cpp/contract_fixture_tests.cc macos/desktop_updater/Sources/DesktopUpdaterKit/Runtime/ReleaseDescriptor.swift macos/desktop_updater/Tests/DesktopUpdaterKitTests/NativeContractConformanceTests.swift test/linux_distribution_contract_test.dart test/native_runtime_conformance_contract_test.dart
  git commit -m "feat: define linux distribution contracts"
  ```

**Evidence:**

- Prerequisite helper plan: `blocked`
- RED: `not run`
- Dart/Swift/C++ conformance: `not run`
- Commit: `not run`

---

### Task 2: Add Linux Artifact Configuration and Fail-Closed Toolchain Doctor

**Files:**

- Create: `lib/src/release_cli/linux/linux_artifact_config.dart`
- Create: `lib/src/release_cli/linux/linux_toolchain.dart`
- Modify: `lib/src/release_cli/release_publish_config.dart`
- Modify: `lib/src/release_cli/doctor_command.dart`
- Create: `test/release_cli/linux_artifact_config_test.dart`
- Create: `test/release_cli/linux_toolchain_test.dart`
- Modify: `test/release_cli/release_publish_config_test.dart`
- Modify: `test/release_cli/release_doctor_test.dart`

**Configuration:**

```yaml
linux:
  artifact:
    kind: appimage # zip|appimage|deb|rpm|flatpak|snap
  architecture: x86_64
  toolchain:
    mode: container
    image: registry.example/build/linux-packagers@sha256:<64-lowercase-hex>
  package:
    name: example
    maintainer: Example Publisher <release@example.com>
    license: Proprietary
  repository:
    origin: https://packages.example.com/example
    signingKeyFingerprint: <40-or-64-uppercase-hex>
```

- [ ] **Step 1: Write failing config and doctor tests**

  Test `zip`, `appimage`, `deb`, `rpm`, `flatpak`, and `snap`; architecture
  normalization (`x86_64`, `aarch64`); digest-pinned container validation; an
  explicit-tool mode requiring absolute paths and SHA-256; missing package
  identity; relative repository URL; unpinned image tag; secret values in YAML;
  and format-specific required fields.

- [ ] **Step 2: Run tests and confirm RED**

  ```sh
  flutter test --no-pub test/release_cli/linux_artifact_config_test.dart test/release_cli/linux_toolchain_test.dart test/release_cli/release_publish_config_test.dart test/release_cli/release_doctor_test.dart
  ```

  Expected: FAIL because `ReleasePublishConfig` has no Linux artifact model.

- [ ] **Step 3: Implement immutable configuration types**

  Define:

  ```dart
  enum LinuxArtifactKind { zip, appImage, deb, rpm, flatpak, snap }

  sealed class LinuxToolchainConfig {
    const LinuxToolchainConfig();
  }

  final class LinuxContainerToolchainConfig extends LinuxToolchainConfig {
    const LinuxContainerToolchainConfig({required this.image});
    final String image;
  }
  ```

  Add format-specific config objects instead of one nullable bag. Parse only
  documented keys and reject unknown security-sensitive fields.

- [ ] **Step 4: Implement doctor probes without installing tools**

  Doctor checks the container digest or executable SHA-256 and runs read-only
  version probes. It reports missing GPG signing, Flatpak remote, or Snap Store
  credentials as `not run` readiness gates; it never downloads packages,
  imports keys, logs secrets, or treats unsigned local builds as production.

- [ ] **Step 5: Run focused tests and commit**

  ```sh
  flutter test --no-pub test/release_cli/linux_artifact_config_test.dart test/release_cli/linux_toolchain_test.dart test/release_cli/release_publish_config_test.dart test/release_cli/release_doctor_test.dart
  dart format --set-exit-if-changed lib/src/release_cli/linux test/release_cli/linux_artifact_config_test.dart test/release_cli/linux_toolchain_test.dart
  ```

  ```sh
  git add lib/src/release_cli/linux/linux_artifact_config.dart lib/src/release_cli/linux/linux_toolchain.dart lib/src/release_cli/release_publish_config.dart lib/src/release_cli/doctor_command.dart test/release_cli/linux_artifact_config_test.dart test/release_cli/linux_toolchain_test.dart test/release_cli/release_publish_config_test.dart test/release_cli/release_doctor_test.dart
  git commit -m "feat: configure linux distribution builds"
  ```

**Evidence:**

- RED: `not run`
- Config/doctor tests: `not run`
- Commit: `not run`

---

### Task 3: Assemble a Deterministic Linux Payload and Sealed Helper Policy

**Files:**

- Create: `lib/src/release_cli/linux/linux_payload_assembler.dart`
- Create: `lib/src/release_cli/linux/linux_desktop_entry.dart`
- Create: `lib/src/release_cli/linux/linux_helper_policy_asset.dart`
- Create: `test/release_cli/linux_payload_assembler_test.dart`
- Create: `test/release_cli/linux_desktop_entry_test.dart`
- Create: `test/release_cli/linux_helper_policy_asset_test.dart`
- Modify: `test/fixtures/release_publish_project.dart`

**Produces:**

```dart
class LinuxPayload {
  const LinuxPayload({
    required this.root,
    required this.executableRelativePath,
    required this.desktopEntry,
    required this.icons,
    required this.helperPolicy,
  });
}
```

- [ ] **Step 1: Write failing payload tests**

  Require normalized `SOURCE_DATE_EPOCH`, stable permissions/order/mtime,
  exactly one executable-relative path, safe desktop file fields, icon sizes,
  package ID consistency, no absolute/symlink escapes, and a helper policy whose
  package name/provider/target class matches the requested artifact. Reject
  setuid/setgid bits, world-writable files, device nodes, sockets, FIFOs, and
  embedded private keys.

- [ ] **Step 2: Run tests and confirm RED**

  ```sh
  flutter test --no-pub test/release_cli/linux_payload_assembler_test.dart test/release_cli/linux_desktop_entry_test.dart test/release_cli/linux_helper_policy_asset_test.dart
  ```

  Expected: FAIL because no common Linux payload assembler exists.

- [ ] **Step 3: Implement the minimal assembler**

  Consume Flutter or installed CMake/manual output and produce a staging tree;
  never mutate the input tree. Apply one normalized timestamp and explicit mode
  table. Generate the `.desktop` file using escaped field values, never shell
  concatenation. Obtain `HelperPolicyV1` through the generator delivered by the
  prerequisite helper plan.

- [ ] **Step 4: Verify deterministic byte inventory and commit**

  ```sh
  flutter test --no-pub test/release_cli/linux_payload_assembler_test.dart test/release_cli/linux_desktop_entry_test.dart test/release_cli/linux_helper_policy_asset_test.dart
  ```

  ```sh
  git add lib/src/release_cli/linux/linux_payload_assembler.dart lib/src/release_cli/linux/linux_desktop_entry.dart lib/src/release_cli/linux/linux_helper_policy_asset.dart test/release_cli/linux_payload_assembler_test.dart test/release_cli/linux_desktop_entry_test.dart test/release_cli/linux_helper_policy_asset_test.dart test/fixtures/release_publish_project.dart
  git commit -m "feat: assemble linux distribution payloads"
  ```

**Evidence:**

- RED: `not run`
- Payload determinism/security tests: `not run`
- Commit: `not run`

---

### Task 4: Build, Verify, and Publish AppImage Artifacts

**Files:**

- Create: `lib/src/release_cli/linux/appimage/appimage_packager.dart`
- Create: `lib/src/release_cli/linux/appimage/appdir_builder.dart`
- Create: `lib/src/release_cli/linux/appimage/appimage_verifier.dart`
- Create: `test/release_cli/linux/appimage_packager_test.dart`
- Create: `test/release_cli/linux/appimage_verifier_test.dart`
- Create: `tool/linux_appimage_smoke.sh`
- Modify: `lib/src/release_cli/release_publisher.dart`
- Modify: `test/release_cli/release_publisher_build_test.dart`

**Output contract:**

```json
{
  "artifact": {"kind": "appImage"},
  "install": {
    "strategy": "singleFileReplace",
    "linux": {
      "provider": "direct",
      "packageName": "example",
      "targetFileName": "Example.AppImage"
    }
  }
}
```

- [ ] **Step 1: Write failing AppDir and packager tests**

  Assert `AppRun`, desktop file, icon, payload, helper client, and portable
  same-user policy layout; deterministic output name; `appImage` descriptor;
  executable mode; SHA-256/length; tool digest verification before execution;
  no FUSE requirement for inspection; and rejection of symlink/device/mode
  attacks. Root-authority policy must not be embedded in the AppImage.

- [ ] **Step 2: Run tests and confirm RED**

  ```sh
  flutter test --no-pub test/release_cli/linux/appimage_packager_test.dart test/release_cli/linux/appimage_verifier_test.dart
  ```

  Expected: FAIL because AppImage packager classes are missing.

- [ ] **Step 3: Implement AppDir and pinned appimagetool execution**

  Build `AppDir/usr/lib/<package-name>`, an `AppRun` launcher with a fixed
  relative executable, and deterministic metadata. Invoke only the verified
  tool path with an argument list. Do not use `sh -c`, auto-download tools, or
  embed update keys with elevation authority.

- [ ] **Step 4: Add real AppImage smoke**

  The smoke builds an AppImage, extracts it with the tool's no-FUSE path, runs
  the application/version probe, performs a writable full-file update, kills
  the helper at every journal state, and verifies convergence. A separate
  root-owned test must use the preinstalled broker and prove missing broker
  fails before mutation.

- [ ] **Step 5: Run verification and commit**

  ```sh
  flutter test --no-pub test/release_cli/linux/appimage_packager_test.dart test/release_cli/linux/appimage_verifier_test.dart test/release_cli/release_publisher_build_test.dart
  sh tool/linux_appimage_smoke.sh --mode writable
  sh tool/linux_appimage_smoke.sh --mode root-broker
  ```

  ```sh
  git add lib/src/release_cli/linux/appimage lib/src/release_cli/release_publisher.dart test/release_cli/linux/appimage_packager_test.dart test/release_cli/linux/appimage_verifier_test.dart test/release_cli/release_publisher_build_test.dart tool/linux_appimage_smoke.sh
  git commit -m "feat: publish appimage releases"
  ```

**Evidence:**

- RED: `not run`
- Deterministic AppImage tests: `not run`
- Writable update/recovery smoke: `not run`
- Root-broker update/recovery smoke: `not run`
- Commit: `not run`

---

### Task 5: Build deb Packages and Signed APT Repositories

**Files:**

- Create: `lib/src/release_cli/linux/deb/deb_packager.dart`
- Create: `lib/src/release_cli/linux/deb/debian_control.dart`
- Create: `lib/src/release_cli/linux/deb/apt_repository_publisher.dart`
- Create: `lib/src/release_cli/linux/deb/apt_repository_verifier.dart`
- Create: `test/release_cli/linux/deb_packager_test.dart`
- Create: `test/release_cli/linux/apt_repository_test.dart`
- Create: `tool/linux_deb_apt_smoke.sh`
- Modify: `lib/src/release_cli/release_publisher.dart`
- Modify: `test/release_cli/release_publisher_build_test.dart`

**Installed payload:**

```text
/opt/<package-name>/...
/usr/bin/<command> -> /opt/<package-name>/<executable-relative-path>
/usr/share/applications/<package-name>.desktop
/usr/share/icons/hicolor/<size>x<size>/apps/<package-name>.png
/usr/libexec/desktop-updater-helper
/usr/share/polkit-1/actions/<helper-service-id>.policy
/etc/desktop-updater/policies/<package-id>.json
```

- [ ] **Step 1: Write failing package and repository tests**

  Assert Debian package name/version/architecture normalization, root ownership,
  safe modes, conffile preservation for helper policy, no maintainer-script
  network access, no arbitrary shell interpolation, descriptor kind
  `debPackage`, provider `apt`, repository origin/fingerprint binding, by-hash
  metadata, signed `InRelease`, immutable pool path, and atomic metadata publish
  order.

- [ ] **Step 2: Run tests and confirm RED**

  ```sh
  flutter test --no-pub test/release_cli/linux/deb_packager_test.dart test/release_cli/linux/apt_repository_test.dart
  ```

  Expected: FAIL because deb/APT components are missing.

- [ ] **Step 3: Implement deterministic dpkg-deb packaging**

  Generate `DEBIAN/control` from validated fields and invoke `dpkg-deb` through
  the pinned toolchain. Package the broker, polkit action, and sealed policy as
  root-owned files. The application helper later calls only the sealed APT
  provider; it never unpacks the `.deb` directly.

- [ ] **Step 4: Implement signed APT repository publication**

  Produce `Packages`, compressed indexes, `Release`, detached signature, and
  clear-signed `InRelease`; verify the configured fingerprint immediately after
  signing. Upload pool artifacts first, then indexes, then `InRelease` last.
  Signing adapters accept an external process/file descriptor and never a
  private key string.

- [ ] **Step 5: Run real APT smoke and commit**

  In an isolated Debian/Ubuntu container, install v1 from the signed repository,
  publish v2, interrupt the package-manager transaction, query provider state,
  and converge to `completed`, `verificationPending`, or non-destructive
  `manualActionRequired` according to actual dpkg/APT state. Never invent file
  rollback. Verify installed version/files/policy ownership, then uninstall.

  ```sh
  flutter test --no-pub test/release_cli/linux/deb_packager_test.dart test/release_cli/linux/apt_repository_test.dart test/release_cli/release_publisher_build_test.dart
  sh tool/linux_deb_apt_smoke.sh
  ```

  ```sh
  git add lib/src/release_cli/linux/deb lib/src/release_cli/release_publisher.dart test/release_cli/linux/deb_packager_test.dart test/release_cli/linux/apt_repository_test.dart test/release_cli/release_publisher_build_test.dart tool/linux_deb_apt_smoke.sh
  git commit -m "feat: publish deb and apt releases"
  ```

**Evidence:**

- RED: `not run`
- deb package inspection: `not run`
- Signed APT install/update/interruption smoke: `not run`
- Commit: `not run`

---

### Task 6: Build rpm Packages and Signed DNF Repositories

**Files:**

- Create: `lib/src/release_cli/linux/rpm/rpm_packager.dart`
- Create: `lib/src/release_cli/linux/rpm/rpm_spec_builder.dart`
- Create: `lib/src/release_cli/linux/rpm/dnf_repository_publisher.dart`
- Create: `lib/src/release_cli/linux/rpm/dnf_repository_verifier.dart`
- Create: `test/release_cli/linux/rpm_packager_test.dart`
- Create: `test/release_cli/linux/dnf_repository_test.dart`
- Create: `tool/linux_rpm_dnf_smoke.sh`
- Modify: `lib/src/release_cli/release_publisher.dart`
- Modify: `test/release_cli/release_publisher_build_test.dart`

- [ ] **Step 1: Write failing RPM and repository tests**

  Assert safe NEVRA fields, architecture mapping, explicit `%files`, fixed
  ownership/modes, no dynamic `%post` downloads, package signature validation,
  descriptor kind `rpmPackage`, provider `dnf`, repository origin/fingerprint,
  signed `repomd.xml`, immutable package paths, and metadata-last publication.

- [ ] **Step 2: Run tests and confirm RED**

  ```sh
  flutter test --no-pub test/release_cli/linux/rpm_packager_test.dart test/release_cli/linux/dnf_repository_test.dart
  ```

  Expected: FAIL because RPM/DNF components are missing.

- [ ] **Step 3: Implement deterministic rpmbuild packaging**

  Generate a spec whose sources are the normalized payload tree, use a private
  build root, disable build-id mutation where inappropriate, and invoke pinned
  `rpmbuild`. Package the broker/polkit/policy with root-owned modes. Verify the
  resulting RPM header, payload inventory, and configured signing fingerprint.

- [ ] **Step 4: Implement signed DNF repository publication**

  Run pinned `createrepo_c`, sign `repodata/repomd.xml`, verify the signature,
  and publish package objects before repository metadata. Never accept a caller
  package-manager command; helper policy fixes DNF provider, repository origin,
  package name, and signing fingerprint.

- [ ] **Step 5: Run real DNF smoke and commit**

  In isolated Fedora/RHEL-compatible containers, install v1, publish v2,
  interrupt update, query provider state, and converge to `completed`,
  `verificationPending`, or non-destructive `manualActionRequired` according to
  actual RPM/DNF state. Never invent file rollback. Verify installed version
  and root-owned helper policy, then uninstall.

  ```sh
  flutter test --no-pub test/release_cli/linux/rpm_packager_test.dart test/release_cli/linux/dnf_repository_test.dart test/release_cli/release_publisher_build_test.dart
  sh tool/linux_rpm_dnf_smoke.sh
  ```

  ```sh
  git add lib/src/release_cli/linux/rpm lib/src/release_cli/release_publisher.dart test/release_cli/linux/rpm_packager_test.dart test/release_cli/linux/dnf_repository_test.dart test/release_cli/release_publisher_build_test.dart tool/linux_rpm_dnf_smoke.sh
  git commit -m "feat: publish rpm and dnf releases"
  ```

**Evidence:**

- RED: `not run`
- RPM package/signature inspection: `not run`
- Signed DNF install/update/interruption smoke: `not run`
- Commit: `not run`

---

### Task 7: Build Flatpak Bundles and Signed Self-Hosted Remotes

**Files:**

- Create: `lib/src/release_cli/linux/flatpak/flatpak_manifest_builder.dart`
- Create: `lib/src/release_cli/linux/flatpak/flatpak_packager.dart`
- Create: `lib/src/release_cli/linux/flatpak/flatpak_repository_publisher.dart`
- Create: `lib/src/release_cli/linux/flatpak/flatpak_verifier.dart`
- Create: `test/release_cli/linux/flatpak_manifest_test.dart`
- Create: `test/release_cli/linux/flatpak_repository_test.dart`
- Create: `tool/linux_flatpak_smoke.sh`
- Modify: `lib/src/release_cli/release_publisher.dart`
- Modify: `test/release_cli/release_publisher_build_test.dart`

**Provider metadata:**

```json
{
  "provider": "flatpak",
  "packageName": "com.example.App",
  "appId": "com.example.App",
  "branch": "stable",
  "remoteName": "example",
  "remoteUrl": "https://packages.example.com/flatpak/repo/",
  "expectedCommit": "64-lowercase-hex"
}
```

- [ ] **Step 1: Write failing manifest/repository tests**

  Require reverse-DNS app ID, fixed runtime/SDK versions, declared finish args,
  no host filesystem or broad device access unless explicitly configured,
  deterministic manifest, offline source payload, GPG-signed OSTree summary,
  `.flatpakref`/`.flatpakrepo`, expected commit binding, descriptor kind
  `flatpakBundle`, and rejection of direct mounted-revision mutation.

- [ ] **Step 2: Run tests and confirm RED**

  ```sh
  flutter test --no-pub test/release_cli/linux/flatpak_manifest_test.dart test/release_cli/linux/flatpak_repository_test.dart
  ```

  Expected: FAIL because Flatpak components are missing.

- [ ] **Step 3: Implement pinned flatpak-builder and repository export**

  Build from the normalized payload without network access, export into a local
  OSTree repository, sign the commit and summary with an external GPG identity,
  create a bundle for inspection/manual distribution, and write remote files.
  Verify app ID, branch, architecture, commit, and fingerprint before publish.
  Runtime refresh must use the supported
  `org.freedesktop.portal.Flatpak` update-monitor/update D-Bus contract from a
  sandboxed application; do not grant broad host command execution and do not
  use `flatpak-spawn --host` as a production updater.

- [ ] **Step 4: Implement Flathub handoff artifacts without GitHub writes**

  Emit a maintainer-ready manifest and validation report. Record Flathub review
  as an external `not run`/`blocked` gate. Do not open a repository, submit a PR,
  or post a comment automatically.

- [ ] **Step 5: Run self-hosted remote smoke and commit**

  Add the generated signed remote in an isolated Flatpak user installation,
  install v1, publish v2, invoke `externalManagedRefresh` through the Flatpak
  portal, interrupt/retry, verify expected commit, and uninstall. The helper
  must not edit files under a mounted Flatpak revision.

  ```sh
  flutter test --no-pub test/release_cli/linux/flatpak_manifest_test.dart test/release_cli/linux/flatpak_repository_test.dart test/release_cli/release_publisher_build_test.dart
  sh tool/linux_flatpak_smoke.sh --remote self-hosted
  ```

  ```sh
  git add lib/src/release_cli/linux/flatpak lib/src/release_cli/release_publisher.dart test/release_cli/linux/flatpak_manifest_test.dart test/release_cli/linux/flatpak_repository_test.dart test/release_cli/release_publisher_build_test.dart tool/linux_flatpak_smoke.sh
  git commit -m "feat: publish flatpak releases"
  ```

**Evidence:**

- RED: `not run`
- Signed self-hosted remote smoke: `not run`
- Flathub validation/submission: `not run`
- Commit: `not run`

---

### Task 8: Build Snap Packages and Integrate Store-Managed Refresh

**Files:**

- Create: `lib/src/release_cli/linux/snap/snapcraft_yaml_builder.dart`
- Create: `lib/src/release_cli/linux/snap/snap_packager.dart`
- Create: `lib/src/release_cli/linux/snap/snap_store_publisher.dart`
- Create: `lib/src/release_cli/linux/snap/snap_verifier.dart`
- Create: `test/release_cli/linux/snapcraft_yaml_test.dart`
- Create: `test/release_cli/linux/snap_store_test.dart`
- Create: `tool/linux_snap_smoke.sh`
- Modify: `lib/src/release_cli/release_publisher.dart`
- Modify: `test/release_cli/release_publisher_build_test.dart`

**Provider metadata:**

```json
{
  "provider": "snap",
  "packageName": "example",
  "channel": "stable",
  "expectedRevision": "42"
}
```

- [ ] **Step 1: Write failing Snapcraft and store tests**

  Require valid Snap name/version/grade/confinement, explicit plugs, no
  `classic` confinement unless separately approved, deterministic staged
  payload, descriptor kind `snapPackage`, store/Brand Store identity, channel
  and revision binding, credential redaction, and hard rejection of
  `--dangerous`, local sideload, or direct mounted-revision mutation in
  production mode.

- [ ] **Step 2: Run tests and confirm RED**

  ```sh
  flutter test --no-pub test/release_cli/linux/snapcraft_yaml_test.dart test/release_cli/linux/snap_store_test.dart
  ```

  Expected: FAIL because Snap components are missing.

- [ ] **Step 3: Implement pinned Snapcraft packaging**

  Generate `snapcraft.yaml` from typed config, stage the normalized payload, and
  build `.snap` inside the pinned toolchain. Inspect package metadata and hash
  before any upload. Debug tests may unpack locally; production code must never
  run `snap install --dangerous`.

- [ ] **Step 4: Implement explicit store upload/release adapter**

  Require execution-time authorization and external credentials. Upload the
  verified `.snap`, capture immutable revision, release only to the configured
  public or Brand Store channel, re-query store state, and emit redacted
  evidence. Normal snaps leave refresh scheduling to snapd and return
  `externalManagerPending` until the expected revision is installed. Do not
  require the super-privileged `snapd-control` interface. A Brand Store/device
  policy may expose an approved refresh operation, but it must be sealed in
  helper policy and independently verified.

- [ ] **Step 5: Run store smoke where credentials exist and commit**

  ```sh
  flutter test --no-pub test/release_cli/linux/snapcraft_yaml_test.dart test/release_cli/linux/snap_store_test.dart test/release_cli/release_publisher_build_test.dart
  sh tool/linux_snap_smoke.sh --mode store
  ```

  The store smoke must install v1 from a real test channel, publish v2, observe
  snapd or an approved Brand Store policy refresh to v2, and verify revision and
  pending-state reporting. Without credentials, record `not run`; local
  dangerous install cannot replace this evidence.

  ```sh
  git add lib/src/release_cli/linux/snap lib/src/release_cli/release_publisher.dart test/release_cli/linux/snapcraft_yaml_test.dart test/release_cli/linux/snap_store_test.dart test/release_cli/release_publisher_build_test.dart tool/linux_snap_smoke.sh
  git commit -m "feat: publish snap store releases"
  ```

**Evidence:**

- RED: `not run`
- Snap package inspection: `not run`
- Public/Brand Store upload-refresh smoke: `not run`
- Commit: `not run`

---

### Task 9: Generalize Publish Layout, Manifest, Upload, and Hosted Validation

**Files:**

- Modify: `lib/src/release_cli/publish_layout.dart`
- Modify: `lib/src/release_cli/publish_manifest.dart`
- Modify: `lib/src/release_cli/release_publisher.dart`
- Modify: `lib/src/release_cli/validate_command.dart`
- Modify: `lib/src/release_cli/upload/upload_provider.dart`
- Modify: `lib/src/release_cli/upload/manual_upload_provider.dart`
- Modify: `lib/src/release_cli/upload/custom_command_upload_provider.dart`
- Modify: `lib/src/release_cli/upload/ftp_upload_provider.dart`
- Modify: `lib/src/release_cli/upload/sftp_upload_provider.dart`
- Modify: `lib/src/release_cli/upload/s3_upload_provider.dart`
- Modify: `test/release_cli/publish_layout_test.dart`
- Modify: `test/release_cli/publish_manifest_test.dart`
- Modify: `test/release_cli/release_publisher_build_test.dart`
- Modify: `test/release_cli/release_validate_test.dart`
- Modify: `test/release_cli/upload/manual_upload_provider_test.dart`
- Modify: `test/release_cli/upload/custom_command_upload_provider_test.dart`
- Modify: `test/release_cli/upload/ftp_upload_provider_test.dart`
- Modify: `test/release_cli/upload/sftp_upload_provider_test.dart`
- Modify: `test/release_cli/upload/s3_upload_provider_test.dart`

**Manifest extension:**

```dart
class PublishManifestAsset {
  const PublishManifestAsset({
    required this.role,
    required this.kind,
    required this.path,
    required this.url,
    required this.sha256,
    required this.length,
  });
}
```

Keep existing `artifact` unchanged and add `List<PublishManifestAsset> assets`
with a default empty list for compatibility. Repository metadata, signatures,
`.flatpakref`, and store receipts use role-specific assets.

- [ ] **Step 1: Write failing multi-asset publication tests**

  Assert deterministic filenames/extensions, path traversal rejection, legacy
  manifest round-trip, multi-asset hash/length, duplicate URL/path rejection,
  upload ordering (packages before repository metadata; index last), metadata
  signature verification, external-store receipt validation, rollback if an
  upload fails before index publication, and no secret-bearing environment in
  custom commands.

- [ ] **Step 2: Run tests and confirm RED**

  ```sh
  flutter test --no-pub test/release_cli/publish_layout_test.dart test/release_cli/publish_manifest_test.dart test/release_cli/release_publisher_build_test.dart test/release_cli/release_validate_test.dart test/release_cli/upload
  ```

  Expected: FAIL because the manifest and uploader model one artifact only.

- [ ] **Step 3: Implement additive multi-asset orchestration**

  Preserve old JSON when `assets` is empty. For direct packages, validate
  hosted bytes against SHA-256/length. For APT/DNF/Flatpak, validate repository
  signatures and expected package/commit. For Snap, re-query store/channel/
  revision rather than downloading and sideloading the snap. Provider upload
  must finish before final descriptor generation so returned repository commit
  or store revision is included in the canonical signed descriptor; publish the
  signed `app-archive.json` only after that final descriptor validates.

- [ ] **Step 4: Prove publish-last ordering and commit**

  ```sh
  flutter test --no-pub test/release_cli/publish_layout_test.dart test/release_cli/publish_manifest_test.dart test/release_cli/release_publisher_build_test.dart test/release_cli/release_validate_test.dart test/release_cli/upload
  ```

  ```sh
  git add lib/src/release_cli/publish_layout.dart lib/src/release_cli/publish_manifest.dart lib/src/release_cli/release_publisher.dart lib/src/release_cli/validate_command.dart lib/src/release_cli/upload test/release_cli/publish_layout_test.dart test/release_cli/publish_manifest_test.dart test/release_cli/release_publisher_build_test.dart test/release_cli/release_validate_test.dart test/release_cli/upload
  git commit -m "feat: publish linux distribution assets"
  ```

**Evidence:**

- RED: `not run`
- Multi-asset/upload ordering tests: `not run`
- Hosted provider validation tests: `not run`
- Commit: `not run`

---

### Task 10: Route Linux Runtime Results to the Existing Helper Strategies

**Files:**

- Modify: `lib/src/core/update_client.dart`
- Modify: `lib/src/core/artifact_stager.dart`
- Modify: `linux/native/include/desktop_updater_runtime.h`
- Modify: `linux/native/src/runtime/update_client_linux.cc`
- Modify: `linux/native/src/runtime/artifact_stager_linux.cc`
- Modify: `linux/native/src/desktop_updater_native.cc`
- Modify: `linux/desktop_updater_plugin.cc`
- Modify: `test/update_client_security_test.dart`
- Create: `test/linux_distribution_routing_test.dart`
- Modify: `linux/native/test/runtime/contract_conformance_test.cc`
- Modify: `linux/native/test/runtime/artifact_stager_test.cc`
- Modify: `linux/native/test/desktop_updater_native_test.cc`
- Modify: `linux/test/desktop_updater_plugin_test.cc`

**Routing:**

```text
zip -> verify/download/extract -> directoryReplace compatibility adapter
appImage -> verify/download/no extraction -> singleFileReplace
deb/rpm -> verify descriptor/provider -> systemPackageTransaction
flatpak/snap -> verify signed descriptor -> externalManagedRefresh
```

- [ ] **Step 1: Write failing Dart/native routing tests**

  Assert AppImage is downloaded as one executable file without archive
  extraction; deb/rpm do not unpack into the app root; Flatpak/Snap do not use
  artifact transport as mutation authority; provider metadata is passed to the
  helper; helper policy mismatch fails before app exit; legacy Linux zip remains
  unchanged; and existing Flutter method/channel arguments remain compatible.

- [ ] **Step 2: Run focused tests and confirm RED**

  ```sh
  flutter test --no-pub test/linux_distribution_routing_test.dart test/update_client_security_test.dart
  ```

  Expected: FAIL because new artifact kinds are unsupported by staging/routing.

- [ ] **Step 3: Implement minimal strategy-aware routing**

  Reuse the native client operations delivered by the prerequisite helper plan.
  Direct artifacts carry verified provenance into the transaction. Provider
  strategies carry signed expected identity plus sealed-policy lookup; they do
  not accept caller commands, keys, remotes, or roots as authority. Flatpak uses
  its update portal, while ordinary Snap installs report/query snapd-managed
  refresh instead of requesting `snapd-control`.

- [ ] **Step 4: Run Dart and Linux target-host tests**

  ```sh
  flutter test --no-pub test/linux_distribution_routing_test.dart test/update_client_security_test.dart
  cmake -S linux/native -B build/linux-distributions -DDESKTOP_UPDATER_NATIVE_BUILD_TESTS=ON -DDESKTOP_UPDATER_NATIVE_RUNTIME=ON
  cmake --build build/linux-distributions
  ctest --test-dir build/linux-distributions --output-on-failure
  ```

  Require nonzero CTest discovery.

- [ ] **Step 5: Commit**

  ```sh
  git add lib/src/core/update_client.dart lib/src/core/artifact_stager.dart linux/native/include/desktop_updater_runtime.h linux/native/src/runtime/update_client_linux.cc linux/native/src/runtime/artifact_stager_linux.cc linux/native/src/desktop_updater_native.cc linux/desktop_updater_plugin.cc test/update_client_security_test.dart test/linux_distribution_routing_test.dart linux/native/test/runtime/contract_conformance_test.cc linux/native/test/runtime/artifact_stager_test.cc linux/native/test/desktop_updater_native_test.cc linux/test/desktop_updater_plugin_test.cc
  git commit -m "feat: route linux distribution updates"
  ```

**Evidence:**

- RED: `not run`
- Dart routing/security tests: `not run`
- Linux native/plugin CTest: `not run`
- Commit: `not run`

---

### Task 11: Add Real Linux Build, Install, Update, and Recovery CI Lanes

**Files:**

- Modify: `.github/workflows/desktop-updater-ci.yml`
- Create: `test/linux_distribution_ci_contract_test.dart`
- Create: `tool/linux_distribution_smoke.sh`
- Modify: `docs/github-actions-ci-cd.md`
- Modify: `docs/windows-linux-production-release.md`
- Modify: `docs/publishing.md`
- Modify: `docs/native-sdk.md`

- [ ] **Step 1: Write failing CI truth tests**

  Require named jobs with nonzero test discovery for AppImage writable/root
  broker, deb/APT, rpm/DNF, signed Flatpak remote, and Snap Store. Assert that
  source scans, unit tests, unsigned local packages, `--dangerous` Snap installs,
  or fixture-only repository metadata cannot be reported as production smoke.

- [ ] **Step 2: Run the CI contract and confirm RED**

  ```sh
  flutter test --no-pub test/linux_distribution_ci_contract_test.dart
  ```

  Expected: FAIL because distribution jobs do not exist.

- [ ] **Step 3: Add secretless isolated lanes**

  Use digest-pinned images for reproducible package builds and ephemeral GPG
  keys generated only inside CI for APT/DNF/Flatpak test repositories. Build
  both Flutter and native CMake inputs. Run package inspection, install v1,
  update to v2, injected interruption, recovery/query, relaunch/version proof,
  uninstall, and cleanup. Upload redacted logs and artifact inventories.

- [ ] **Step 4: Add external credential/review lanes**

  Snap public/Brand Store upload-refresh and Flathub submission/review remain
  explicitly gated. Missing credentials or approval yields `not run`, not a
  substituted local green. Do not authorize uploads merely because CI YAML
  exists.

- [ ] **Step 5: Update production documentation**

  Document exact config, toolchain pinning, signing key rotation, repository
  publish ordering, rollback expectations, helper provisioning, per-format
  update authority, credential gates, and the ban on production Snap dangerous
  sideloading. Remove claims that only Linux zip is supported after the actual
  lanes pass.

- [ ] **Step 6: Run tests and commit**

  ```sh
  flutter test --no-pub test/linux_distribution_ci_contract_test.dart test/native_sdk_docs_test.dart
  ```

  ```sh
  git add .github/workflows/desktop-updater-ci.yml test/linux_distribution_ci_contract_test.dart tool/linux_distribution_smoke.sh docs/github-actions-ci-cd.md docs/windows-linux-production-release.md docs/publishing.md docs/native-sdk.md
  git commit -m "ci: verify linux distribution channels"
  ```

**Evidence:**

- RED: `not run`
- AppImage lanes: `not run`
- Signed APT lane: `not run`
- Signed DNF lane: `not run`
- Signed self-hosted Flatpak lane: `not run`
- Snap Store lane: `not run`
- Flathub review: `not run`
- Commit: `not run`

---

### Task 12: Run the Full Validation Ladder and Independent Adversarial Review

**Files:**

- Modify: this plan
- Modify only for validated findings: files named by the finding

- [ ] **Step 1: Re-run every focused format lane from fresh outputs**

  Regenerate fixtures and rebuild AppImage, deb, rpm, Flatpak, and Snap outputs.
  Re-run artifact inspection, signature/repository verification, installation,
  v1-to-v2 update, interruption/recovery, uninstall, and hosted validation.
  Record exact host, command, exit status, test count, artifact digest, and
  signer/repository/store identity.

- [ ] **Step 2: Run the complete repository validation ladder**

  ```sh
  dart run tool/generate_native_contract_fixtures.dart --check
  dart format --set-exit-if-changed .
  flutter analyze --no-fatal-infos
  flutter test --no-pub
  dart pub publish --dry-run
  swift test --package-path macos/desktop_updater
  swift test
  ```

  On Linux, run full CMake/CTest with nonzero discovery and all available real
  format smokes. No macOS/Windows packaging behavior may regress.

- [ ] **Step 3: Run `superpowers:verification-before-completion`**

  Use only fresh command output. Treat unavailable Snap/Flathub credentials or
  approvals literally as `not run`; do not infer production readiness.

- [ ] **Step 4: Run fresh `killcritic-complete-review`**

  Review four tracks:

  1. package/repository/store trust and credential boundaries;
  2. helper strategy, privilege, target, mount, rollback, and recovery safety;
  3. schema/native/Flutter compatibility and legacy zip behavior;
  4. CI, hosted validation, publication order, and release-truth claims.

  Validate findings before changing code. For every validated P0/P1, add a
  failing regression test, implement the smallest complete fix, re-run the
  applicable real format lane, and create an independent Conventional Commit.

- [ ] **Step 5: Record literal readiness per format**

  Mark each of AppImage, deb/APT, rpm/DNF, self-hosted Flatpak, Flathub, public
  Snap Store, and Brand Store independently as `verified locally`, `verified in
  CI`, `not run`, or `blocked`. A missing external gate keeps only that channel
  `candidate-only`; do not blend it into another format's evidence.

- [ ] **Step 6: Commit final evidence**

  ```sh
  git add docs/exec-plans/active/2026-07-11-linux-distribution-artifacts-plan.md
  git commit -m "docs: record linux distribution verification"
  ```

**Evidence:**

- Prerequisite helper plan: `blocked`
- Dart/Flutter validation ladder: `not run`
- Linux native validation ladder: `not run`
- AppImage production readiness: `candidate-only`
- deb/APT production readiness: `candidate-only`
- rpm/DNF production readiness: `candidate-only`
- Self-hosted Flatpak readiness: `candidate-only`
- Flathub readiness: `candidate-only`
- Public Snap Store readiness: `candidate-only`
- Brand Store readiness: `candidate-only`
- Verification-before-completion: `not run`
- Fresh killcritic review: `not run`
- Validated P0/P1 remaining: `not run`
- Commit: `not run`
