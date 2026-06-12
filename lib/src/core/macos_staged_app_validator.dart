import "dart:io";

Future<void> rejectTopLevelMacOSAppSymlink(String stagedPath) async {
  final type = await FileSystemEntity.type(stagedPath, followLinks: false);
  if (type == FileSystemEntityType.link) {
    throw FormatException(
      "Staged macOS app must be a real directory, not a symlink: $stagedPath",
    );
  }
  if (type != FileSystemEntityType.directory) {
    throw FormatException(
      "Staged macOS app must be a directory: $stagedPath",
    );
  }
}
