import "dart:io";

import "package:path/path.dart" as path;

/// Returns the install directory that contains the running executable or app.
Directory currentInstallDirectory({String? executablePath}) {
  final executable = executablePath ?? Platform.resolvedExecutable;
  final executableDirectory = Directory(path.dirname(executable));

  if (Platform.isMacOS) {
    return executableDirectory.parent.parent;
  }

  return executableDirectory;
}

/// Returns the directory used as the root for install fingerprinting.
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
