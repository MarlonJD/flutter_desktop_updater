import "dart:async";

import "package:desktop_updater/desktop_updater.dart";
import "package:desktop_updater/updater_controller.dart";
import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  testWidgets("opens without notifying listeners during route build", (
    tester,
  ) async {
    final controller = _NotesTestController(
      factory: () => Future.value(const ReleaseNotes(sections: [])),
    );

    await _pumpSheet(tester, controller);

    expect(tester.takeException(), isNull);

    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets("shows CircularProgressIndicator while loading", (tester) async {
    final completer = Completer<ReleaseNotes>();
    final controller = _NotesTestController(
      factory: () => completer.future,
    );

    await _pumpSheet(tester, controller);

    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    completer.complete(const ReleaseNotes(sections: []));
    await tester.pumpAndSettle();
  });

  testWidgets("shows grouped sections when notes are loaded", (tester) async {
    final notes = ReleaseNotes.fromJson({
      "data": [
        {"type": "feat", "message": "Dark mode"},
        {"type": "fix", "message": "Fix crash"},
        {"type": "other", "message": "Maintenance"},
      ],
    });
    final controller = _NotesTestController(
      factory: () => Future.value(notes),
    );

    await _pumpSheet(tester, controller);
    await tester.pumpAndSettle();

    expect(find.text("New features"), findsOneWidget);
    expect(find.text("Dark mode"), findsOneWidget);
    expect(find.text("Bug fixes"), findsOneWidget);
    expect(find.text("Fix crash"), findsOneWidget);
    expect(find.text("Other changes"), findsOneWidget);
    expect(find.text("Maintenance"), findsOneWidget);
  });

  testWidgets("shows empty state when notes list is empty", (tester) async {
    final controller = _NotesTestController(
      factory: () => Future.value(const ReleaseNotes(sections: [])),
    );

    await _pumpSheet(tester, controller);
    await tester.pumpAndSettle();

    expect(find.text("No release notes available."), findsOneWidget);
  });

  testWidgets("shows error message when fetch throws", (tester) async {
    final controller = _NotesTestController(
      factory: () => Future.error(Exception("network error")),
    );

    await _pumpSheet(tester, controller);
    await tester.pumpAndSettle();

    expect(find.text("Could not load release notes."), findsOneWidget);
    expect(find.text("Try again"), findsOneWidget);
  });

  testWidgets("Try again button triggers re-fetch", (tester) async {
    var attempt = 0;
    final retryCompleter = Completer<ReleaseNotes>();

    final controller = _CallbackNotesController(
      nextFuture: () {
        attempt++;
        if (attempt == 1) return Future.error(Exception("fail"));
        return retryCompleter.future;
      },
    );

    await _pumpSheet(tester, controller);
    await tester.pumpAndSettle();

    expect(find.text("Could not load release notes."), findsOneWidget);

    await tester.tap(find.text("Try again"));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    retryCompleter.complete(
      ReleaseNotes.fromJson({
        "data": [
          {"type": "feat", "message": "Retry worked"},
        ],
      }),
    );

    await tester.pumpAndSettle();

    expect(find.text("Retry worked"), findsOneWidget);
  });

  testWidgets("sheet title uses releaseNotesTitleText from localization", (
    tester,
  ) async {
    final notes = ReleaseNotes.fromJson({
      "data": [
        {"type": "feat", "message": "Something"},
      ],
    });
    final controller = _NotesTestController(
      factory: () => Future.value(notes),
      localization: DesktopUpdateLocalization(
        releaseNotesTitleText: "Nouveautés",
      ),
    );

    await _pumpSheet(tester, controller);
    await tester.pumpAndSettle();

    expect(find.text("Nouveautés"), findsOneWidget);
  });

  testWidgets("section headers use releaseNotesTypeLabels overrides", (
    tester,
  ) async {
    final notes = ReleaseNotes.fromJson({
      "data": [
        {"type": "feat", "message": "Nouvelle fonctionnalité"},
      ],
    });
    final controller = _NotesTestController(
      factory: () => Future.value(notes),
      localization: DesktopUpdateLocalization(
        releaseNotesTypeLabels: {"feat": "Nouvelles fonctionnalités"},
      ),
    );

    await _pumpSheet(tester, controller);
    await tester.pumpAndSettle();

    expect(find.text("Nouvelles fonctionnalités"), findsOneWidget);
    expect(find.text("New features"), findsNothing);
  });
}

Future<void> _pumpSheet(
  WidgetTester tester,
  DesktopUpdaterController controller,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () =>
                showReleaseNotesBottomSheet(context, notifier: controller),
            child: const Text("Open"),
          ),
        ),
      ),
    ),
  );

  await tester.tap(find.text("Open"));
  await tester.pump();
}

class _NotesTestController extends DesktopUpdaterController {
  _NotesTestController({
    required Future<ReleaseNotes> Function() factory,
    super.localization,
  })  : _factory = factory,
        super(
          appArchiveUrl: null,
          skipInitialVersionCheck: true,
          releaseNotesUrl: Uri.parse("https://example.com/notes.json"),
        );

  final Future<ReleaseNotes> Function() _factory;
  ReleaseNotesState _releaseNotesState = const ReleaseNotesIdle();

  @override
  ReleaseNotesState get releaseNotesState => _releaseNotesState;

  @override
  Future<ReleaseNotes> loadReleaseNotes({bool forceRefresh = false}) async {
    _releaseNotesState = const ReleaseNotesLoading();
    notifyListeners();
    try {
      final notes = await _factory();
      _releaseNotesState = ReleaseNotesLoaded(notes);
      notifyListeners();
      return notes;
    } on Object catch (error) {
      _releaseNotesState = ReleaseNotesFailed(error);
      notifyListeners();
      rethrow;
    }
  }
}

class _CallbackNotesController extends DesktopUpdaterController {
  _CallbackNotesController({
    required Future<ReleaseNotes> Function() nextFuture,
  })  : _nextFuture = nextFuture,
        super(
          appArchiveUrl: null,
          skipInitialVersionCheck: true,
          releaseNotesUrl: Uri.parse("https://example.com/notes.json"),
        );

  final Future<ReleaseNotes> Function() _nextFuture;
  ReleaseNotesState _releaseNotesState = const ReleaseNotesIdle();

  @override
  ReleaseNotesState get releaseNotesState => _releaseNotesState;

  @override
  Future<ReleaseNotes> loadReleaseNotes({bool forceRefresh = false}) async {
    _releaseNotesState = const ReleaseNotesLoading();
    notifyListeners();
    try {
      final notes = await _nextFuture();
      _releaseNotesState = ReleaseNotesLoaded(notes);
      notifyListeners();
      return notes;
    } on Object catch (error) {
      _releaseNotesState = ReleaseNotesFailed(error);
      notifyListeners();
      rethrow;
    }
  }
}
