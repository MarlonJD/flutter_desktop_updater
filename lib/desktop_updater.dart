import "package:desktop_updater/desktop_updater_platform_interface.dart";
import "package:desktop_updater/src/app_archive.dart";
import "package:desktop_updater/src/file_hash.dart";

class DesktopUpdater {
  Future<String?> getPlatformVersion() {
    return DesktopUpdaterPlatform.instance.getPlatformVersion();
  }

  Future<String?> sayHello() {
    return Future.value("Hello from DesktopUpdater!");
  }

  /// Uygulamayı kapatır ve yeniden başlatır
  Future<void> restartApp() {
    return DesktopUpdaterPlatform.instance.restartApp();
  }

  Future<String?> getExecutablePath() {
    return DesktopUpdaterPlatform.instance.getExecutablePath();
  }

  Future<List<FileHashModel?>> verifyFileHash(String oldHashFilePath, String newHashFilePath) {
    return verifyFileHashes(oldHashFilePath, newHashFilePath);
  }

  Future<String?> generateFileHashes({String? path}) {
    return genFileHashes(path: path);
  }
  
}
