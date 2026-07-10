import "dart:io";

import "package:desktop_updater/src/core/staged_update_provenance.dart";
import "package:path/path.dart" as path;

export "package:desktop_updater/src/core/staged_update_provenance.dart"
    show desktopUpdaterStagingPrefix;

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
  final normalizedPreservedPaths = <String>{};
  for (final value in preservedPaths) {
    final entity = Directory(value);
    try {
      normalizedPreservedPaths.add(
        path.normalize(await entity.resolveSymbolicLinks()),
      );
    } on FileSystemException {
      normalizedPreservedPaths.add(path.normalize(path.absolute(value)));
    }
  }
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

    String normalizedPath;
    try {
      normalizedPath = path.normalize(await entity.resolveSymbolicLinks());
    } on FileSystemException {
      continue;
    }
    if (normalizedPreservedPaths.contains(normalizedPath)) {
      continue;
    }

    try {
      final modified = (await entity.stat()).modified;
      if (!modified.isBefore(cutoff)) {
        continue;
      }
      final basename = path.basename(normalizedPath);
      if (!basename.startsWith(desktopUpdaterStagingPrefix)) {
        continue;
      }
      final nonce = basename.substring(desktopUpdaterStagingPrefix.length);
      final state = await readStagedUpdateProvenance(stageRoot: entity);
      if (state.provenance.nonce != nonce) {
        continue;
      }
      await deleteOwnedStagingDirectory(
        parent: parent,
        stageRoot: entity,
        nonce: nonce,
      );
      deleted += 1;
    } on FormatException {
      // Unmarked or malformed prefix directories are caller-owned.
      continue;
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
