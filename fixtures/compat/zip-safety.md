# 2.2.0 Safe Zip Policy Fixture

- Reject parent traversal entries before extraction.
- Reject absolute paths before extraction.
- Reject Windows drive paths before extraction.
- Reject symlink entries on Windows and Linux by default.
- macOS app bundles use ditto; Dart extraction rejects `.app` bundles.
