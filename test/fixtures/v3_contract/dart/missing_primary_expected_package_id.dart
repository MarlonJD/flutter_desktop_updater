import "package:desktop_updater/desktop_updater.dart";

import "support.dart";

void main() {
  DesktopUpdaterController(
    appArchiveUrl: null,
    trustedReleasePublicKeys: trustedReleasePublicKeys,
    recoveryStore: FixtureRecoveryStore(),
  );
}
