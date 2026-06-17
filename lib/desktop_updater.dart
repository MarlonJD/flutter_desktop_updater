import "package:desktop_updater/desktop_updater_platform_interface.dart";
import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:desktop_updater/src/core/update_client.dart";
import "package:desktop_updater/src/current_version.dart";
import "package:desktop_updater/src/version_info.dart";

export "package:desktop_updater/src/core/release_descriptor.dart";
export "package:desktop_updater/src/core/release_index.dart";
export "package:desktop_updater/src/core/release_notes.dart";
export "package:desktop_updater/src/core/update_diagnostics.dart";
export "package:desktop_updater/src/core/update_diagnostics_recorder.dart";
export "package:desktop_updater/src/core/update_recovery.dart";
export "package:desktop_updater/src/core/update_state.dart";
export "package:desktop_updater/src/localization.dart";
export "package:desktop_updater/src/manual_update_check_result.dart";
export "package:desktop_updater/widget/release_notes_bottom_sheet.dart";
export "package:desktop_updater/widget/update_card.dart";
export "package:desktop_updater/widget/update_dialog.dart";
export "package:desktop_updater/widget/update_direct_card.dart";
export "package:desktop_updater/widget/update_problem_report_dialog.dart";
export "package:desktop_updater/widget/update_sliver.dart";
export "package:desktop_updater/widget/update_widget.dart";

export "desktop_updater_inherited_widget.dart";

/// Entry point for platform update helpers and zip-first update operations.
class DesktopUpdater {
  /// Creates a desktop updater facade.
  DesktopUpdater();

  /// Returns the current desktop platform version string.
  Future<String?> getPlatformVersion() {
    return DesktopUpdaterPlatform.instance.getPlatformVersion();
  }

  /// Restarts or installs a staged update.
  Future<void> restartApp({
    /// Optional staged update path to install before restarting.
    String? stagingPath,

    /// Allows unsigned macOS update artifacts for explicitly trusted lanes.
    bool allowUnsignedMacOSUpdates = false,

    /// Optional app-owned native helper diagnostics log path.
    String? diagnosticsLogPath,
  }) {
    if (stagingPath != null) {
      return installUpdate(
        stagingPath: stagingPath,
        allowUnsignedMacOSUpdates: allowUnsignedMacOSUpdates,
        diagnosticsLogPath: diagnosticsLogPath,
      );
    }

    return DesktopUpdaterPlatform.instance.restartApp();
  }

  /// Installs an already staged update artifact.
  Future<void> installUpdate({
    /// Platform-specific staged artifact path.
    required String stagingPath,

    /// Legacy-compatible list of files removed during install.
    List<String> removedFiles = const [],

    /// Allows unsigned macOS update artifacts for explicitly trusted lanes.
    bool allowUnsignedMacOSUpdates = false,

    /// Optional app-owned native helper diagnostics log path.
    String? diagnosticsLogPath,
  }) {
    return DesktopUpdaterPlatform.instance.installUpdate(
      stagingPath: stagingPath,
      removedFiles: removedFiles,
      allowUnsignedMacOSUpdates: allowUnsignedMacOSUpdates,
      diagnosticsLogPath: diagnosticsLogPath,
    );
  }

  /// Returns the current executable path when the platform supports it.
  Future<String?> getExecutablePath() {
    return DesktopUpdaterPlatform.instance.getExecutablePath();
  }

  /// Returns the raw current app version string.
  Future<String?> getCurrentVersion() {
    return DesktopUpdaterPlatform.instance.getCurrentVersion();
  }

  /// Returns the structured current app version.
  Future<DesktopVersionInfo?> getCurrentVersionInfo() {
    return currentVersionInfo();
  }

  /// Checks the zip-first update index for a matching newer release.
  Future<UpdateCheckResult?> checkZipFirstUpdate({
    /// Hosted app archive URL.
    required Uri appArchiveUrl,

    /// Version currently installed on this machine.
    required DesktopVersionInfo currentVersion,

    /// Stable app-owned identity used for deterministic staged rollouts.
    String? installationIdentity,
  }) {
    return UpdateClient(
      appArchiveUrl: appArchiveUrl,
      currentVersion: currentVersion,
      installationIdentity: installationIdentity,
    ).checkForUpdate();
  }

  /// Downloads, verifies, and stages a zip-first update artifact.
  Future<UpdateStageResult> downloadZipFirstUpdate({
    /// Hosted app archive URL.
    required Uri appArchiveUrl,

    /// Version currently installed on this machine.
    required DesktopVersionInfo currentVersion,

    /// Release descriptor selected by [checkZipFirstUpdate].
    required ReleaseDescriptor descriptor,

    /// Optional download progress callback.
    void Function(int receivedBytes, int? totalBytes)? onProgress,
  }) {
    return UpdateClient(
      appArchiveUrl: appArchiveUrl,
      currentVersion: currentVersion,
    ).downloadVerifyAndStage(
      descriptor: descriptor,
      onProgress: onProgress,
    );
  }
}
