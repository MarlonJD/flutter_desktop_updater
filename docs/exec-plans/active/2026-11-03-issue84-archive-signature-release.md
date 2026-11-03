# Issue 84 archive signature diagnostics and patch release

## Context and acceptance

Continue the authorized implementation and release on existing main, initially
`3dcbc0e2bc7362ffd1206d3a494384402b5c773e`. Preserve the unrelated `.gitignore`
change, two old 2.x plans, and their ledger entries. The user authorized scoped
commits, normal pushes, a new immutable patch release, CI target-host validation,
and fresh local notarized macOS E2E. No branch operations are authorized.
Release publication remains on hold. The later explicit authorization to post
the read-only diagnostic script via GitHub CLI is recorded below.

The reporter's redacted archive cannot establish the cryptographic cause.
The confirmed defect is that local and hosted signature failures both report
`Hosted app-archive.json signature verification failed.` Identify the actual
source and key ID, distinguish determinable failure categories, and preserve
signature verification, byte/revision guards, immutable identities, and
validation before build/output mutation.

## Progress

- [x] Read repository guidance, issue discussion, history, and current CI/tags.
- [x] Reproduce ambiguous errors with focused regression tests.
- [x] Implement source-aware diagnostics and document supported recovery.
- [x] Verify valid cross-platform history and malformed/untrusted inputs.
- [x] Run focused tests and the full local harness on an immutable export.
- [x] Obtain Windows/Linux CI evidence and fresh local notarized macOS E2E.
- [x] Post the explicitly authorized diagnostic script and request original Mac/Windows evidence.
- [x] Verify cross-host and cross-version archive transfer in dedicated CI.
- [ ] Obtain the reporter's original Mac/Windows comparison before resolving the release hold.
- [ ] Publish the next unused patch and verify registry/tag/package identity.
- [ ] Complete the ledger, draft reporter reply, and clean owned fixtures.

## Decision Log

- Keep the existing cryptographic verifier and canonical signature contract.
  Diagnostics must not bypass trust or claim that a mismatch proves a wrong key.
- Cover absent/present hosted archives, same-path local input, matching and
  differing snapshots, malformed JSON/schema/signatures, unknown IDs, wrong
  public keys, and signed-content tampering. Verify no build/hooks/output writes
  on rejected inputs. Exercise spaces, Unicode, and native Windows paths.
- Keep generated evidence in ignored `reports/releases/desktop_updater-3.2.11/`.
  Stage only task-owned source, tests, docs, and release metadata.
- Use `general-notary` with default Keychain resolution. Old 3.2.10 results
  provide reusable procedures only, not evidence for this release.

## Verification and recovery

Start with `flutter test --no-pub test/release_cli/release_publisher_build_test.dart`,
then release CLI tests, `dart run tool/harness_check.dart`, native macOS tests,
and the repository's Windows/Linux publishing lanes on the exact release commit.
Use an immutable source export so ignored historical scripts do not affect
formatting, analysis, or package contents. Recheck remote HEAD, version and tag
availability, staged scope, and outgoing commits before publishing. Never move
an existing tag or overwrite a published version. Read back uncertain external
writes before retrying. Clean only the recorded disposable app, mounts, processes,
and temporary roots after acceptance and publication.

## Surprises & Discoveries

- Both archive sources call the same verifier; hosted history is fetched and
  verified before the explicitly selected local file is read.
- The 3.2.10 release CI runs now report success. They do not validate new work.

## Outcomes & Retrospective

The diagnostic implementation and bounded local/CI checks are complete.
Release publication remains on the user's explicit hold. The supplied archive
fails verification, but its original generation cause is unconfirmed; original
Mac/Windows comparisons and generation commands/version remain outstanding.

## Revision history

- 2026-11-03: Created the scoped continuation plan after live preflight.

### Implementation evidence

