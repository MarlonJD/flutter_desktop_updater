import "package:desktop_updater/src/core/update_recovery.dart";

/// Opaque proof that a pending install marker was durably written and read
/// back exactly before native dispatch.
final class PersistedInstallTransaction {
  PersistedInstallTransaction._({
    required this.marker,
  });

  /// Marker bytes that were written and read back field-for-field.
  final UpdateInstallRecoveryMarker marker;

  /// Native helper transaction identifier bound to the marker.
  String get transactionId => marker.transactionId!;

  /// Expected package identity bound to the marker.
  String get expectedPackageId => marker.expectedPackageId!;

  /// Staged path bound to the marker.
  String get stagingPath => marker.stagingPath!;

  /// Stage provenance digest bound to the marker.
  String get stageProvenanceSha256 => marker.stageProvenanceSha256!;

  /// Update version bound to the durable marker.
  String get updateVersion => marker.updateVersion!;

  /// Nullable update build number bound to the durable marker.
  int? get updateBuildNumber => marker.updateBuildNumber;

  /// Target platform bound to the durable marker.
  String get platform => marker.platform;

  /// Release channel bound to the durable marker.
  String get channel => marker.channel;
}

/// Creates a persistence receipt only after exact marker readback.
PersistedInstallTransaction persistedInstallTransactionFromExactReadback({
  required UpdateInstallRecoveryMarker written,
  required UpdateInstallRecoveryMarker? readback,
}) {
  if (!_sameMarker(written, readback)) {
    throw StateError("Recovery marker readback did not match the write.");
  }
  return PersistedInstallTransaction._(marker: written);
}

/// Writes [marker], reads it back, and returns an exact durable receipt.
Future<PersistedInstallTransaction> persistInstallTransaction({
  required UpdateRecoveryStore store,
  required UpdateInstallRecoveryMarker marker,
}) async {
  await store.writePendingInstall(marker);
  final readback = await store.readPendingInstall(channel: marker.channel);
  return persistedInstallTransactionFromExactReadback(
    written: marker,
    readback: readback,
  );
}

bool _sameMarker(
  UpdateInstallRecoveryMarker expected,
  UpdateInstallRecoveryMarker? actual,
) {
  if (actual == null) {
    return false;
  }
  return expected.createdAt.toUtc() == actual.createdAt.toUtc() &&
      expected.packageVersion == actual.packageVersion &&
      expected.platform == actual.platform &&
      expected.channel == actual.channel &&
      expected.appVersion == actual.appVersion &&
      expected.updateVersion == actual.updateVersion &&
      expected.updateBuildNumber == actual.updateBuildNumber &&
      expected.expectedPackageId == actual.expectedPackageId &&
      expected.stagingPath == actual.stagingPath &&
      expected.stageProvenanceSha256 == actual.stageProvenanceSha256 &&
      expected.diagnosticsText == actual.diagnosticsText &&
      expected.transactionId == actual.transactionId;
}
