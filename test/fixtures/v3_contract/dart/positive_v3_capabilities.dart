import "package:desktop_updater/desktop_updater.dart";
import "package:desktop_updater/desktop_updater_platform_interface.dart";
import "package:desktop_updater/src/core/install_handoff.dart";
import "package:desktop_updater/src/core/update_client.dart";

import "support.dart";

Future<NativeInstallTransactionStatus?> _status(String id) async => null;

void main() {
  final marker = UpdateInstallRecoveryMarker.pendingV3(
    createdAt: DateTime.utc(2026, 8, 3),
    packageVersion: "3.0.0",
    platform: "windows",
    channel: "stable",
    appVersion: "2.7.0",
    updateVersion: "3.0.0",
    updateBuildNumber: null,
    expectedPackageId: "com.example.desktop",
    stagingPath: r"C:\stage\Example.app",
    stageProvenanceSha256: "a" * 64,
    diagnosticsText: null,
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
  const queryAndRecover = QueryAndRecoverNativeInstallRecovery(
    query: _status,
    recover: _status,
  );
  const atomic = AtomicAfterExitNativeInstallRecovery(
    query: _status,
    resolveAfterExit: _status,
  );
  final capabilities = <Object?>[
    marker,
    session,
    queryAndRecover,
    atomic,
    persistInstallTransaction,
    claimRetainedVerifiedStageForDispatch,
    dispatchVerifiedInstall,
  ];

  assert(
    marker.transactionId != null &&
        capabilities.length == 7 &&
        queryAndRecover.queryInstallTransaction == _status &&
        queryAndRecover.recoverPendingInstallTransaction == _status &&
        atomic.queryInstallTransaction == _status &&
        atomic.resolvePendingInstallTransactionAfterExit == _status,
    "v3 capabilities must compile as a coherent typed surface",
  );
}
