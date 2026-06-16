import "dart:io";

import "package:desktop_updater/desktop_updater.dart";
import "package:desktop_updater/src/io/release_notes_fetcher.dart";
import "package:desktop_updater/updater_controller.dart";
import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";

const MethodChannel _channel = MethodChannel("desktop_updater");

final _fakeNotes = ReleaseNotes.fromJson({
  "data": [
    {"type": "feat", "message": "Dark mode"},
    {"type": "fix", "message": "Crash fix"},
  ],
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (_) async => null);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  test("fetchReleaseNotes returns parsed notes from the fetcher", () async {
    final controller = DesktopUpdaterController.forTesting(
      appArchiveUrl: null,
      skipInitialVersionCheck: true,
      releaseNotesUrl: Uri.parse("https://example.com/notes.json"),
      releaseNotesFetcher: _ConstantNotesFetcher(_fakeNotes),
    );

    final notes = await controller.fetchReleaseNotes();

    expect(notes.entries, hasLength(2));
    expect(notes.entries[0].type, "feat");
    expect(notes.entries[0].message, "Dark mode");
    expect(notes.entries[1].type, "fix");
  });

  test("fetchReleaseNotes returns cached result on second call", () async {
    final fetcher = _CountingNotesFetcher(_fakeNotes);
    final controller = DesktopUpdaterController.forTesting(
      appArchiveUrl: null,
      skipInitialVersionCheck: true,
      releaseNotesUrl: Uri.parse("https://example.com/notes.json"),
      releaseNotesFetcher: fetcher,
    );

    await controller.fetchReleaseNotes();
    await controller.fetchReleaseNotes();

    expect(fetcher.callCount, 1);
  });

  test("fetchReleaseNotes throws StateError when releaseNotesUrl is null", () {
    final controller = DesktopUpdaterController(
      appArchiveUrl: null,
      skipInitialVersionCheck: true,
    );

    expect(controller.fetchReleaseNotes, throwsStateError);
  });

  test("fetchReleaseNotes propagates errors from the fetcher", () async {
    final controller = DesktopUpdaterController.forTesting(
      appArchiveUrl: null,
      skipInitialVersionCheck: true,
      releaseNotesUrl: Uri.parse("https://example.com/notes.json"),
      releaseNotesFetcher: _FailingNotesFetcher(
        HttpException("HTTP 404",
            uri: Uri.parse("https://example.com/notes.json")),
      ),
    );

    expect(controller.fetchReleaseNotes, throwsA(isA<HttpException>()));
  });

  test("checkVersion clears the cached release notes", () async {
    final fetcher = _CountingNotesFetcher(_fakeNotes);
    final missingArchive = Uri.file(
      "${Directory.systemTemp.path}/missing-${DateTime.now().millisecondsSinceEpoch}.json",
    );
    final controller = DesktopUpdaterController.forTesting(
      appArchiveUrl: missingArchive,
      skipInitialVersionCheck: true,
      releaseNotesUrl: Uri.parse("https://example.com/notes.json"),
      releaseNotesFetcher: fetcher,
    );

    await controller.fetchReleaseNotes();
    expect(fetcher.callCount, 1);

    try {
      await controller.checkVersion();
    } on Object {
      // expected — missing archive
    }

    await controller.fetchReleaseNotes();
    expect(fetcher.callCount, 2);
  });
}

class _ConstantNotesFetcher extends ReleaseNotesFetcher {
  _ConstantNotesFetcher(this._notes) : super(client: null);
  final ReleaseNotes _notes;

  @override
  Future<ReleaseNotes> fetch(Uri url) async => _notes;
}

class _CountingNotesFetcher extends ReleaseNotesFetcher {
  _CountingNotesFetcher(this._notes) : super(client: null);
  final ReleaseNotes _notes;
  int callCount = 0;

  @override
  Future<ReleaseNotes> fetch(Uri url) async {
    callCount++;
    return _notes;
  }
}

class _FailingNotesFetcher extends ReleaseNotesFetcher {
  _FailingNotesFetcher(this._error) : super(client: null);
  final Object _error;

  @override
  Future<ReleaseNotes> fetch(Uri url) => Future.error(_error);
}
