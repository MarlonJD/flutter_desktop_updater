# desktop_updater 3.2.13 release

Publish the Windows portable update fix from [PR #87](https://github.com/MarlonJD/flutter_desktop_updater/pull/87) and notify the reporter on [issue #86](https://github.com/MarlonJD/flutter_desktop_updater/issues/86).

## Progress

- [x] Merge the CI-tested PR head `2458067` into `main` at `ce56023`.
- [x] Confirm 3.2.12 is the current release and 3.2.13 is available.
- [ ] Run the local release harness and check Windows CI for the versioned source commit.
- [ ] Publish to pub.dev, verify the archive against Git, create the GitHub release and reply to the reporter.

## Decision log

Use a patch release for the completed-install startup delay. Package the same Windows helper that passed the two-process regression. Build the pub.dev upload from a clean export of the release commit.

## Verification

Run `dart run tool/version_check.dart` and `dart run tool/harness_check.dart`. Verify the Windows native ZIP smoke on the release commit. Download the published archive and compare every packaged file with Git. Confirm the tag target and issue comment by reading them back from GitHub.
