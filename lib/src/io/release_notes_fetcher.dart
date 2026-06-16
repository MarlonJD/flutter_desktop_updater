import "dart:convert";
import "dart:io";

import "package:desktop_updater/src/core/release_notes.dart";
import "package:http/http.dart" as http;

/// Fetches a release notes JSON array from a hosted REST endpoint.
///
/// Inject a custom [http.Client] for testing:
/// ```dart
/// ReleaseNotesFetcher(client: MockClient(...))
/// ```
class ReleaseNotesFetcher {
  /// Fetches a release notes JSON array from a hosted REST endpoint.
  ReleaseNotesFetcher({http.Client? client})
      : _client = client ?? http.Client();

  final http.Client _client;

  /// GETs [url] and returns the parsed [ReleaseNotes].
  ///
  /// Throws [HttpException] if the server returns a non-2xx status.
  Future<ReleaseNotes> fetch(Uri url) async {
    final response = await _client.get(url);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        "Failed to fetch release notes: HTTP ${response.statusCode}",
        uri: url,
      );
    }
    return ReleaseNotes.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }
}
