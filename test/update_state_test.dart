import "package:desktop_updater/src/core/update_state.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  test("typed update states are distinct", () {
    const states = <UpdateState>[
      UpdateIdle(),
      UpdateChecking(),
      UpdateDownloading(receivedBytes: 1, totalBytes: 2),
      UpdateReadyToInstall(stagingPath: "/tmp/stage"),
      UpdateInstalling(),
      UpdateFailed("boom"),
    ];

    expect(states.map((state) => state.runtimeType).toSet(), hasLength(6));
  });
}
