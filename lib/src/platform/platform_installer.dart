abstract interface class PlatformInstaller {
  Future<void> installUpdate({
    required String stagingPath,
    List<String> removedFiles,
    bool allowUnsignedMacOSUpdates = false,
  });
}
