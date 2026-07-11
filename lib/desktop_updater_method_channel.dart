import "package:desktop_updater/desktop_updater_platform_interface.dart";
import "package:desktop_updater/src/macos_install_location.dart";
import "package:flutter/foundation.dart";
import "package:flutter/services.dart";

/// An implementation of [DesktopUpdaterPlatform] that uses method channels.
class MethodChannelDesktopUpdater extends DesktopUpdaterPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel("desktop_updater");

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>(
      "getPlatformVersion",
    );
    return version;
  }

  @override
  Future<void> restartApp() async {
    await methodChannel.invokeMethod<void>("restartApp");
  }

  @override
  Future<void> installUpdate({
    required String stagingPath,
    List<String> removedFiles = const [],
    bool allowUnsignedMacOSUpdates = false,
    String? diagnosticsLogPath,
  }) async {
    await _invokeInstallUpdate(
      stagingPath: stagingPath,
      removedFiles: removedFiles,
      allowUnsignedMacOSUpdates: allowUnsignedMacOSUpdates,
      diagnosticsLogPath: diagnosticsLogPath,
    );
  }

  /// Installs a staged update with optional native target validation context.
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
  }) async {
    await _invokeInstallUpdate(
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
    );
  }

  Future<void> _invokeInstallUpdate({
    required String stagingPath,
    required List<String> removedFiles,
    required bool allowUnsignedMacOSUpdates,
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
  }) async {
    if (!const {"auto", "always", "never"}.contains(innoRequiresElevation)) {
      throw ArgumentError.value(
        innoRequiresElevation,
        "innoRequiresElevation",
        "must be auto, always, or never",
      );
    }
    final arguments = <String, Object?>{
      "stagingPath": stagingPath,
      "removedFiles": removedFiles,
      "allowUnsignedMacOSUpdates": allowUnsignedMacOSUpdates,
    };
    if (diagnosticsLogPath != null && diagnosticsLogPath.isNotEmpty) {
      arguments["diagnosticsLogPath"] = diagnosticsLogPath;
    }
    if (installRoot != null && installRoot.isNotEmpty) {
      arguments["installRoot"] = installRoot;
    }
    if (executableRelativePath != null && executableRelativePath.isNotEmpty) {
      arguments["executableRelativePath"] = executableRelativePath;
    }
    if (packageId != null && packageId.isNotEmpty) {
      arguments["packageId"] = packageId;
    }
    if (stageProvenanceSha256 != null && stageProvenanceSha256.isNotEmpty) {
      arguments["stageProvenanceSha256"] = stageProvenanceSha256;
    }
    if (stageProvenanceNonce != null && stageProvenanceNonce.isNotEmpty) {
      arguments["stageProvenanceNonce"] = stageProvenanceNonce;
    }
    if (stageProvenanceEntries.isNotEmpty) {
      arguments["stageProvenanceEntries"] = stageProvenanceEntries;
    }
    if (expectedArtifactSha256 != null && expectedArtifactSha256.isNotEmpty) {
      arguments["expectedArtifactSha256"] = expectedArtifactSha256;
    }
    if (allowedSignerThumbprints.isNotEmpty) {
      arguments["allowedSignerThumbprints"] = allowedSignerThumbprints;
    }
    if (innoRequiresElevation != "auto") {
      arguments["innoRequiresElevation"] = innoRequiresElevation;
    }
    await methodChannel.invokeMethod<void>("installUpdate", arguments);
  }

  @override
  Future<String?> getExecutablePath() async {
    return methodChannel.invokeMethod<String>("getExecutablePath");
  }

  @override
  Future<String?> getCurrentVersion() async {
    return methodChannel.invokeMethod<String>("getCurrentVersion");
  }

  @override
  Future<MacOSInstallLocationStatus> checkMacOSInstallLocation() async {
    final status = await methodChannel.invokeMapMethod<String, Object?>(
      "checkMacOSInstallLocation",
    );
    if (status == null) {
      return const MacOSInstallLocationStatus(
        kind: MacOSInstallLocationKind.unsupported,
        bundlePath: null,
        targetPath: null,
      );
    }
    return MacOSInstallLocationStatus.fromJson(
      Map<String, Object?>.from(status),
    );
  }

  @override
  Future<void> moveMacOSAppToApplications({
    bool replaceExisting = false,
  }) async {
    await methodChannel.invokeMethod<void>(
      "moveMacOSAppToApplications",
      {"replaceExisting": replaceExisting},
    );
  }

  /// Returns structured native version metadata for update checks.
  Future<Map<String, String?>?> getCurrentVersionInfo() async {
    final versionInfo = await methodChannel.invokeMapMethod<String, String?>(
      "getCurrentVersionInfo",
    );
    return versionInfo == null ? null : Map<String, String?>.from(versionInfo);
  }
}
