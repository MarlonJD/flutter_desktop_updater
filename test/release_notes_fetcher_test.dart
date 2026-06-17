import "dart:convert";
import "dart:io";

import "package:desktop_updater/src/io/release_notes_fetcher.dart";
import "package:flutter_test/flutter_test.dart";
import "package:http/http.dart" as http;
import "package:http/testing.dart";

const _url = "https://example.com/notes.json";

void main() {
  test("fetch parses notes from a 200 response", () async {
    final fetcher = ReleaseNotesFetcher(
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            "data": [
              {"type": "feat", "message": "Dark mode"},
              {"type": "fix", "message": "Crash fix"},
            ],
          }),
          200,
        ),
      ),
    );

    final notes = await fetcher.fetch(Uri.parse(_url));

    expect(notes.entries, hasLength(2));
    expect(notes.entries[0].type, "feat");
    expect(notes.entries[0].message, "Dark mode");
    expect(notes.entries[1].type, "fix");
    expect(notes.entries[1].message, "Crash fix");
  });

  test("fetch throws HttpException on non-200 response", () async {
    final fetcher = ReleaseNotesFetcher(
      client: MockClient((_) async => http.Response("Not Found", 404)),
    );

    expect(
      () => fetcher.fetch(Uri.parse(_url)),
      throwsA(isA<HttpException>()),
    );
  });

  test("fetch throws HttpException on 500 response", () async {
    final fetcher = ReleaseNotesFetcher(
      client: MockClient((_) async => http.Response("Server Error", 500)),
    );

    expect(
      () => fetcher.fetch(Uri.parse(_url)),
      throwsA(isA<HttpException>()),
    );
  });

  test("fetch sends GET request to the provided URL", () async {
    Uri? capturedUri;
    final fetcher = ReleaseNotesFetcher(
      client: MockClient((request) async {
        capturedUri = request.url;
        return http.Response(jsonEncode({"data": []}), 200);
      }),
    );

    await fetcher.fetch(Uri.parse(_url));

    expect(capturedUri, Uri.parse(_url));
  });

  test("fetch handles empty data array", () async {
    final fetcher = ReleaseNotesFetcher(
      client: MockClient(
        (_) async => http.Response(jsonEncode({"data": []}), 200),
      ),
    );

    final notes = await fetcher.fetch(Uri.parse(_url));

    expect(notes.entries, isEmpty);
  });

  test("fetch throws FormatException for non-object JSON", () {
    final fetcher = ReleaseNotesFetcher(
      client: MockClient((_) async => http.Response("[]", 200)),
    );

    expect(
      () => fetcher.fetch(Uri.parse(_url)),
      throwsFormatException,
    );
  });
}
