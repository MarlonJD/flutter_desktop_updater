# Runtime Request Headers

Use `requestHeadersProvider` when your app downloads updates from a private
host that requires runtime-owned authentication headers.

```dart
final controller = DesktopUpdaterController(
  appArchiveUrl: Uri.parse("https://updates.example.com/app-archive.json"),
  requestHeadersProvider: (source) async {
    final token = await myAuth.currentUpdateToken();
    return {"authorization": "Bearer $token"};
  },
);
```

The provider runs for each HTTP(S) update request:

- `app-archive.json`
- the selected `release.json`
- the selected update artifact zip
- hosted release notes loaded through `releaseNotesUrl`

The returned headers are added to the request before it is sent. If an artifact
download resumes from a partial `.part` file, `desktop_updater` still adds its
own `Range` header after app headers so resumable downloads keep working.
Release notes loaded through an app-owned `releaseNotesLoader` remain fully
owned by your loader; add headers in that code path yourself.

## Shared Or Request-Specific Headers

Return one header map when the same runtime token protects every update file and
hosted release notes document:

```dart
final controller = DesktopUpdaterController(
  appArchiveUrl: Uri.parse("https://updates.example.com/app-archive.json"),
  releaseNotesUrl: Uri.parse("https://updates.example.com/release-notes.json"),
  requestHeadersProvider: (source) async {
    final token = await myAuth.currentUpdateToken();
    return {"authorization": "Bearer $token"};
  },
);
```

The `source` argument is the exact URL being fetched, so apps can route headers
when release notes live behind a different auth boundary:

```dart
final controller = DesktopUpdaterController(
  appArchiveUrl: Uri.parse("https://updates.example.com/app-archive.json"),
  releaseNotesUrl: Uri.parse("https://updates.example.com/release-notes.json"),
  requestHeadersProvider: (source) async {
    if (source.path.endsWith("release-notes.json")) {
      return {"x-notes-auth": await myAuth.currentReleaseNotesToken()};
    }

    return {"authorization": "Bearer ${await myAuth.currentUpdateToken()}"};
  },
);
```

Keep credentials out of `release.json`, `app-archive.json`, and
`desktop_updater.yaml`; those files can be signed, cached, uploaded, and
inspected independently of the user's runtime session. Use the provider for
short-lived bearer tokens, account-scoped update tokens, or private reverse
proxy headers owned by your app session.

S3-compatible upload credentials still belong to the publish/upload side.
Runtime S3 access should be exposed as fetchable HTTPS URLs, signed URLs,
private proxy URLs, or app-owned request headers.
