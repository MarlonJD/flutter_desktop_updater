import "package:desktop_updater/desktop_updater.dart";

import "support.dart";

void main() {
  DesktopUpdaterController.forTesting(
    appArchiveUrl: null,
    expectedPackageId: "com.example.desktop",
    recoveryStore: FixtureRecoveryStore(),
  );
}
