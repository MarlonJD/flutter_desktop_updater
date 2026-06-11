# desktop_updater Migration Example

This folder shows the zip-first metadata shape expected by desktop_updater 2.0.

- `app_archive_v3.json` points to `release.json`.
- `release.json` points to one exact zip artifact URL with length and SHA-256.
- Production releases should include descriptor or artifact authenticity metadata.
