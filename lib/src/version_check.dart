import "dart:convert";
import "dart:io";

import "package:desktop_updater/desktop_updater.dart";
import "package:desktop_updater/src/file_hash.dart";
import "package:desktop_updater/src/remote_file.dart";
import "package:path/path.dart" as path;

Future<ItemModel?> versionCheckFunction({required String appArchiveUrl}) async {
  final tempDir = await Directory.systemTemp.createTemp("desktop_updater_");

  try {
    final appArchiveFile = File(path.join(tempDir.path, "app-archive.json"));
    await downloadUriToFile(appArchiveUrl, appArchiveFile);

    final appArchiveDecoded = AppArchiveModel.fromJson(
      jsonDecode(await appArchiveFile.readAsString()) as Map<String, dynamic>,
    );

    final versions = appArchiveDecoded.items
        .where((element) => element.platform == Platform.operatingSystem)
        .toList(growable: false);

    if (versions.isEmpty) {
      return null;
    }

    final latestVersion = versions.reduce(
      (value, element) =>
          value.shortVersion > element.shortVersion ? value : element,
    );

    final currentVersion = await _currentBuildNumber();
    if (currentVersion == null ||
        latestVersion.shortVersion <= currentVersion) {
      return null;
    }

    final newHashFile = File(path.join(tempDir.path, "hashes.json"));
    await downloadRemoteFileTo(
      base: latestVersion.url,
      relativePath: "hashes.json",
      destination: newHashFile,
    );

    final oldHashFilePath = await genFileHashes();
    final diff = await diffFileHashes(oldHashFilePath, newHashFile.path);

    if (diff.changedFiles.isEmpty && diff.removedFiles.isEmpty) {
      return null;
    }

    return latestVersion.copyWith(
      changedFiles: diff.changedFiles,
      removedFiles: diff.removedFiles,
      appName: appArchiveDecoded.appName,
    );
  } finally {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  }
}

Future<int?> _currentBuildNumber() async {
  String? currentVersion;

  if (Platform.isLinux) {
    final exePath = await File("/proc/self/exe").resolveSymbolicLinks();
    final appPath = path.dirname(exePath);
    final versionPath = path.join(
      appPath,
      "data",
      "flutter_assets",
      "version.json",
    );
    final versionJson =
        jsonDecode(await File(versionPath).readAsString())
            as Map<String, dynamic>;
    currentVersion = versionJson["build_number"]?.toString();
  } else {
    currentVersion = await DesktopUpdater().getCurrentVersion();
  }

  if (currentVersion == null || currentVersion.trim().isEmpty) {
    return null;
  }

  return int.tryParse(currentVersion.trim());
}
