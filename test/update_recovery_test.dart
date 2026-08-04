import "package:desktop_updater/desktop_updater.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  test("pending v3 marker requires transaction identity and stage binding", () {
    final marker = UpdateInstallRecoveryMarker.pendingV3(
      createdAt: DateTime.utc(2026, 8, 3, 12, 30),
      packageVersion: "3.0.0",
      platform: "macos",
      channel: "stable",
      appVersion: "1.0.0+100",
      updateVersion: "2.0.0",
      updateBuildNumber: null,
      expectedPackageId: "com.example.app",
      stagingPath: "/tmp/desktop_updater_stage",
      stageProvenanceSha256: "a" * 64,
      diagnosticsText: "redacted diagnostics",
      transactionId: "123e4567-e89b-42d3-a456-426614174000",
    );

    expect(marker.expectedPackageId, "com.example.app");
    expect(marker.stageProvenanceSha256, "a" * 64);
    expect(marker.updateBuildNumber, isNull);
    expect(marker.transactionId, "123e4567-e89b-42d3-a456-426614174000");

    expect(
      () => UpdateInstallRecoveryMarker.pendingV3(
        createdAt: DateTime.utc(2026, 8, 3),
        packageVersion: "3.0.0",
        platform: "macos",
        channel: "stable",
        appVersion: "1.0.0+100",
        updateVersion: "2.0.0",
        updateBuildNumber: null,
        expectedPackageId: " ",
        stagingPath: "/tmp/desktop_updater_stage",
        stageProvenanceSha256: "a" * 64,
        diagnosticsText: null,
        transactionId: "123e4567-e89b-42d3-a456-426614174000",
      ),
      throwsArgumentError,
    );
    expect(
      () => UpdateInstallRecoveryMarker.pendingV3(
        createdAt: DateTime.utc(2026, 8, 3),
        packageVersion: "3.0.0",
        platform: "macos",
        channel: "stable",
        appVersion: "1.0.0+100",
        updateVersion: "2.0.0",
        updateBuildNumber: null,
        expectedPackageId: "com.example.app",
        stagingPath: "/tmp/desktop_updater_stage",
        stageProvenanceSha256: "A" * 64,
        diagnosticsText: null,
        transactionId: "123e4567-e89b-42d3-a456-426614174000",
      ),
      throwsArgumentError,
    );
    expect(
      () => UpdateInstallRecoveryMarker.pendingV3(
        createdAt: DateTime.utc(2026, 8, 3),
        packageVersion: "3.0.0",
        platform: "macos",
        channel: "stable",
        appVersion: "1.0.0+100",
        updateVersion: "2.0.0",
        updateBuildNumber: null,
        expectedPackageId: "com.example.app",
        stagingPath: "/tmp/desktop_updater_stage",
        stageProvenanceSha256: "a" * 64,
        diagnosticsText: null,
        transactionId: "123E4567-E89B-42D3-A456-426614174000",
      ),
      throwsArgumentError,
    );
  });

  test("install recovery marker retains app-owned recovery fields", () {
    final marker = UpdateInstallRecoveryMarker(
      createdAt: DateTime.utc(2026, 6, 16, 10),
      packageVersion: "2.1.4",
      platform: "macos",
      channel: "beta",
      appVersion: "1.0.0+100",
      updateVersion: "2.0.1",
      updateBuildNumber: 201,
      stagingPath: "/tmp/staged-app",
      diagnosticsText: "redacted diagnostics",
      transactionId: "123e4567-e89b-42d3-a456-426614174000",
    );

    expect(marker.createdAt, DateTime.utc(2026, 6, 16, 10));
    expect(marker.packageVersion, "2.1.4");
    expect(marker.platform, "macos");
    expect(marker.channel, "beta");
    expect(marker.appVersion, "1.0.0+100");
    expect(marker.updateVersion, "2.0.1");
    expect(marker.updateBuildNumber, 201);
    expect(marker.stagingPath, "/tmp/staged-app");
    expect(marker.diagnosticsText, "redacted diagnostics");
    expect(marker.transactionId, "123e4567-e89b-42d3-a456-426614174000");
  });

  test("native transaction status keeps helper authority explicit", () {
    final status = NativeInstallTransactionStatus.fromJson({
      "transactionId": "123e4567-e89b-42d3-a456-426614174000",
      "state": "completed",
      "resultCode": "succeeded",
      "detail": "Install completed.",
      "responseDigestSha256": "a" * 64,
      "helperEndpointIdentitySha256": "b" * 64,
    });

    expect(status.state, NativeInstallTransactionState.completed);
    expect(status.resultCode, NativeInstallTransactionResultCode.succeeded);
    expect(status.isTerminalSuccess, isTrue);
    expect(status.requiresRecovery, isFalse);
  });

  test("recovery-required helper status remains non-authoritative UX data", () {
    final status = NativeInstallTransactionStatus.fromJson({
      "transactionId": "123e4567-e89b-42d3-a456-426614174000",
      "state": "prepared",
      "resultCode": "recoveryRequired",
      "detail": "Recovery is required.",
      "responseDigestSha256": "a" * 64,
      "helperEndpointIdentitySha256": "b" * 64,
    });

    expect(status.requiresRecovery, isTrue);
    expect(status.isTerminalSuccess, isFalse);
  });

  test("manual action is not an active caller-exit acknowledgement", () {
    final status = NativeInstallTransactionStatus.fromJson({
      "transactionId": "123e4567-e89b-42d3-a456-426614174000",
      "state": "manualActionRequired",
      "resultCode": "recoveryRequired",
      "detail": "Operator action is required.",
      "responseDigestSha256": "a" * 64,
      "helperEndpointIdentitySha256": "b" * 64,
    });

    expect(status.requiresRecovery, isTrue);
    expect(status.awaitsCallerExit, isFalse);
  });

  test("relaunch failure is a distinct terminal non-recovery result", () {
    final status = NativeInstallTransactionStatus.fromJson({
      "transactionId": "123e4567-e89b-42d3-a456-426614174000",
      "state": "completed",
      "resultCode": "relaunchFailure",
      "detail": "The verified application was not relaunched.",
      "responseDigestSha256": "a" * 64,
      "helperEndpointIdentitySha256": "b" * 64,
    });

    expect(
      status.resultCode,
      NativeInstallTransactionResultCode.relaunchFailure,
    );
    expect(status.isTerminalSuccess, isFalse);
    expect(status.isTerminalFailure, isFalse);
    expect(status.awaitsCallerExit, isFalse);
    expect(status.requiresRecovery, isFalse);
  });

  test("app-owned recovery store contract can read write and clear by channel",
      () async {
    final store = _MemoryRecoveryStore();
    final stable = UpdateInstallRecoveryMarker(
      createdAt: DateTime.utc(2026, 6, 16, 10),
      packageVersion: "2.1.4",
      platform: "linux",
      channel: "stable",
    );
    final beta = UpdateInstallRecoveryMarker(
      createdAt: DateTime.utc(2026, 6, 16, 11),
      packageVersion: "2.1.4",
      platform: "linux",
      channel: "beta",
    );

    await store.writePendingInstall(stable);
    await store.writePendingInstall(beta);

    expect(await store.readPendingInstall(channel: "stable"), same(stable));
    expect(await store.readPendingInstall(channel: "beta"), same(beta));

    await store.clearPendingInstall(channel: "stable");

    expect(await store.readPendingInstall(channel: "stable"), isNull);
    expect(await store.readPendingInstall(channel: "beta"), same(beta));
  });
}

class _MemoryRecoveryStore implements UpdateRecoveryStore {
  final _markers = <String, UpdateInstallRecoveryMarker>{};

  @override
  Future<UpdateInstallRecoveryMarker?> readPendingInstall({
    required String channel,
  }) async {
    return _markers[channel];
  }

  @override
  Future<void> writePendingInstall(UpdateInstallRecoveryMarker marker) async {
    _markers[marker.channel] = marker;
  }

  @override
  Future<void> clearPendingInstall({required String channel}) async {
    _markers.remove(channel);
  }
}
