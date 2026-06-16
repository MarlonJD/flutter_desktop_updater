import "dart:io";

import "package:desktop_updater/src/core/update_diagnostics.dart";
import "package:desktop_updater/src/package_version.dart";

/// In-memory diagnostics recorder for updater lifecycle events.
class UpdateDiagnosticsRecorder {
  /// Creates an in-memory diagnostics recorder.
  UpdateDiagnosticsRecorder({
    DateTime Function()? clock,
    this.packageVersion = desktopUpdaterPackageVersion,
    String? platform,
    this.channel = "stable",
    int maxEntries = UpdateProblemReport.maxEntries,
  })  : _clock = clock ?? DateTime.now,
        platform = platform ?? Platform.operatingSystem,
        _maxEntries = maxEntries < 1 ? 1 : maxEntries;

  final DateTime Function() _clock;
  final int _maxEntries;
  final List<UpdateDiagnosticEntry> _entries = [];
  int _omittedEntryCount = 0;

  /// Version of the package that records diagnostics.
  final String packageVersion;

  /// Runtime platform for generated reports.
  final String platform;

  /// Update channel for generated reports.
  final String channel;

  /// Snapshot of currently retained entries.
  List<UpdateDiagnosticEntry> get entries => List.unmodifiable(_entries);

  /// Records a lifecycle entry in memory.
  void record({
    required UpdateDiagnosticStage stage,
    required UpdateDiagnosticLevel level,
    required String message,
    Object? error,
  }) {
    if (_entries.length == _maxEntries) {
      _entries.removeAt(0);
      _omittedEntryCount += 1;
    }
    _entries.add(
      UpdateDiagnosticEntry(
        timestamp: _clock(),
        stage: stage,
        level: level,
        message: message,
        error: error,
      ),
    );
  }

  /// Clears retained entries for a fresh update lifecycle.
  void clear() {
    _entries.clear();
    _omittedEntryCount = 0;
  }

  /// Builds a local, redacted problem report from retained entries.
  UpdateProblemReport buildReport({
    String? appVersion,
    String? updateVersion,
    String? stagingPath,
    Object? failure,
  }) {
    return UpdateProblemReport(
      generatedAt: _clock(),
      packageVersion: packageVersion,
      platform: platform,
      channel: channel,
      appVersion: appVersion,
      updateVersion: updateVersion,
      stagingPath: stagingPath,
      failure: failure,
      entries: List.of(_entries),
      omittedEntryCount: _omittedEntryCount,
    );
  }
}
