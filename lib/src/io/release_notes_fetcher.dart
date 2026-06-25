import "dart:convert";
import "dart:io";

import "package:desktop_updater/src/core/release_notes.dart";
import "package:desktop_updater/src/io/http_update_transport.dart"
    show UpdateRequestHeadersProvider;
import "package:http/http.dart" as http;

/// Fetches a release notes JSON array from a hosted REST endpoint.
///
/// Inject a custom [http.Client] for testing:
/// ```dart
/// ReleaseNotesFetcher(client: MockClient(...))
/// ```
class ReleaseNotesFetcher {
  /// Fetches a release notes JSON array from a hosted REST endpoint.
  ReleaseNotesFetcher({
    http.Client? client,
    UpdateRequestHeadersProvider? requestHeadersProvider,
  })  : _requestHeadersProvider = requestHeadersProvider,
        _client = client ?? http.Client(),
        _ownsClient = client == null;

  final http.Client _client;
  final UpdateRequestHeadersProvider? _requestHeadersProvider;
  final bool _ownsClient;

  /// GETs [url] and returns the parsed [ReleaseNotes].
  ///
  /// Throws [HttpException] if the server returns a non-2xx status.
  Future<ReleaseNotes> fetch(Uri url) async {
    final requestHeadersProvider = _requestHeadersProvider;
    final headers = requestHeadersProvider == null
        ? null
        : await requestHeadersProvider(url);
    final response = await _client.get(url, headers: headers);
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
