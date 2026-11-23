# desktop_updater 3.2.13 release

Version 3.2.13 ships the Windows portable update fix from [PR #87](https://github.com/MarlonJD/flutter_desktop_updater/pull/87).

## Progress

- [x] Merge the CI-tested PR head `2458067` into `main` at `ce56023`.
- [x] Confirm 3.2.12 is the current release and 3.2.13 is available.
- [x] Run the local release harness and check Windows CI for the versioned source commit.
- [x] Publish to pub.dev, verify the archive against Git, create the GitHub release and reply to the reporter.

## Decision Log

The patch release covers the completed-install startup delay. The pub.dev upload used a clean export of `bf3ffd2cd4ede3e605f95188cfdc4cedf3c59f2a`.

## Surprises & Discoveries

Portable recovery uses the helper generation recorded when the update started. An installation upgrading from an older helper can experience the delay once more. The release notes and reporter reply explain how to test an update started by a build bundling 3.2.13.

## Outcomes & Retrospective

- The local release harness passed with 1,161 Flutter tests passing, seven skipped and zero publish warnings. All six focused Swift helper version tests passed.
- Release CI passed 13 jobs and skipped four conditional jobs. Windows x64 verified the completed response and helper exit while the updated app remained open. Both Debug and both Release update smoke runs passed. [Release CI](https://github.com/MarlonJD/flutter_desktop_updater/actions/runs/45086009880)
- All 869 files in the downloaded pub.dev archive matched the release commit. Its SHA-256 was `125e8e8dc7ce2fe4e9c16ff534892b1a62e8337f022eea0d52af6f54f7f5ca66`. The registry and GitHub both reported 3.2.13 as latest. The tag targets the release commit. [pub.dev](https://pub.dev/packages/desktop_updater/versions/3.2.13) · [GitHub release](https://github.com/MarlonJD/flutter_desktop_updater/releases/tag/v3.2.13)
- Merging the PR closed issue #86. The maintainer's release comment was posted and read back. [Issue comment](https://github.com/MarlonJD/flutter_desktop_updater/issues/86#issuecomment-7088338884)
