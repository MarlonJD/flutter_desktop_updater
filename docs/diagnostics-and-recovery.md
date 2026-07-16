# Diagnostics And Recovery

This page explains where update logs are written, how diagnostics flow through
the updater, and how an app should wire support collection.

## Where Logs Go

The package writes no caller-selected log files by default. It keeps a bounded
in-memory diagnostics report for failures. Your app decides whether app-owned
diagnostics become a file, database row, support attachment, or upload. The
standalone helpers separately use fixed platform-owned sinks described below.

| Surface | Default location | Who chooses storage | When it is written | How to use it |
| --- | --- | --- | --- | --- |
| In-memory problem report | No path | Package keeps it in memory | When check, download, verify, stage, or install handoff fails | Show/copy `UpdateFailed.report.toPlainText()` or use `onProblemReport` after a user action |
| Dart lifecycle log | No path unless your app supplies a sink | Your `UpdateDiagnosticsSink` | While the Flutter process is running update checks, downloads, verification, staging, and native handoff | Persist redacted `UpdateDiagnosticEntry` lines in your app-owned support location |
| Native helper log | Windows Application Event Log; Linux syslog plus helper-owned `events.jsonl` | The helper selects a fixed `platformLog` sink; the caller does not provide a path | After the app process hands off install, rollback, cleanup, recovery, and relaunch work | Collect the platform log with user consent; do not expect a caller-selected JSONL file |
| Pending install recovery marker | No marker unless your app supplies a store | Your `UpdateRecoveryStore` | Immediately before native install handoff, then cleared after a verified relaunch | Turn "the app relaunched but stayed on the old version" into `UpdateFailed(report)` on next startup |
| Cleanup report | In memory on the controller | Optional `onCleanupReport` callback | After install scheduling or cleanup evidence is available | Save scheduling or cleanup evidence in your app-owned audit trail |

## Recommended Setup

Start with the default in-memory problem report. Add durable logs only when your
support workflow needs them.

1. **In-memory problem report only.** Use the default problem report for
   ordinary UI support.
2. **App-owned Dart lifecycle log.** Add a Dart lifecycle sink when support
   needs a durable update flow log.
3. **Platform helper log plus recovery store.** Add `UpdateRecoveryStore` when
   support needs post-relaunch state and collect the platform-owned helper log
   when post-exit evidence is required.

Do not present `diagnosticsLogPath` as the destination of standalone helper
events. Pick an app-owned support directory for your Dart diagnostics sink,
show that path in your own Settings or support UI, and own retention, rotation,
encryption, and upload consent.

## macOS Privileged Helper Approval

macOS directory-replacement updates use the bundled helper without elevation
when the target parent is writable. That unprivileged path does not register a
background item. A protected directory target uses the signed `SMAppService`
daemon on macOS 13 or later. PKG `macosInstaller` +
`verifiedInstallerHandoff` always uses the daemon because its fixed
`/usr/sbin/installer` operation requires root. The daemon path
fails before mutation until an administrator approves it in System Settings.
Approval is a protected-target setup gate, not an expected prompt for every
ordinary update. The updater reuses an enabled daemon. When ServiceManagement
requires a daemon refresh, it waits for asynchronous unregistration to finish
before registering again so an existing approval is preserved. If the user or
an administrator revoked approval, macOS requires explicit approval again and
the updater reports the same stable error without mutating the target.

The MethodChannel reports this gate as a `PlatformException` with the stable
code `PrivilegedHelperApprovalRequired`. Custom UI can distinguish it without
matching localized text:

```dart
try {
  await controller.restartApp();
} on Object catch (error) {
  if (isMacOSPrivilegedHelperApprovalRequiredError(error)) {
    await controller.openMacOSBackgroundItemsSettings();
    return;
  }
  rethrow;
}
```

`openMacOSBackgroundItemsSettings` opens System Settings > General > Login
Items & Extensions. It does not grant approval itself. Ask the user to enable
the app, return to the update UI, and retry the same staged update. Other
install failures keep their existing error codes and diagnostics behavior.

