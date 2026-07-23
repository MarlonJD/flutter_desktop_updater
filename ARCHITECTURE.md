# Architecture

`desktop_updater` is a Flutter desktop plugin with a Dart update runtime,
release tooling, ready-made Flutter UI, platform-channel adapters, and native
install helpers for macOS, Windows, and Linux.

## Component Map

| Surface | Primary paths | Responsibility |
| --- | --- | --- |
| Public Flutter API | `lib/desktop_updater.dart`, `lib/updater_controller.dart`, `lib/widget/` | App-facing update orchestration, state, localization, and UI |
| Update runtime | `lib/src/core/` | Release selection, trust checks, staging, provenance, diagnostics, and recovery |
| Transports | `lib/src/io/` | HTTP and file access behind update transport interfaces |
| Platform bridge | `lib/desktop_updater_platform_interface.dart`, `lib/desktop_updater_method_channel.dart` | Stable Dart-to-native contract and MethodChannel dispatch |
| Native plugins and helpers | `macos/`, `windows/`, `linux/` | Platform integration, privileged install handoff, recovery, and relaunch |
| Release toolchain | `bin/`, `lib/src/cli/`, `lib/src/package/`, `lib/src/release_cli/` | Package, sign, publish, validate, verify, and migrate releases |
| Native SDKs and preview runtime | `Package.swift`, `macos/desktop_updater/`, `windows/native/`, `linux/native/` | Flutter-free helper SDKs and opt-in native update runtime |
| Executable evidence | `test/`, platform-native test directories, `example/`, `.github/workflows/` | Unit, contract, integration, consumer, and target-host verification |

## Dependency Direction

- Flutter widgets depend on `DesktopUpdaterController` and public state types;
  runtime and transport code do not depend on widgets.
- The controller and `UpdateClient` coordinate release metadata, trust,
  downloads, staging, and recovery. Transport implementations stay under
  `lib/src/io/`.
- Dart reaches operating-system behavior through
  `DesktopUpdaterPlatform` and the `desktop_updater` MethodChannel. Native
  plugins validate the handoff before invoking packaged helpers.
- Release CLI entrypoints delegate to package and release services. They may
  reuse runtime schemas and verification code, but runtime code must not depend
  on CLI presentation or upload providers.
- macOS, Windows, and Linux share versioned contracts, schemas, and fixtures.
  Destructive mutation, privilege, filesystem, and recovery implementations
  remain platform-owned.

## Update Flow

```text
app-archive.json
  -> select release.json
  -> verify descriptor authority and artifact metadata
  -> download and verify artifact
  -> stage with provenance
  -> MethodChannel/native SDK handoff
  -> platform helper installs, recovers, and relaunches
```

The discovery index locates a release; it is not itself installation authority.
The selected descriptor, pinned keys, artifact digest and length, package
identity, stage provenance, and platform publisher checks form the trust
boundary. See [Native contract](docs/native-contract.md),
[Native install-helper protocol](docs/native-install-helper-protocol.md), and
[Diagnostics and recovery](docs/diagnostics-and-recovery.md).

## Release Flow

The release CLI resolves project metadata, builds or accepts platform
artifacts, verifies platform trust requirements, writes versioned release
metadata, uploads immutable files first, and publishes `app-archive.json` last.
See [Publishing](docs/publishing.md) and
[GitHub Actions CI/CD](docs/github-actions-ci-cd.md).

## Change Boundaries

- Public Dart API changes start in `lib/desktop_updater.dart`,
  `lib/updater_controller.dart`, or `lib/widget/` and require focused public
  behavior tests.
- Metadata or helper protocol changes must keep Dart and native schemas,
  fixtures, conformance tests, and documentation aligned.
- Platform mutation or trust changes require the relevant native tests and
  platform smoke lane; a configured workflow is not execution evidence.
- Release claims use literal evidence labels from
  [Harness engineering](docs/harness-engineering.md).

Run the narrowest relevant test first, then use the validation ladder in
[AGENTS.md](AGENTS.md). Cross-cutting or risky work belongs in the
[execution-plan ledger](docs/exec-plans/index.md).
