import "package:desktop_updater/desktop_updater.dart";
import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";

import "fixtures/controller_v3_test_support.dart";

void main() {
  testWidgets("wrapper keeps failure report and retry actions visible", (
    tester,
  ) async {
    final controller = _SliverFailureController()..showAvailableUpdate();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DesktopUpdateWidget(
            controller: controller,
            child: const Text("Custom app content"),
          ),
        ),
      ),
    );

    expect(find.text("Download"), findsOneWidget);

    controller.showFailedUpdate();
    await tester.pumpAndSettle();

    expect(find.text("Please try again later."), findsOneWidget);
    expect(find.text("Check again"), findsOneWidget);
    expect(find.text("View report"), findsOneWidget);

    await tester.tap(find.text("View report"));
    await tester.pumpAndSettle();
    expect(find.text("Update failed"), findsOneWidget);
    await tester.tap(find.text("Close"));
    await tester.pumpAndSettle();

    await tester.tap(find.text("Check again"));
    await tester.pumpAndSettle();
    expect(controller.checkAgainCallCount, 1);
    expect(find.text("Download"), findsOneWidget);
  });

  testWidgets("sliver keeps macOS helper approval recovery actions usable", (
    tester,
  ) async {
    final controller = _SliverFailureController()..showAvailableUpdate();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            slivers: [
              DesktopUpdateSliver(controller: controller),
              const SliverToBoxAdapter(child: Text("Custom app content")),
            ],
          ),
        ),
      ),
    );

    expect(find.text("Download"), findsOneWidget);

    controller.showApprovalRequired();
    await tester.pumpAndSettle();

    expect(find.text("Open settings"), findsOneWidget);
    expect(find.text("Try again"), findsOneWidget);
    expect(find.text("View report"), findsOneWidget);

    await tester.tap(find.text("Open settings"));
    await tester.pump();
    expect(controller.openSettingsCallCount, 1);

    await tester.tap(find.text("Try again"));
    await tester.pump();
    expect(controller.approvalRetryCallCount, 1);
  });
}

class _SliverFailureController extends DesktopUpdaterController {
  _SliverFailureController()
      : super(
          appArchiveUrl: null,
          expectedPackageId: "com.example.test",
          trustedReleasePublicKeys: controllerTestPublicKeys,
          recoveryStore: ControllerTestRecoveryStore(),
          skipInitialVersionCheck: true,
        );

  final ReleaseDescriptor _descriptor = ReleaseDescriptor(
    schemaVersion: 3,
    packageId: "com.example.test",
    appName: "Test App",
    version: "2.0.0",
    buildNumber: 200,
    platform: "linux",
    channel: "stable",
    artifact: ReleaseArtifact(
      kind: "zip",
      url: Uri.parse("https://example.com/app.zip"),
      sha256: "a" * 64,
      length: 100 * 1024 * 1024,
    ),
    install: const ReleaseInstall(strategy: "wholeDirectoryReplace"),
    minimumUpdaterVersion: "2.0.0",
    generatedAt: DateTime.utc(2026, 6, 12),
  );

  UpdateState _state = const UpdateIdle();
  int checkAgainCallCount = 0;
  int openSettingsCallCount = 0;
  int approvalRetryCallCount = 0;

  @override
  String? get appName => "Test App";

  @override
  String? get appVersion => "2.0.0";

  @override
  ReleaseDescriptor? get activeDescriptor => _descriptor;

  @override
  UpdateState get state => _state;

  void showAvailableUpdate() {
    _state = UpdateAvailable(
      descriptor: _descriptor,
      mandatory: false,
    );
    notifyListeners();
  }

  void showFailedUpdate() {
    _state = UpdateFailed(StateError("network down"), report: _testReport());
    notifyListeners();
  }

  void showApprovalRequired() {
    _state = UpdateFailed(
      PlatformException(
        code: macOSPrivilegedHelperApprovalRequiredErrorCode,
        message: "Administrator approval is required.",
      ),
      report: _testReport(),
    );
    notifyListeners();
  }

  @override
  Future<void> checkVersion() async {
    checkAgainCallCount += 1;
    showAvailableUpdate();
  }

  @override
  Future<void> openMacOSBackgroundItemsSettings() async {
    openSettingsCallCount += 1;
  }

  @override
  Future<void> retryInstallAfterMacOSHelperApproval() async {
    approvalRetryCallCount += 1;
  }
}

UpdateProblemReport _testReport() {
  return UpdateProblemReport(
    generatedAt: DateTime.utc(2026, 6, 13, 9),
    packageVersion: "2.1.4",
    platform: "linux",
    channel: "stable",
    updateVersion: "2.0.0",
    failure: StateError("network down"),
    entries: [
      UpdateDiagnosticEntry(
        timestamp: DateTime.utc(2026, 6, 13, 8),
        stage: UpdateDiagnosticStage.download,
        level: UpdateDiagnosticLevel.error,
        message: "Download failed",
      ),
    ],
  );
}