The unknown-key regression failed against the unmodified 3.2.10 publisher
because a local input was labeled Hosted. The fixed publisher retains the same
verifier and diagnoses only rejected inputs. Coverage includes 18 successful
history/path/platform combinations and 48 source/category rejection cases,
plus byte-only snapshot mismatch and invalid initialization of a present feed.
The real hosted and local source locations are included without printing the
raw document or signature. CI runs these publisher tests on each CLI host.

Pub.dev reports 3.2.11 absent; `general-notary` default-resolution history
access passed. The candidate version is 3.2.11. Generated native version source
files are release metadata and will be committed; QA artifacts remain ignored.

The first complete candidate harness exposed four release-version expectations
that the version generator does not own (README and source-shape tests); these
are synchronized to 3.2.11 along with the native helper test and example lock.
Two Swift negative-compilation tests require the source directory basename
`flutter_desktop_updater`; rerun the immutable export with that basename. The
initial failure report is retained separately. All 393 release CLI tests and
the real CLI/HTTP/ZIP/signing smoke passed. The latter retained three macOS
records while adding Windows and then Linux, and distinguished hosted/local
unknown-key failures with exit 64 and unchanged output.

The complete local harness on f7d2482 passed (1,144 tests, 4 skipped), as did
155 macOS native tests and 6 helper-version tests. Windows CI executed every
new archive case successfully but exposed an existing DMG test expectation
that compared a mixed-separator path with a native Windows path. Normalize
the test's path construction by joining URL path segments; production code
already emitted the correct native path. Keep the failed CI log and rerun on
the final test-corrected commit before publishing.

### Final candidate evidence

The release candidate is `bdd7377b81a43f16907c3845f3ba8ef6c4e0364c`. Its
complete local harness passed with 1,144 tests and 4 optional skips, format,
analysis, version consistency, structural 31/31, 10 harness documentation tests,
and a zero-warning publish dry run. The 155 native macOS tests and 6 helper
version tests passed again. All 869 expected package paths are unchanged from
3.2.10; only excluded documentation paths were added/moved. All tracked export
bytes match the candidate commit.

Real CLI/HTTP/ZIP/Ed25519 evidence passed: invalid hosted and local inputs return
64 without output mutation, and three macOS history records survive Windows
and then Linux additions. A real macOS CLI run packaged a fresh notarized app
and retained the signed Windows history with a valid final archive signature.

Fresh local same-user DMG update/relaunch passed from 1.0.0+1 to 1.0.0+2.
Apple accepted app build 1 `97b027b8-78e5-46dd-b3e6-ae659a7bc48b`, app build 2
`c5370a5b-5f70-40c0-8507-bcb75a7f45d3`, and DMG
`6db4d142-efa7-437c-b430-419fb59e0e3f`. The initial process exited 0 and the
replacement PID was distinct. Strict signature, stapling, Gatekeeper, embedded
helper metadata, and unchanged helper policy checks passed. The unrelated
recovery receipt and source export were preserved; no owned app process or
DMG mount remained. Build 1 preceded the final test-only commit, whose only
changes were the DMG test assertion and this plan; all app build inputs were
byte-identical.

Exact-candidate full CI: https://github.com/MarlonJD/flutter_desktop_updater/actions/runs/41629264550 .
All four standalone CLI hosts passed the 102 publisher tests, including native
Windows separators. Dart/package and documentation jobs passed. The larger
Windows/Linux application builds and publishing smoke lanes remain pending at
this checkpoint. Superseded/duplicate task runs were cancelled to free runners.

Publication and cleanup are pending. Disposable roots are
`/private/tmp/desktop-updater-3.2.11-validation-20261103`,
`/private/tmp/desktop-updater-3.2.11-final-20261103`,
`/private/tmp/desktop-updater-release-3211-20261103`, and
`/private/tmp/desktop-updater-release-3211-final-20261103`; the installed fixture
is `/Applications/Desktop Updater Release 3211.app`. Retain the ignored QA
evidence and remove only these owned roots after verified publication.

### User publication hold