## Dart Lifecycle Log

`UpdateDiagnosticsRecorder` records bounded entries in memory. If you also pass
a sink, the same entries are forwarded to your app. Sink failures are ignored so
logging cannot break update checks or installs.

```dart
import "dart:io";

class AppUpdateLogSink implements UpdateDiagnosticsSink {
  AppUpdateLogSink(this.file);

  final File file;

  @override
  void record(UpdateDiagnosticEntry entry) {
    file.writeAsStringSync(
      "${entry.toRedactedLogLine()}\n",
      mode: FileMode.append,
      flush: true,
    );
  }
}

final dartLogFile = File("${appOwnedSupportDir.path}/update-lifecycle.log");
await dartLogFile.parent.create(recursive: true);

final controller = DesktopUpdaterController(
  appArchiveUrl: archiveUrl,
  diagnosticsRecorder: UpdateDiagnosticsRecorder(
    sink: AppUpdateLogSink(dartLogFile),
  ),
);
```

Use `UpdateDiagnosticEntry.toRedactedLogLine()` for file-oriented sinks. It
redacts obvious token, signature, password, secret, authorization, credential,
and key assignments before writing the line.

## Native Helper Log

Native helper logging is separate from the Dart lifecycle log. It starts only
after the app hands off to the platform helper, so it is useful for
locked-file replacement, rollback, cleanup, and relaunch failures.

`diagnosticsLogPath` remains a compatibility input for existing Flutter and
native callers, but the versioned standalone request converts diagnostics to a
fixed `platformLog` destination. The standalone protocol-v1 Windows and Linux
helpers do not receive, open, create, append to, or otherwise use that
caller-provided path. App-owned Dart diagnostics and the package's in-memory
problem report remain available before the helper handoff.

For an app-owned durable file, configure `UpdateDiagnosticsRecorder` as shown
above. Existing code may keep passing `diagnosticsLogPath` while migrating:

```dart
final helperLogFile =
    File("${appOwnedSupportDir.path}/update-helper.jsonl");
await helperLogFile.parent.create(recursive: true);

final controller = DesktopUpdaterController(
  appArchiveUrl: archiveUrl,
  diagnosticsLogPath: helperLogFile.path,
);
```

The standalone protocol-v1 Windows helper emits best-effort support events to
the Windows Application Event Log
under the source `DesktopUpdater.InstallHelper.ProtocolV1`. It writes only
fixed protocol-v1 event names and IDs (1000 through 1016): no caller-provided
text, paths, tokens, headers, or transaction payloads are accepted by this
sink. An Event Log write failure never changes install or recovery outcome.
Windows UAC and real helper execution: `not run`.

The Linux helper writes the same bounded support facts with the
`desktop-updater-helper` syslog identity and appends one JSON object per line to
helper-owned `events.jsonl` inside its transaction registry. Broker mode uses
the root-owned registry; portable mode uses the exact user's protected state
registry. The file is mode `0600`, accepts no caller-selected destination, and
is support evidence rather than transaction authority. Example Linux entries
have this shape:

```jsonl
{"detailCode":"none","event":"helper authenticated","journalState":"preparing","packageId":"com.example.app","targetClass":"systemInstallRoot","targetName":"example","timestampUnixMilliseconds":1784157330000,"transactionId":"00000000-0000-4000-8000-000000000001"}
{"detailCode":"none","event":"transaction completed","journalState":"completed","packageId":"com.example.app","targetClass":"systemInstallRoot","targetName":"example","timestampUnixMilliseconds":1784157335000,"transactionId":"00000000-0000-4000-8000-000000000001"}
```

Fixed Windows Event Log names include:

- `helper scheduled`
- `waiting for parent process`
- `parent process exited`
- `staging path validation`
- `backup start`, `backup success`, `backup failure`
- `move start`, `move success`, `move failure`
- `rollback start`, `rollback success`, `rollback failure`
- `cleanup start`, `cleanup success`, `cleanup failure`
- `relaunch attempt`

