import "package:desktop_updater/desktop_updater.dart";
import "package:desktop_updater/updater_controller.dart";
import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  testWidgets(
    "shows one dialog while repeated notifications keep update available",
    (tester) async {
      final controller = _TestDesktopUpdaterController();

      await tester.pumpWidget(_buildTestApp(controller));

      controller.showAvailableUpdate();
      await tester.pump();
      await tester.pump();

      expect(find.byType(AlertDialog), findsOneWidget);

      controller.showAvailableUpdate();
      await tester.pump();
      await tester.pump();

      expect(find.byType(AlertDialog), findsOneWidget);
    },
  );

  testWidgets(
    "can show the dialog again after the previous dialog is dismissed",
    (tester) async {
      final controller = _TestDesktopUpdaterController();

      await tester.pumpWidget(_buildTestApp(controller));

      controller.showAvailableUpdate();
      await tester.pump();
      await tester.pump();

      expect(find.byType(AlertDialog), findsOneWidget);

      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);

      controller.showAvailableUpdate();
      await tester.pump();
      await tester.pump();

      expect(find.byType(AlertDialog), findsOneWidget);
    },
  );

  testWidgets(
    "mandatory save-first from listener dismisses dialogs so the app can save",
    (tester) async {
      final controller = _TestDesktopUpdaterController();

      await tester.pumpWidget(_buildTestApp(controller));

      controller.showAvailableUpdate(mandatory: true);
      await tester.pump();
      await tester.pump();

      controller.showReadyToInstallUpdate(mandatory: true);
      await tester.pumpAndSettle();

      await tester.tap(find.text("Restart to update"));
      await tester.pumpAndSettle();

      expect(find.text("Save first"), findsOneWidget);

      await tester.tap(find.text("Save first"));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(controller.restartAppCallCount, 0);
    },
  );

  testWidgets(
    "mandatory ready-to-install listener can restart without a confirmation",
    (tester) async {
      final controller = _TestDesktopUpdaterController();

      await tester.pumpWidget(
        _buildTestApp(
          controller,
          mandatoryReadyToInstallBehavior:
              MandatoryReadyToInstallBehavior.restartWithoutPrompt,
        ),
      );

      controller.showAvailableUpdate(mandatory: true);
      await tester.pump();
      await tester.pump();

      controller.showReadyToInstallUpdate(mandatory: true);
      await tester.pumpAndSettle();

      await tester.tap(find.text("Restart to update"));
      await tester.pump();

      expect(controller.restartAppCallCount, 1);
      expect(find.text("Are you sure?"), findsNothing);
    },
  );

  testWidgets("manual up-to-date result helper shows one confirmation dialog", (
    tester,
  ) async {
    final controller = _TestDesktopUpdaterController();

    await tester.pumpWidget(
      _buildManualResultApp(
        controller: controller,
        result: const ManualUpdateCheckUpToDate(),
      ),
    );

    await tester.tap(find.text("Show result"));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text("Application is up to date"), findsOneWidget);
    expect(
      find.text("Test App 2.0.0 is the latest available version."),
      findsOneWidget,
    );
  });

  testWidgets("manual failed result helper shows retry-later dialog", (
    tester,
  ) async {
    final controller = _TestDesktopUpdaterController();

    await tester.pumpWidget(
      _buildManualResultApp(
        controller: controller,
        result: ManualUpdateCheckFailed(
          StateError("network down"),
          StackTrace.current,
        ),
      ),
    );

    await tester.tap(find.text("Show result"));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text("Could not check for updates"), findsOneWidget);
    expect(find.text("Please try again later."), findsOneWidget);
  });

  testWidgets("manual failed result helper can open a problem report", (
    tester,
  ) async {
    final controller = _TestDesktopUpdaterController()..showFailedUpdate();

    await tester.pumpWidget(
      _buildManualResultApp(
        controller: controller,
        result: ManualUpdateCheckFailed(
          StateError("network down"),
          StackTrace.current,
        ),
      ),
    );

    await tester.tap(find.text("Show result"));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text("Could not check for updates"), findsOneWidget);
    expect(find.text("View report"), findsOneWidget);

    await tester.tap(find.text("View report"));
    await tester.pumpAndSettle();

    expect(find.text("Update failed"), findsOneWidget);
  });

  testWidgets("manual available result helper stays quiet by default", (
    tester,
  ) async {
    final controller = _TestDesktopUpdaterController();

    await tester.pumpWidget(
      _buildManualResultApp(
        controller: controller,
        result: ManualUpdateCheckAvailable(
          descriptor: _testDescriptor(),
          mandatory: false,
        ),
      ),
    );

    await tester.tap(find.text("Show result"));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
  });
}

Widget _buildTestApp(
  _TestDesktopUpdaterController controller, {
  MandatoryReadyToInstallBehavior mandatoryReadyToInstallBehavior =
      MandatoryReadyToInstallBehavior.promptToSaveFirst,
}) {
  return MaterialApp(
    home: Scaffold(
      body: UpdateDialogListener(
        controller: controller,
        mandatoryReadyToInstallBehavior: mandatoryReadyToInstallBehavior,
      ),
    ),
  );
}

Widget _buildManualResultApp({
  required _TestDesktopUpdaterController controller,
  required ManualUpdateCheckResult result,
}) {
  return MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) {
          return TextButton(
            onPressed: () {
              showManualUpdateCheckResultDialog(
                context,
                controller: controller,
                result: result,
              );
            },
            child: const Text("Show result"),
          );
        },
      ),
    ),
  );
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

class _TestDesktopUpdaterController extends DesktopUpdaterController {
  _TestDesktopUpdaterController()
      : super(
          appArchiveUrl: null,
          skipInitialVersionCheck: true,
        );

  bool _skipUpdate = false;
  UpdateState _state = const UpdateIdle();
  int restartAppCallCount = 0;

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
      length: 1024,
    ),
    install: const ReleaseInstall(strategy: "wholeDirectoryReplace"),
    minimumUpdaterVersion: "2.0.0",
    generatedAt: DateTime.utc(2026, 6, 12),
  );

  @override
  String? get appName => "Test App";

  @override
  String? get appVersion => "2.0.0";

  @override
  bool get skipUpdate => _skipUpdate;

  @override
  ReleaseDescriptor? get activeDescriptor =>
      _state is UpdateIdle ? null : _descriptor;

  @override
  UpdateState get state => _state;

  void showAvailableUpdate({bool mandatory = false}) {
    _state = UpdateAvailable(descriptor: _descriptor, mandatory: mandatory);
    _skipUpdate = false;
    notifyListeners();
  }

  void showReadyToInstallUpdate({bool mandatory = false}) {
    _state = UpdateReadyToInstall(
      stagingPath: "/tmp/stage",
      mandatory: mandatory,
    );
    _skipUpdate = false;
    notifyListeners();
  }

  void showFailedUpdate() {
    _state = UpdateFailed(
      StateError("network down"),
      report: _testProblemReport(),
    );
    notifyListeners();
  }

  @override
  Future<void> makeSkipUpdate() async {
    _skipUpdate = true;
    notifyListeners();
  }

  @override
  Future<void> restartApp() async {
    restartAppCallCount += 1;
  }
}

UpdateProblemReport _testProblemReport() {
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
        stage: UpdateDiagnosticStage.check,
        level: UpdateDiagnosticLevel.error,
        message: "Update check failed",
      ),
    ],
  );
}
