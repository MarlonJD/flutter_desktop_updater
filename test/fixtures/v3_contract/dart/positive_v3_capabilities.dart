import "package:desktop_updater/desktop_updater.dart";
import "package:desktop_updater/desktop_updater_platform_interface.dart";
import "package:desktop_updater/src/core/install_handoff.dart";
import "package:desktop_updater/src/core/update_client.dart";
import "package:desktop_updater/src/core/update_recovery.dart";

import "support.dart";

Future<NativeInstallTransactionStatus?> _status(String id) async => null;

void main() {
  final marker = UpdateInstallRecoveryMarker.pendingV3(
    createdAt: DateTime.utc(2026, 8, 3),
    packageVersion: "3.0.0",
    platform: "windows",
    channel: "stable",
    updateVersion: "3.0.0",
    updateBuildNumber: null,
    expectedPackageId: "com.example.desktop",
    stagingPath: r"C:\stage\Example.app",
    stageProvenanceSha256: "a" * 64,
    transactionId: "00000000-0000-4000-8000-000000000001",
  );
  final session = DesktopUpdater().createZipFirstUpdateSession(
    appArchiveUrl: Uri.parse(
      "https://updates.example.test/app-archive.json",
    ),
    currentVersion: DesktopVersionInfo.parse("2.7.0"),
    expectedPackageId: "com.example.desktop",
    trustedReleasePublicKeys: trustedReleasePublicKeys,
  );
  final queryAndRecover = QueryAndRecoverNativeInstallRecovery(
    query: _status,
    recover: _status,
  );
  final atomic = AtomicAfterExitNativeInstallRecovery(
    query: _status,
    resolveAfterExit: _status,
  );
  final persist = persistInstallTransaction;
  final claim = claimRetainedVerifiedStageForDispatch;
  final dispatch = dispatchVerifiedInstall;

  assert(
    marker.transactionId != null &&
        session is ZipFirstUpdateSession &&
        queryAndRecover is NativeInstallRecovery &&
        atomic is NativeInstallRecovery &&
        persist is Function &&
        claim is Function &&
        dispatch is Function,
  );
}
