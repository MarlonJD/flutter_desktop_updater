import "package:desktop_updater/desktop_updater_method_channel.dart";
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

    /// Optional app-owned native helper diagnostics log path.
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
}
