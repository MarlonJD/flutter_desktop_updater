# Issue 82 DMG update reproduction and helper setup

## Context and acceptance

The user requested investigation of the remaining macOS DMG update problem
following main `e6b83f5`, then asked to make helper setup easier and automatic.
The deleted runtime report cannot establish its exact cause. The subsequent
[policy setup comment](https://github.com/MarlonJD/flutter_desktop_updater/issues/82#issuecomment-6465573496)
and [generator-path comment](https://github.com/MarlonJD/flutter_desktop_updater/issues/82#issuecomment-6466362904)
provide concrete build/setup failures that can be reproduced locally.

Acceptance: exercise a real notarized DMG 1-to-2 update and relaunch with the
signed native helper, preserve failed-run evidence, and provide a packaged
policy setup command that runs in the consuming Flutter app. Preserve unrelated
work, existing branch, and credentials. Version remains 3.2.6; this continuation
does not create a release, tag, issue comment, or review submission.

## Progress

- [x] Read repository guidance, issue history, and previous verification records.
- [x] Reproduce and fix malformed/stale policy-pin diagnostics.
- [x] Verify that correction locally and at exact commit `4511b7e` in CI.
- [x] Resolve existing notarization profile access without changing credentials.
- [x] Run the actual notarized DMG 1-to-2 update and verify relaunch/trust.
- [x] Isolate hosted smoke recovery receipts and preserve the foreign receipt.
- [x] Replace the repository-only Flutter setup recipe with a packaged command.
- [x] Verify consumer invocation, signed helper requirements, and path handling.
- [x] Review independently and run the local validation ladder.
- [ ] Verify CI for the final implementation commit.
- [ ] Complete the record and remove remaining task-owned temporary exports.

## Findings and decisions

1. The original policy setup snapshot contained a placeholder digest and a
   helper identifier in the application signing requirement. Exact digest
   comparison and native signer authorization correctly reject these inputs.
   The reporter later corrected the application identifier in the comment;
   do not describe that old typo as the current report.
2. The generator-path error occurs because `tool/generate_native_install_helper_policy.dart`
   belongs to this repository, not the consumer app. `flutter pub get` does
   not copy it into the consumer's `tool/`. The initial documentation-only
   two-directory recipe was executed successfully, but the user's follow-up
   correctly identified unnecessary setup work. It is superseded for Flutter
   consumers by `dart run desktop_updater:release helper-policy`.
3. `general-notary` works with default Data Protection Keychain resolution.
   All three successful Apple submissions below omitted `--keychain`.
   Explicit login-Keychain lookup searches a different store. Earlier default
   lookup failures remain historical observations; their exact cause was not
   established. No profile was recreated and no credentials were exported.
4. The first full DMG run passed app/DMG notarization and staging, then failed
   before native handoff with `A pending install must be recovered before
   another install`. The hosted smoke driver had read an August receipt for a
   different sample app. Give each invocation its own recovery-store path;
   retain the real pending-install guard and preserve the unrelated receipt.
5. Fresh helper policies reuse the feed-bound public release-key profile and
   literal bundle ID, require an explicit Team ID, and generate distinct app
   and helper signing requirements. Defaults permit bundle replacement in
   writable `/Applications`; elevated and PKG authority must be reviewed in
   the source. Existing source bytes/custom authority remain unchanged.
   Canonical JSON and digest are validated together and the digest is written
   last. Build-time pin comparison remains independent of generated JSON.
6. The shared strict policy validator and UTF-8 canonicalizer moved from
   repository tools into `lib/src/native_install_helper/`; fixture generation
   remains in `tool/`. Existing fixture bytes and digests are unchanged.
7. Real consumer verification with spaces in project/DerivedData paths exposed
   an existing unquoted architecture-output list in the embed script. Quoted
   positional arguments now preserve paths for both `cp` and universal `lipo`.
   No native Swift runtime or install authorization was changed.
8. Independent read-only reviews found no blocking issues in the final policy
   command, receipt isolation, documentation, or shell quoting. The suggested
   explicit-package-ID regeneration note and consumer invocation check were
   incorporated. Only the main agent edited source and ran GUI/signing tests.

## Verification

Local evidence is retained under `reports/releases/issue82-dmg-2026-10-28/`.
The app and artifact evidence are separate from setup-command signing checks.

### Earlier policy preflight correction

- Seven original malformed-pin cases failed before the correction; the final
  suite also covers unset pins and ad hoc policy selection.
- Full suite: 1,022 passed, four skipped. Format, analysis (no errors/warnings),
  version consistency, shell syntax, and committed publish dry-run passed.
- Exact code commit: `4511b7e94dbc0a91189169c9cbb40813b1698051`.
- [CI 40667815377](https://github.com/MarlonJD/flutter_desktop_updater/actions/runs/40667815377)
  passed: Dart Package, docs, macOS Native Consumer, SwiftPM Flutter, CocoaPods
  Flutter, and aggregate gate. Credential-gated jobs were skipped.

### Actual notarized DMG update

- Source export: `52b4a62fdcfe82c941db1ec64b2a1d6ddd3fa1e7`; source hashes and
  fixture-only namespace changes are recorded in `candidate-source.json`.
- Isolated app: `/Applications/Desktop Updater DMG82 Smoke.app`, bundle ID
  `com.example.desktopUpdaterDmg82`. Outgoing `1.0.0+1`, incoming `1.0.0+2`.
- Both application builds and the DMG received Apple `Accepted` results and
  passed stapling. The mounted DMG app passed strict signature and trust checks.
- Signed DMG SHA-256:
  `7ca4afe6f4c61ed3ec57e49138c578974b7c7c2b3f30d378ed79cf5324403f81`.
  The retry reused this exact artifact with the isolated recovery-store driver.
- `dmg-isolated-retry.json`: exit 0, installed build changed 1 to 2, foreign
  receipt preserved. Diagnostics reached checking, downloading, installing,
  and relaunch. The outgoing process exited 0; the relaunched app wrote its
  marker and was observed running before cleanup.
- Final installed app and DMG strict signatures, Gatekeeper assessment, and
  stapled tickets passed (`dmg-final-verification.json`, `dmg-final-trust.log`).
- The installed fixture and its process were removed; no task DMG was mounted.
  `dmg-evidence/` retains the exact DMG, signed metadata, diagnostics, and local
  pending receipt. The old unrelated receipt remains byte-for-byte intact.
- This run establishes DMG install/relaunch for this fixture. It does not
  establish the reporter's app behavior or recovery on a subsequent update.

### Packaged helper setup and final local checks

- `helper-policy-before.log`: ten consumer-command cases failed before the
  command existed. Focused policy/native-contract suites subsequently passed.
- Full `flutter test --no-pub --reporter expanded`: 1,037 passed, four skipped.
- Final focused helper/setup/harness tests: 35 passed after the path fix.
- `dart format --output=none --set-exit-if-changed .`: 294 files, unchanged.
- `flutter analyze --no-pub --no-fatal-infos`: exit 0; no errors or warnings.
- Native helper contract and policy fixture checks: unchanged.
- Version check: all native SDK versions still match 3.2.6.
- Shell syntax and `git diff --check`: passed.
- `helper-policy-packaged.json`: the exact published-style invocation ran from
  a separate app with a package containing `bin/` and `lib/` but no `tool/`.
  Paths contained spaces; repeat runs preserved all three generated files.
- Executed the README build phase with the generated policy and digest. Actual
  Developer ID single-arm64 and universal arm64/x86_64 helpers built and passed
  strict app/helper signing requirements. Using the helper requirement for the
  app failed; changing JSON while retaining the pin failed before compilation.
- The packaged-command fixture was signed but was not separately notarized.
  The preceding DMG run is independently recorded notarization evidence.
- The first dry-run reported only uncommitted package files; repeat after the
  source commit before handoff. No publication is authorized by that check.

## Remaining boundaries

The reporter's actual application, deleted DMG report, and original post-update
file-selection scenario remain unverified. The earlier intermittent restart
failure and Flutter-runner timeout are separate historical evidence; these
passes do not establish their causes. The command automates policy generation;
Runner still needs its documented helper build phase and signing configuration.
New command availability is explicitly marked as main-only, absent from pub.dev
3.2.6. No package release, Git tag, or GitHub issue comment was created here.

## Revision history

- 2026-10-28: opened for DMG reproduction and the policy setup report.
- 2026-10-28: resolved profile lookup, verified notarized DMG, and added the
  consumer CLI after the user requested simpler automatic setup.
