import "dart:io";

import "package:desktop_updater/src/core/install_handoff.dart";
import "package:desktop_updater/updater_controller.dart";
import "package:flutter_test/flutter_test.dart";

import "../example/lib/json_file_update_recovery_store.dart";

void main() {
  test("file recovery store durably round-trips every v3 field", () async {
    final root = await Directory.systemTemp.createTemp("example_recovery_");
    addTearDown(() => root.delete(recursive: true));
    final store = JsonFileUpdateRecoveryStore(File("${root.path}/marker.json"));
    final marker = UpdateInstallRecoveryMarker.pendingV3(
      createdAt: DateTime.utc(2026, 8, 3, 12, 34, 56),
      packageVersion: "3.0.0",
      platform: "linux",
      channel: "stable",
      appVersion: "2.0.1+201",
      updateVersion: "2.7.1",
      updateBuildNumber: 271,
      expectedPackageId: "com.example.desktop_updater",
      stagingPath: "/tmp/desktop_updater_stage_owned",
      stageProvenanceSha256: List<String>.filled(64, "a").join(),
      diagnosticsText: "pending",
      transactionId: "123e4567-e89b-42d3-a456-426614174000",
    );

    final receipt = await persistInstallTransaction(
      store: store,
      marker: marker,
    );

    expect(receipt.marker.createdAt, marker.createdAt);
    expect(receipt.marker.packageVersion, marker.packageVersion);
    expect(receipt.marker.platform, marker.platform);
    expect(receipt.marker.channel, marker.channel);
    expect(receipt.marker.appVersion, marker.appVersion);
    expect(receipt.marker.updateVersion, marker.updateVersion);
    expect(receipt.marker.updateBuildNumber, marker.updateBuildNumber);
    expect(receipt.marker.expectedPackageId, marker.expectedPackageId);
    expect(receipt.marker.stagingPath, marker.stagingPath);
    expect(
      receipt.marker.stageProvenanceSha256,
      marker.stageProvenanceSha256,
    );
    expect(receipt.marker.diagnosticsText, marker.diagnosticsText);
    expect(receipt.marker.transactionId, marker.transactionId);

    await store.clearPendingInstall(channel: "stable");
    expect(await store.readPendingInstall(channel: "stable"), isNull);
  });
}
