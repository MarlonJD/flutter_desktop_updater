import "package:desktop_updater/updater_controller.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  test("skipInitialVersionCheck lets callers trigger checks manually", () {
    final controller = DesktopUpdaterController(
      appArchiveUrl: null,
      skipInitialVersionCheck: true,
    );
    final archiveUrl = Uri.parse("https://example.com/app-archive.json");
    var notifications = 0;

    controller
      ..addListener(() {
        notifications += 1;
      })
      ..init(archiveUrl);

    expect(controller.appArchiveUrl, archiveUrl);
    expect(controller.skipInitialVersionCheck, isTrue);
    expect(controller.needUpdate, isFalse);
    expect(notifications, 1);
  });

  test("skipCheckVersion remains available as a deprecated alias", () {
    final controller = DesktopUpdaterController(
      appArchiveUrl: null,
      // ignore: deprecated_member_use_from_same_package
      skipCheckVersion: true,
    );

    expect(controller.skipInitialVersionCheck, isTrue);
    // ignore: deprecated_member_use_from_same_package
    expect(controller.getSkipCheckVersion, isTrue);
  });
}
