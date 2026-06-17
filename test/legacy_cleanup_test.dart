import "dart:io";

import "package:flutter_test/flutter_test.dart";

void main() {
  test("unused rewrite leftovers are not kept in the repository", () {
    expect(File("example.json").existsSync(), isFalse);
    expect(File("example/output.txt").existsSync(), isFalse);
    expect(File("bin/smoke_update.dart").existsSync(), isFalse);
    expect(File("bin/archive.dart").existsSync(), isFalse);
    expect(File("bin/helper/copy.dart").existsSync(), isFalse);
    expect(Directory("lib/src/platform").existsSync(), isFalse);
    expect(File("lib/src/update_progress.dart").existsSync(), isFalse);
    expect(File("lib/src/app_archive.dart").existsSync(), isFalse);
    expect(File("lib/src/download.dart").existsSync(), isFalse);
    expect(File("lib/src/file_hash.dart").existsSync(), isFalse);
    expect(File("lib/src/prepare.dart").existsSync(), isFalse);
    expect(File("lib/src/remote_file.dart").existsSync(), isFalse);
    expect(File("lib/src/update.dart").existsSync(), isFalse);
    expect(File("lib/src/version_check.dart").existsSync(), isFalse);
  });

  test("ready-made update UI files are kept in the 2.x runtime", () {
    expect(
      File("lib/desktop_updater_inherited_widget.dart").existsSync(),
      isTrue,
    );
    expect(File("lib/widget/update_widget.dart").existsSync(), isTrue);
    expect(File("lib/widget/update_card.dart").existsSync(), isTrue);
    expect(File("lib/widget/update_direct_card.dart").existsSync(), isTrue);
    expect(File("lib/widget/update_sliver.dart").existsSync(), isTrue);
    expect(File("bin/release.dart").existsSync(), isTrue);
  });

  test("public 2.x runtime does not expose legacy folder update API", () {
    final checkedFiles = Directory("lib")
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith(".dart"))
        .where((file) => !file.path.contains("lib/src/migrate/"))
        .toList(growable: false);
    const forbiddenTokens = <String>[
      "versionCheck",
      "prepareUpdateApp",
      "updateApp(",
      "verifyFileHash",
      "generateFileHashes",
      "legacyFolderReplace",
      "skipCheckVersion",
      "getSkipCheckVersion",
      "needUpdate",
      "isDownloading",
      "isDownloaded",
      "downloadProgress",
      "downloadedSize",
      "downloadSize",
      "updateProgress",
      "sayHello",
      "FileHashModel",
      "AppArchiveModel",
      "ItemModel",
      // Keep legacy folder-update API out of the 2.x runtime. The new release
      // notes capability is allowed through ReleaseNotes models and
      // releaseNotesLoader.
      "getReleaseNotes",
      "setReleaseNotes",
      "ReleaseNotesModel",
    ];

    for (final file in checkedFiles) {
      final source = file.readAsStringSync();
      for (final token in forbiddenTokens) {
        expect(
          source,
          isNot(contains(token)),
          reason: "${file.path} contains $token",
        );
      }
    }
  });
}
