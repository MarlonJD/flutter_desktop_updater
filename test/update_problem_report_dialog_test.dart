import "package:desktop_updater/updater_controller.dart";
import "package:desktop_updater/widget/update_problem_report_dialog.dart";
import "package:flutter/foundation.dart";
import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final clipboardWrites = <String>[];

  setUp(() {
    clipboardWrites.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (
      MethodCall methodCall,
    ) async {
      if (methodCall.method == "Clipboard.setData") {
        final data = methodCall.arguments as Map<dynamic, dynamic>;
        clipboardWrites.add(data["text"] as String);
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets("dialog shows summary before collapsible technical details", (
    tester,
  ) async {
    final controller = _ProblemReportTestController();

    await tester.pumpWidget(
      _buildDialogHost(controller: controller, report: _testReport()),
    );

    await tester.tap(find.text("Open report"));
    await tester.pumpAndSettle();

    expect(find.text("Update failed"), findsOneWidget);
    expect(
      find.textContaining("The update could not be completed"),
      findsOneWidget,
    );
    expect(find.text("Technical details"), findsOneWidget);
    expect(find.textContaining("Update Problem Report"), findsNothing);

    await tester.tap(find.text("Technical details"));
    await tester.pumpAndSettle();

    expect(find.textContaining("Update Problem Report"), findsOneWidget);
    expect(find.textContaining("token=<redacted>"), findsOneWidget);
  });

  testWidgets("copy report writes redacted plain text to the clipboard", (
    tester,
  ) async {
    final controller = _ProblemReportTestController();

    await tester.pumpWidget(
      _buildDialogHost(controller: controller, report: _testReport()),
    );

    await tester.tap(find.text("Open report"));
    await tester.pumpAndSettle();
    await tester.tap(find.text("Copy report"));
    await tester.pump();

    expect(clipboardWrites, hasLength(1));
    expect(clipboardWrites.single, contains("token=<redacted>"));
    expect(clipboardWrites.single, contains("Authorization: <redacted>"));
    expect(clipboardWrites.single, isNot(contains("abc123")));
  });

  testWidgets("report issue is hidden without an app callback", (tester) async {
    final controller = _ProblemReportTestController();

    await tester.pumpWidget(
      _buildDialogHost(controller: controller, report: _testReport()),
    );

    await tester.tap(find.text("Open report"));
    await tester.pumpAndSettle();

    expect(find.text("Report issue"), findsNothing);
  });

  testWidgets("report issue invokes the app callback when supplied", (
    tester,
  ) async {
    final sentReports = <UpdateProblemReport>[];
    final report = _testReport();
    final controller = _ProblemReportTestController(
      onProblemReport: (report) async {
        sentReports.add(report);
      },
    );

    await tester.pumpWidget(
      _buildDialogHost(controller: controller, report: report),
    );

    await tester.tap(find.text("Open report"));
    await tester.pumpAndSettle();
    await tester.tap(find.text("Report issue"));
    await tester.pump();

    expect(sentReports, [same(report)]);
  });

  testWidgets("try again calls controller checkVersion", (tester) async {
    final controller = _ProblemReportTestController();

    await tester.pumpWidget(
      _buildDialogHost(controller: controller, report: _testReport()),
    );

    await tester.tap(find.text("Open report"));
    await tester.pumpAndSettle();
    await tester.tap(find.text("Try again"));
    await tester.pump();

    expect(controller.checkVersionCalls, 1);
  });

  testWidgets("technical details stay bounded and actions remain available", (
    tester,
  ) async {
    final controller = _ProblemReportTestController(
      onProblemReport: (_) async {},
    );
    final report = _testReportWithManyEntries();

    await tester.binding.setSurfaceSize(const Size(760, 520));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _buildDialogHost(controller: controller, report: report),
    );

    await tester.tap(find.text("Open report"));
    await tester.pumpAndSettle();
    await tester.tap(find.text("Technical details"));
    await tester.pumpAndSettle();

    final detailsRect = tester.getRect(
      find.byKey(const Key("desktopUpdaterProblemReportDetails")),
    );

    expect(detailsRect.height, lessThanOrEqualTo(260));
    expect(find.text("Copy report"), findsOneWidget);
    expect(find.text("Try again"), findsOneWidget);
    expect(find.text("Report issue"), findsOneWidget);
    expect(find.text("Close"), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets("technical details scrollbar stays attached inside page scroll", (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final controller = _ProblemReportTestController();
      final report = _testReportWithManyEntries();

      await tester.binding.setSurfaceSize(const Size(760, 520));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        _buildScrollableDialogHost(controller: controller, report: report),
      );

      await tester.tap(find.text("Open report"));
      await tester.pumpAndSettle();
      await tester.tap(find.text("Technical details"));
      await tester.pumpAndSettle();

      final details = find.byKey(
        const Key("desktopUpdaterProblemReportDetails"),
      );

      await tester.drag(details, const Offset(0, -80));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets("actions keep a stable two-column layout with readable labels", (
    tester,
  ) async {
    final controller = _ProblemReportTestController(
      onProblemReport: (_) async {},
    );

    await tester.binding.setSurfaceSize(const Size(760, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _buildDialogHost(controller: controller, report: _testReport()),
    );

    await tester.tap(find.text("Open report"));
    await tester.pumpAndSettle();

    final copyRect = tester.getRect(
      find.byKey(const Key("desktopUpdaterProblemReportCopyAction")),
    );
    final retryRect = tester.getRect(
      find.byKey(const Key("desktopUpdaterProblemReportRetryAction")),
    );
    final closeRect = tester.getRect(
      find.byKey(const Key("desktopUpdaterProblemReportCloseAction")),
    );
    final submitRect = tester.getRect(
      find.byKey(const Key("desktopUpdaterProblemReportSubmitAction")),
    );

    expect(copyRect.top, retryRect.top);
    expect(closeRect.top, submitRect.top);
    expect(closeRect.top, greaterThan(copyRect.bottom));
    expect(copyRect.width, retryRect.width);
    expect(closeRect.width, submitRect.width);
    expect(copyRect.height, greaterThanOrEqualTo(40));
    expect(retryRect.height, copyRect.height);
    expect(closeRect.height, copyRect.height);
    expect(submitRect.height, copyRect.height);
    expect(tester.getCenter(find.text("Copy report")).dx, copyRect.center.dx);
    expect(
      tester.getCenter(find.text("Report issue")).dx,
      submitRect.center.dx,
    );
    expect(tester.takeException(), isNull);
  });
}

Widget _buildDialogHost({
  required DesktopUpdaterController controller,
  required UpdateProblemReport report,
}) {
  return MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) {
          return TextButton(
            onPressed: () {
              showUpdateProblemReportDialog(
                context,
                controller: controller,
                report: report,
              );
            },
            child: const Text("Open report"),
          );
        },
      ),
    ),
  );
}

Widget _buildScrollableDialogHost({
  required DesktopUpdaterController controller,
  required UpdateProblemReport report,
}) {
  return MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Builder(
              builder: (context) {
                return TextButton(
                  onPressed: () {
                    showUpdateProblemReportDialog(
                      context,
                      controller: controller,
                      report: report,
                    );
                  },
                  child: const Text("Open report"),
                );
              },
            ),
          ],
        ),
      ),
    ),
  );
}

