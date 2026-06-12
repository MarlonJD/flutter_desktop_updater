import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:desktop_updater/src/core/update_state.dart";
import "package:desktop_updater/updater_controller.dart";
import "package:desktop_updater/widget/update_dialog.dart";
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
