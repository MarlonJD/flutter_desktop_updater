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
- [ ] Commit, pass the complete local harness, and push main normally.
- [ ] Pass exact-candidate CI, including macOS native and both Flutter lanes.
- [ ] Verify the exact candidate with a local notarized DMG 1-to-2 fixture.
- [ ] Publish pub.dev, create an immutable tag, and publish the matching GitHub release.
- [ ] Verify archive inventory/bytes, tag commit, public versions, and links.
- [ ] Post the requested scoped reporter comment and verify it.

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
