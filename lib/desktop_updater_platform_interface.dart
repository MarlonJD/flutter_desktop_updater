import "package:desktop_updater/desktop_updater_method_channel.dart";
import "package:desktop_updater/src/core/install_handoff.dart";
import "package:desktop_updater/src/core/update_client.dart";
import "package:desktop_updater/src/core/update_recovery.dart";
import "package:desktop_updater/src/macos_install_location.dart";
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

  /// Installs a verified staged update, then lets the native helper relaunch.
  Future<void> installVerifiedUpdate(VerifiedNativeInstallRequest request) {
    throw UnimplementedError(
      "installVerifiedUpdate() has not been implemented.",
    );
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

  /// Opens the macOS Background Items settings for helper approval.
  Future<void> openMacOSBackgroundItemsSettings() {
    throw UnimplementedError(
      "openMacOSBackgroundItemsSettings() has not been implemented.",
    );
  }

  /// Typed native recovery capability for this platform.
  NativeInstallRecovery get nativeInstallRecovery {
    throw UnimplementedError(
      "nativeInstallRecovery has not been implemented.",
    );
  }
}

/// Opaque typed native install request created only by this library.
sealed class VerifiedNativeInstallRequest {
  const VerifiedNativeInstallRequest();

  /// Platform-specific staged artifact path.
  String get stagingPath;

  /// Expected package identity from signed metadata and durable receipt.
  String get expectedPackageId;

  /// Expected update version from signed metadata and durable receipt.
  String get updateVersion;

  /// Nullable expected update build number from signed metadata and receipt.
  int? get updateBuildNumber;

  /// Expected target platform from signed metadata and durable receipt.
  String get platform;

  /// Expected release channel from signed metadata and durable receipt.
  String get channel;

  /// Expected artifact SHA-256 from the signed descriptor.
  String get expectedArtifactSha256;

  /// SHA-256 of the retained stage provenance marker.
  String get stageProvenanceSha256;

  /// Durable native helper transaction identifier.
  String get transactionId;
}

final class _VerifiedNativeInstallRequest extends VerifiedNativeInstallRequest {
  const _VerifiedNativeInstallRequest({
    required this.stagingPath,
    required this.expectedPackageId,
    required this.updateVersion,
    required this.updateBuildNumber,
    required this.platform,
    required this.channel,
    required this.expectedArtifactSha256,
    required this.stageProvenanceSha256,
    required this.transactionId,
  });

  @override
  final String stagingPath;
  @override
  final String expectedPackageId;
  @override
  final String updateVersion;
  @override
  final int? updateBuildNumber;
  @override
  final String platform;
  @override
  final String channel;
  @override
  final String expectedArtifactSha256;
  @override
  final String stageProvenanceSha256;
  @override
  final String transactionId;
}

/// Native helper status operation used by typed recovery capabilities.
typedef NativeInstallStatusOperation = Future<NativeInstallTransactionStatus?>
    Function(String transactionId);

/// Sealed native recovery capability exposed by each platform implementation.
sealed class NativeInstallRecovery {
  const NativeInstallRecovery._();

  /// Queries authenticated native helper status for [transactionId].
  Future<NativeInstallTransactionStatus?> queryInstallTransaction(
    String transactionId,
  );
}

/// Recovery capability for helpers that support read-only query plus recover.
final class QueryAndRecoverNativeInstallRecovery extends NativeInstallRecovery {
  /// Creates a query/recover native recovery capability.
  const QueryAndRecoverNativeInstallRecovery({
    required NativeInstallStatusOperation query,
    required NativeInstallStatusOperation recover,
  })  : _query = query,
        _recover = recover,
        super._();

  final NativeInstallStatusOperation _query;
  final NativeInstallStatusOperation _recover;

  @override
  Future<NativeInstallTransactionStatus?> queryInstallTransaction(
    String transactionId,
  ) {
    return _query(transactionId);
  }

  /// Requests helper-owned recovery for [transactionId].
  Future<NativeInstallTransactionStatus?> recoverPendingInstallTransaction(
    String transactionId,
  ) {
    return _recover(transactionId);
  }
}

/// Recovery capability for helpers that must resolve recovery after caller exit.
final class AtomicAfterExitNativeInstallRecovery extends NativeInstallRecovery {
  /// Creates an atomic after-exit native recovery capability.
  const AtomicAfterExitNativeInstallRecovery({
    required NativeInstallStatusOperation query,
    required NativeInstallStatusOperation resolveAfterExit,
  })  : _query = query,
        _resolveAfterExit = resolveAfterExit,
        super._();

  final NativeInstallStatusOperation _query;
  final NativeInstallStatusOperation _resolveAfterExit;

  @override
  Future<NativeInstallTransactionStatus?> queryInstallTransaction(
    String transactionId,
  ) {
    return _query(transactionId);
  }

  /// Resolves a pending install transaction in one exit-bound exchange.
  Future<NativeInstallTransactionStatus?>
      resolvePendingInstallTransactionAfterExit(String transactionId) {
    return _resolveAfterExit(transactionId);
  }
}

/// Claims a staged result and receipt for exactly one native dispatch.
Future<VerifiedNativeInstallRequest> verifiedNativeInstallRequestFromStage({
  required UpdateClient session,
  required UpdateStageResult stageResult,
  required PersistedInstallTransaction receipt,
}) async {
  final retained = await claimRetainedVerifiedStageForDispatch(
    stageResult: stageResult,
    expectedPackageId: receipt.expectedPackageId,
    ownerToken: session.ownerTokenForDispatch,
    generation: stageResult.generationForDispatch,
  );
  final descriptor = stageResult.descriptor;
  if (descriptor.packageId != receipt.expectedPackageId ||
      descriptor.version != receipt.updateVersion ||
      descriptor.buildNumber != receipt.updateBuildNumber ||
      descriptor.platform != receipt.platform ||
      descriptor.channel != receipt.channel) {
    throw StateError(
      "Persisted install transaction does not match the signed release "
      "descriptor.",
    );
  }
  if (retained.stagingPath != receipt.stagingPath ||
      retained.state.markerSha256 != receipt.stageProvenanceSha256 ||
      stageResult.stageProvenanceSha256 != receipt.stageProvenanceSha256 ||
      retained.state.provenance.packageId != descriptor.packageId ||
      retained.state.provenance.artifactSha256 != descriptor.artifact.sha256) {
    throw StateError(
      "Persisted install transaction does not match the verified stage.",
    );
  }
  return _VerifiedNativeInstallRequest(
    stagingPath: receipt.stagingPath,
    expectedPackageId: receipt.expectedPackageId,
    updateVersion: receipt.updateVersion,
    updateBuildNumber: receipt.updateBuildNumber,
    platform: receipt.platform,
    channel: receipt.channel,
    expectedArtifactSha256: descriptor.artifact.sha256,
    stageProvenanceSha256: receipt.stageProvenanceSha256,
    transactionId: receipt.transactionId,
  );
}

/// Claims a verified stage and dispatches the resulting typed request.
Future<void> dispatchVerifiedInstall({
  required UpdateClient session,
  required UpdateStageResult stageResult,
  required PersistedInstallTransaction persistedTransaction,
}) async {
  final request = await verifiedNativeInstallRequestFromStage(
    session: session,
    stageResult: stageResult,
    receipt: persistedTransaction,
  );
  await DesktopUpdaterPlatform.instance.installVerifiedUpdate(request);
}
