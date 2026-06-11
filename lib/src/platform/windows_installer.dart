import "package:desktop_updater/desktop_updater_platform_interface.dart";
import "package:desktop_updater/src/platform/platform_installer.dart";

class WindowsInstaller implements PlatformInstaller {
  const WindowsInstaller();

  @override
  Future<void> installUpdate({
    required String stagingPath,
    List<String> removedFiles = const [],
  }) {
    return DesktopUpdaterPlatform.instance.installUpdate(
      stagingPath: stagingPath,
      removedFiles: removedFiles,
    );
  }
}
