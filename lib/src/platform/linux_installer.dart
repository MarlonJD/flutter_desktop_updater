import "package:desktop_updater/desktop_updater_platform_interface.dart";
import "package:desktop_updater/src/platform/platform_installer.dart";

class LinuxInstaller implements PlatformInstaller {
  const LinuxInstaller();

  @override
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
}
