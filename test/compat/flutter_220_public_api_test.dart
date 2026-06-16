import "package:desktop_updater/desktop_updater.dart";
import "package:desktop_updater/updater_controller.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  test("Flutter package keeps 2.2.0 public runtime surface", () {
    final updater = DesktopUpdater();
    final controller = DesktopUpdaterController(
      appArchiveUrl: null,
      skipInitialVersionCheck: true,
    );

    expect(updater, isA<DesktopUpdater>());
    expect(controller.skipInitialVersionCheck, isTrue);
    expect(const UpdateIdle(), isA<UpdateState>());
    expect(UpdateFailed(StateError("x")), isA<UpdateState>());
    expect(UpdateProblemReport, isNotNull);
    expect(UpdateDiagnosticsRecorder, isNotNull);
    expect(UpdateInstallRecoveryMarker, isNotNull);
    expect(UpdateCleanupReport, isNotNull);
  });
}
