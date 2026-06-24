import "dart:async";
import "dart:convert";
import "dart:io";

import "package:archive/archive.dart";
import "package:crypto/crypto.dart" as crypto;
import "package:desktop_updater/desktop_updater.dart";
import "package:desktop_updater/updater_controller.dart";
import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;

const MethodChannel _desktopUpdaterChannel = MethodChannel("desktop_updater");

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(_setMockPlatformHandler);

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_desktopUpdaterChannel, null);
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

  test("localization updates notify ready-made UI listeners", () {
    final controller = DesktopUpdaterController(
      appArchiveUrl: null,
      skipInitialVersionCheck: true,
    );
    var notifications = 0;

    controller
      ..addListener(() {
        notifications += 1;
      })
      ..localization = const DesktopUpdateLocalization(
        restartText: "Install update",
      );

    expect(controller.getLocalization?.restartText, "Install update");
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

  test("failed check exposes a problem report", () async {
    final missingArchive = Uri.file(
      "${Directory.systemTemp.path}/desktop-updater-missing-archive.json",
    );
    final controller = DesktopUpdaterController(
      appArchiveUrl: missingArchive,
      skipInitialVersionCheck: true,
    );

    await expectLater(controller.checkVersion(), throwsA(isA<Object>()));

    final failed = controller.state as UpdateFailed;
    final report = failed.report;
    expect(report, isNotNull);
    expect(report!.failure, same(failed.error));
    expect(report.channel, "stable");
    expect(report.appVersion, "1.0.0+100");
    expect(
      report.entries.map((entry) => entry.stage),
      contains(UpdateDiagnosticStage.check),
    );
    expect(report.entries.last.level, UpdateDiagnosticLevel.error);
    expect(report.toPlainText(), contains("Checking for updates"));
  });

  test(
    "failed download report keeps check and download lifecycle entries",
    () async {
      final fixture = await _ControllerUpdateFixture.create(mandatory: false);
      try {
        final controller = DesktopUpdaterController(
          appArchiveUrl: fixture.archiveUrl,
          skipInitialVersionCheck: true,
        );

        await controller.checkVersion();
        await expectLater(controller.downloadUpdate(), throwsA(isA<Object>()));

        final failed = controller.state as UpdateFailed;
        final report = failed.report;
        expect(report, isNotNull);
        expect(report!.updateVersion, "2.0.1");
        expect(
          report.entries.map((entry) => entry.stage),
          containsAllInOrder([
            UpdateDiagnosticStage.check,
            UpdateDiagnosticStage.descriptor,
            UpdateDiagnosticStage.download,
          ]),
        );
        expect(report.entries.last.level, UpdateDiagnosticLevel.error);
        expect(report.entries.last.message, contains("Download failed"));
      } finally {
        await fixture.delete();
      }
    },
  );

  test("failed install report records install failure", () async {
    _setMockPlatformHandler(failInstall: true);
    final fixture = await _ControllerUpdateFixture.create(
      mandatory: false,
      validArtifact: true,
    );
    try {
      final controller = DesktopUpdaterController(
        appArchiveUrl: fixture.archiveUrl,
        skipInitialVersionCheck: true,
      );

      await controller.checkVersion();
      await controller.downloadUpdate();
      await expectLater(
        controller.restartApp(),
        throwsA(isA<PlatformException>()),
      );

      final failed = controller.state as UpdateFailed;
      final report = failed.report;
      expect(report, isNotNull);
      expect(report!.stagingPath, isNotEmpty);
      expect(report.entries.last.stage, UpdateDiagnosticStage.install);
      expect(report.entries.last.level, UpdateDiagnosticLevel.error);
      expect(report.entries.last.message, contains("Install failed"));

      final cleanupReport = controller.lastCleanupReport;
      expect(cleanupReport, isNotNull);
      expect(cleanupReport!.stagingPath, report.stagingPath);
      expect(cleanupReport.descriptorVersion, "2.0.1");
      expect(cleanupReport.cleanupAttempted, isFalse);
      expect(cleanupReport.cleanupSucceeded, isFalse);
      expect(cleanupReport.backupRestoredByNativeHelper, isNull);
      expect(cleanupReport.errorText, contains("Native install failed"));
    } finally {
      await fixture.delete();
    }
  });

  test("restartApp writes a recovery marker before native handoff", () async {
    final recoveryStore = _MemoryRecoveryStore();
    final fixture = await _ControllerUpdateFixture.create(
      mandatory: false,
      validArtifact: true,
    );
    try {
      _setMockPlatformHandler(
        onInstallUpdate: (_) async {
          expect(
            await recoveryStore.readPendingInstall(channel: "stable"),
            isNotNull,
          );
        },
      );
      final controller = DesktopUpdaterController(
        appArchiveUrl: fixture.archiveUrl,
        skipInitialVersionCheck: true,
        recoveryStore: recoveryStore,
      );

      await controller.checkVersion();
      await controller.downloadUpdate();
      await controller.restartApp();

      final marker = await recoveryStore.readPendingInstall(channel: "stable");
      expect(marker, isNotNull);
      expect(marker!.channel, "stable");
      expect(marker.appVersion, "1.0.0+100");
      expect(marker.updateVersion, "2.0.1");
      expect(marker.updateBuildNumber, 201);
      expect(marker.stagingPath, isNotEmpty);
      expect(marker.diagnosticsText, contains("Install handoff started"));
    } finally {
      await fixture.delete();
    }
  });

  test("restartApp forwards explicit native diagnostics log path", () async {
    late MethodCall capturedCall;
    final fixture = await _ControllerUpdateFixture.create(
      mandatory: false,
      validArtifact: true,
    );
    try {
      _setMockPlatformHandler(
        onInstallUpdate: (methodCall) {
          capturedCall = methodCall;
        },
      );
      final controller = DesktopUpdaterController(
        appArchiveUrl: fixture.archiveUrl,
        skipInitialVersionCheck: true,
        diagnosticsLogPath: "/tmp/helper.jsonl",
      );

      await controller.checkVersion();
      await controller.downloadUpdate();
      await controller.restartApp();

      expect(
        capturedCall.arguments,
        containsPair("diagnosticsLogPath", "/tmp/helper.jsonl"),
      );
    } finally {
      await fixture.delete();
    }
  });

  test("pre-handoff native failure clears marker and exposes report", () async {
    _setMockPlatformHandler(failInstall: true);
    final recoveryStore = _MemoryRecoveryStore();
    final fixture = await _ControllerUpdateFixture.create(
      mandatory: false,
      validArtifact: true,
    );
    try {
      final controller = DesktopUpdaterController(
        appArchiveUrl: fixture.archiveUrl,
        skipInitialVersionCheck: true,
        recoveryStore: recoveryStore,
      );

      await controller.checkVersion();
      await controller.downloadUpdate();
      await expectLater(
        controller.restartApp(),
        throwsA(isA<PlatformException>()),
      );

      expect(
        await recoveryStore.readPendingInstall(channel: "stable"),
        isNull,
      );
      final failed = controller.state as UpdateFailed;
      expect(failed.report, isNotNull);
      expect(failed.report!.entries.last.stage, UpdateDiagnosticStage.install);
    } finally {
      await fixture.delete();
    }
  });

  test("relaunch on old version creates recovered failed report", () async {
    final recoveryStore = _MemoryRecoveryStore()
      ..marker = UpdateInstallRecoveryMarker(
        createdAt: DateTime.utc(2026, 6, 16, 10),
        packageVersion: "2.1.4",
        platform: Platform.operatingSystem,
        channel: "stable",
        appVersion: "1.0.0+100",
        updateVersion: "2.0.1",
        updateBuildNumber: 201,
        stagingPath: "/tmp/staged-app",
        diagnosticsText: "previous redacted diagnostics",
      );
    final controller = DesktopUpdaterController(
      appArchiveUrl: null,
      skipInitialVersionCheck: true,
      recoveryStore: recoveryStore,
    );

    await controller.recoverPendingInstall();

    final failed = controller.state as UpdateFailed;
    final report = failed.report;
    expect(report, isNotNull);
    expect(report!.appVersion, "1.0.0+100");
    expect(report.updateVersion, "2.0.1");
    expect(report.stagingPath, "/tmp/staged-app");
    expect(
      report.toPlainText(),
      contains("Pending install did not complete"),
    );
    expect(
      await recoveryStore.readPendingInstall(channel: "stable"),
      isNotNull,
    );
  });

  test("relaunch on target version clears marker without failure", () async {
    _setMockPlatformHandler(versionName: "2.0.1", buildNumber: "201");
    final recoveryStore = _MemoryRecoveryStore()
      ..marker = UpdateInstallRecoveryMarker(
        createdAt: DateTime.utc(2026, 6, 16, 10),
        packageVersion: "2.1.4",
        platform: Platform.operatingSystem,
        channel: "stable",
        appVersion: "1.0.0+100",
        updateVersion: "2.0.1",
        updateBuildNumber: 201,
        stagingPath: "/tmp/staged-app",
      );
    final controller = DesktopUpdaterController(
      appArchiveUrl: null,
      skipInitialVersionCheck: true,
      recoveryStore: recoveryStore,
    );

    await controller.recoverPendingInstall();

    expect(controller.state, isA<UpdateIdle>());
    expect(await recoveryStore.readPendingInstall(channel: "stable"), isNull);
    expect(recoveryStore.clearedChannels, ["stable"]);
  });

  test("recovery store failures do not crash startup or install handoff",
      () async {
    final readFailureStore = _ThrowingRecoveryStore(readFailure: true);
    final readController = DesktopUpdaterController(
      appArchiveUrl: null,
      skipInitialVersionCheck: true,
      recoveryStore: readFailureStore,
    );

    await readController.recoverPendingInstall();

    expect(readController.state, isA<UpdateIdle>());
    expect(
      readController.diagnosticsRecorder.entries.last.message,
      contains("Recovery marker read failed"),
    );

    final writeFailureStore = _ThrowingRecoveryStore(writeFailure: true);
    final fixture = await _ControllerUpdateFixture.create(
      mandatory: false,
      validArtifact: true,
    );
    try {
      final controller = DesktopUpdaterController(
        appArchiveUrl: fixture.archiveUrl,
        skipInitialVersionCheck: true,
        recoveryStore: writeFailureStore,
      );

      await controller.checkVersion();
      await controller.downloadUpdate();
      await controller.restartApp();

      expect(controller.state, isA<UpdateInstalling>());
      expect(
        controller.diagnosticsRecorder.entries.map((entry) => entry.message),
        contains("Recovery marker write failed."),
      );
    } finally {
      await fixture.delete();
    }
  });

  test(
    "successful install scheduling emits cleanup report without blocking",
    () async {
      final reports = <UpdateCleanupReport>[];
      final fixture = await _ControllerUpdateFixture.create(
        mandatory: false,
        validArtifact: true,
      );
      try {
        final controller = DesktopUpdaterController(
          appArchiveUrl: fixture.archiveUrl,
          skipInitialVersionCheck: true,
          onCleanupReport: (report) {
            reports.add(report);
            throw StateError("report sink is down");
          },
        );

        await controller.checkVersion();
        await controller.downloadUpdate();
        await controller.restartApp();

        expect(reports, hasLength(1));
        final report = reports.single;
        expect(controller.lastCleanupReport, same(report));
        expect(report.stagingPath, isNotEmpty);
        expect(report.descriptorVersion, "2.0.1");
        expect(report.cleanupAttempted, isFalse);
        expect(report.cleanupSucceeded, isNull);
        expect(report.backupRestoredByNativeHelper, isNull);
        expect(report.errorText, isNull);

        final state = controller.state;
        expect(state, isA<UpdateInstalling>());
        expect((state as UpdateInstalling).cleanupReport, same(report));
      } finally {
        await fixture.delete();
      }
    },
  );

  test("telemetry failures do not prevent diagnostics reports", () async {
    final missingArchive = Uri.file(
      "${Directory.systemTemp.path}/desktop-updater-missing-archive.json",
    );
    final controller = DesktopUpdaterController(
      appArchiveUrl: missingArchive,
      skipInitialVersionCheck: true,
      telemetry: (_) {
        throw StateError("telemetry sink is down");
      },
    );

    await expectLater(controller.checkVersion(), throwsA(isA<Object>()));

    final failed = controller.state as UpdateFailed;
    expect(failed.report, isNotNull);
    expect(failed.report!.entries.last.level, UpdateDiagnosticLevel.error);
  });

  test("problem report callback is invoked only by explicit action", () async {
    final sentReports = <UpdateProblemReport>[];
    final report = UpdateProblemReport(
      generatedAt: DateTime.utc(2026, 6, 13, 9),
      packageVersion: "2.1.4",
      platform: "linux",
      channel: "stable",
      entries: const [],
    );
    final controller = DesktopUpdaterController(
      appArchiveUrl: null,
      skipInitialVersionCheck: true,
      onProblemReport: (report) async {
        sentReports.add(report);
      },
    );
    final controllerWithoutCallback = DesktopUpdaterController(
      appArchiveUrl: null,
      skipInitialVersionCheck: true,
    );

    expect(controller.canReportProblem, isTrue);
    expect(controllerWithoutCallback.canReportProblem, isFalse);
    expect(sentReports, isEmpty);

    await controller.reportProblem(report);

    expect(sentReports, [same(report)]);
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

void _setMockPlatformHandler({
  bool failInstall = false,
  String versionName = "1.0.0",
  String buildNumber = "100",
  FutureOr<void> Function(MethodCall methodCall)? onInstallUpdate,
}) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_desktopUpdaterChannel, (
    MethodCall methodCall,
  ) async {
    if (methodCall.method == "getCurrentVersionInfo") {
      return <String, String?>{
        "version": versionName,
        "buildNumber": buildNumber,
      };
    }
    if (methodCall.method == "getCurrentVersion") {
      return buildNumber;
    }
    if (methodCall.method == "installUpdate") {
      await onInstallUpdate?.call(methodCall);
    }
    if (methodCall.method == "installUpdate" && failInstall) {
      throw PlatformException(
        code: "install-failed",
        message: "Native install failed",
      );
    }
    return null;
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

class _MemoryRecoveryStore implements UpdateRecoveryStore {
  UpdateInstallRecoveryMarker? marker;
  final clearedChannels = <String>[];

  @override
  Future<UpdateInstallRecoveryMarker?> readPendingInstall({
    required String channel,
  }) async {
    if (marker?.channel != channel) {
      return null;
    }
    return marker;
  }

  @override
  Future<void> writePendingInstall(UpdateInstallRecoveryMarker marker) async {
    this.marker = marker;
  }

  @override
  Future<void> clearPendingInstall({required String channel}) async {
    if (marker?.channel == channel) {
      marker = null;
    }
    clearedChannels.add(channel);
  }
}

class _ThrowingRecoveryStore implements UpdateRecoveryStore {
  _ThrowingRecoveryStore({
    this.readFailure = false,
    this.writeFailure = false,
  });

  final bool readFailure;
  final bool writeFailure;

  @override
  Future<UpdateInstallRecoveryMarker?> readPendingInstall({
    required String channel,
  }) async {
    if (readFailure) {
      throw StateError("read unavailable");
    }
    return null;
  }

  @override
  Future<void> writePendingInstall(UpdateInstallRecoveryMarker marker) async {
    if (writeFailure) {
      throw StateError("write unavailable");
    }
  }

  @override
  Future<void> clearPendingInstall({required String channel}) async {}
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
    bool validArtifact = false,
  }) async {
    final root = await Directory.systemTemp.createTemp(
      "updater_controller_",
    );
    final releaseUrl = root.uri.resolve("release.json");
    final artifactUrl = root.uri.resolve("artifact.zip");

    final appName =
        Platform.operatingSystem == "macos" ? "Example.app" : "Example";
    final artifact = File(path.join(root.path, "artifact.zip"));
    final artifactBytes = validArtifact
        ? ZipEncoder().encode(
            Archive()
              ..addFile(
                ArchiveFile.string(
                  Platform.operatingSystem == "macos"
                      ? "$appName/Contents/Info.plist"
                      : "app.txt",
                  "version=2.0.1",
                ),
              ),
          )
        : utf8.encode("zip");
    await artifact.writeAsBytes(artifactBytes);
    final artifactSha256 =
        crypto.sha256.convert(await artifact.readAsBytes()).toString();
    await File(path.join(root.path, "app-archive.json")).writeAsString(
      "${const JsonEncoder.withIndent("  ").convert({
            "schemaVersion": 3,
            "appName": appName,
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
            "appName": appName,
            "version": "2.0.1",
            "buildNumber": 201,
            "platform": Platform.operatingSystem,
            "channel": "stable",
            "artifact": {
              "kind": "zip",
              "url": artifactUrl.toString(),
              "sha256": validArtifact ? artifactSha256 : "a" * 64,
              "length": await artifact.length(),
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
