import "dart:io";

import "package:path/path.dart" as path;

String resolveDartExecutable() {
  final executableName = Platform.isWindows ? "dart.exe" : "dart";
  final flutterRoot = Platform.environment["FLUTTER_ROOT"];
  if (flutterRoot != null && flutterRoot.isNotEmpty) {
    final cached = _cachedDartExecutable(flutterRoot, executableName);
    if (File(cached).existsSync()) {
      return cached;
    }
  }

  final wrapperName = Platform.isWindows ? "dart.bat" : executableName;
  for (final directory in (Platform.environment["PATH"] ?? "")
      .split(Platform.isWindows ? ";" : ":")) {
    if (directory.isEmpty) {
      continue;
    }
    final direct = File(path.join(directory, executableName));
    if (direct.existsSync()) {
      return direct.path;
    }
    final wrapper = File(path.join(directory, wrapperName));
    if (!wrapper.existsSync()) {
      continue;
    }
    if (Platform.isWindows) {
      final inferredFlutterRoot = Directory(directory).parent.path;
      final cached = _cachedDartExecutable(inferredFlutterRoot, executableName);
      if (File(cached).existsSync()) {
        return cached;
      }
    }
    return wrapper.path;
  }

  throw StateError("Unable to resolve the Dart executable from this test.");
}

String _cachedDartExecutable(String flutterRoot, String executableName) {
  return path.join(
    flutterRoot,
    "bin",
    "cache",
    "dart-sdk",
    "bin",
    executableName,
  );
}
