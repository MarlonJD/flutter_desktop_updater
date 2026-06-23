import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:desktop_updater/src/core/release_index.dart";
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
  const UpdateAvailable({
    required this.descriptor,
    required this.mandatory,
    this.supportPolicy,
  });

  /// Release descriptor selected from the app archive.
  final ReleaseDescriptor descriptor;

  /// Whether the selected release should be treated as mandatory.
  final bool mandatory;

  /// Optional support deadline that applies to the current app version.
  final ReleaseSupportPolicy? supportPolicy;
}

/// A newer release exists but must be installed from a fresh download.
final class UpdateFreshInstallRequired extends UpdateState {
  /// Creates a fresh-install-required state.
  const UpdateFreshInstallRequired({
    required this.descriptor,
    required this.freshInstall,
    required this.mandatory,
    this.supportPolicy,
  });

  /// Release descriptor selected from the app archive.
  final ReleaseDescriptor descriptor;

  /// Fresh download policy for the selected release.
  final ReleaseFreshInstall freshInstall;

  /// Whether the prompt should block skip/dismiss choices.
  final bool mandatory;

  /// Optional support deadline that applies to the current app version.
  final ReleaseSupportPolicy? supportPolicy;
}

/// The current app version is past the support deadline.
final class UpdateBlockedBySupportPolicy extends UpdateState {
  /// Creates a support-policy blocking state.
  const UpdateBlockedBySupportPolicy({
    required this.descriptor,
    required this.supportPolicy,
    this.freshInstall,
  });

  /// Release descriptor selected from the app archive.
  final ReleaseDescriptor descriptor;

  /// Support policy forcing the blocking update UI.
  final ReleaseSupportPolicy supportPolicy;

  /// Optional fresh download policy for the selected release.
  final ReleaseFreshInstall? freshInstall;
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
  const UpdateReadyToInstall({
    required this.stagingPath,
    this.mandatory = false,
  });

  /// Platform-specific path passed to the native install helper.
  final String stagingPath;

  /// Whether the staged update should still be treated as mandatory.
  final bool mandatory;
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
