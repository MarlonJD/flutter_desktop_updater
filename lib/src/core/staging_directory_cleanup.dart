import "dart:io";

import "package:path/path.dart" as path;

/// Prefix used for temporary staging directories created by the updater.
const String desktopUpdaterStagingPrefix = "desktop_updater_stage_";

/// Default age after which abandoned staging directories can be removed.
const Duration defaultStaleStagingAge = Duration(days: 7);

/// Summary of one stale staging directory cleanup pass.
class StagingDirectoryCleanupReport {
  /// Creates a cleanup report with scan, delete, and failure counts.
  const StagingDirectoryCleanupReport({
    required this.scanned,
    required this.deleted,
    required this.failedPaths,
  });

  /// Number of direct children scanned in the staging parent.
  final int scanned;

  /// Number of stale staging directories deleted.
  final int deleted;

  /// Staging directory paths that could not be deleted.
  final List<String> failedPaths;
}

/// Removes old `desktop_updater_stage_*` directories from [parent].
Future<StagingDirectoryCleanupReport>
    cleanupStaleDesktopUpdaterStagingDirectories({
  required Directory parent,
  DateTime? now,
  Duration staleAge = defaultStaleStagingAge,
  Set<String> preservedPaths = const {},
}) async {
  if (!await parent.exists()) {
    return const StagingDirectoryCleanupReport(
      scanned: 0,
      deleted: 0,
      failedPaths: [],
    );
  }

  final cutoff = (now ?? DateTime.now()).subtract(staleAge);
  final normalizedPreservedPaths = preservedPaths
      .map((value) => path.normalize(path.absolute(value)))
      .toSet();
  var scanned = 0;
  var deleted = 0;
  final failedPaths = <String>[];

  await for (final entity in parent.list(followLinks: false)) {
    scanned += 1;
    if (entity is! Directory) {
      continue;
    }
    if (!path.basename(entity.path).startsWith(desktopUpdaterStagingPrefix)) {
      continue;
    }

    final normalizedPath = path.normalize(path.absolute(entity.path));
    if (normalizedPreservedPaths.contains(normalizedPath)) {
      continue;
    }

    try {
      final modified = (await entity.stat()).modified;
      if (!modified.isBefore(cutoff)) {
        continue;
      }
      await entity.delete(recursive: true);
      deleted += 1;
    } on FileSystemException {
      failedPaths.add(entity.path);
    }
  }

  return StagingDirectoryCleanupReport(
    scanned: scanned,
    deleted: deleted,
    failedPaths: List.unmodifiable(failedPaths),
  );
}
