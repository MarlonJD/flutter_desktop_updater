import "package:desktop_updater/desktop_updater_method_channel.dart";
import "package:desktop_updater/src/app_archive.dart";
import "package:plugin_platform_interface/plugin_platform_interface.dart";

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

  Future<String?> getPlatformVersion() {
    throw UnimplementedError("platformVersion() has not been implemented.");
  }

  Future<void> restartApp() {
    throw UnimplementedError("restartApp() has not been implemented.");
  }

  Future<void> installUpdate({
    required String stagingPath,
    List<String> removedFiles = const [],
  }) {
    throw UnimplementedError("installUpdate() has not been implemented.");
  }

  Future<String?> sayHello() {
    throw UnimplementedError("sayHello() has not been implemented.");
  }

  Future<String?> getExecutablePath() {
    throw UnimplementedError("getExecutablePath() has not been implemented.");
  }

  Future<void> generateFileHashes({String? path}) {
    throw UnimplementedError("generateFileHashes() has not been implemented.");
  }

  Future<List<FileHashModel?>> verifyFileHash(
    String oldHashFilePath,
    String newHashFilePath,
  ) {
    throw UnimplementedError("verifyFileHash() has not been implemented.");
  }

  Future<void> updateApp({required String remoteUpdateFolder}) {
    throw UnimplementedError("updateApp() has not been implemented.");
  }

  Future<List<FileHashModel?>> prepareUpdateApp({
    required String remoteUpdateFolder,
  }) {
    throw UnimplementedError("prepareUpdateApp() has not been implemented.");
  }

  Future<String?> getCurrentVersion() {
    throw UnimplementedError("getCurrentVersion() has not been implemented.");
  }
}
