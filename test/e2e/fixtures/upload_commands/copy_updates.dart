import "dart:io";

import "package:path/path.dart" as path;

Future<void> main(List<String> args) async {
  final localRoot = Platform.environment["DESKTOP_UPDATER_LOCAL_ROOT"];
  final baseUrl = Platform.environment["DESKTOP_UPDATER_BASE_URL"];
  if (localRoot == null || localRoot.isEmpty) {
    stderr.writeln("DESKTOP_UPDATER_LOCAL_ROOT is required.");
    exitCode = 64;
    return;
  }
  if (baseUrl == null || baseUrl.isEmpty) {
    stderr.writeln("DESKTOP_UPDATER_BASE_URL is required.");
    exitCode = 64;
    return;
  }

  final source = Directory(localRoot);
  final destination = Directory(
    path.join(source.parent.parent.path, "web"),
  );
  await _copyDirectory(source, destination);
}

Future<void> _copyDirectory(Directory source, Directory destination) async {
  await destination.create(recursive: true);
  await for (final entity in source.list(recursive: true, followLinks: false)) {
    final relative = path.relative(entity.path, from: source.path);
    final targetPath = path.join(destination.path, relative);
    if (entity is Directory) {
      await Directory(targetPath).create(recursive: true);
    } else if (entity is File) {
      await File(targetPath).parent.create(recursive: true);
      await entity.copy(targetPath);
    }
  }
}
