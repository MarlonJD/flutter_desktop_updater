import "package:desktop_updater/desktop_updater_platform_interface.dart";
import "package:desktop_updater/src/core/update_client.dart";
import "package:desktop_updater/src/current_version.dart";
import "package:desktop_updater/src/io/http_update_transport.dart"
    show UpdateRequestHeadersProvider;
import "package:desktop_updater/src/macos_install_location.dart";
import "package:desktop_updater/src/version_info.dart";

export "package:desktop_updater/src/core/release_descriptor.dart";
export "package:desktop_updater/src/core/release_index.dart";
export "package:desktop_updater/src/core/release_notes.dart";
export "package:desktop_updater/src/core/update_client.dart"
    show MinimumOSSupportChecker, UpdateCheckResult, UpdateStageResult;
export "package:desktop_updater/src/core/update_diagnostics.dart";
export "package:desktop_updater/src/core/update_diagnostics_recorder.dart";
export "package:desktop_updater/src/core/update_recovery.dart";
export "package:desktop_updater/src/core/update_state.dart";
export "package:desktop_updater/src/io/http_update_transport.dart"
    show UpdateRequestHeadersProvider;
export "package:desktop_updater/src/localization.dart";
export "package:desktop_updater/src/macos_install_location.dart";
export "package:desktop_updater/src/macos_privileged_helper_approval.dart";
export "package:desktop_updater/src/manual_update_check_result.dart";
export "package:desktop_updater/src/version_info.dart" show DesktopVersionInfo;
export "package:desktop_updater/widget/release_notes_bottom_sheet.dart";
export "package:desktop_updater/widget/macos_move_to_applications_prompt.dart";
export "package:desktop_updater/widget/update_card.dart";
export "package:desktop_updater/widget/update_dialog.dart";
export "package:desktop_updater/widget/update_direct_card.dart";
export "package:desktop_updater/widget/update_problem_report_dialog.dart";
export "package:desktop_updater/widget/update_sliver.dart";
export "package:desktop_updater/widget/update_widget.dart";

export "desktop_updater_inherited_widget.dart";
export "updater_controller.dart";

/// Entry point for platform update helpers and zip-first update operations.
class DesktopUpdater {
  /// Creates a desktop updater facade.
  DesktopUpdater();

  /// Returns the current desktop platform version string.
  Future<String?> getPlatformVersion() {
    return DesktopUpdaterPlatform.instance.getPlatformVersion();
  }

  /// Restarts the current app without installing a staged update.
  Future<void> restartApp() {
    return DesktopUpdaterPlatform.instance.restartApp();
  }

  /// Returns the current executable path when the platform supports it.
  Future<String?> getExecutablePath() {
    return DesktopUpdaterPlatform.instance.getExecutablePath();
  }

  /// Returns the raw current app version string.
  Future<String?> getCurrentVersion() {
    return DesktopUpdaterPlatform.instance.getCurrentVersion();
  }

  /// Returns macOS install-location status for optional move prompts.
  Future<MacOSInstallLocationStatus> checkMacOSInstallLocation() {
    return DesktopUpdaterPlatform.instance.checkMacOSInstallLocation();
  }

  /// Moves the running macOS app to `/Applications`.
  Future<void> moveMacOSAppToApplications({
    bool replaceExisting = false,
  }) {
    return DesktopUpdaterPlatform.instance.moveMacOSAppToApplications(
      replaceExisting: replaceExisting,
    );
  }

  /// Opens macOS Background Items settings for privileged helper approval.
  Future<void> openMacOSBackgroundItemsSettings() {
    return DesktopUpdaterPlatform.instance.openMacOSBackgroundItemsSettings();
  }

  /// Returns the structured current app version.
  Future<DesktopVersionInfo?> getCurrentVersionInfo() {
    return currentVersionInfo();
  }

  /// Creates a configured zip-first update session.
  ZipFirstUpdateSession createZipFirstUpdateSession({
    /// Hosted app archive URL.
    required Uri appArchiveUrl,

    /// Version currently installed on this machine.
    required DesktopVersionInfo currentVersion,

    /// Stable package identity expected in signed release descriptors.
    required String expectedPackageId,

    /// Pinned Ed25519 public keys required for archive and descriptor trust.
    required Map<String, String> trustedReleasePublicKeys,

    /// Stable app-owned identity used for deterministic staged rollouts.
    String? installationIdentity,

    /// Optional app-owned HTTP headers for update metadata requests.
    UpdateRequestHeadersProvider? requestHeadersProvider,
  }) {
    return ZipFirstUpdateSession._(
      UpdateClient(
        appArchiveUrl: appArchiveUrl,
        currentVersion: currentVersion,
        expectedPackageId: expectedPackageId,
        trustedReleasePublicKeys: trustedReleasePublicKeys,
        installationIdentity: installationIdentity,
        requestHeadersProvider: requestHeadersProvider,
      ),
    );
  }
}

/// Per-client zip-first update session.
final class ZipFirstUpdateSession {
  ZipFirstUpdateSession._(this._client);

  final UpdateClient _client;

  /// Checks the signed app archive for a matching newer release.
  Future<UpdateCheckResult?> checkForUpdate() => _client.checkForUpdate();

  /// Downloads, verifies, and stages the selected update once.
  Future<UpdateStageResult> downloadVerifyAndStage({
    required UpdateCheckResult checkResult,
    void Function(int receivedBytes, int? totalBytes)? onProgress,
  }) {
    return _client.downloadVerifyAndStage(
      checkResult: checkResult,
      onProgress: onProgress,
    );
  }
}
