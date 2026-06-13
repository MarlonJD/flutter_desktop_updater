/// Optional callback type for app-owned update telemetry.
typedef DesktopUpdaterTelemetry = void Function(UpdateTelemetryEvent event);

/// Typed update telemetry event names emitted by the updater.
enum UpdateTelemetryEventType {
  /// An update check started.
  checkStarted,

  /// An update check failed.
  checkFailed,

  /// A newer update was selected.
  updateSelected,

  /// Artifact download started.
  downloadStarted,

  /// Artifact download failed.
  downloadFailed,

  /// Artifact checksum and descriptor policy verification completed.
  artifactVerified,

  /// Install handoff was scheduled.
  installScheduled,

  /// Install handoff failed.
  installFailed,
}

/// App-consumable telemetry payload for updater lifecycle events.
class UpdateTelemetryEvent {
  /// Creates a telemetry event.
  const UpdateTelemetryEvent({
    required this.type,
    this.version,
    this.channel,
    this.platform,
    this.source,
    this.stagingPath,
    this.mandatory,
    this.error,
  });

  /// Creates a check-started event.
  const UpdateTelemetryEvent.checkStarted({
    Uri? source,
    String? channel,
  }) : this(
          type: UpdateTelemetryEventType.checkStarted,
          source: source,
          channel: channel,
        );

  /// Creates a check-failed event.
  const UpdateTelemetryEvent.checkFailed({
    Uri? source,
    String? channel,
    Object? error,
  }) : this(
          type: UpdateTelemetryEventType.checkFailed,
          source: source,
          channel: channel,
          error: error,
        );

  /// Creates an update-selected event.
  const UpdateTelemetryEvent.updateSelected({
    String? version,
    String? channel,
    String? platform,
    bool? mandatory,
  }) : this(
          type: UpdateTelemetryEventType.updateSelected,
          version: version,
          channel: channel,
          platform: platform,
          mandatory: mandatory,
        );

  /// Creates a download-started event.
  const UpdateTelemetryEvent.downloadStarted({
    Uri? source,
    String? version,
    String? channel,
    String? platform,
  }) : this(
          type: UpdateTelemetryEventType.downloadStarted,
          source: source,
          version: version,
          channel: channel,
          platform: platform,
        );

  /// Creates a download-failed event.
  const UpdateTelemetryEvent.downloadFailed({
    Uri? source,
    String? version,
    String? channel,
    String? platform,
    Object? error,
  }) : this(
          type: UpdateTelemetryEventType.downloadFailed,
          source: source,
          version: version,
          channel: channel,
          platform: platform,
          error: error,
        );

  /// Creates an artifact-verified event.
  const UpdateTelemetryEvent.artifactVerified({
    Uri? source,
    String? version,
    String? channel,
    String? platform,
  }) : this(
          type: UpdateTelemetryEventType.artifactVerified,
          source: source,
          version: version,
          channel: channel,
          platform: platform,
        );

  /// Creates an install-scheduled event.
  const UpdateTelemetryEvent.installScheduled({
    String? stagingPath,
    String? version,
    String? channel,
    String? platform,
  }) : this(
          type: UpdateTelemetryEventType.installScheduled,
          stagingPath: stagingPath,
          version: version,
          channel: channel,
          platform: platform,
        );

  /// Creates an install-failed event.
  const UpdateTelemetryEvent.installFailed({
    String? stagingPath,
    String? version,
    String? channel,
    String? platform,
    Object? error,
  }) : this(
          type: UpdateTelemetryEventType.installFailed,
          stagingPath: stagingPath,
          version: version,
          channel: channel,
          platform: platform,
          error: error,
        );

  /// Event kind.
  final UpdateTelemetryEventType type;

  /// Release version associated with the event, when known.
  final String? version;

  /// Release channel associated with the event, when known.
  final String? channel;

  /// Platform associated with the event, when known.
  final String? platform;

  /// Network or file source associated with the event, when known.
  final Uri? source;

  /// Staged update path associated with install events, when known.
  final String? stagingPath;

  /// Whether the selected update is mandatory, when known.
  final bool? mandatory;

  /// Failure object associated with failed events, when known.
  final Object? error;
}

/// Emits [event] to [telemetry] and ignores telemetry sink failures.
void emitUpdateTelemetry(
  DesktopUpdaterTelemetry? telemetry,
  UpdateTelemetryEvent event,
) {
  try {
    telemetry?.call(event);
  } on Object {
    // Telemetry is observational and must not affect update behavior.
  }
}
