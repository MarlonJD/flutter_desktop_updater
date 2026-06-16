import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:desktop_updater/src/core/update_diagnostics.dart";

/// Base type for the updater lifecycle states exposed by the controller.
sealed class UpdateState {
  /// Creates an update lifecycle state.
  const UpdateState();
}

/// No update operation is currently active.
final class UpdateIdle extends UpdateState {
  /// Creates an idle update state.
  const UpdateIdle();
}

/// The controller is checking the hosted app archive for a newer release.
final class UpdateChecking extends UpdateState {
  /// Creates an update-checking state.
  const UpdateChecking();
}

/// A release newer than the installed app is available.
final class UpdateAvailable extends UpdateState {
  /// Creates an available-update state for [descriptor].
  const UpdateAvailable({required this.descriptor, required this.mandatory});

  /// Release descriptor selected from the app archive.
  final ReleaseDescriptor descriptor;

  /// Whether the selected release should be treated as mandatory.
  final bool mandatory;
}

/// The selected update artifact is being downloaded and verified.
final class UpdateDownloading extends UpdateState {
  /// Creates a download-progress state.
  const UpdateDownloading({
    required this.receivedBytes,
    required this.totalBytes,
  });

  /// Number of artifact bytes downloaded so far.
  final int receivedBytes;

  /// Expected total artifact bytes.
  final int totalBytes;
}

/// The update artifact has been staged and can be installed.
final class UpdateReadyToInstall extends UpdateState {
  /// Creates a ready-to-install state for [stagingPath].
  const UpdateReadyToInstall({required this.stagingPath});

  /// Platform-specific path passed to the native install helper.
  final String stagingPath;
}

/// The native install or restart helper is running.
final class UpdateInstalling extends UpdateState {
  /// Creates an installing state.
  const UpdateInstalling({this.cleanupReport});

  /// Report emitted after install scheduling, when available.
  final UpdateCleanupReport? cleanupReport;
}

/// The most recent update check, download, verification, or install failed.
final class UpdateFailed extends UpdateState {
  /// Creates a failed state with the original [error].
  const UpdateFailed(this.error, {this.report});

  /// Error reported by the failing update operation.
  final Object error;

  /// Redacted diagnostics report for this failure, when available.
  final UpdateProblemReport? report;
}
