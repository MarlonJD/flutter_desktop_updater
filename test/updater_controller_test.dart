import "dart:async";

import "package:desktop_updater/desktop_updater.dart";
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
    expect(controller.state, isA<UpdateIdle>());
    expect(notifications, 1);
  });

  test(
    "checkForUpdates returns up to date when checkVersion leaves idle state",
    () async {
      final controller = _ManualCheckTestController(
        onCheckVersion: (controller) {
          controller.stateForTest = const UpdateIdle();
        },
      );

      final result = await controller.checkForUpdates();

      expect(result, isA<ManualUpdateCheckUpToDate>());
    },
  );

  test(
    "checkForUpdates returns available when checkVersion sets available state",
    () async {
      final descriptor = _testDescriptor();
      final controller = _ManualCheckTestController(
        onCheckVersion: (controller) {
          controller.stateForTest =
              UpdateAvailable(descriptor: descriptor, mandatory: true);
        },
      );

      final result = await controller.checkForUpdates();

      expect(result, isA<ManualUpdateCheckAvailable>());
      final available = result as ManualUpdateCheckAvailable;
      expect(available.descriptor, descriptor);
      expect(available.mandatory, isTrue);
    },
  );

  test("checkForUpdates returns failed when checkVersion throws", () async {
    final error = StateError("network down");
    final controller = _ManualCheckTestController(
      onCheckVersion: (_) {
        throw error;
      },
    );

    final result = await controller.checkForUpdates();

    expect(result, isA<ManualUpdateCheckFailed>());
    expect((result as ManualUpdateCheckFailed).error, same(error));
    expect(controller.state, isA<UpdateFailed>());
  });
}

class _ManualCheckTestController extends DesktopUpdaterController {
  _ManualCheckTestController({required this.onCheckVersion})
      : super(
          appArchiveUrl: null,
          skipInitialVersionCheck: true,
        );

  final FutureOr<void> Function(_ManualCheckTestController controller)
      onCheckVersion;

  UpdateState? _stateOverride;

  @override
  UpdateState get state => _stateOverride ?? super.state;

  set stateForTest(UpdateState value) {
    _stateOverride = value;
  }

  @override
  Future<void> checkVersion() async {
    await onCheckVersion(this);
  }
}

ReleaseDescriptor _testDescriptor() {
  return ReleaseDescriptor(
    schemaVersion: 3,
    packageId: "com.example.app",
    appName: "Example.app",
    version: "2.0.1",
    buildNumber: 201,
    platform: "macos",
    channel: "stable",
    artifact: ReleaseArtifact(
      kind: "zip",
      url: Uri.parse("https://example.com/Example.zip"),
      sha256:
          "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      length: 1024,
    ),
    install: const ReleaseInstall(strategy: "wholeBundleReplace"),
    minimumUpdaterVersion: "2.0.0",
    generatedAt: DateTime.utc(2026, 6, 12),
  );
}
