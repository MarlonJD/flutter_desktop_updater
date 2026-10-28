# desktop_updater 3.2.7 release

## Context and acceptance

The user authorized publication when ready and a follow-up comment to the
reporter on GitHub issue 82. Continue on existing main and preserve unrelated
work. Use the previously approved GitHub CLI account route for the requested
comment, never a connector identity. Do not overwrite a published version or
move an existing tag.

On 2026-10-28 both pub.dev and GitHub reported 3.2.6 as latest; 3.2.7 and
v3.2.7 were absent. This release includes the completed helper setup, diagnostic,
DMG naming, and path handling work since v3.2.6. The original resource-only
privacy bundle fix remains included: these resources are sealed by their
enclosing code object without independent entitlement extraction.

## Progress

- [x] Check registry/tag availability, main, authentication, and unrelated work.
- [x] Prepare 3.2.7 changelog, README availability, and synchronized versions.
- [x] Review the candidate and run focused release checks.
- [x] Commit, pass the complete local harness, and push main normally.
- [x] Pass exact-candidate CI, including macOS native and both Flutter lanes.
- [x] Verify the exact candidate with a local notarized DMG 1-to-2 fixture.
- [x] Publish pub.dev, create an immutable tag, and publish the matching GitHub release.
- [x] Verify archive inventory/bytes, tag commit, public versions, and links.
- [x] Post the requested scoped reporter comment and verify it.

## Decisions and verification boundaries

- Reuse validated helper/runtime behavior and the packaged consumer command.
  New source policies require explicit Apple Team ID and a feed-bound public
  key profile. Existing custom policies remain intact. Trust and digest checks
  are not relaxed to pass setup or update tests.
- Run notarization through existing `general-notary` with default resolution;
  omit `--keychain` and `macos.keychain`. Do not read or change credentials.
- Use an immutable source export and unique app/bundle identity. Capture exact
  candidate/source hashes, artifact hash, version/build, process/relaunch,
  strict signatures, stapling, and Gatekeeper results. Clean only owned fixtures.
- The reporter's actual app and original post-update file-selection scenario
  are not established by an isolated fixture. Earlier intermittent restart
  failures and the Flutter runner timeout remain separate historical evidence.
- Credential-gated privileged CI lanes are not covered by ordinary CI or local
  notarized same-user bundle replacement.

## Execution and recovery

Evidence lives under `reports/releases/desktop_updater-3.2.7/`, excluded from
Git and package publication. Use `dart run tool/sync_versions.dart`, focused
version/helper/real-signing tests, Swift helper version tests, and the complete
`tool/harness_check.dart` ladder. Inspect CI for the exact candidate commit,
not just a previous source revision. Verify the registry before retrying an
uncertain publication. Any permission/credential block leaves all remaining
preparation complete and identifies the precise pending operation.

After publication, download the pub.dev archive and compare every file with
the candidate commit and expected package inventory. Resolve the tag to that
same commit. Verify both public release URLs. The issue reply must explain the
consumer command, preserved source policy, generated digest build input,
required rebuilding of both versions, and the bounds of the test evidence.

## Revision history

- 2026-10-28: created after explicit release and reporter-comment authorization.
- Focused validation: 52 Dart tests and 6 Swift helper version tests passed.
  The review caught four stale 3.2.6 version assertions; they were updated
  before freezing the candidate. The initial failures remain in local logs.

## Release outcome

- Release commit: `16b56da31194b6b6af6d107f3ca79815b19282cd`; normal main
  push completed. Both originally required commits remain ancestors.
- Exact-candidate [CI run 40684624878](https://github.com/MarlonJD/flutter_desktop_updater/actions/runs/40684624878)
  passed all 13 standard jobs, including macOS Native Consumer, macOS Flutter
  SwiftPM, and macOS Flutter CocoaPods. Four credential-gated jobs were skipped.
- The complete local harness passed: structure, formatting, analysis, version
  synchronization, documentation contracts, 1,037 Flutter tests (4 skipped),
  and a zero-warning publication dry-run. The focused 52 Dart and 6 Swift
  helper version tests also passed.
- Local host: macOS 27.2 (26B123), Xcode 27.1 (27A9275), Flutter 3.44.8 stable
  at `058e0af2c2b57e369d905a03ac9748b0ebf543c6`, Dart 3.12.2.
- An immutable export of the release commit generated its helper policy from
  the existing example policy using the published consumer command. Namespace
  and SwiftPM fixture settings were isolated to the export; all 199 tracked
  Dart/native package source files in the source manifest remained identical.
- The isolated `com.example.desktopUpdater327` app completed a DMG update
  from 1.0.0+1 to 1.0.0+2. Both apps and the DMG received Apple notarization
  acceptance, were stapled, and passed strict signature and Gatekeeper checks.
  The updated app emitted its relaunch marker and contained the build-2
  sentinel. The exact DMG SHA-256 is
  `4338386e591a8a006ac7986ba23dea5a5054652f3054c227ce09768c290b96db`.
- The prior recovery receipt remained byte-identical. Only the owned test app,
  source export, artifacts, and hosted-smoke temporary directory were removed;
  no fixture processes or mounts remained. The notarized DMG, source hashes,
  generated policy, diagnostics, and configuration evidence were retained.
- [pub.dev 3.2.7](https://pub.dev/packages/desktop_updater/versions/3.2.7)
  was published at `2026-10-28T12:29:05.713624Z`. The downloaded
  archive's 865 files match the complete expected inventory and release commit.
  Archive SHA-256:
  `9fb388798cd1ff9984077f08e649921e8de37c9d867320ac14f847cb19b1c41c`.
  The version page and archive were available immediately; the latest pointer
  initially returned cached 3.2.6 and then converged to 3.2.7. No upload retry
  or overwrite was performed.
- [GitHub release v3.2.7](https://github.com/MarlonJD/flutter_desktop_updater/releases/tag/v3.2.7)
  was published at `2026-10-28T12:29:59Z`. The annotated tag resolves
  locally and remotely to the release commit; the release body matches the
  prepared notes and GitHub's latest release is v3.2.7. The package, release,
  and immutable README links all returned HTTP 200.
- The requested [issue 82 reply](https://github.com/MarlonJD/flutter_desktop_updater/issues/82#issuecomment-6469062043)
  was posted at `2026-10-28T12:32:28Z` using the approved GitHub CLI
  route. The API confirms author MarlonJD and the exact drafted body. It
  explains the generated source/digest, rebuilding both versions, manual
  installation of the rebuilt baseline, and asks whether the update succeeds.

- Release-ledger closure passed the structural harness gate and all 10 focused
  documentation tests. This structural result is not a new source/attestation
  certification claim.

## Remaining limitations

This is verified local fixture and exact-candidate CI evidence. The reporter's
application and original post-update file-selection scenario remain unverified.
The earlier intermittent restart failure and unresolved Flutter-runner timeout
remain historical observations with no root cause established by this passing
run. Credential-gated privileged installation lanes were not run. The release
does not claim notarization or scenario coverage for the reporter's own app.

The previously completed resource-only privacy bundle fix remains unchanged:
resource-only bundles are sealed by the enclosing code object without
independent entitlement extraction; executable code remains independently
validated and signed.
