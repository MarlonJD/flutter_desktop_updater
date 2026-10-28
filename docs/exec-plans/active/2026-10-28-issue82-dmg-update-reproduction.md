# Issue 82 DMG update reproduction

## Context and acceptance

The user asks to reproduce and fix the remaining macOS update problem after
main `e6b83f5` added bounded preparation diagnostics and publishing readiness
checks. The reporter deleted the October 28 comment; both REST and GraphQL
currently omit it and its direct endpoint returns 404. The completed
install-preparation record preserves a DMG 1.0.0+1 to 1.0.0+2 failure after
successful download/staging. The user confirms the problem involved DMG.

The previous local notarized E2E exercised ZIP updates. Exercise the actual
DMG mount/copy/install/relaunch path with the new diagnostics, retain failure
evidence, fix a reproduced defect with focused regressions, and rerun that
same path. Keep claims scoped to the isolated test app; the deleted report
cannot establish the reporter's exact cause. No new release is requested.

## Progress

- [x] Read current instructions, available issue history, and new main record.
- [x] Preserve unrelated work and fast-forward the existing main to e6b83f5.
- [ ] Reproduce the DMG 1 to 2 update through the real signed native helper.
- [x] Reproduce the new comment's helper policy setup error and add regressions.
- [x] Review the fix independently and run the relevant local validation ladder.
- [ ] Verify the corrected notarized DMG update and cleanup task fixtures.
- [ ] Record evidence and complete the plan with remaining limitations.

## Surprises & Discoveries

- The latest reporter comment is deleted, as confirmed by the user. No new
  consumer artifacts or detailed phase/reason output are available.
- The prior notarized 3.2.6 test exercised `app-update` (ZIP); this task must
  exercise `dmg-update` rather than treating that ZIP success as DMG evidence.
- The new [reporter comment](https://github.com/MarlonJD/flutter_desktop_updater/issues/82#issuecomment-6465573496)
  shows a build-time setup failure: the digest remains the literal
  `REPLACE_WITH_GENERATED_SHA256`, and `allowedApplicationSigner` uses the
  helper identifier instead of `applicationPackageId`. The first necessarily
  fails the exact digest check; the second rejects the signed application.
  This does not establish the cause of the deleted DMG runtime report.
- The fresh DMG fixture built and passed strict Developer ID signature checks,
  but the first notarization stopped because the previously used Keychain
  profile was unavailable. Default and explicit login-Keychain checks failed;
  the repository's CI profile name was also unavailable locally. Broader
  Keychain metadata/GUI discovery was rejected by automatic approval review.
  The user was asked for the exact existing profile name, without secrets.

## Decision Log

- 2026-10-28: use isolated exports and a unique test app/bundle ID, reusing
  the authorized local Developer ID identity and existing notary profile.
  Preserve the user's installed apps, current branch, and unrelated plans.
- 2026-10-28: run read-only DMG contract investigation independently while
  the main agent builds and runs the notarized fixture. Only the main agent
  writes source or runs GUI tests.
- 2026-10-28: address the concrete new setup error first. Read the generator's
  reviewed `.sha256` input from the build phase; do not derive the expected
  digest from the policy during a build. Preserve exact digest comparison and
  native signature authorization. Explain the distinct app/helper requirements
  without inventing a partial parser for Apple's requirement language.
- 2026-10-28: read-only DMG review identified a possible custom bundle-name
  mismatch and staging trust-check asymmetry. Neither was reproduced or tied
  to the new build failure; do not change DMG runtime behavior speculatively.

## Verification and recovery

Evidence lives in `reports/releases/issue82-dmg-2026-10-28/`. Record the base
commit and package source hashes for exported hosts. Use a unique `/Applications`
fixture, verify ownership before replacing or removing it, preserve trust and
transaction checks, and stop only task-owned processes. Keep SDK/cache writes,
GUI tests, and authenticated GitHub commands outside the sandbox. Authenticated
GitHub CLI calls unset GH_TOKEN and GITHUB_TOKEN.

Start with focused Swift/Dart regressions for the observed cause, then run
format, analysis, full relevant suites, version check, documentation contracts,
and publish dry-run as applicable. The product remains version 3.2.6; no tag,
publication, or issue comment is part of this new request. Missing reporter
artifacts limit attribution, not local reproduction work.

## Outcomes & Retrospective

The setup correction is verified locally; notarized DMG E2E remains blocked.

- Seven original regression cases failed against the old embed script, which
  returned only a generic missing/mismatched digest error. The final coverage
  also exercises unset pins and ad hoc policy selection boundaries.
- Full `flutter test --no-pub --reporter expanded`: 1,022 passed, four skipped.
- `flutter analyze --no-pub --no-fatal-infos`: exit 0, no errors or warnings.
- `dart format --output=none --set-exit-if-changed .`: 289 files, no changes.
- `dart run tool/version_check.dart`: all native versions match 3.2.6.
- `/bin/sh -n macos/install_helper/embed_install_helper.sh` and
  `git diff --check`: passed.
- Executed the actual README build-phase snippet with newly generated canonical
  JSON and `.sha256`, including its final newline, in an isolated Developer ID
  signed application. Helper embedding and strict app/helper verification passed.
  Applying the helper's requirement to the app failed with codesign exit 3,
  confirming why the reporter's swapped identifier cannot authorize the app.
- Signed test evidence: `policy-signed-setup-final.log` and
  `policy-signed-setup.json` under the local report directory. These are signing
  checks, not notarization or update/relaunch evidence.

Pending: obtain the exact existing notary profile name, rerun the real DMG
`1.0.0+1` to `1.0.0+2` update, and retain its result. The historical intermittent
restart failure and Flutter-runner timeout remain separate unresolved evidence;
this setup fix does not explain them. The reporter's actual app and original
post-update file-selection scenario remain unverified.

## Revision history

- 2026-10-28: created for the user-requested DMG reproduction and fix.
