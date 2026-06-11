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

  bool _needUpdate = false;
  bool _skipUpdate = false;
  bool _isDownloading = false;
  bool _isMandatory = false;

  @override
  String? get appName => "Test App";

  @override
  String? get appVersion => "2.0.0";

  @override
  double? get downloadSize => 1024;

  @override
  bool get isDownloading => _isDownloading;

  @override
  bool get isMandatory => _isMandatory;

  @override
  bool get needUpdate => _needUpdate;

  @override
  bool get skipUpdate => _skipUpdate;

  void showAvailableUpdate() {
    _needUpdate = true;
    _skipUpdate = false;
    _isDownloading = false;
    _isMandatory = false;
    notifyListeners();
  }

  @override
  void makeSkipUpdate() {
    _skipUpdate = true;
    notifyListeners();
  }
}
