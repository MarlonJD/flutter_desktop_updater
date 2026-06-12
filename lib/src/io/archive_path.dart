import "package:path/path.dart" as path;

String normalizeArchivePath(String filePath) {
  final normalized = filePath.replaceAll(r"\", "/");
  final segments = normalized
      .split("/")
      .where((segment) => segment.isNotEmpty && segment != ".")
      .toList(growable: false);

  if (segments.any((segment) => segment == "..") ||
      normalized.startsWith("/") ||
      RegExp(r"^[a-zA-Z]:").hasMatch(normalized)) {
    throw FormatException("Unsafe update path: $filePath");
  }

  return segments.join("/");
}

String localPathForArchivePath(String root, String filePath) {
  final normalized = normalizeArchivePath(filePath);
  return path.joinAll([root, ...normalized.split("/")]);
}
