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
      : _client = client ?? http.Client(),
        _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;

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
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw const FormatException("release-notes.json must be a JSON object.");
    }
    return ReleaseNotes.fromJson(Map<String, dynamic>.from(decoded));
  }

  /// Closes the owned HTTP client.
  void close() {
    if (_ownsClient) {
      _client.close();
    }
  }
}
