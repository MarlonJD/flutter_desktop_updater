import "package:desktop_updater/desktop_updater.dart";

import "support.dart";

void main() {
  DesktopUpdaterController.forTesting(
    appArchiveUrl: null,
    trustedReleasePublicKeys: trustedReleasePublicKeys,
    recoveryStore: FixtureRecoveryStore(),
  );
}
