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

The returned headers are added to the request before it is sent. If an artifact
download resumes from a partial `.part` file, `desktop_updater` still adds its
own `Range` header after app headers so resumable downloads keep working.

Keep credentials out of `release.json`, `app-archive.json`, and
`desktop_updater.yaml`; those files can be signed, cached, uploaded, and
inspected independently of the user's runtime session. Use the provider for
short-lived bearer tokens, account-scoped update tokens, or private reverse
proxy headers owned by your app session.

S3-compatible upload credentials still belong to the publish/upload side.
Runtime S3 access should be exposed as fetchable HTTPS URLs, signed URLs,
private proxy URLs, or app-owned request headers.