On 2026-11-03 the user explicitly asked to wait for the reporter's new comment
and evaluate it before publishing. Release publication is paused at that
boundary. Version 3.2.11 has not been published and no v3.2.11 tag has been
created. Existing CI may finish, but do not publish until the new reporter
evidence has been reviewed against the fix and this hold has been resolved.
Keep the candidate and evidence intact; no issue reply or closure is authorized.

The latest live discussion includes reporter comment 6602705614 confirming
that the hosted archive returns HTTP 404 and asking whether the public profile
should be shared unmasked. Maintainer comment 6602907167 requests intact public
key IDs/values from both machines and the unchanged original signed archive.
Those new cryptographic inputs have not arrived at this checkpoint. The
comment draft in ignored reports predates those externally posted replies and
should not be posted again. No comments were posted by this task.

### Reporter attachment investigation

Reporter comment 6603155097 supplied one public profile and the unredacted
archive. Preserve attachment SHA-256
`a7e5aa70db087707b3143125f0525d016b91372f1b3d8ef53e5db9d42c526e1e`;
a read-only copy and bounded scripts/results are under
`reports/releases/issue84-reporter-signature-2026-11-03/flow-investigation/`.
The key ID matches the public-key fingerprint, lengths are correct, and both
the package verifier and OpenSSL reject the signature. All eight item subsets
fail. Five formatting/key-order/line-ending encodings retain identical
canonical bytes; formatting alone does not explain it.

Ten real CLI publications (three macOS builds, Windows, then Linux; with and
without an archive-mutating post-package hook) all emitted valid signatures
and preserved history. Six profile-backed signing/normalization variants
passed. Low-level upsert refused signed input unchanged. OpenSSL accepted a
CLI-generated positive control. The archive signing components are identical
across 18 published 3.1/3.2 tags and current HEAD. A controlled post-sign edit
reproduces rejection, but no external edit by the reporter is proven. No
additional product bug was identified; the specific generation cause remains
unresolved. See findings.md and the concise next-reporter-comment-draft.md.

Request original Mac bytes, exact generation commands/version, any deliberate
content merges/edits, confirmation of the same supplied public profile, and
Mac/Windows file hashes. Do not re-request already supplied public data or
secrets. Re-signing is only a possible recovery after preserving evidence,
not a causal finding. A recovery comment (6603396994) was posted externally
while this investigation ran; this task posted nothing. Publication stays on
hold while the original cause is unresolved.

The exact-candidate CI run 41629264550 has now completed successfully, including
real Windows and Linux release publish smoke steps. Credentialed privileged
lanes remained skipped. No production code or release identity changed during
this evidence-only investigation.

### Further causal investigation requested by the maintainer

The latest reporter comment, 6603468146, says the Mac is currently unavailable
and the investigation must wait until tomorrow. Publication remains on hold.
The public attachment was fetched again; its bytes match the preserved original.
The archive endpoint and its three referenced release descriptors all returned
HTTP 404, so no hosted original was available for comparison.

The exact reporter archive was supplied to the real publisher's public
verification preflight. It was rejected before build, packaging, or output
mutation; the input remained byte-identical and no new output files appeared.
This establishes that the reported failing invocation encounters an existing
mismatch. It does not identify the earlier event that created it.

Controlled real CLI failures before packaging, after packaging, and after
signing respectively left the original valid archive, an unsigned updated
archive, and a valid updated archive. None retained an old signature on new
content. These are bounded synthetic application/ZIP checks on macOS, not a
reproduction of the reporter's unknown generating workflow.

An independent Node verifier accepted the supported-CLI positive control and
rejected 18,728 distinct bounded payload reconstructions covering item subsets
and permutations plus selected app-name, URL, platform, and mandatory changes.
No match was found. This excludes only the enumerated inputs and is not proof
of an external edit. Earlier source inspection also found unchanged archive
canonicalization; historical direct-key selection remains an unconfirmed
possibility only if the unknown original generation used such a version.