Fixed Linux names include `helper authenticated`, `target lock acquired`,
`transaction journal persisted`, `caller exit observed`, `recovery detected`,
`backup restored`, `activation verified`, `package manager state verified`,
`manual action required`, and `transaction completed`.

Platform-log failures are ignored and never change install, rollback, cleanup,
recovery, or relaunch outcome.

On Windows, a machine-wide install under `Program Files` may require UAC. Both
portable and elevated standalone requests use the fixed Event Log sink. If the
user cancels the UAC prompt, the app remains open and `installUpdate` returns
an `InstallError`; no post-exit helper starts.

Protected Windows recovery and relaunch have different guarantees. The helper
durably completes or rolls back the filesystem transaction, then makes one
best-effort relaunch attempt with the caller token captured before exit. It
persists pending, attempting, launched, or failed relaunch state and reports
success only after the launch call and the `launched` state are both durable.
A crash in the irreducible process-creation acknowledgement window is reported
as `relaunchFailure`; it is not retried automatically because a retry could
create a duplicate app process. The user can safely start the already verified
new or restored old application manually. The updater does not claim
exactly-once process launch.

Before staging a new update, the Dart update client removes old
`desktop_updater_stage_*` directories from the staging parent when they are
older than the bounded stale-staging window. Recent staging directories are left
alone so a user who downloaded an update but has not installed it yet does not
lose the staged update.

## Recovery Store

Platform helper diagnostics tell you what happened inside the helper. They do
not by themselves decide whether the next app launch succeeded. Add an
`UpdateRecoveryStore` when you want the next startup to detect unfinished or
unverified installs.

Flutter `UpdateRecoveryStore` is not a native transaction journal. It records
an app-owned expectation across relaunch; it does not provide a cross-process
target lock, fsynced transaction states, or deterministic recovery after a
native helper is killed between filesystem mutations. The standalone helpers
now own that separate durable native transaction journal and recover a pending
transaction to a restored old target or completed new target. Do not interpret
the Flutter marker below as native-journal evidence. Local implementation
tests are candidate evidence: mandatory Windows and privileged Linux
target-host lanes remain `not run`, while signed/elevated combined-boundary
evidence remains `blocked`.

```dart
class AppUpdateRecoveryStore implements UpdateRecoveryStore {
  @override
  Future<UpdateInstallRecoveryMarker?> readPendingInstall({
    required String channel,
  }) {
    return myStore.readMarker(channel);
  }

  @override
  Future<void> writePendingInstall(UpdateInstallRecoveryMarker marker) {
    return myStore.writeMarker(marker.channel, marker);
  }

  @override
  Future<void> clearPendingInstall({required String channel}) {
    return myStore.clearMarker(channel);
  }
}

final controller = DesktopUpdaterController(
  appArchiveUrl: archiveUrl,
  recoveryStore: AppUpdateRecoveryStore(),
);
```

When a recovery store is present, `restartApp()` writes a pending marker before
native handoff. On the next startup, `DesktopUpdaterController` checks the
marker before the first automatic update check. If the current app version does
not match the expected update version or build number, the controller enters
`UpdateFailed` with a redacted problem report.

Store read, write, and clear failures are recorded as diagnostics warnings and
do not crash startup or block native install scheduling.

## Support Flow

Recommended user-facing copy:

```text
Open Settings > Updates > Copy update report. If the app cannot open that
screen, attach the update log from the location shown in Settings.
```

Use this order during support triage:

1. Ask for the copied problem report first. It is bounded, redacted, and does
   not require a log file.
2. Ask for the Dart lifecycle log when the failure happened while the app was
   checking, downloading, verifying, staging, or scheduling the install.
3. Ask for the Windows Event Log entries or Linux helper registry
   `events.jsonl` when the app exited for install and then failed to replace
   files, roll back, clean up, or relaunch.
4. Check the recovery marker result when the app relaunched but stayed on the
   old version.

Keep uploads user-approved. The package does not include a logging backend,
telemetry backend, storage package, retention policy, or automatic support
upload.
