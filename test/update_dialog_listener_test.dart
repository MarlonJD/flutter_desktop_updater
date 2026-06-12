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

Widget _buildTestApp(_TestDesktopUpdaterController controller) {
  return MaterialApp(
    home: Scaffold(
      body: UpdateDialogListener(
        controller: controller,
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
  bool _hasAvailableUpdate = false;

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
      _hasAvailableUpdate ? _descriptor : null;

  @override
  UpdateState get state => _hasAvailableUpdate
      ? UpdateAvailable(descriptor: _descriptor, mandatory: false)
      : const UpdateIdle();

  void showAvailableUpdate() {
    _hasAvailableUpdate = true;
    _skipUpdate = false;
    notifyListeners();
  }

  @override
  void makeSkipUpdate() {
    _skipUpdate = true;
    notifyListeners();
  }
}
