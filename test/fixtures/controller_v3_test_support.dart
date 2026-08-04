import "package:desktop_updater/updater_controller.dart";

const controllerTestPublicKeys = <String, String>{
  "test-placeholder": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
};

final class ControllerTestRecoveryStore implements UpdateRecoveryStore {
  UpdateInstallRecoveryMarker? _marker;

  @override
  Future<void> clearPendingInstall({required String channel}) async {
    if (_marker?.channel == channel) {
      _marker = null;
    }
  }

  @override
  Future<UpdateInstallRecoveryMarker?> readPendingInstall({
    required String channel,
  }) async {
    final marker = _marker;
    if (marker == null || marker.channel != channel) {
      return null;
    }
    return marker;
  }

  @override
  Future<void> writePendingInstall(UpdateInstallRecoveryMarker marker) async {
    _marker = marker;
  }
}
