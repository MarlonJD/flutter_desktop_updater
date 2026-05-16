import "dart:io";

import "package:path/path.dart" as path;

Directory currentInstallDirectory({String? executablePath}) {
  final executable = executablePath ?? Platform.resolvedExecutable;
  final executableDirectory = Directory(path.dirname(executable));

  if (Platform.isMacOS) {
    return executableDirectory.parent;
  }

  return executableDirectory;
}

Directory hashRootDirectory({String? pathValue}) {
  if (pathValue == null || pathValue.isEmpty) {
    return currentInstallDirectory();
  }

  final type = FileSystemEntity.typeSync(pathValue);
  if (type == FileSystemEntityType.directory) {
    return Directory(pathValue);
  }

  return currentInstallDirectory(executablePath: pathValue);
}
