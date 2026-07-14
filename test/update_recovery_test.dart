import "package:desktop_updater/desktop_updater.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
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
