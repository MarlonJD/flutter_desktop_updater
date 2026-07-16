import "dart:async";
import "dart:io";

import "package:desktop_updater/desktop_updater_platform_interface.dart";
import "package:desktop_updater/src/core/staged_update_provenance.dart";
import "package:desktop_updater/src/core/update_client.dart"
    show retainedVerifiedStageFor;
import "package:desktop_updater/src/core/update_recovery.dart";
import "package:desktop_updater/src/macos_install_location.dart";
import "package:flutter/foundation.dart";
import "package:flutter/services.dart";

final Object _installUpdateContextZoneKey = Object();
final Object _verifiedInstallContextDispatch = Object();

class _InstallUpdateContext {
  const _InstallUpdateContext({
    required this.owner,
    required this.stagingPath,
    required this.removedFiles,
    required this.allowUnsignedMacOSUpdates,
    required this.diagnosticsLogPath,
    required this.installRoot,
    required this.executableRelativePath,
    required this.packageId,
    required this.stageProvenanceSha256,
    required this.stageProvenanceNonce,
    required this.stageProvenanceEntries,
    required this.expectedArtifactSha256,
    required this.allowedSignerThumbprints,
    required this.innoRequiresElevation,
    required this.transactionId,
    required this.resolveMissingVerifiedContext,
  });

  final MethodChannelDesktopUpdater owner;
  final String stagingPath;
  final List<String> removedFiles;
  final bool allowUnsignedMacOSUpdates;
  final String? diagnosticsLogPath;
  final String? installRoot;
  final String? executableRelativePath;
  final String? packageId;
  final String? stageProvenanceSha256;
  final String? stageProvenanceNonce;
  final List<Map<String, Object?>> stageProvenanceEntries;
  final String? expectedArtifactSha256;
  final List<String> allowedSignerThumbprints;
  final String innoRequiresElevation;
  final String? transactionId;
  final bool resolveMissingVerifiedContext;

  Future<_InstallUpdateContext> resolveVerifiedContext() async {
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
      final retained = await retainedVerifiedStageFor(stagingPath);
      if (retained == null) {
        throw StateError(
          "Legacy installs require retained verified stage provenance "
          "from UpdateClient staging.",
        );
      }
      final stageRoot = Directory(retained.stageRoot);
      final state = retained.state;
      final provenance = await verifyStagedUpdateProvenance(
        stageRoot: stageRoot,
        expectedMarkerSha256: state.markerSha256,
      );
      if (provenance.canonicalJson != state.provenance.canonicalJson) {
        throw StateError("Retained verified stage provenance changed.");
      }
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
    return _InstallUpdateContext(
      owner: owner,
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
      innoRequiresElevation: innoRequiresElevation,
      transactionId: transactionId,
      resolveMissingVerifiedContext: resolveMissingVerifiedContext,
    );
  }
}

/// An implementation of [DesktopUpdaterPlatform] that uses method channels.
class MethodChannelDesktopUpdater extends DesktopUpdaterPlatform {
  /// Runs an install-context call as verified platform-interface dispatch.
  static Future<T> runWithVerifiedInstallContext<T>(
    Future<T> Function() action,
  ) {
    return runZoned<Future<T>>(
      action,
      zoneValues: {
        _installUpdateContextZoneKey: _verifiedInstallContextDispatch,
      },
    );
  }

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
    final context = Zone.current[_installUpdateContextZoneKey];
    if (context is _InstallUpdateContext && identical(context.owner, this)) {
      final resolvedContext = context.resolveMissingVerifiedContext
          ? await context.resolveVerifiedContext()
          : context;
      await _invokeInstallUpdate(
        stagingPath: stagingPath,
        removedFiles: removedFiles,
        allowUnsignedMacOSUpdates: allowUnsignedMacOSUpdates,
        diagnosticsLogPath: diagnosticsLogPath,
        installRoot: resolvedContext.installRoot,
        executableRelativePath: resolvedContext.executableRelativePath,
        packageId: resolvedContext.packageId,
        stageProvenanceSha256: resolvedContext.stageProvenanceSha256,
        stageProvenanceNonce: resolvedContext.stageProvenanceNonce,
        stageProvenanceEntries: resolvedContext.stageProvenanceEntries,
        expectedArtifactSha256: resolvedContext.expectedArtifactSha256,
        allowedSignerThumbprints: resolvedContext.allowedSignerThumbprints,
        innoRequiresElevation: resolvedContext.innoRequiresElevation,
        transactionId: resolvedContext.transactionId,
      );
      return;
    }
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
    String? transactionId,
  }) async {
    final context = _InstallUpdateContext(
      owner: this,
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
      resolveMissingVerifiedContext: identical(
        Zone.current[_installUpdateContextZoneKey],
        _verifiedInstallContextDispatch,
      ),
    );
    await runZoned<Future<void>>(
      () => installUpdate(
        stagingPath: stagingPath,
        removedFiles: removedFiles,
        allowUnsignedMacOSUpdates: allowUnsignedMacOSUpdates,
        diagnosticsLogPath: diagnosticsLogPath,
      ),
      zoneValues: {_installUpdateContextZoneKey: context},
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
    String? transactionId,
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
    if (transactionId != null && transactionId.isNotEmpty) {
      arguments["transactionId"] = transactionId;
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

  @override
  Future<void> openMacOSBackgroundItemsSettings() async {
    await methodChannel.invokeMethod<void>(
      "openMacOSBackgroundItemsSettings",
    );
  }

  /// Returns structured native version metadata for update checks.
  Future<Map<String, String?>?> getCurrentVersionInfo() async {
    final versionInfo = await methodChannel.invokeMapMethod<String, String?>(
      "getCurrentVersionInfo",
    );
    return versionInfo == null ? null : Map<String, String?>.from(versionInfo);
  }

  /// Queries read-only transaction status from the authenticated native helper.
  Future<NativeInstallTransactionStatus> queryInstallTransaction(
    String transactionId,
  ) async {
    return _invokeTransactionStatus(
      "queryInstallTransaction",
      transactionId,
    );
  }

  /// Asks the authenticated native helper to recover its pending transaction.
  Future<NativeInstallTransactionStatus> recoverPendingInstallTransaction(
    String transactionId,
  ) async {
    return _invokeTransactionStatus(
      "recoverPendingInstallTransaction",
      transactionId,
    );
  }

  /// Acknowledges active recovery, exits, then lets the helper recover and
  /// relaunch with the captured caller token.
  Future<NativeInstallTransactionStatus>
      resolvePendingInstallTransactionAfterExit(
    String transactionId,
  ) async {
    return _invokeTransactionStatus(
      "resolvePendingInstallTransactionAfterExit",
      transactionId,
    );
  }

  Future<NativeInstallTransactionStatus> _invokeTransactionStatus(
    String method,
    String transactionId,
  ) async {
    if (transactionId.isEmpty) {
      throw ArgumentError.value(
        transactionId,
        "transactionId",
        "must not be empty",
      );
    }
    final status = await methodChannel.invokeMapMethod<String, Object?>(
      method,
      {"transactionId": transactionId},
    );
    if (status == null) {
      throw StateError("Native helper returned no transaction status.");
    }
    final parsed = NativeInstallTransactionStatus.fromJson(
      Map<String, Object?>.from(status),
    );
    if (parsed.transactionId != transactionId) {
      throw const FormatException(
        "Native helper changed the transaction binding.",
      );
    }
    return parsed;
  }
}