UpdateProblemReport _testReport() {
  return UpdateProblemReport(
    generatedAt: DateTime.utc(2026, 6, 13, 9),
    packageVersion: "2.1.4",
    platform: "macos",
    channel: "stable",
    appVersion: "1.0.0+100",
    updateVersion: "2.0.1",
    failure: StateError("Authorization: Bearer abc123"),
    entries: [
      UpdateDiagnosticEntry(
        timestamp: DateTime.utc(2026, 6, 13, 8),
        stage: UpdateDiagnosticStage.download,
        level: UpdateDiagnosticLevel.error,
        message: "Download failed token=abc123",
      ),
    ],
  );
}

UpdateProblemReport _testReportWithManyEntries() {
  return UpdateProblemReport(
    generatedAt: DateTime.utc(2026, 6, 13, 9),
    packageVersion: "2.1.4",
    platform: "macos",
    channel: "stable",
    appVersion: "1.0.0+100",
    updateVersion: "2.0.1",
    failure: StateError("Authorization: Bearer abc123"),
    entries: [
      for (var index = 0; index < 40; index += 1)
        UpdateDiagnosticEntry(
          timestamp: DateTime.utc(2026, 6, 13, 8, 0, index),
          stage: UpdateDiagnosticStage.download,
          level: index.isEven
              ? UpdateDiagnosticLevel.info
              : UpdateDiagnosticLevel.error,
          message:
              "Download lifecycle entry $index token=abc123 signature=deadbeef password=hunter2",
        ),
    ],
  );
}

class _ProblemReportTestController extends DesktopUpdaterController {
  _ProblemReportTestController({
    super.onProblemReport,
  }) : super(
          appArchiveUrl: null,
          skipInitialVersionCheck: true,
        );

  int checkVersionCalls = 0;

  @override
  Future<void> checkVersion() async {
    checkVersionCalls += 1;
  }
}
