import "dart:io";

import "package:desktop_updater/src/core/staging_directory_cleanup.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as path;

void main() {
  test("deletes only stale desktop updater staging directories", () async {
    final root = await Directory.systemTemp.createTemp("staging_cleanup_");
    try {
      final oldStage =
          await Directory(path.join(root.path, "desktop_updater_stage_old"))
              .create();
      final recentStage =
          await Directory(path.join(root.path, "desktop_updater_stage_recent"))
              .create();
      final unrelated =
          await Directory(path.join(root.path, "other_stage_old")).create();
      final stageFile =
          File(path.join(root.path, "desktop_updater_stage_file"));
      await stageFile.writeAsString("not a directory");

      final now = DateTime.utc(2026, 7, 7, 12);
      await _setLastModified(
        oldStage,
        now.subtract(const Duration(days: 8)),
      );
      await _setLastModified(
        recentStage,
        now.subtract(const Duration(hours: 2)),
      );
      await _setLastModified(
        unrelated,
        now.subtract(const Duration(days: 8)),
      );
      await stageFile.setLastModified(now.subtract(const Duration(days: 8)));

      final report = await cleanupStaleDesktopUpdaterStagingDirectories(
        parent: root,
        now: now,
      );

      expect(oldStage.existsSync(), isFalse);
      expect(recentStage.existsSync(), isTrue);
      expect(unrelated.existsSync(), isTrue);
      expect(stageFile.existsSync(), isTrue);
      expect(report.scanned, 4);
      expect(report.deleted, 1);
      expect(report.failedPaths, isEmpty);
    } finally {
      await root.delete(recursive: true);
    }
  });

  test("preserves explicitly protected staging paths", () async {
    final root = await Directory.systemTemp.createTemp("staging_cleanup_");
    try {
      final protectedStage =
          await Directory(path.join(root.path, "desktop_updater_stage_keep"))
              .create();
      final now = DateTime.utc(2026, 7, 7, 12);
      await _setLastModified(
        protectedStage,
        now.subtract(const Duration(days: 8)),
      );

      final report = await cleanupStaleDesktopUpdaterStagingDirectories(
        parent: root,
        now: now,
        preservedPaths: {protectedStage.path},
      );

      expect(protectedStage.existsSync(), isTrue);
      expect(report.scanned, 1);
      expect(report.deleted, 0);
      expect(report.failedPaths, isEmpty);
    } finally {
      await root.delete(recursive: true);
    }
  });
}

Future<void> _setLastModified(FileSystemEntity entity, DateTime value) async {
  if (entity is File) {
    await entity.setLastModified(value);
    return;
  }

  final result = Platform.isWindows
      ? await _setLastModifiedWithPowerShell(entity, value)
      : await _setLastModifiedWithTouch(entity, value);
  if (result.exitCode != 0) {
    fail(
      "Unable to set last modified for ${entity.path}: "
      "${result.stderr}${result.stdout}",
    );
  }
}

Future<ProcessResult> _setLastModifiedWithPowerShell(
  FileSystemEntity entity,
  DateTime value,
) {
  final escapedPath = entity.path.replaceAll("'", "''");
  final timestamp = value.toUtc().toIso8601String();
  return Process.run("powershell.exe", [
    "-NoProfile",
    "-Command",
    "\$item = Get-Item -LiteralPath '$escapedPath'; "
        "\$item.LastWriteTimeUtc = [DateTime]::Parse('$timestamp')",
  ]);
}

Future<ProcessResult> _setLastModifiedWithTouch(
  FileSystemEntity entity,
  DateTime value,
) {
  final local = value.toLocal();
  final timestamp = "${local.year.toString().padLeft(4, "0")}"
      "${local.month.toString().padLeft(2, "0")}"
      "${local.day.toString().padLeft(2, "0")}"
      "${local.hour.toString().padLeft(2, "0")}"
      "${local.minute.toString().padLeft(2, "0")}"
      ".${local.second.toString().padLeft(2, "0")}";
  return Process.run("touch", ["-t", timestamp, entity.path]);
}
