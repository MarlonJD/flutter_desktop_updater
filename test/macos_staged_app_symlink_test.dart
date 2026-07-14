import "dart:io";

import "package:desktop_updater/src/core/macos_staged_app_validator.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;

void main() {
  test("native macOS client rechecks staged app before provenance work", () {
    final source = File(
      "macos/desktop_updater/Sources/DesktopUpdaterKit/MacInstallHelper.swift",
    ).readAsStringSync();

    final appValidation =
        source.indexOf("try validateStagingPath(stagingPath)");
    final provenanceCheck = source.indexOf("StageProvenance.verify(");
    final validator = source.indexOf("func validateStagingPath(");
    final resourceCheck = source.indexOf(
      ".resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])",
      validator,
    );
    final symlinkCheck = source.indexOf(
      "if values.isSymbolicLink == true",
      validator,
    );
    final directoryCheck = source.indexOf(
      "if values.isDirectory != true",
      validator,
    );

    expect(appValidation, isNonNegative);
    expect(provenanceCheck, isNonNegative);
    expect(validator, isNonNegative);
    expect(resourceCheck, isNonNegative);
    expect(symlinkCheck, isNonNegative);
    expect(directoryCheck, isNonNegative);
    expect(appValidation, lessThan(provenanceCheck));
    expect(resourceCheck, lessThan(symlinkCheck));
    expect(symlinkCheck, lessThan(directoryCheck));
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
