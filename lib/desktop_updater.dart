import "package:desktop_updater/desktop_updater_platform_interface.dart";
import "package:desktop_updater/src/core/artifact_verifier.dart";
import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:desktop_updater/src/core/release_index_signature_verifier.dart";
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
    show UpdateCheckResult, UpdateStageResult;
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

  /// Restarts or installs a staged update.
  Future<void> restartApp({
    /// Optional staged update path to install before restarting.
    String? stagingPath,

    /// Legacy compatibility flag rejected before native install handoff.
    ///
    /// Keep this false. Native install handoff requires signed release
    /// metadata; privileged macOS installs also require signed, notarized
    /// application code.
    bool allowUnsignedMacOSUpdates = false,

    /// Compatibility-only diagnostics path. Standalone helpers use their
    /// fixed platform log sink instead of writing this caller-selected path.
    String? diagnosticsLogPath,

    /// Verified package identity required by protected native install targets.
    String? packageId,

    /// Canonical app-owned install root for explicit native target proof.
    String? installRoot,

    /// Running executable path relative to [installRoot].
    String? executableRelativePath,
  }) {
    if (stagingPath != null) {
      return installUpdate(
        stagingPath: stagingPath,
        allowUnsignedMacOSUpdates: allowUnsignedMacOSUpdates,
        diagnosticsLogPath: diagnosticsLogPath,
        packageId: packageId,
        installRoot: installRoot,
        executableRelativePath: executableRelativePath,
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

    /// Legacy compatibility flag rejected before native install handoff.
    ///
    /// Keep this false. Native install handoff requires signed release
    /// metadata; privileged macOS installs also require signed, notarized
    /// application code.
    bool allowUnsignedMacOSUpdates = false,

    /// Compatibility-only diagnostics path. Standalone helpers use their
    /// fixed platform log sink instead of writing this caller-selected path.
    String? diagnosticsLogPath,

    /// Verified package identity required by protected native install targets.
    String? packageId,

    /// Canonical app-owned install root for explicit native target proof.
    String? installRoot,

    /// Running executable path relative to [installRoot].
    String? executableRelativePath,
  }) {
    return DesktopUpdaterPlatform.instance.installUpdateWithContext(
      stagingPath: stagingPath,
      removedFiles: removedFiles,
      allowUnsignedMacOSUpdates: allowUnsignedMacOSUpdates,
      diagnosticsLogPath: diagnosticsLogPath,
      installRoot: installRoot,
      executableRelativePath: executableRelativePath,
      packageId: packageId,
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

  /// Checks the zip-first update index for a matching newer release.
  Future<UpdateCheckResult?> checkZipFirstUpdate({
    /// Hosted app archive URL.
    required Uri appArchiveUrl,

    /// Version currently installed on this machine.
    required DesktopVersionInfo currentVersion,

    /// Stable app-owned identity used for deterministic staged rollouts.
    String? installationIdentity,

    /// Optional app-owned HTTP headers for update metadata requests.
    UpdateRequestHeadersProvider? requestHeadersProvider,

    /// Pinned Ed25519 public keys required for archive and descriptor trust.
    Map<String, String>? trustedReleasePublicKeys,
  }) {
    final publicKeys = trustedReleasePublicKeys;
    return UpdateClient(
      appArchiveUrl: appArchiveUrl,
      currentVersion: currentVersion,
      installationIdentity: installationIdentity,
      requestHeadersProvider: requestHeadersProvider,
      requireIndexSignature: publicKeys != null,
      indexSignatureVerifier: publicKeys == null
          ? null
          : Ed25519ReleaseIndexSignatureVerifier(publicKeys),
      verifier: publicKeys == null
          ? const ArtifactVerifier()
          : ArtifactVerifier(
              policy: ArtifactVerificationPolicy.requireEd25519Signature(
                publicKeys: publicKeys,
              ),
            ),
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

    /// Optional app-owned HTTP headers for artifact requests.
    UpdateRequestHeadersProvider? requestHeadersProvider,

    /// Pinned Ed25519 public keys required for descriptor trust.
    Map<String, String>? trustedReleasePublicKeys,
  }) {
    final publicKeys = trustedReleasePublicKeys;
    return UpdateClient(
      appArchiveUrl: appArchiveUrl,
      currentVersion: currentVersion,
      requestHeadersProvider: requestHeadersProvider,
      verifier: publicKeys == null
          ? const ArtifactVerifier()
          : ArtifactVerifier(
              policy: ArtifactVerificationPolicy.requireEd25519Signature(
                publicKeys: publicKeys,
              ),
            ),
    ).downloadVerifyAndStage(
      descriptor: descriptor,
      onProgress: onProgress,
    );
  }
}
