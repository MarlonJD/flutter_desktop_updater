import "package:desktop_updater/desktop_updater_platform_interface.dart";

final class LegacyPlatform extends DesktopUpdaterPlatform {
  @override
  Future<void> installUpdate({
    required String stagingPath,
    List<String> removedFiles = const <String>[],
    bool allowUnsignedMacOSUpdates = false,
    String? diagnosticsLogPath,
  }) async {}
}
