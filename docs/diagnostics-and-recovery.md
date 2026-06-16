# Diagnostics And Recovery

This page explains where update logs are written, how diagnostics flow through
the updater, and how an app should wire support collection.

## Where Logs Go

The package writes no log files by default. It keeps a bounded in-memory
diagnostics report for failures, and your app decides whether anything becomes a
file, a database row, a support attachment, or an upload.

| Surface | Default location | Who chooses storage | When it is written | How to use it |
| --- | --- | --- | --- | --- |
| In-memory problem report | No path | Package keeps it in memory | When check, download, verify, stage, or install handoff fails | Show/copy `UpdateFailed.report.toPlainText()` or use `onProblemReport` after a user action |
| Dart lifecycle log | No path unless your app supplies a sink | Your `UpdateDiagnosticsSink` | While the Flutter process is running update checks, downloads, verification, staging, and native handoff | Persist redacted `UpdateDiagnosticEntry` lines in your app-owned support location |
| Native helper log | No path unless your app passes `diagnosticsLogPath` | Your app passes the exact path | After the Flutter process exits and the platform helper performs install, rollback, cleanup, and relaunch work | Ask support users to attach this JSON Lines file only when post-exit install evidence is needed |
| Pending install recovery marker | No marker unless your app supplies a store | Your `UpdateRecoveryStore` | Immediately before native install handoff, then cleared after a verified relaunch | Turn "the app relaunched but stayed on the old version" into `UpdateFailed(report)` on next startup |
| Cleanup report | In memory on the controller | Optional `onCleanupReport` callback | After install scheduling or cleanup evidence is available | Save scheduling or cleanup evidence in your app-owned audit trail |

## Recommended Setup

Start with the default in-memory problem report. Add durable logs only when your
support workflow needs them.

1. **In-memory problem report only.** Use the default problem report for
   ordinary UI support.
2. **App-owned Dart lifecycle log.** Add a Dart lifecycle sink when support
   needs a durable update flow log.
3. **App-owned native helper log plus recovery store.** Add
   `diagnosticsLogPath` and `UpdateRecoveryStore` only when support needs
   evidence from the native helper after the Flutter process has exited.

Do not document a package-owned log path for users. Pick an app-owned support
directory, create it before update handoff, show that path in your own Settings
or support UI, and own retention, rotation, encryption, and upload consent.

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
after the Flutter process hands off to the platform helper, so it is useful for
locked-file replacement, rollback, cleanup, and relaunch failures.

Pass an explicit path with `diagnosticsLogPath`:

```dart
final helperLogFile =
    File("${appOwnedSupportDir.path}/update-helper.jsonl");
await helperLogFile.parent.create(recursive: true);

final controller = DesktopUpdaterController(
  appArchiveUrl: archiveUrl,
  diagnosticsLogPath: helperLogFile.path,
);
```

The helper appends one JSON object per line when the path is present:

```jsonl
{"timestamp":"2026-06-16T10:15:30Z","event":"helper scheduled"}
{"timestamp":"2026-06-16T10:15:31Z","event":"waiting for parent process"}
{"timestamp":"2026-06-16T10:15:32Z","event":"parent process exited"}
{"timestamp":"2026-06-16T10:15:33Z","event":"move start"}
{"timestamp":"2026-06-16T10:15:34Z","event":"move success"}
{"timestamp":"2026-06-16T10:15:35Z","event":"relaunch attempt"}
```

Common helper events include:

- `helper scheduled`
- `waiting for parent process`
- `parent process exited`
- `staging path validation`
- `backup start`, `backup success`, `backup failure`
- `move start`, `move success`, `move failure`
- `rollback start`, `rollback success`, `rollback failure`
- `cleanup start`, `cleanup success`, `cleanup failure`
- `relaunch attempt`

macOS may also emit `package identity checks` before bundle replacement.
Windows may emit repeated `move start` entries while it waits for locked files
to become replaceable.

The helpers do not create a support directory for you. Create the parent directory
before passing the path. If the path is missing, the parent directory does not
exist, or the file cannot be written, the helper ignores the logging failure and
continues the install, rollback, cleanup, or relaunch attempt.

## Recovery Store

`diagnosticsLogPath` tells you what happened inside the native helper. It does
not by itself decide whether the next app launch succeeded. Add an
`UpdateRecoveryStore` when you want the next startup to detect unfinished or
unverified installs.

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
  diagnosticsLogPath: helperLogFile.path,
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
3. Ask for the native helper JSONL log when the app exited for install and then
   failed to replace files, roll back, clean up, or relaunch.
4. Check the recovery marker result when the app relaunched but stayed on the
   old version.

Keep uploads user-approved. The package does not include a logging backend,
telemetry backend, storage package, retention policy, or automatic support
upload.
