# Agent Instructions For desktop_updater

This file is the repo map for agentic work. Keep it short; deeper project
knowledge belongs in `docs/`.

## Start Here

- Read this file first, then follow the most local instruction file that applies
  to the files you touch.
- Use `docs/harness-engineering.md` for the agent harness model, validation
  ladder, and staged adoption plan.
- Use `docs/exec-plans/index.md` to find active and completed execution plans.
- Do not create, switch, rename, or delete branches unless the user explicitly
  asks for that branch action.
- Do not post GitHub comments or PR reviews through connector identities. Draft
  text for the user instead.

## Repository Map

- Public package API: `lib/desktop_updater.dart`,
  `lib/updater_controller.dart`, and `lib/widget/`.
- Update runtime core: `lib/src/core/`.
- Network and file transports: `lib/src/io/`.
- Release, package, verify, and migration CLIs: `bin/` and
  `lib/src/release_cli/`.
- Native plugin code: `macos/`, `windows/`, and `linux/`.
- Example host app and platform smoke tools: `example/`.
- Package docs: `README.md`, `docs/`, and `doc/`.
- Repository-backed execution plans: `docs/exec-plans/`.

## Validation Ladder

Use the narrowest useful command first, then widen before handoff:

```sh
flutter test --no-pub test/<focused_test>.dart
dart format --set-exit-if-changed .
flutter analyze --no-fatal-infos
flutter test --no-pub
dart pub publish --dry-run
```

Platform lanes are heavier and usually belong to CI or explicit release work:

- Windows and Linux example builds, native tests, integration tests, and update
  smoke tests live in `.github/workflows/desktop-updater-ci.yml`.
- macOS notarized publish smoke requires explicit secrets and
  `workflow_dispatch`.

## Local Conventions

- Keep canonical docs, code comments, API names, and file names in English.
- Do not bump package versions, changelog headings, or lockfiles unless the
  task is explicitly release/version work.
- Prefer focused tests in `test/` for Dart behavior and docs drift checks.
- Keep diagnostics, publishing, localization, and UI documentation aligned with
  the corresponding tests when changing user-facing behavior.
