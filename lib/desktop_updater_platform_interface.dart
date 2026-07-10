import "dart:io";

import "package:desktop_updater/desktop_updater_method_channel.dart";
import "package:desktop_updater/src/core/staged_update_provenance.dart";
import "package:desktop_updater/src/macos_install_location.dart";
import "package:path/path.dart" as path;
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
}

/// Internal install-context handoff that preserves old platform implementers.
extension DesktopUpdaterPlatformInstallContext on DesktopUpdaterPlatform {
  /// Installs a staged update with verified context when the default
  /// MethodChannel implementation is active, otherwise uses the compatible
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
  }) async {
    final platform = this;
    if (platform.runtimeType == MethodChannelDesktopUpdater) {
      final methodChannel = platform as MethodChannelDesktopUpdater;
      var resolvedPackageId = packageId;
      var resolvedProvenanceSha256 = stageProvenanceSha256;
      var resolvedProvenanceNonce = stageProvenanceNonce;
      var resolvedProvenanceEntries = stageProvenanceEntries;
      var resolvedArtifactSha256 = expectedArtifactSha256;
      if (resolvedPackageId == null ||
          resolvedPackageId.isEmpty ||
          resolvedProvenanceSha256 == null ||
          resolvedProvenanceSha256.isEmpty ||
          resolvedProvenanceNonce == null ||
          resolvedProvenanceNonce.isEmpty ||
          resolvedProvenanceEntries.isEmpty ||
          resolvedArtifactSha256 == null ||
          resolvedArtifactSha256.isEmpty) {
        final stageRoot = await _verifiedStageRoot(stagingPath);
        final state = await readStagedUpdateProvenance(stageRoot: stageRoot);
        final provenance = await verifyStagedUpdateProvenance(
          stageRoot: stageRoot,
          expectedMarkerSha256: state.markerSha256,
        );
        if (resolvedPackageId != null &&
            resolvedPackageId.isNotEmpty &&
            resolvedPackageId != provenance.packageId) {
          throw StateError(
            "Explicit package identity does not match verified stage provenance.",
          );
        }
        resolvedPackageId = provenance.packageId;
        resolvedProvenanceSha256 = state.markerSha256;
        resolvedProvenanceNonce = provenance.nonce;
        resolvedProvenanceEntries = provenance.entries
            .map((entry) => Map<String, Object?>.from(entry.toJson()))
            .toList(growable: false);
        resolvedArtifactSha256 = provenance.artifactSha256;
      }
      return methodChannel.installUpdateWithContext(
        stagingPath: stagingPath,
        removedFiles: removedFiles,
        allowUnsignedMacOSUpdates: allowUnsignedMacOSUpdates,
        diagnosticsLogPath: diagnosticsLogPath,
        installRoot: installRoot,
        executableRelativePath: executableRelativePath,
        packageId: resolvedPackageId,
        stageProvenanceSha256: resolvedProvenanceSha256,
        stageProvenanceNonce: resolvedProvenanceNonce,
        stageProvenanceEntries: resolvedProvenanceEntries,
        expectedArtifactSha256: resolvedArtifactSha256,
        allowedSignerThumbprints: allowedSignerThumbprints,
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

Future<Directory> _verifiedStageRoot(String stagingPath) async {
  final candidate = Directory(stagingPath);
  if (await File(
    path.join(candidate.path, stagedUpdateProvenanceFileName),
  ).exists()) {
    return candidate;
  }
  final parent = candidate.parent;
  if (await File(
    path.join(parent.path, stagedUpdateProvenanceFileName),
  ).exists()) {
    return parent;
  }
  throw const FormatException(
    "Stage provenance marker is missing from the staged update root.",
  );
}
