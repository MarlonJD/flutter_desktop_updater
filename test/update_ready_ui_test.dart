import "package:desktop_updater/desktop_updater.dart";
import "package:desktop_updater/updater_controller.dart";
import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  testWidgets("direct card shows available update actions", (tester) async {
    final controller = _ReadyUiTestController();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DesktopUpdateDirectCard(controller: controller),
        ),
      ),
    );

    expect(find.text("Update Available"), findsNothing);

    controller.showAvailableUpdate();
    await tester.pump();

    expect(find.text("Update Available"), findsOneWidget);
    expect(find.text("Download"), findsOneWidget);
    expect(find.text("Skip this version"), findsOneWidget);
  });

  testWidgets("mandatory updates hide the skip action", (tester) async {
    final controller = _ReadyUiTestController()
      ..showAvailableUpdate(mandatory: true);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DesktopUpdateDirectCard(controller: controller),
        ),
      ),
    );

    expect(find.text("Update Available"), findsOneWidget);
    expect(find.text("Download"), findsOneWidget);
    expect(find.text("Skip this version"), findsNothing);
  });

  testWidgets("ready UI shows download progress from typed state", (
    tester,
  ) async {
    final controller = _ReadyUiTestController()
      ..showDownloadingUpdate(
        receivedBytes: 50 * 1024 * 1024,
        totalBytes: 100 * 1024 * 1024,
      );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DesktopUpdateDirectCard(controller: controller),
        ),
      ),
    );

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text("50% (50.00 MB / 100.00 MB)"), findsOneWidget);
  });

  testWidgets("wrapper widget can show the card above custom content", (
    tester,
  ) async {
    final controller = _ReadyUiTestController()..showAvailableUpdate();

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

    expect(find.text("Update Available"), findsOneWidget);
    expect(find.text("Custom app content"), findsOneWidget);
  });

  testWidgets("inherited notifier supports custom update UI", (tester) async {
    final controller = _ReadyUiTestController();

    await tester.pumpWidget(
      MaterialApp(
        home: DesktopUpdaterInheritedNotifier(
          controller: controller,
          child: Builder(
            builder: (context) {
              final notifier =
                  DesktopUpdaterInheritedNotifier.of(context).notifier!;
              final state = notifier.state;

              return Text(
                switch (state) {
                  UpdateAvailable(:final mandatory) =>
                    mandatory ? "Custom mandatory update" : "Custom update",
                  _ => "Custom idle",
                },
              );
            },
          ),
        ),
      ),
    );

    expect(find.text("Custom idle"), findsOneWidget);

    controller.showAvailableUpdate(mandatory: true);
    await tester.pump();

    expect(find.text("Custom mandatory update"), findsOneWidget);
  });
}

class _ReadyUiTestController extends DesktopUpdaterController {
  _ReadyUiTestController()
      : super(
          appArchiveUrl: null,
          skipInitialVersionCheck: true,
        );

  bool _skipUpdate = false;
  UpdateState _state = const UpdateIdle();

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

  @override
  String? get appName => "Test App";

  @override
  String? get appVersion => "2.0.0";

  @override
  bool get skipUpdate => _skipUpdate;

  @override
  ReleaseDescriptor? get activeDescriptor => _descriptor;

  @override
  UpdateState get state => _state;

  void showAvailableUpdate({bool mandatory = false}) {
    _skipUpdate = false;
    _state = UpdateAvailable(
      descriptor: _descriptor,
      mandatory: mandatory,
    );
    notifyListeners();
  }

  void showDownloadingUpdate({
    required int receivedBytes,
    required int totalBytes,
  }) {
    _state = UpdateDownloading(
      receivedBytes: receivedBytes,
      totalBytes: totalBytes,
    );
    notifyListeners();
  }

  @override
  Future<void> downloadUpdate() async {
    showDownloadingUpdate(
      receivedBytes: 50 * 1024 * 1024,
      totalBytes: 100 * 1024 * 1024,
    );
  }

  @override
  void makeSkipUpdate() {
    _skipUpdate = true;
    notifyListeners();
  }
}
