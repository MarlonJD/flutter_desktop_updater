import "dart:convert";
import "dart:io";

import "package:crypto/crypto.dart" as crypto;
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
  if (args.length < 2 || args[1].isEmpty) {
    stderr.writeln("web root argument is required.");
    exitCode = 64;
    return;
  }

  final source = Directory(localRoot);
  final destination = Directory(args[1]);
  await _copyDirectory(source, destination);

  if (Platform.environment["DESKTOP_UPDATER_UPLOAD_PHASE"] == "index") {
    await _writeReceipt(
      receiptPath:
          Platform.environment["DESKTOP_UPDATER_INDEX_PUBLISH_RECEIPT"],
      localRoot: source,
    );
  }
}

Future<void> _writeReceipt({
  required String? receiptPath,
  required Directory localRoot,
}) async {
  if (receiptPath == null || receiptPath.isEmpty) {
    stderr.writeln("DESKTOP_UPDATER_INDEX_PUBLISH_RECEIPT is required.");
    exitCode = 64;
    return;
  }
  final absent =
      Platform.environment["DESKTOP_UPDATER_EXPECTED_REMOTE_INDEX_ABSENT"] ==
          "true";
  final indexFile = File(path.join(localRoot.path, "app-archive.json"));
  final digest = await crypto.sha256.bind(indexFile.openRead()).first;
  final receipt = <String, Object?>{
    "schemaVersion": 1,
    "observedPriorRevision": <String, Object?>{
      "absent": absent,
      "sha256": absent
          ? null
          : Platform
              .environment["DESKTOP_UPDATER_EXPECTED_REMOTE_INDEX_SHA256"],
      "etag": absent
          ? null
          : Platform.environment["DESKTOP_UPDATER_EXPECTED_REMOTE_INDEX_ETAG"],
    },
    "publishedSha256": digest.toString(),
    "mechanism": "conditionalWrite",
    "leaseEvidenceSha256": null,
  };
  await File(receiptPath).writeAsString(jsonEncode(receipt));
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
