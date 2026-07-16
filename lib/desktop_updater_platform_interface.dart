import "package:desktop_updater/desktop_updater_method_channel.dart";
import "package:desktop_updater/src/core/update_recovery.dart";
import "package:desktop_updater/src/macos_install_location.dart";
import "package:plugin_platform_interface/plugin_platform_interface.dart";

/// Platform interface implemented by macOS, Windows, and Linux helpers.
abstract class DesktopUpdaterPlatform extends PlatformInterface {
  /// Constructs a DesktopUpdaterPlatform.
  DesktopUpdaterPlatform() : super(token: _token);

  static final Object _token = Object();

  static DesktopUpdaterPlatform _instance = MethodChannelDesktopUpdater();

  /// The default instance of [DesktopUpdaterPlatform] to use.
  ///
  /// Defaults to [MethodChannelDesktopUpdater].
  static DesktopUpdaterPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [DesktopUpdaterPlatform] when
  /// they register themselves.
  static set instance(DesktopUpdaterPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  /// Returns a platform-specific version string from the native plugin.
  Future<String?> getPlatformVersion() {
    throw UnimplementedError("platformVersion() has not been implemented.");
  }

  /// Restarts the current app without installing a staged update.
  Future<void> restartApp() {
    throw UnimplementedError("restartApp() has not been implemented.");
  }

  /// Installs a staged update, then lets the native helper relaunch the app.
  Future<void> installUpdate({
    /// Platform-specific staged artifact path.
    required String stagingPath,

    /// Legacy-compatible list of files removed during install.
    List<String> removedFiles = const [],

    /// Allows unsigned macOS update artifacts for explicitly trusted lanes.
    bool allowUnsignedMacOSUpdates = false,

    /// Compatibility-only diagnostics path. Standalone helpers use their
    /// fixed platform log sink instead of writing this caller-selected path.
    String? diagnosticsLogPath,
  }) {
    throw UnimplementedError("installUpdate() has not been implemented.");
  }

  /// Returns the current executable path when the platform supports it.
  Future<String?> getExecutablePath() {
    throw UnimplementedError("getExecutablePath() has not been implemented.");
  }

  /// Returns the raw current app version string from the native plugin.
  Future<String?> getCurrentVersion() {
    throw UnimplementedError("getCurrentVersion() has not been implemented.");
  }

  /// Returns macOS install-location status when supported.
  Future<MacOSInstallLocationStatus> checkMacOSInstallLocation() {
    return Future.value(
      const MacOSInstallLocationStatus(
        kind: MacOSInstallLocationKind.unsupported,
        bundlePath: null,
        targetPath: null,
      ),
    );
  }

  /// Moves the running macOS app to `/Applications`.
  Future<void> moveMacOSAppToApplications({
    bool replaceExisting = false,
  }) {
    throw UnimplementedError(
      "moveMacOSAppToApplications() has not been implemented.",
    );
  }

  /// Opens the macOS Background Items settings for helper approval.
  Future<void> openMacOSBackgroundItemsSettings() {
    throw UnimplementedError(
      "openMacOSBackgroundItemsSettings() has not been implemented.",
    );
  }
}

/// Internal install-context handoff that preserves old platform implementers.
extension DesktopUpdaterPlatformInstallContext on DesktopUpdaterPlatform {
  /// Installs a staged update with verified context when a MethodChannel
  /// implementation is active, otherwise uses the compatible
  /// [DesktopUpdaterPlatform.installUpdate] call.
  Future<void> installUpdateWithContext({
    required String stagingPath,
    List<String> removedFiles = const [],
    bool allowUnsignedMacOSUpdates = false,
    String? diagnosticsLogPath,
    String? installRoot,
    String? executableRelativePath,
    String? packageId,
    String? stageProvenanceSha256,
    String? stageProvenanceNonce,
    List<Map<String, Object?>> stageProvenanceEntries = const [],
    String? expectedArtifactSha256,
    List<String> allowedSignerThumbprints = const [],
    String innoRequiresElevation = "auto",
    String? transactionId,
  }) async {
    final platform = this;
    if (platform is MethodChannelDesktopUpdater) {
      return MethodChannelDesktopUpdater.runWithVerifiedInstallContext(
        () => platform.installUpdateWithContext(
          stagingPath: stagingPath,
          removedFiles: removedFiles,
          allowUnsignedMacOSUpdates: allowUnsignedMacOSUpdates,
          diagnosticsLogPath: diagnosticsLogPath,
          installRoot: installRoot,
          executableRelativePath: executableRelativePath,
          packageId: packageId,
          stageProvenanceSha256: stageProvenanceSha256,
          stageProvenanceNonce: stageProvenanceNonce,
          stageProvenanceEntries: stageProvenanceEntries,
          expectedArtifactSha256: expectedArtifactSha256,
          allowedSignerThumbprints: allowedSignerThumbprints,
          innoRequiresElevation: innoRequiresElevation,
          transactionId: transactionId,
        ),
      );
    }
    return installUpdate(
      stagingPath: stagingPath,
      removedFiles: removedFiles,
      allowUnsignedMacOSUpdates: allowUnsignedMacOSUpdates,
      diagnosticsLogPath: diagnosticsLogPath,
    );
  }
}

/// Internal native recovery lookup that preserves released platform subclasses.
extension DesktopUpdaterPlatformNativeRecovery on DesktopUpdaterPlatform {
  /// Queries native helper status when the default MethodChannel adapter is in
  /// use. Custom released platform subclasses keep their existing behavior.
  Future<NativeInstallTransactionStatus?> queryNativeInstallTransaction(
    String transactionId,
  ) {
    final platform = this;
    if (platform.runtimeType == MethodChannelDesktopUpdater) {
      return (platform as MethodChannelDesktopUpdater).queryInstallTransaction(
        transactionId,
      );
    }
    return Future.value();
  }

  /// Requests helper-owned recovery without granting the Dart store mutation
  /// authority.
  Future<NativeInstallTransactionStatus?> recoverNativeInstallTransaction(
    String transactionId,
  ) {
    final platform = this;
    if (platform.runtimeType == MethodChannelDesktopUpdater) {
      return (platform as MethodChannelDesktopUpdater)
          .recoverPendingInstallTransaction(transactionId);
    }
    return Future.value();
  }

  /// Resolves a pending transaction in one elevated exchange. An active
  /// recovery acknowledgement causes the native plugin to exit the app before
  /// the helper mutates or relaunches it.
  Future<NativeInstallTransactionStatus?>
      resolveNativeInstallTransactionAfterExit(String transactionId) {
    final platform = this;
    if (platform.runtimeType == MethodChannelDesktopUpdater) {
      return (platform as MethodChannelDesktopUpdater)
          .resolvePendingInstallTransactionAfterExit(transactionId);
    }
    return Future.value();
  }
}
