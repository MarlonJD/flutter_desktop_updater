// Helper function to copy directory recursively
import "dart:io";

import "package:path/path.dart" as path;

// Helper function to copy directory recursively
Future<void> copyDirectory(Directory source, Directory destination) async {
  await destination.create(recursive: true);
  await for (final entity in source.list(
    recursive: false,
    followLinks: false,
  )) {
    final newPath = path.join(destination.path, path.basename(entity.path));
    if (entity is Directory) {
      await copyDirectory(entity, Directory(newPath));
    } else if (entity is File) {
      await entity.copy(newPath);
    } else if (entity is Link) {
      final target = await entity.target();
      await Link(newPath).create(target);
    }
  }
}
