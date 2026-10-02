# Project review — 2026-10-02

Reviewed the working tree at `7e14afb2bea54029443740d550bc1a3cd09cbb30`, including Dart runtime, widgets, release tooling, and selected native transport paths. Findings, runtime evidence, and line references describe that reviewed snapshot. A later read-only upstream comparison is recorded below; it does not extend the local runtime verification to a newer commit. Existing uncommitted macOS restart work was left untouched. No production source, existing tests, versions, lockfiles, or branches were changed.

This is a scoped engineering review, not an exhaustive security audit or production certification. P1 means address before the next release; P2 means a concrete correctness or reliability fix.

## Upstream comparison before publication

The local checkout was 33 commits behind `origin/main` at `a415bd5` when this note was prepared for publication. The source files cited by F01–F06 and F08–F10 are unchanged between the reviewed snapshot and that upstream commit. F07's store has newer process handling, but its ciphertext comparison remains unchanged. Upstream adds a real Windows DPAPI round-trip test; it does not repeat the same write or import. No finding was marked fixed based on this source comparison, and no tests were rerun against the upstream checkout.

## Findings reproduced locally

### F01 · P1 · Repeated installation overwrites the recovery transaction

Source: [updater_controller.dart:764](https://github.com/MarlonJD/flutter_desktop_updater/blob/7e14afb2bea54029443740d550bc1a3cd09cbb30/lib/updater_controller.dart#L764), [update_client.dart:95](https://github.com/MarlonJD/flutter_desktop_updater/blob/7e14afb2bea54029443740d550bc1a3cd09cbb30/lib/src/core/update_client.dart#L95).

`restartApp()` writes a new pending transaction before attempting to claim the staged update. After one dispatch, that stage remains consumed. A second call therefore overwrites the persisted transaction and then throws because the stage was already claimed. The recovery marker now identifies a transaction the native installer never received.

The local regression completed one dispatch, attempted another, and observed different IDs in the persisted marker and the original native request. The existing concurrent-dispatch test checks only platform call count, so it misses this invariant.

The macOS approval retry buttons also call `restartApp()` on the consumed stage. An approval-required response therefore needs an explicit recovery/retry path, not a blind second dispatch. That platform-specific scenario was traced in source; it was not run against a real helper.

**Fix:** serialize install attempts before persistence, preserve the original receipt after ambiguous native outcomes, and obtain authenticated recovery evidence before authorizing another dispatch. Test both repeated calls and permission-denied-then-approved behavior.

### F02 · P1 · Channels and build numbers share release paths

Source: [publish_layout.dart:62](https://github.com/MarlonJD/flutter_desktop_updater/blob/7e14afb2bea54029443740d550bc1a3cd09cbb30/lib/src/release_cli/publish_layout.dart#L62), [release_publisher.dart:224](https://github.com/MarlonJD/flutter_desktop_updater/blob/7e14afb2bea54029443740d550bc1a3cd09cbb30/lib/src/release_cli/release_publisher.dart#L224).

Release paths contain only `version/platform`. Build number and channel are separate metadata fields and separate archive slots, but do not participate in descriptor or artifact URLs. Publishing stable and beta for the same version overwrites the same descriptor. Publishing build 2 after build 1 does likewise. Existing archive entries can then resolve to mismatching metadata, and immutable caches can retain old bytes at the reused URLs.

Two local `ReleasePublisher` regressions confirmed that both channel changes and build-number changes return identical descriptor URLs. Packaging was mocked; no remote publication occurred.

**Fix:** include the complete release identity in immutable paths and reject accidental replacement. Test multiple releases within one feed, including channel and build-number variants.

### F03 · P2 · HTTP timeout excludes response bodies

Source: [http_update_transport.dart:167](https://github.com/MarlonJD/flutter_desktop_updater/blob/7e14afb2bea54029443740d550bc1a3cd09cbb30/lib/src/io/http_update_transport.dart#L167).

The timeout applies only to `_client.send()`. Successful body streaming and unsuccessful response draining run without a deadline. A server can send headers and then stall indefinitely, leaving checking/downloading stuck without retry or cleanup.

Local regressions returned headers immediately and delayed the body for 250 ms with a 20 ms timeout. HTTP 200 completed successfully and HTTP 503 produced an HTTP error after the body finished; neither produced the required timeout.

**Fix:** bound and cancel body consumption and error draining, then perform retry and partial-file cleanup. Merely wrapping the outer future without cancelling the stream would leave work running.

### F04 · P2 · Direct UpdateCard misses the first available update

Source: [update_card.dart:34](https://github.com/MarlonJD/flutter_desktop_updater/blob/7e14afb2bea54029443740d550bc1a3cd09cbb30/lib/widget/update_card.dart#L34).

When `UpdateCard(controller: controller)` first builds in `UpdateIdle`, it returns before creating `ListenableBuilder`. It consequently has no subscription to rebuild when the controller later reports an update, unless its parent independently rebuilds. The inherited wrapper masks this problem, explaining why the existing wrapper test passes.

**Fix:** always subscribe when a controller exists, and evaluate state visibility inside the listener. The local idle-to-available regression found no Download button.

### F05 · P2 · Skip action leaves the update dialog open

Source: [update_dialog.dart:634](https://github.com/MarlonJD/flutter_desktop_updater/blob/7e14afb2bea54029443740d550bc1a3cd09cbb30/lib/widget/update_dialog.dart#L634); the optional fresh-install action has the same pattern at line 607.

The button sets `skipUpdate`, but neither closes the route nor makes `UpdateDialogWidget` disappear. `UpdateDialogListener` only prevents opening future dialogs. The visible dialog remains and still presents update actions.

**Fix:** dismiss the owned route after a successful skip, with appropriate mounted/route checks. The local regression confirmed `skipUpdate == true` while an `AlertDialog` remained visible.

### F06 · P2 · Sliver/wrapper hides failures and recovery actions

Source: [update_sliver.dart:59](https://github.com/MarlonJD/flutter_desktop_updater/blob/7e14afb2bea54029443740d550bc1a3cd09cbb30/lib/widget/update_sliver.dart#L59).

The visibility switch excludes `UpdateFailed`, although `UpdateCard` implements failure details, retry, report, and macOS approval controls. `DesktopUpdateWidget` uses this sliver, so a failure removes the entire recovery UI.

**Fix:** retain the card for failed states and test download/install failure transitions through the actual public wrappers. The local regression found no Check again action after transitioning to failure.

## Additional findings from source inspection

The following were not executed on Windows or Linux target hosts.

### F07 · P2 · Windows key reimport compares randomized ciphertext

Source: [release_key_store.dart:246](https://github.com/MarlonJD/flutter_desktop_updater/blob/7e14afb2bea54029443740d550bc1a3cd09cbb30/lib/src/release_cli/keys/release_key_store.dart#L246), [release_key_manager.dart:341](https://github.com/MarlonJD/flutter_desktop_updater/blob/7e14afb2bea54029443740d550bc1a3cd09cbb30/lib/src/release_cli/keys/release_key_manager.dart#L341).

The DPAPI store encrypts the incoming seed again and compares the resulting ciphertext to the stored ciphertext. DPAPI derives its protection key using random data, so equal plaintext does not imply equal protected blobs. Reimporting an identical backup can therefore fail with “A different private key already exists.” This conclusion follows from the code and [Microsoft's DPAPI description](https://learn.microsoft.com/en-us/previous-versions/ms995355%28v%3Dmsdn.10%29).

**Fix:** decrypt the existing entry and compare seed bytes, preserving the existing blob when equal. Add a Windows round-trip and identical-backup reimport test; current tests use the local-file store.

### F08 · P2 · Native retries append HTTP error bodies to artifacts

Source: [update_transport_curl.cc:87](https://github.com/MarlonJD/flutter_desktop_updater/blob/7e14afb2bea54029443740d550bc1a3cd09cbb30/linux/native/src/runtime/update_transport_curl.cc#L87), [update_transport_winhttp.cpp:285](https://github.com/MarlonJD/flutter_desktop_updater/blob/7e14afb2bea54029443740d550bc1a3cd09cbb30/windows/native/src/runtime/update_transport_winhttp.cpp#L285).

In the opt-in native runtime, a 503/429 error body can be written into `.part`. The next attempt resumes from that error-body length; a subsequent 206 appends the actual artifact suffix. SHA-256 verification rejects the result, so a transient service failure becomes a failed update. Integrity checks still prevent installation of the corrupted artifact.

**Fix:** validate response status before accepting artifact bytes, preserving only legitimate partial content. Test an artifact response of 503 with a body followed by a valid range response.

### F09 · P2 · Windows resume cannot handle a server ignoring Range

Source: [update_transport_winhttp.cpp:401](https://github.com/MarlonJD/flutter_desktop_updater/blob/7e14afb2bea54029443740d550bc1a3cd09cbb30/windows/native/src/runtime/update_transport_winhttp.cpp#L401), byte-limit check at line 285.

With a nonempty `.part`, `Perform()` limits received bytes to the remaining artifact length. If the server ignores Range and returns the full file with 200, the byte limit throws before the caller reaches its intended delete-and-restart branch. Subsequent attempts retain the same failure condition.

**Fix:** inspect status and reset the destination before streaming a full 200 response. Add a seeded-partial/ignored-Range transport test.

### F10 · P2 · Windows metadata retries multiply through the redirect loop

Source: [update_transport_winhttp.cpp:345](https://github.com/MarlonJD/flutter_desktop_updater/blob/7e14afb2bea54029443740d550bc1a3cd09cbb30/windows/native/src/runtime/update_transport_winhttp.cpp#L345).

If all responses are successfully received retryable HTTP statuses, exhausting the inner retry loop advances the outer redirect loop without an actual redirect. Default settings allow 18 requests instead of three, then report a misleading redirect-limit error.

**Fix:** throw after status retries are exhausted and advance the redirect loop only after a redirect. Test request count and error classification for repeated 503 responses.

## Development priorities

1. Fix installation transaction ownership and immutable publication identity first (F01–F02).
2. Add real asynchronous transition tests alongside existing state-snapshot tests: initial idle, failure, skip, retry, overlapping check/download, and retained recovery identity.
3. Extend native transport fixtures with artifact error bodies, ignored Range, and exhausted retries. The current metadata-retry and successful-206 cases miss these failures.
4. Complete the documented S3/SFTP conditional-publication adapters, or reject unsupported capabilities before building/uploading files. The current capability checks happen during index publication, after versioned uploads. This is already recorded project debt, not an additional newly discovered defect.

## Verification

- **Verified locally:** 78 existing tests across `update_dialog_listener_test.dart`, `update_ready_ui_test.dart`, `release_notes_bottom_sheet_test.dart`, `updater_controller_test.dart`, `update_transport_test.dart`, `publish_layout_test.dart`, and `release_key_management_test.dart` passed.
- **Verified locally:** eight temporary regression cases failed on the intended assertions, reproducing F01–F06. These are evidence of existing defects, not successful fixes.
- Initial sandbox attempts were blocked by Flutter SDK/cache access and then local socket permissions. Successful runs used the already-installed Flutter tools snapshot, disabled analytics/version checking, and ran outside the sandbox to permit the local test server.
- **Not run:** full Flutter suite, repository-wide analysis, package publish dry-run, native target-host tests, signed/elevated installers, or hosted publication.
- No task-owned Flutter test processes remained after completion.

The temporary regression tests were kept outside the repository after execution. The durable observations are recorded below; these notes do not depend on temporary local paths.

| Regression scenario | Expected behavior | Observed behavior |
| --- | --- | --- |
| Repeated install | Pending transaction ID remains the native-dispatched ID | A new pending ID replaced the dispatched ID before the repeated call failed |
| Stable and beta with the same version | Different release descriptor URLs | Both used `releases/2.1.0/windows/release.json` |
| Build 1 and build 2 with the same version | Different release descriptor URLs | Both used `releases/2.1.0/windows/release.json` |
| HTTP 200 with a delayed body | 20 ms timeout interrupts a 250 ms body delay | Download completed successfully after the delay |
| HTTP 503 with a delayed body | 20 ms timeout interrupts a 250 ms body delay | HTTP error was emitted only after body consumption |
| Direct card, idle to available | Download action becomes visible | No Download action was found |
| Skip from listener dialog | Dialog closes after skip | Skip flag was set but one dialog remained |
| Wrapper, available to failed | Check again action stays visible | No Check again action was found |
