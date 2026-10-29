# Issue 82 helper policy digest investigation

## Context and acceptance

The reporter still gets the sealed-policy digest mismatch in 3.2.7 after
cleaning and regenerating the policy. The user requested reproduction and a fix,
including the missing fresh-consumer notarized update flow. Work
locally on the existing main branch, preserve unrelated work, and retain the
digest and signer trust boundaries. Do not infer the reporter's root cause
from an unrelated passing fixture or silently substitute the expected hash.

Source: [issue comment 6486081436](https://github.com/MarlonJD/flutter_desktop_updater/issues/82#issuecomment-6486081436).
The installed package baseline is 3.2.7; the working source starts at
`139fc40cc15c5e4cd05161c8b8b1b3cbb49e8ab1`.

## Progress

- [x] Read the current report, generator, embed script, and selected-policy rules.
- [x] Reproduce the generated-policy build boundary and protect any defect.
- [x] Correct proven hashing defects and make mismatch diagnostics identify the
  selected inputs without weakening verification.
- [x] Verify actual helper packaging, negative cases, and the local ladder.
- [x] Prepare a minimal reporter diagnostic request and record the remaining
  customer-environment uncertainty.
- [x] Obtain the reporter's selected input diagnostics and establish the digest
  failure's cause. After explicit user approval, the diagnostic request was posted
  through the MarlonJD `gh` keyring account and its body verified:
  [comment 6493345344](https://github.com/MarlonJD/flutter_desktop_updater/issues/82#issuecomment-6493345344).
  [Reply 6495852126](https://github.com/MarlonJD/flutter_desktop_updater/issues/82#issuecomment-6495852126)
  identifies formatting the generated JSON as the cause. Its diagnostic selects
  the normal policy, not an ad hoc override. Keeping the generated JSON intact
  let the reporter publish build 1.
- [x] Reproduce build 2's separate `Packaged helper policy does not match bundle
  metadata` failure through a fresh consumer, identify the differing fields, and
  verify the repair through consecutive builds. This follow-up is explicitly
  requested by the user; preserve the remaining customer-specific uncertainty.
- [x] Obtain reporter confirmation after applying the generated-plist input.
  Comment 6496938835 reports successful build 2 publication, 1-to-2 update
  installation, and normal file access on 3.2.7. The exact project/bundle was
  not supplied, so this is reporter-confirmed behavior rather than local inspection.
- [x] Exercise a fresh Flutter consumer using the published 3.2.7 README phase,
  its generated digest file, Developer ID signing, notarization, and a DMG
  build 1 to 2 update with relaunch. The user explicitly requested this missing
  coverage after the release audit. Keep baseline and patched-source results
  separate.
- [x] Verify the patched consumer through a notarized DMG update and relaunch,
  and build a separate fresh CocoaPods consumer with the same source export.

## Surprises & Discoveries

- The error follows pin syntax validation: the expected value is already 64
  lowercase hex characters. An ad hoc override can replace both policy and pin.
- `shasum FILE` prefixes its output with a backslash when the filename contains
  a literal backslash. Parsing the first token then yields a non-digest. A
  local byte probe confirms this differs from stdin hashing for identical bytes.
  The reporter's path is unknown, so this is a reproduced package defect, not
  an established explanation of their failure.
- Existing error output omits the selected policy path, the environment variable
  providing the pin, and the actual/expected values. Regenerating the default
  policy cannot repair a separately selected ad hoc input.
- Fixing the hash calculation exposed a separate Xcode 27.1 Swift build-system
  escaping failure in a DerivedData path containing a literal backslash. The
  hash fix does not claim full toolchain support for those paths. Use a directory
  without that character. Actual helper compilation/signing was verified with
  spaces and Unicode; escaped-path digest handling is covered independently.
- Release-coverage audit: the 3.2.7 notarized DMG run used the repository example.
  Its fixture preparer rewrote both policies for the fixture identity and
  precomputed matching literal digests in the Xcode build phase. Although the
  consumer policy command ran, that phase did not read its generated `.sha256`
  file. The consumer README phase and generated digest were exercised in a
  separate real helper/signing test, whose evidence explicitly says the new
  policy fixture was not notarized. Those proofs were not one fresh-consumer
  setup-to-notarized-update run. The published unit packaging tests covered
  rejection cases, without a generator-to-successful-embed integration case.
  Preserve the actual notarized success while treating this setup coverage gap
  as a limitation; it does not identify the reporter's cause.
- The fresh published consumer passed helper-policy generation and the real
  SwiftPM Release build, including spaces and Unicode in its path. Its first
  notarization submission was rejected because raw Xcode build settings injected
  `get-task-allow` and omitted the app timestamp. Distribution builds now set
  `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO` and `OTHER_CODE_SIGN_FLAGS=--timestamp`;
  the original rejection is retained. Xcode 27.1 also requires deployment target
  12.0 rather than the Flutter 3.44.8 template's 10.15.
- Both fresh 3.2.7 app versions and the DMG were then accepted by Apple. The
  update failed with `helperEndpointUnavailable`: the notarized outgoing app
  contained its helper but lacked all four `DesktopUpdaterInstall*` host plist
  fields. The example had prepopulated source fields, masking this failure mode.
  The original hash mismatch did not occur in this fresh consumer.
- The README phase omitted a generated `Info.plist` input dependency. The
  missing-metadata build is retained, but subsequent incremental baseline runs
  retained the fields; no deterministic overwrite trace was captured. Treat the
  missing dependency as a build-order defect and the precise timing of that
  observed loss as unresolved. Apple documents that phase ordering follows
  declared dependencies, not just visual phase placement.

## Decision Log

- 2026-10-29: hash file contents through stdin so filesystem spelling cannot
  alter the digest token. Keep exact digest comparison and strict verification.
- 2026-10-29: report bounded mismatch context and document a read-only build
  diagnostic for published 3.2.7. Do not log policy contents or credentials.
- 2026-10-29: keep this work local; a new release and a new external reporter
  comment are not part of the current question's execution scope.
- 2026-10-29: create a new Flutter macOS project instead of copying the example
  Xcode project. Resolve exactly 3.2.7 from pub.dev and compare all 865 archive
  files with the resolved cache. Extract the build phase and AppDelegate
  bootstrap from that published README. The build phase reads `.sha256` with
  `cat`; no literal or recomputed pin is substituted. Reuse only the documented
  file-backed recovery adapter and test-feed signing convention.
- 2026-10-29: declare `$(TARGET_BUILD_DIR)/$(INFOPLIST_PATH)` as an input in the
  example and consumer recipe. Reject Xcode embedding without this explicit
  dependency before changing host metadata. Add final host-field checks to the
  README and notarized fixture. Do not add static policy values to the fresh
  consumer's source plist to hide the problem.
- 2026-10-29: execute the README shell phase directly in the regression test.
  Verify the compiled helper with an escaped canonical-policy filename, and
  still reject a changed policy without modifying the installed helper or host.

## Verification and recovery

Run the focused `test/macos_helper_packaging_test.dart` regressions first against
the unchanged script, then against the fix. Exercise a consumer-generated policy
with actual helper compilation and ad hoc signing in an owned temporary folder,
including Unicode, spaces, and backslashes. Tampering and stale ad hoc pins must
still fail before changing host metadata or replacing an embedded helper.
Then run formatting, analysis, the full local harness, and relevant documentation
tests. Preserve logs under `reports/releases/issue82-policy-digest-2026-10-29/`.
Remove only owned temporary fixtures and generated test outputs.

## Outcomes & Retrospective

`verified locally`: the baseline failed three focused assertions: missing
diagnostic context and rejection of a valid generated pair under an escaped
DerivedData path. The corrected scripts passed all 12 focused tests, including
real helper compilation, ad hoc signature/embedded-policy verification, and
rejection of a modified policy without changing host metadata or the installed
helper. A stale ad hoc pin still fails and identifies the overridden inputs.

The documented diagnostic was executed against the actual v3.2.7 embed script.
It selected the correct inputs for a stale default pin, stale ad hoc override,
and equal hashes with an escaped DerivedData path. All three original failures
remained enforced; the diagnostic did not modify policy or host metadata.

The initial root ladder passed structure, formatting, analysis, version checks,
10 documentation tests, and the full suite (1,038 passed, 4 skipped). Its publish
dry-run returned only the expected warning for four modified tracked package
files; therefore the aggregate harness report is not labelled passed. An export
of HEAD with the exact local patch overlaid passed publish dry-run with zero
warnings. No package publication was performed. The first broad run also found
a local README link into pub-ignored docs (fixed to a GitHub URL) and a previous
release-evidence `pubspec.yaml` accidentally treated as a live package. Its bytes
were preserved as `pubspec.yaml.txt`; analysis then passed. Generated .NET probe
outputs and owned temporary fixtures were removed.

The reporter's selected policy and expected/actual hashes remain unavailable.
The earlier notarized DMG fixture remains historical evidence and does not
establish this customer's build configuration. The patch is local and
uncommitted; the new reporter request is prepared under the evidence directory.
Keep this plan active until customer diagnostics establish which repair applies.

### Fresh consumer follow-up

`verified locally`: a new `flutter create --platforms=macos --no-pub --empty`
consumer resolved exactly pub.dev 3.2.7; all 865 cached package files matched the
downloaded archive. Its Xcode phase was extracted from the published README and
read the generated `.sha256` with `cat`, with no precomputed pin in the project.
The generated pair built successfully. After correcting the test's distribution
signing flags, Apple accepted both apps and the DMG, but the outgoing app lacked
its helper metadata and the update failed before handoff. Preserve that failed
baseline; it is not a passing E2E result and is not the reporter's hash error.

`verified locally`: the patched-source export required the generated plist input.
A real Xcode build without that input failed with the new actionable message.
With the input configured, builds 1 and 2 retained all four helper fields and
both apps plus the DMG were accepted by Apple. The signed loopback feed drove
the installed app through download, native helper installation, exit, and v2
relaunch. Final `CFBundleVersion` was 2; strict signature verification, stapler,
Gatekeeper, and entitlement equality all passed. The separate CocoaPods Release
build also passed with its helper metadata and strict signatures; notarization
was exercised in the SwiftPM lane only. This is local source evidence, not CI.

Evidence is under `reports/releases/issue82-policy-digest-2026-10-29/`:

- `fresh-published-identity.json`, `fresh-consumer-setup/`, and
  `fresh-notarized-result.json` bind the failed published baseline.
- `fresh-candidate-source.json`, `candidate.patch`,
  `candidate-consumer-setup/`, and `fresh-artifact-identities.json` bind the local
  patch, generated inputs, final host plists, helper binaries, and executables.
- `candidate-notarized-result.json` records all three Apple acceptances and the
  successful update. Retained DMG SHA-256:
  `f8dd0653d2360e232fb8c0f8183c993e8ead1f3f99c4c5ea13bd5b1b5debdef0`.
- `fresh-cocoapods-result.json` records the second Flutter integration build.
- `packaging-final.log`: all 13 focused cases passed, including execution of the
  README phase, missing Xcode dependency rejection, escaped-path verification,
  and tamper rejection without host/helper changes.
- `harness-fresh-final.md`: structure, format, analysis, version, 10 docs tests,
  and the full suite passed (1,039 tests, 4 skipped). The workspace publish
  dry-run had only the five modified tracked files warning. The exact source
  export passed publish dry-run with zero warnings; the aggregate dirty-tree
  harness is not labelled passed.

The exact timing of the baseline metadata loss remains unresolved: subsequent
incremental rebuilds retained it even before adding the explicit dependency.
The dependency correction follows Xcode's documented build-order contract:
[Running custom scripts during a build](https://developer.apple.com/documentation/xcode/running-custom-scripts-during-a-build).
Do not describe that inference as a captured overwrite trace or as the cause of
the reporter's digest mismatch. The reporter's app and original post-update
file-selection scenario remain untested. No new release or push was performed.
The user subsequently authorized the diagnostic issue comment; its URL and
verified author/body are recorded in `reporter-diagnostic-comment-posted.json`.

All owned consumer checkouts, installed test app, remaining owned stage/journal
files, and generated .NET probe outputs were removed after retaining source,
artifact, and notarization evidence. No owned app/helper process or mounted DMG
remained. The unrelated dirty files and pre-existing recovery receipt were
verified byte-for-byte unchanged. Final documentation tests passed all 20 cases,
and `git diff --check` passed. See `fresh-cleanup-and-preservation.json`.

### Ad hoc override hypothesis follow-up

The user asked to check whether an ad hoc override can explain the repeated
build-time mismatch after regenerating the default policy. The issue was read
again; no reporter reply followed diagnostic request 6493345344. The earlier
shared Runner phase does not explicitly set ad hoc overrides, but effective
Xcode settings were not supplied. Their presence in the failing build remains
unconfirmed.

`verified locally`: an isolated export of the published `v3.2.7` commit
`16b56da31194b6b6af6d107f3ca79815b19282cd` exercised the actual CLI producer and
embed script. The CLI generated a valid normal pair and a separate ad hoc pair.
After changing the ad hoc source, its previously generated pin was deliberately
retained as the build input. The embed script selected that pair and emitted the
same mismatch as the report. Regenerating the normal pair left the ad hoc inputs
unchanged and reproduced the same failure. Using the new generated ad hoc pin
then passed real helper compilation, ad hoc signing, and layout verification.

Identity cases also passed: an expanded identity of `-` selects the overrides
even if `CODE_SIGN_IDENTITY` names Apple Development; an empty expanded value
falls back to `CODE_SIGN_IDENTITY`; a non-ad-hoc expanded value selects the normal
pair even when `CODE_SIGN_IDENTITY` is `-`. The non-ad-hoc case deliberately used
a wrong normal pin and stopped before signing, so it does not claim Developer ID
signing evidence. An old but internally matching policy/pin pair is not by
itself a hash mismatch.

Evidence in the same report directory:

- `reproduce-ad-hoc-override.py`: isolated published-source reproduction.
- `ad-hoc-override-result.json` and `ad-hoc-*.log`: six asserted cases, generated
  hash identities, and successful temporary-directory cleanup.
- `ad-hoc-focused-tests.log`: all 27 cases passed from
  `flutter test --no-pub --reporter expanded test/macos_helper_packaging_test.dart test/release_cli/helper_policy_command_test.dart`.

This check covers helper packaging, not another notarized update or the reporter's
application. It confirms a possible configuration cause without establishing
the customer's actual cause. No runtime code, version, release, or GitHub comment
was changed by this follow-up. The SDK documentation now states identity
precedence and distinguishes an old pair from a mismatched pair.

### Bundle metadata follow-up: reproduced and repaired

The reporter's new comment resolves the original hash failure: formatting the
generated JSON changed its bytes. The normal policy was selected. The separate
build 2 failure occurs in release preflight, before notarization, when the
helper's sealed identities do not match the app's final bundle metadata.

`verified locally`: a fresh Flutter SwiftPM consumer using pub.dev 3.2.7 and the
published README phase passed builds `1.0.0+1` and `1.0.0+2` with the phase always
running. With dependency analysis enabled and policy/script inputs plus helper
outputs declared (the example's configuration pattern), build 1 still passed.
On build 2, the helper phase finished successfully, then `ProcessInfoPlistFile`
regenerated the host plist and removed all four `DesktopUpdaterInstall*` fields.
The real 3.2.7 `MacOSReleaseTrust.preflight` rejected that bundle with exactly
`Bad state: Packaged helper policy does not match bundle metadata.` No plist
contents were manually removed to cause this failure.

Adding only `$(TARGET_BUILD_DIR)/$(INFOPLIST_PATH)` to the same phase's input
files made both builds pass. The logs show plist generation preceding the helper
phase, and all four fields survive in the final bundle. This is a captured
overwrite trace and supersedes the earlier inability to reproduce the timing.
It also verifies a configuration repair available to consumers on 3.2.7; the
reporter's exact phase inputs/outputs remain unavailable.

`verified locally`: a separate fresh CocoaPods consumer using the current local
source, current README phase, and the generated-plist input passed builds 1 and
2 plus real release preflight. The first attempt hit Xcode 27.1's rejection of
the Flutter template's macOS 10.15 deployment target in Pods. The owned fixture
was corrected to 12.0 in its Podfile and pod targets; the repository deployment
target was not changed. Both lanes used ad hoc signatures. This follow-up did
not run notarization, publication, or the app's update/file-selection scenario.

Package changes keep exact identity checks and now report each missing or
different field with bounded expected/actual values and rebuild guidance.
Regression assertions cover missing and wrong values for all four host fields,
and acceptance of an app build-number change without a policy revision. The
helper-policy command and README explicitly identify the source JSON as editable
and warn against formatting generated JSON. Existing generated-plist guards and
the example input dependency are retained.

Evidence is under `reports/releases/issue82-bundle-metadata-2026-10-29/`:

- `reproduce-flutter-builds.py`, `reproduce-phase-input.py`, `baseline-result.json`,
  and `phase-input-result.json`: fresh setup and failing/passing build matrix.
- `cached-build-2.log`: helper success followed by `ProcessInfoPlistFile` and
  final signing. `cached-build-2-Info.plist.txt` has no helper fields.
- `fixed-build-1.log`, `fixed-build-2.log`, and the retained final plists:
  corrected ordering and matching metadata with unchanged 3.2.7 package code.
- `cocoapods/fixed-result.json`: current-source CocoaPods builds and preflight.
- `metadata-diagnostics-before.log` and `metadata-diagnostics-after.log`:
  regression assertion failure against the generic message, then all 36 release
  trust tests passing. A prior test-edit compilation error is separately retained
  as `metadata-diagnostics-setup-error.log`.
- `patched-metadata-diagnostic.log`: the new diagnostic applied to a copy with
  the actual failing build's retained plist identifies all four missing fields.
- `harness-final.md`: structure, formatting, analysis, version, 10 docs tests,
  and all 1,039 tests passed (4 skipped). Publish dry-run's only warning was the
  eight modified tracked package files, so the aggregate dirty-tree harness is
  not labelled passed.
- `source-export.json` and `export-publish-dry-run.log`: an immutable HEAD export
  plus the named local overlays passed package validation with zero warnings.

The correction is local and uncommitted, with no new version, push, publication,
or GitHub comment. Keep reporter confirmation separate from local proof.

### Reporter confirmation

After the user authorized a reply, the repair was posted through the MarlonJD
keyring account in [comment 6496598916](https://github.com/MarlonJD/flutter_desktop_updater/issues/82#issuecomment-6496598916).
The reporter subsequently confirmed in [comment 6496938835](https://github.com/MarlonJD/flutter_desktop_updater/issues/82#issuecomment-6496938835)
that adding the generated-plist Input Files entry on **3.2.7** allowed publication
of `1.0.0+2`, successful installation of the `1.0.0+1 → 1.0.0+2` update, and normal
file access. This is reporter-confirmed app behavior, distinct from our local
test evidence; the comment does not separately establish notarization details.
The fetched comment is retained as `reporter-confirmation.json` in the bundle
metadata evidence directory. Automatic setup is tracked in the separate
[automatic setup plan](2026-10-29-macos-helper-automatic-setup.md).

## Revision history

- 2026-10-29: created for the renewed helper-policy mismatch report.
- 2026-10-29: reproduced the separate ad hoc override hypothesis with the
  published 3.2.7 producer and packager; customer inputs were still pending.
- 2026-10-29: the reporter identified formatting as the digest cause; reproduced
  and repaired the subsequent incremental-build metadata overwrite.
- 2026-10-29: posted the authorized repair and received reporter confirmation
  that 3.2.7 publication, update installation, and file access succeeded; closed
  this investigation and tracked automatic setup separately.
