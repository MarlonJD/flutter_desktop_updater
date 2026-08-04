import "package:desktop_updater/desktop_updater.dart";
import "package:flutter/widgets.dart";

import "support.dart";

void main() {
  final controller = DesktopUpdaterController(
    appArchiveUrl: null,
    expectedPackageId: "com.example.desktop",
    trustedReleasePublicKeys: trustedReleasePublicKeys,
    recoveryStore: FixtureRecoveryStore(),
    skipInitialVersionCheck: true,
  );
  final testingController = DesktopUpdaterController.forTesting(
    appArchiveUrl: null,
    expectedPackageId: "com.example.desktop",
    trustedReleasePublicKeys: trustedReleasePublicKeys,
    recoveryStore: FixtureRecoveryStore(),
    skipInitialVersionCheck: true,
  );
  final UpdateState state = const UpdateIdle();
  final Widget card = UpdateCard(controller: controller);
  final Widget widget = DesktopUpdateWidget(
    controller: testingController,
    child: const SizedBox(),
  );

  assert(state is UpdateIdle &&
      card is UpdateCard &&
      widget is DesktopUpdateWidget);
}
