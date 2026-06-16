/// Marker persisted by an app-owned store before native install handoff.
class UpdateInstallRecoveryMarker {
  /// Creates a pending install recovery marker.
  const UpdateInstallRecoveryMarker({
    required this.createdAt,
    required this.packageVersion,
    required this.platform,
    required this.channel,
    this.appVersion,
    this.updateVersion,
    this.updateBuildNumber,
    this.stagingPath,
    this.diagnosticsText,
  });

  /// Time the marker was created.
  final DateTime createdAt;

  /// Version of the `desktop_updater` package that created the marker.
  final String packageVersion;

  /// Runtime platform associated with the pending install.
  final String platform;

  /// Update channel associated with the pending install.
  final String channel;

  /// App version that was running when install was handed off, when known.
  final String? appVersion;

  /// Target update version expected after relaunch, when known.
  final String? updateVersion;

  /// Target update build number expected after relaunch, when known.
  final int? updateBuildNumber;

  /// Platform-specific staged update path handed to the native helper.
  final String? stagingPath;

  /// Redacted diagnostics text captured before native install handoff.
  final String? diagnosticsText;
}

/// App-owned persistence adapter for pending native install recovery markers.
abstract interface class UpdateRecoveryStore {
  /// Reads a pending install marker for [channel], when one exists.
  Future<UpdateInstallRecoveryMarker?> readPendingInstall({
    required String channel,
  });

  /// Writes a pending install [marker].
  Future<void> writePendingInstall(UpdateInstallRecoveryMarker marker);

  /// Clears the pending install marker for [channel].
  Future<void> clearPendingInstall({required String channel});
}
