## 2.0.0-dev.2

* Added macOS release manifests, content-addressed gzip payloads, and `ditto` full ZIP fallback archives for `.app` bundles.
* Added macOS staged app verification for SHA-256 hashes, file modes, symlinks, unexpected files, bundle identifiers, Team IDs, code signatures, Gatekeeper, and stapler validation.
* Changed macOS releases to publish artifact directories instead of raw `.app` trees or ZIP-only updates.
* Reworked the update pipeline around verified temporary staging directories.
* Added native macOS and Windows install helpers that wait for the app to exit before replacing files.
* Added hash/length verification for downloaded files and normalized archive paths for Windows-hosted files.
* Added support for removing files that no longer exist in the target version.

## 1.3.0
* Revert fix macOS issues, sorry for the inconvenience, do not use 1.2.0 for macOS

## 1.2.0
* Fix macOS issues (thanks to @TheFilyng)

## 1.1.1

* Fix download and skip this version localization and add colors

## 1.1.0

* Fix alert dialog skip condition

## 1.0.5

* Add alert dialog option

## 1.0.4

* Add custom direct widget for theme colors

## 1.0.3

* Fix mandotory skip issue

## 1.0.2

* Lower macOS platform requirement to 10.14
* Add DesktopUpdateSliver widget
* Update version to 1.0.2

## 1.0.1

* Add repository link to pubspec.yaml
* Add example visual to README.md

## 1.0.0

* First version of plugin
