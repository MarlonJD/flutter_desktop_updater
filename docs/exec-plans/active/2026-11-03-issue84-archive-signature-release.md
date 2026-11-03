# Issue 84 archive signature diagnostics and patch release

## Context and acceptance

Continue the authorized implementation and release on existing main, initially
`3dcbc0e2bc7362ffd1206d3a494384402b5c773e`. Preserve the unrelated `.gitignore`
change, two old 2.x plans, and their ledger entries. The user authorized scoped
commits, normal pushes, a new immutable patch release, CI target-host validation,
and fresh local notarized macOS E2E. No branch operations or GitHub feedback
writes are authorized. Prepare an English reporter comment without posting it.

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
- [ ] Run focused tests and the full local harness on an immutable export.
- [ ] Obtain Windows/Linux CI evidence and fresh local notarized macOS E2E.
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

Implementation and release pending. Reporter-specific cryptographic cause is
unconfirmed; public profiles and unedited source data are still needed.

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
