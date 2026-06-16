import "dart:io";

import "package:desktop_updater/src/core/macos_staged_app_validator.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;

void main() {
  test("generated macOS helper rechecks staged app before install work", () {
    final source = File(
      "macos/desktop_updater/Sources/desktop_updater/DesktopUpdaterPlugin.swift",
    ).readAsStringSync();

    final symlinkCheck = source.indexOf(r'if [ -L "$STAGING" ]; then');
    final directoryCheck = source.indexOf(r'if [ ! -d "$STAGING" ]; then');
    final manifestCheck = source.indexOf(
      r'MANIFEST="$(dirname "$STAGING")/.desktop_updater_release_manifest.json"',
    );

    expect(symlinkCheck, isNonNegative);
    expect(directoryCheck, isNonNegative);
    expect(manifestCheck, isNonNegative);
    expect(symlinkCheck, lessThan(manifestCheck));
    expect(directoryCheck, lessThan(manifestCheck));
    expect(
      source,
      contains(
        "Staged macOS update must be a real .app directory, not a symlink.",
      ),
    );
    expect(
      source,
      contains("Staged macOS update directory does not exist."),
    );
  });

  test(
    "top-level staged macOS app symlink is rejected before install",
    () async {
      final tempDir = await Directory.systemTemp.createTemp("macos_symlink_");
      try {
        final realApp = Directory(path.join(tempDir.path, "Real.app"));
        await Directory(path.join(realApp.path, "Contents")).create(
          recursive: true,
        );
        final stagedLink = Link(path.join(tempDir.path, "Staged.app"));
        await stagedLink.create(realApp.path);

        expect(
          FileSystemEntity.typeSync(stagedLink.path, followLinks: false),
          FileSystemEntityType.link,
        );
        await expectLater(
          rejectTopLevelMacOSAppSymlink(stagedLink.path),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              "message",
              contains("Staged macOS app must be a real directory"),
            ),
          ),
        );
      } finally {
        await tempDir.delete(recursive: true);
      }
    },
    skip: !Platform.isMacOS,
  );
}
