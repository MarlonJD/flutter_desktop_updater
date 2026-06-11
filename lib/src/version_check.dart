import "dart:convert";
import "dart:io";

import "package:desktop_updater/desktop_updater_method_channel.dart";
import "package:desktop_updater/src/app_archive.dart";
import "package:desktop_updater/src/file_hash.dart";
import "package:desktop_updater/src/macos_update.dart";
import "package:desktop_updater/src/release_manifest.dart";
import "package:desktop_updater/src/remote_file.dart";
import "package:desktop_updater/src/version_info.dart";
import "package:flutter/services.dart";
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
          compareArchiveItems(value, element) >= 0 ? value : element,
    );

    final currentVersion = await _currentVersionInfo();
    if (currentVersion == null ||
        !isArchiveItemNewerThanCurrent(latestVersion, currentVersion)) {
      return null;
    }

    if (Platform.isMacOS) {
      return await _macOSVersionCheck(
        latestVersion: latestVersion,
        appArchive: appArchiveDecoded,
        tempDir: tempDir,
      );
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

Future<ItemModel?> _macOSVersionCheck({
  required ItemModel latestVersion,
  required AppArchiveModel appArchive,
  required Directory tempDir,
}) async {
  final manifestFile = File(path.join(tempDir.path, releaseManifestFileName));
  await downloadRemoteFileTo(
    base: latestVersion.url,
    relativePath: latestVersion.manifestPath ?? releaseManifestFileName,
    destination: manifestFile,
  );
  final manifest = await readReleaseManifest(manifestFile);
  final diff = await diffInstalledMacOSApp(targetManifest: manifest);

  if (diff.changedEntries.isEmpty && diff.removedPaths.isEmpty) {
    return null;
  }

  return latestVersion.copyWith(
    changedFiles: fileHashModelsForManifestDiff(diff),
    removedFiles: diff.removedPaths,
    appName: appArchive.appName,
    manifestPath: latestVersion.manifestPath ?? releaseManifestFileName,
    channel: latestVersion.channel ?? manifest.channel,
  );
}

Future<DesktopVersionInfo?> _currentVersionInfo() async {
  if (Platform.isLinux) {
    final exePath = await File("/proc/self/exe").resolveSymbolicLinks();
    final appPath = path.dirname(exePath);
    final versionPath = path.join(
      appPath,
      "data",
      "flutter_assets",
      "version.json",
    );
    final versionJson = jsonDecode(await File(versionPath).readAsString())
        as Map<String, dynamic>;
    return DesktopVersionInfo.fromParts(
      versionName: versionJson["version"]?.toString(),
      buildNumber: versionJson["build_number"]?.toString(),
    );
  }

  final methodChannel = MethodChannelDesktopUpdater();
  Map<String, String?>? versionInfo;
  try {
    versionInfo = await methodChannel.getCurrentVersionInfo();
  } on MissingPluginException {
    versionInfo = null;
  }

  if (versionInfo != null) {
    return DesktopVersionInfo.fromParts(
      versionName: versionInfo["version"],
      buildNumber: versionInfo["buildNumber"],
    );
  }

  final buildNumber = await methodChannel.getCurrentVersion();
  if (buildNumber == null || buildNumber.trim().isEmpty) {
    return null;
  }

  return DesktopVersionInfo.fromParts(buildNumber: buildNumber);
}
