import "package:desktop_updater/desktop_updater_platform_interface.dart";
import "package:desktop_updater/src/core/update_recovery.dart";
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
  Future<void> installVerifiedUpdate(
      VerifiedNativeInstallRequest request) async {
    final arguments = <String, Object?>{
      "stagingPath": request.stagingPath,
      "expectedPackageId": request.expectedPackageId,
      "expectedArtifactSha256": request.expectedArtifactSha256,
      "stageProvenanceSha256": request.stageProvenanceSha256,
      "transactionId": request.transactionId,
    };
    await methodChannel.invokeMethod<void>("installUpdate", arguments);
  }

  @override
  NativeInstallRecovery get nativeInstallRecovery {
    return switch (defaultTargetPlatform) {
      TargetPlatform.windows => AtomicAfterExitNativeInstallRecovery(
          query: queryInstallTransaction,
          resolveAfterExit: resolvePendingInstallTransactionAfterExit,
        ),
      TargetPlatform.macOS ||
      TargetPlatform.linux =>
        QueryAndRecoverNativeInstallRecovery(
          query: queryInstallTransaction,
          recover: recoverPendingInstallTransaction,
        ),
      _ => QueryAndRecoverNativeInstallRecovery(
          query: queryInstallTransaction,
          recover: recoverPendingInstallTransaction,
        ),
    };
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
