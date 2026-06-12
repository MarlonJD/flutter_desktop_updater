import "package:desktop_updater/desktop_updater_platform_interface.dart";
import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:desktop_updater/src/core/update_client.dart";
import "package:desktop_updater/src/current_version.dart";
import "package:desktop_updater/src/version_info.dart";

export "package:desktop_updater/src/core/release_descriptor.dart";
export "package:desktop_updater/src/core/release_index.dart";
export "package:desktop_updater/src/core/update_state.dart";
export "package:desktop_updater/src/localization.dart";
export "package:desktop_updater/widget/update_dialog.dart";

class DesktopUpdater {
  DesktopUpdater();
  Future<String?> getPlatformVersion() {
    return DesktopUpdaterPlatform.instance.getPlatformVersion();
  }

  Future<void> restartApp({
    String? stagingPath,
    bool allowUnsignedMacOSUpdates = false,
  }) {
    if (stagingPath != null) {
      return installUpdate(
        stagingPath: stagingPath,
        allowUnsignedMacOSUpdates: allowUnsignedMacOSUpdates,
      );
    }

    return DesktopUpdaterPlatform.instance.restartApp();
  }

  Future<void> installUpdate({
    required String stagingPath,
    List<String> removedFiles = const [],
    bool allowUnsignedMacOSUpdates = false,
  }) {
    return DesktopUpdaterPlatform.instance.installUpdate(
      stagingPath: stagingPath,
      removedFiles: removedFiles,
      allowUnsignedMacOSUpdates: allowUnsignedMacOSUpdates,
    );
  }

  Future<String?> getExecutablePath() {
    return DesktopUpdaterPlatform.instance.getExecutablePath();
  }

  Future<String?> getCurrentVersion() {
    return DesktopUpdaterPlatform.instance.getCurrentVersion();
  }

  Future<DesktopVersionInfo?> getCurrentVersionInfo() {
    return currentVersionInfo();
  }

  Future<UpdateCheckResult?> checkZipFirstUpdate({
    required Uri appArchiveUrl,
    required DesktopVersionInfo currentVersion,
  }) {
    return UpdateClient(
      appArchiveUrl: appArchiveUrl,
      currentVersion: currentVersion,
    ).checkForUpdate();
  }

  Future<UpdateStageResult> downloadZipFirstUpdate({
    required Uri appArchiveUrl,
    required DesktopVersionInfo currentVersion,
    required ReleaseDescriptor descriptor,
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
