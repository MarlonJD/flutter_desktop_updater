import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:desktop_updater/src/core/release_index.dart";

/// Result returned by an explicit user-triggered update check.
///
/// Automatic startup checks should continue to use controller state and should
/// not show an "up to date" confirmation by default.
sealed class ManualUpdateCheckResult {
  /// Creates a manual update-check result.
  const ManualUpdateCheckResult();
}

/// No newer release is available for the current app, platform, and channel.
final class ManualUpdateCheckUpToDate extends ManualUpdateCheckResult {
  /// Creates an up-to-date manual update-check result.
  const ManualUpdateCheckUpToDate();
}

/// A newer release is available and the controller state has been updated.
final class ManualUpdateCheckAvailable extends ManualUpdateCheckResult {
  /// Creates an available-update manual update-check result.
  const ManualUpdateCheckAvailable({
    required this.descriptor,
    required this.mandatory,
  });

  /// The release descriptor selected by the update check.
  final ReleaseDescriptor descriptor;

  /// Whether the selected release should be treated as mandatory.
  final bool mandatory;
}

/// A newer release is available but requires a fresh download.
final class ManualUpdateCheckFreshInstallRequired
    extends ManualUpdateCheckResult {
  /// Creates a fresh-install manual update-check result.
  const ManualUpdateCheckFreshInstallRequired({
    required this.descriptor,
    required this.freshInstall,
    required this.mandatory,
  });

  /// The release descriptor selected by the update check.
  final ReleaseDescriptor descriptor;

  /// Fresh download policy for the selected release.
  final ReleaseFreshInstall freshInstall;

  /// Whether the selected release should block skip/dismiss choices.
  final bool mandatory;
}

/// The current app version is past the support-policy deadline.
final class ManualUpdateCheckBlockedBySupportPolicy
    extends ManualUpdateCheckResult {
  /// Creates a support-policy blocked manual update-check result.
  const ManualUpdateCheckBlockedBySupportPolicy({
    required this.descriptor,
    required this.supportPolicy,
  });

  /// The release descriptor selected by the update check.
  final ReleaseDescriptor descriptor;

  /// Support policy forcing the blocking update UI.
  final ReleaseSupportPolicy supportPolicy;
}

/// The update check failed before a final available or up-to-date result.
final class ManualUpdateCheckFailed extends ManualUpdateCheckResult {
  /// Creates a failed manual update-check result.
  const ManualUpdateCheckFailed(this.error, this.stackTrace);

  /// The error thrown while checking for updates.
  final Object error;

  /// The stack trace captured when [error] was thrown.
  final StackTrace stackTrace;
}