The ignored evidence directory now includes `causal-probes/README.md` and the
read-only `diagnose_archive.dart` handoff. It reports raw/canonical hashes,
public-key fingerprints, archive and contained descriptor signature results,
and resolved dependency versions. Reporter input, valid signed control, and
deliberately edited control produced the expected results without input writes.
The diagnostic itself was verified locally on macOS; reporter Windows execution
is not run. Original Mac and Windows diagnostics, original generation commands,
and the package version at generation remain the discriminating evidence.
No product code, release identity, GitHub feedback, or publication changed.

### Authorized reporter handoff and independent CI investigation

The user explicitly authorized sharing the read-only script in the issue,
requesting both Mac and Windows outputs, and preserving the original files
before re-signing. Posted through the maintainer's sanitized GitHub CLI/keyring
session and read back byte-for-byte:
https://github.com/MarlonJD/flutter_desktop_updater/issues/84#issuecomment-6603900915 .
The author is MarlonJD; no connector identity was used. The package release
remains on hold.

The user also requested further synthetic/CI investigation without waiting for
the reporter. Add a manual, secretless archive interoperability workflow with
four native host producers/readers and three package versions: actual pub.dev
3.2.9, actual pub.dev 3.2.10, and the current candidate. Transfer signed archive
and descriptor bytes across jobs; compare producer hashes and canonical bytes,
verify signatures, extend transferred history through the real ZIP publisher,
and reject deliberate content changes without output mutation. Keep HTTP
simulation and synthetic application input explicit. This scope authorizes CI
test commits/pushes, not package publication or branch operations.

Local macOS production and consumption passed across all three versions: 180
case records, including 27 history extensions and 18 tampering rejections. The
posted read-only diagnostic accepted a signed control under all three package
versions without changing input files. Dart analysis has no errors/warnings,
Python/YAML syntax checks passed, the structural gate passed 31/31, and 15
focused harness/native documentation tests passed. Exact-head target-host CI
results are pending. The workflow cannot establish the reporter's original
input or signing key; it can expose reproducible platform, dependency,
transfer, and publication defects independently.

### Cross-host CI results

The interoperability workflow completed successfully at source commit
`1be56844a3a50d05ae918a6a631496491d140c9b`:
https://github.com/MarlonJD/flutter_desktop_updater/actions/runs/41638061915 .
All eight host jobs passed. Twelve producer fixtures (four hosts times three
package versions) were consumed by twelve reader combinations. Downloaded
artifacts contain 2,880 passing case records: 1,728 archive verification cases,
432 descriptor verifications, 432 history extensions, and 288 deliberate
signed-content changes rejected before output mutation. Each reader report
contains all twelve producers; artifact bytes match producer hashes.

The reporter diagnostic passed its signed positive control on all twelve
producer combinations, including Windows x64 with CurrentUser DPAPI. Actual
runner architecture was confirmed from Dart runtime metadata. Node/OpenSSL
independently accepted all 72 transferred archive/descriptor signatures and
rejected an edited control for each. The reporter's original attachment remains
unchanged. Aggregated evidence is in ignored
`reports/releases/issue84-reporter-signature-2026-11-03/ci-artifacts/summary.json`.

Actual pub.dev 3.2.9/3.2.10 sources and the candidate share identical archive
model, canonicalization/verifier, and signing command bytes. The published
consumer environments resolved crypto 3.0.8 and archive 4.6.0 while the local
candidate lock resolved crypto 3.0.7 and archive 4.0.9; all used
cryptography_plus 2.7.1. Exact per-host dependency versions and source hashes
are retained in producer/reader artifacts.

This narrows the tested host, package-version, dependency, formatting, transfer,
key-store, and archive-extension causes. It does not prove an external edit or
reconstruct the reporter's unknown input. The general full CI run 41638062549
had passed Dart/package, documentation, and all four CLI candidates at this
checkpoint; its longer native application lanes were still running. No package
release or version tag was published.
