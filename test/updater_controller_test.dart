import "dart:async";
import "dart:convert";
import "dart:io";

import "package:desktop_updater/desktop_updater.dart";
import "package:desktop_updater/updater_controller.dart";
import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel("desktop_updater");

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      if (methodCall.method == "getCurrentVersionInfo") {
        return <String, String?>{
          "version": "1.0.0",
          "buildNumber": "100",
        };
      }
      if (methodCall.method == "getCurrentVersion") {
        return "100";
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

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
    "automatic startup check failure updates state without unhandled error",
    () async {
      final missingArchive = Uri.file(
        "${Directory.systemTemp.path}/desktop-updater-missing-archive.json",
      );
      final unhandledErrors = <Object>[];
      final failed = Completer<void>();
      late DesktopUpdaterController controller;

      await runZonedGuarded<Future<void>>(
        () async {
          controller = DesktopUpdaterController(appArchiveUrl: missingArchive);
          controller.addListener(() {
            if (controller.state is UpdateFailed && !failed.isCompleted) {
              failed.complete();
            }
          });

          await failed.future.timeout(const Duration(seconds: 5));
          await Future<void>.delayed(Duration.zero);
        },
        (error, _) {
          unhandledErrors.add(error);
        },
      );

      expect(controller.state, isA<UpdateFailed>());
      expect(unhandledErrors, isEmpty);
    },
  );

  test("checkVersion remains strict when awaited explicitly", () async {
    final missingArchive = Uri.file(
      "${Directory.systemTemp.path}/desktop-updater-missing-archive.json",
    );
    final controller = DesktopUpdaterController(
      appArchiveUrl: missingArchive,
      skipInitialVersionCheck: true,
    );

    await expectLater(controller.checkVersion(), throwsA(isA<Object>()));
    expect(controller.state, isA<UpdateFailed>());
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

  test(
    "preference adapter persists skipped optional version across controllers",
    () async {
      final fixture = await _ControllerUpdateFixture.create(mandatory: false);
      final preferences = _MemoryUpdatePreferences();
      try {
        final first = DesktopUpdaterController(
          appArchiveUrl: fixture.archiveUrl,
          skipInitialVersionCheck: true,
          preferences: preferences,
        );

        await first.checkVersion();
        expect(first.state, isA<UpdateAvailable>());

        await first.makeSkipUpdate();

        expect(first.skipUpdate, isTrue);
        expect(
          await preferences.skippedVersion(channel: "stable"),
          "2.0.1",
        );

        final second = DesktopUpdaterController(
          appArchiveUrl: fixture.archiveUrl,
          skipInitialVersionCheck: true,
          preferences: preferences,
        );

        await second.checkVersion();

        expect(second.state, isA<UpdateIdle>());
        expect(second.skipUpdate, isTrue);
      } finally {
        await fixture.delete();
      }
    },
  );

  test("mandatory updates ignore persisted skipped versions", () async {
    final fixture = await _ControllerUpdateFixture.create(mandatory: true);
    final preferences = _MemoryUpdatePreferences();
    try {
      await preferences.skipVersion(version: "2.0.1", channel: "stable");
      final controller = DesktopUpdaterController(
        appArchiveUrl: fixture.archiveUrl,
        skipInitialVersionCheck: true,
        preferences: preferences,
      );

      await controller.checkVersion();

      expect(controller.state, isA<UpdateAvailable>());
      expect((controller.state as UpdateAvailable).mandatory, isTrue);
      expect(controller.skipUpdate, isFalse);
    } finally {
      await fixture.delete();
    }
  });

  test("telemetry callback failures do not break update checks", () async {
    final fixture = await _ControllerUpdateFixture.create(mandatory: false);
    final events = <UpdateTelemetryEventType>[];
    try {
      final controller = DesktopUpdaterController(
        appArchiveUrl: fixture.archiveUrl,
        skipInitialVersionCheck: true,
        telemetry: (event) {
          events.add(event.type);
          if (event.type == UpdateTelemetryEventType.checkStarted) {
            throw StateError("telemetry sink is down");
          }
        },
      );

      await controller.checkVersion();

      expect(controller.state, isA<UpdateAvailable>());
      expect(
        events,
        containsAllInOrder([
          UpdateTelemetryEventType.checkStarted,
          UpdateTelemetryEventType.updateSelected,
        ]),
      );
    } finally {
      await fixture.delete();
    }
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

class _MemoryUpdatePreferences implements UpdatePreferences {
  final Map<String, String> _skippedVersions = {};

  @override
  Future<String?> skippedVersion({required String channel}) async {
    return _skippedVersions[channel];
  }

  @override
  Future<void> skipVersion({
    required String version,
    required String channel,
  }) async {
    _skippedVersions[channel] = version;
  }

  @override
  Future<void> clearSkippedVersion({required String channel}) async {
    _skippedVersions.remove(channel);
  }
}

class _ControllerUpdateFixture {
  const _ControllerUpdateFixture({
    required this.root,
    required this.archiveUrl,
  });

  final Directory root;
  final Uri archiveUrl;

  static Future<_ControllerUpdateFixture> create({
    required bool mandatory,
  }) async {
    final root = await Directory.systemTemp.createTemp(
      "updater_controller_",
    );
    final releaseUrl = root.uri.resolve("release.json");
    final artifactUrl = root.uri.resolve("artifact.zip");

    await File(path.join(root.path, "artifact.zip")).writeAsString("zip");
    await File(path.join(root.path, "app-archive.json")).writeAsString(
      "${const JsonEncoder.withIndent("  ").convert({
            "schemaVersion": 3,
            "appName": "Example",
            "items": [
              {
                "version": "2.0.1",
                "buildNumber": 201,
                "platform": Platform.operatingSystem,
                "channel": "stable",
                "mandatory": mandatory,
                "release": releaseUrl.toString(),
              },
            ],
          })}\n",
    );
    await File(path.join(root.path, "release.json")).writeAsString(
      "${const JsonEncoder.withIndent("  ").convert({
            "schemaVersion": 3,
            "packageId": "com.example.app",
            "appName": "Example",
            "version": "2.0.1",
            "buildNumber": 201,
            "platform": Platform.operatingSystem,
            "channel": "stable",
            "artifact": {
              "kind": "zip",
              "url": artifactUrl.toString(),
              "sha256": "a" * 64,
              "length": 3,
            },
            "install": {"strategy": "wholeDirectoryReplace"},
            "minimumUpdaterVersion": "2.0.0",
            "generatedAt": DateTime.utc(2026, 6, 13).toIso8601String(),
          })}\n",
    );

    return _ControllerUpdateFixture(
      root: root,
      archiveUrl: root.uri.resolve("app-archive.json"),
    );
  }

  Future<void> delete() async {
    await root.delete(recursive: true);
  }
}
