import "package:desktop_updater/desktop_updater.dart";

const trustedReleasePublicKeys = <String, String>{
  "release-2026": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
};

final class FixtureRecoveryStore implements UpdateRecoveryStore {
  @override
  Future<void> clearPendingInstall({required String channel}) async {}

  @override
  Future<UpdateInstallRecoveryMarker?> readPendingInstall({
    required String channel,
  }) async =>
      null;

  @override
  Future<void> writePendingInstall(UpdateInstallRecoveryMarker marker) async {}
}
