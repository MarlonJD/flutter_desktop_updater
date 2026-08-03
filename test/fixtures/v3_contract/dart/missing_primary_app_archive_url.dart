import "package:desktop_updater/desktop_updater.dart";

import "support.dart";

void main() {
  DesktopUpdaterController(
    expectedPackageId: "com.example.desktop",
    trustedReleasePublicKeys: trustedReleasePublicKeys,
    recoveryStore: FixtureRecoveryStore(),
  );
}
