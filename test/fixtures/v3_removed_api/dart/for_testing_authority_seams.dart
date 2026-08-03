import "package:desktop_updater/desktop_updater.dart";

import "../../v3_contract/dart/support.dart";

void main() {
  DesktopUpdaterController.forTesting(
    appArchiveUrl: null,
    expectedPackageId: "com.example.desktop",
    trustedReleasePublicKeys: trustedReleasePublicKeys,
    recoveryStore: FixtureRecoveryStore(),
    checkResult: null,
    stageResult: null,
    verifiedNativeInstallRequest: null,
    persistedInstallTransaction: null,
  );
}
