import "package:desktop_updater/desktop_updater_platform_interface.dart";
import "package:desktop_updater/src/core/update_recovery.dart";

final class VerifiedPlatform extends DesktopUpdaterPlatform {
  @override
  Future<void> installVerifiedUpdate(
      VerifiedNativeInstallRequest request) async {
    final requiredPayload = <String>[
      request.stagingPath,
      request.expectedPackageId,
      request.updateVersion,
      request.updateBuildNumber?.toString() ?? "",
      request.platform,
      request.channel,
      request.expectedArtifactSha256,
      request.stageProvenanceSha256,
      request.transactionId,
    ];
    assert(requiredPayload.length == 9);
  }

  @override
  NativeInstallRecovery get nativeInstallRecovery =>
      AtomicAfterExitNativeInstallRecovery(
        query: _status,
        resolveAfterExit: _status,
      );
}

Future<NativeInstallTransactionStatus?> _status(String id) async => null;
