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

  test("canLoadReleaseNotes is false before a descriptor is selected", () {
    final controller = DesktopUpdaterController(
      appArchiveUrl: null,
      skipInitialVersionCheck: true,
      releaseNotesLoader: (_) async => _fakeNotes,
    );

    expect(controller.canLoadReleaseNotes, isFalse);
    expect(controller.releaseNotesState, isA<ReleaseNotesIdle>());
  });

  test("loadReleaseNotes passes active descriptor to loader", () async {
    ReleaseDescriptor? captured;
    final controller = _ReleaseNotesControllerForTest(
      releaseNotesLoader: (descriptor) async {
        captured = descriptor;
        return _fakeNotes;
      },
    );

    final notes = await controller.loadReleaseNotes();

    expect(notes.entries, hasLength(2));
    expect(captured, controller.activeDescriptor);
    expect(controller.releaseNotesState, isA<ReleaseNotesLoaded>());
  });

  test("loadReleaseNotes returns cached result on second call", () async {
    var callCount = 0;
    final controller = _ReleaseNotesControllerForTest(
      releaseNotesLoader: (_) async {
        callCount++;
        return _fakeNotes;
      },
    );

    await controller.loadReleaseNotes();
    await controller.loadReleaseNotes();

    expect(callCount, 1);
  });

  test("loadReleaseNotes supports forceRefresh", () async {
    var callCount = 0;
    final controller = _ReleaseNotesControllerForTest(
      releaseNotesLoader: (_) async {
        callCount++;
        return _fakeNotes;
      },
    );

    await controller.loadReleaseNotes();
    await controller.loadReleaseNotes(forceRefresh: true);

    expect(callCount, 2);
  });

  test("loadReleaseNotes throws StateError when no loader is configured", () {
    final controller = _ReleaseNotesControllerForTest();

    expect(controller.loadReleaseNotes, throwsStateError);
  });

  test("loadReleaseNotes propagates errors and records failed state", () async {
    final error = HttpException(
      "HTTP 404",
      uri: Uri.parse("https://example.com/notes.json"),
    );
    final controller = _ReleaseNotesControllerForTest(
      releaseNotesLoader: (_) => Future.error(error),
    );

    await expectLater(
      controller.loadReleaseNotes,
      throwsA(same(error)),
    );
    final state = controller.releaseNotesState;
    expect(state, isA<ReleaseNotesFailed>());
    expect((state as ReleaseNotesFailed).error, same(error));
  });

  test("releaseNotesUrl remains a convenience fetch path", () async {
    final fetcher = _CountingNotesFetcher(_fakeNotes);
    final controller = _UrlReleaseNotesControllerForTest(
      releaseNotesUrl: Uri.parse("https://example.com/notes.json"),
      releaseNotesFetcher: fetcher,
    );

    final notes = await controller.loadReleaseNotes();

    expect(notes.entries, hasLength(2));
    expect(fetcher.callCount, 1);
  });

  test("releaseNotesUrl uses app-owned request headers provider", () async {
    final server = await _ReleaseNotesServer.start();
    try {
      final notes = await HttpOverrides.runZoned(
        () {
          final controller = _UrlReleaseNotesControllerForTest(
            releaseNotesUrl: server.url,
            requestHeadersProvider: (source) {
              return {"x-update-auth": "runtime-token"};
            },
          );
          return controller.loadReleaseNotes();
        },
        createHttpClient: _RealHttpOverrides().createHttpClient,
      );

      expect(notes.entries.single.message, "Private release notes");
      expect(server.authHeaders, ["runtime-token"]);
    } finally {
      await server.close();
    }
  });

  test("checkVersion clears the cached release notes", () async {
    final fetcher = _CountingNotesFetcher(_fakeNotes);
    final missingArchive = Uri.file(
      "${Directory.systemTemp.path}/missing-${DateTime.now().millisecondsSinceEpoch}.json",
    );
    final controller = _UrlReleaseNotesControllerForTest(
      appArchiveUrl: missingArchive,
      releaseNotesUrl: Uri.parse("https://example.com/notes.json"),
      releaseNotesFetcher: fetcher,
    );

    await controller.loadReleaseNotes();
    expect(fetcher.callCount, 1);

    try {
      await controller.checkVersion();
    } on Object {
      // expected — missing archive
    }

    await controller.loadReleaseNotes();
    expect(fetcher.callCount, 2);
  });
}

class _ReleaseNotesControllerForTest extends DesktopUpdaterController {
  _ReleaseNotesControllerForTest({
    super.releaseNotesLoader,
  }) : super(
          appArchiveUrl: null,
          skipInitialVersionCheck: true,
        );

  final ReleaseDescriptor _descriptor = _testDescriptor();

  @override
  ReleaseDescriptor? get activeDescriptor => _descriptor;
}

class _UrlReleaseNotesControllerForTest extends DesktopUpdaterController {
  _UrlReleaseNotesControllerForTest({
    super.appArchiveUrl,
    required Uri releaseNotesUrl,
    ReleaseNotesFetcher? releaseNotesFetcher,
    super.requestHeadersProvider,
  }) : super.forTesting(
          skipInitialVersionCheck: true,
          releaseNotesUrl: releaseNotesUrl,
          releaseNotesFetcher: releaseNotesFetcher,
        );

  final ReleaseDescriptor _descriptor = _testDescriptor();

  @override
  ReleaseDescriptor? get activeDescriptor => _descriptor;
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

class _ReleaseNotesServer {
  _ReleaseNotesServer._(this._server);

  final HttpServer _server;
  final authHeaders = <String?>[];

  Uri get url => Uri.parse("http://127.0.0.1:${_server.port}/notes.json");

  static Future<_ReleaseNotesServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fixture = _ReleaseNotesServer._(server);
    fixture._serve();
    return fixture;
  }

  void _serve() {
    _server.listen((request) async {
      authHeaders.add(request.headers.value("x-update-auth"));
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write(
          '{"data":[{"type":"feat","message":"Private release notes"}]}',
        );
      await request.response.close();
    });
  }

  Future<void> close() => _server.close(force: true);
}

class _RealHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context);
  }
}

ReleaseDescriptor _testDescriptor() {
  return ReleaseDescriptor(
    schemaVersion: 3,
    packageId: "com.example.test",
    appName: "Test App",
    version: "1.2.3",
    buildNumber: 123,
    platform: "macos",
    channel: "stable",
    artifact: ReleaseArtifact(
      kind: "zip",
      url: Uri.parse("https://example.com/app.zip"),
      sha256: "a" * 64,
      length: 42,
    ),
    install: const ReleaseInstall(strategy: "wholeBundleReplace"),
    minimumUpdaterVersion: "2.0.0",
    generatedAt: DateTime.utc(2026, 6, 17),
  );
}
