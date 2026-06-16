/// Severity for a structured updater diagnostics entry.
enum UpdateDiagnosticLevel {
  /// Informational lifecycle event.
  info,

  /// Non-fatal condition worth surfacing in technical details.
  warning,

  /// Failure condition.
  error,
}

/// Lifecycle area associated with an updater diagnostics entry.
enum UpdateDiagnosticStage {
  /// App archive lookup and version selection.
  check,

  /// Release descriptor fetch or parsing.
  descriptor,

  /// App-owned or package-owned update policy checks.
  policy,

  /// Artifact download.
  download,

  /// Artifact integrity and trust verification.
  verify,

  /// Staging the artifact for install.
  stage,

  /// Native install or restart handoff.
  install,

  /// Temporary file cleanup.
  cleanup,
}

/// A single structured diagnostics entry for the update lifecycle.
class UpdateDiagnosticEntry {
  /// Creates a diagnostics entry.
  const UpdateDiagnosticEntry({
    required this.timestamp,
    required this.stage,
    required this.level,
    required this.message,
    this.error,
  });

  /// Entry timestamp.
  final DateTime timestamp;

  /// Lifecycle stage associated with this entry.
  final UpdateDiagnosticStage stage;

  /// Entry severity.
  final UpdateDiagnosticLevel level;

  /// Human-readable message.
  final String message;

  /// Optional error captured with the entry.
  final Object? error;

  /// Formats this entry as one redacted line for app-owned log sinks.
  String toRedactedLogLine() {
    final buffer = StringBuffer()
      ..write(timestamp.toUtc().toIso8601String())
      ..write(" ")
      ..write(level.name)
      ..write(" ")
      ..write(stage.name)
      ..write(": ")
      ..write(_redact(message));
    if (error != null) {
      buffer
        ..write(" Error: ")
        ..write(_redact(error.toString()));
    }
    return buffer.toString();
  }
}

/// Optional app-owned sink for receiving retained diagnostics entries.
abstract interface class UpdateDiagnosticsSink {
  /// Records one diagnostics [entry].
  void record(UpdateDiagnosticEntry entry);
}

/// Locally generated, user-copyable update problem report.
class UpdateProblemReport {
  /// Creates a bounded problem report.
  UpdateProblemReport({
    required this.generatedAt,
    required this.packageVersion,
    required this.platform,
    required this.channel,
    required List<UpdateDiagnosticEntry> entries,
    this.appVersion,
    this.updateVersion,
    this.stagingPath,
    this.failure,
    int omittedEntryCount = 0,
  })  : entries = List.unmodifiable(_boundedEntries(entries)),
        omittedEntryCount =
            omittedEntryCount + _omittedCountFor(entries.length);

  /// Maximum diagnostics entries retained in a report.
  static const int maxEntries = 80;

  /// Report generation time.
  final DateTime generatedAt;

  /// Version of the `desktop_updater` package that generated the report.
  final String packageVersion;

  /// Runtime platform associated with the update flow.
  final String platform;

  /// Update channel associated with the flow.
  final String channel;

  /// Bounded, ordered diagnostics entries.
  final List<UpdateDiagnosticEntry> entries;

  /// Number of older entries omitted while bounding the report.
  final int omittedEntryCount;

  /// Installed app version, when known.
  final String? appVersion;

  /// Selected update version, when known.
  final String? updateVersion;

  /// Staged update path, when known.
  final String? stagingPath;

  /// Failure that caused the report, when known.
  final Object? failure;

  /// Builds redacted text suitable for clipboard copy or app-owned export.
  String toPlainText() {
    final buffer = StringBuffer()
      ..writeln("Update Problem Report")
      ..writeln("Generated: ${generatedAt.toUtc().toIso8601String()}")
      ..writeln("Package version: ${_redact(packageVersion)}")
      ..writeln("Platform: ${_redact(platform)}")
      ..writeln("Channel: ${_redact(channel)}");

    _writeOptional(buffer, "App version", appVersion);
    _writeOptional(buffer, "Update version", updateVersion);
    _writeOptional(buffer, "Staging path", stagingPath);

    if (failure != null) {
      buffer.writeln("Failure: ${_redact(failure.toString())}");
    }

    buffer
      ..writeln()
      ..writeln("Diagnostics:");
    if (omittedEntryCount > 0) {
      buffer.writeln("Entries omitted: $omittedEntryCount older entries");
    }

    for (final entry in entries) {
      buffer.writeln(
        "[${entry.timestamp.toUtc().toIso8601String()}] "
        "${entry.level.name.toUpperCase()} ${entry.stage.name}: "
        "${_redact(entry.message)}",
      );
      if (entry.error != null) {
        buffer.writeln("  Error: ${_redact(entry.error.toString())}");
      }
    }

    return buffer.toString().trimRight();
  }

  static void _writeOptional(
    StringBuffer buffer,
    String label,
    String? value,
  ) {
    if (value == null || value.isEmpty) {
      return;
    }
    buffer.writeln("$label: ${_redact(value)}");
  }

  static List<UpdateDiagnosticEntry> _boundedEntries(
    List<UpdateDiagnosticEntry> entries,
  ) {
    if (entries.length <= maxEntries) {
      return entries;
    }
    return entries.sublist(entries.length - maxEntries);
  }

  static int _omittedCountFor(int entryCount) {
    if (entryCount <= maxEntries) {
      return 0;
    }
    return entryCount - maxEntries;
  }
}

/// Small report emitted after install scheduling or cleanup evidence.
class UpdateCleanupReport {
  /// Creates an install cleanup report.
  const UpdateCleanupReport({
    required this.stagingPath,
    required this.descriptorVersion,
    required this.cleanupAttempted,
    this.cleanupSucceeded,
    this.backupRestoredByNativeHelper,
    this.errorText,
  });

  /// Platform-specific staged update path associated with the report.
  final String stagingPath;

  /// Release descriptor version associated with the staged update.
  final String? descriptorVersion;

  /// Whether cleanup was attempted for the staged update.
  final bool cleanupAttempted;

  /// Whether cleanup succeeded, when cleanup or install-scheduling result is
  /// known.
  final bool? cleanupSucceeded;

  /// Whether the native helper reported restoring a backup during rollback.
  final bool? backupRestoredByNativeHelper;

  /// Error text captured while scheduling install or cleanup, when known.
  final String? errorText;
}

const String _redacted = "<redacted>";

final RegExp _authorizationHeaderPattern = RegExp(
  r"\b(authorization)\s*:\s*([^\r\n,;]+?)(?=\s+[A-Za-z0-9_-]*(?:token|signature|password|secret|credentials?|key)[A-Za-z0-9_-]*\s*[=:]|[\r\n,;]|$)",
  caseSensitive: false,
  multiLine: true,
);

final RegExp _secretAssignmentPattern = RegExp(
  r"\b([A-Za-z0-9_-]*(?:token|signature|password|secret|authorization|credentials?|key)[A-Za-z0-9_-]*)\s*([=:])\s*([^&\s,;]+)",
  caseSensitive: false,
);

String _redact(String input) {
  final withoutAuthorizationHeaders = input.replaceAllMapped(
    _authorizationHeaderPattern,
    (match) => "${match.group(1)}: $_redacted",
  );

  return withoutAuthorizationHeaders.replaceAllMapped(
    _secretAssignmentPattern,
    (match) {
      final separator = match.group(2);
      if (separator == ":") {
        return "${match.group(1)}: $_redacted";
      }
      return "${match.group(1)}=$_redacted";
    },
  );
}
