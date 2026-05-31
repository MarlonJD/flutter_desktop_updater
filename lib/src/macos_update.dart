// ignore_for_file: avoid_catches_without_on_clauses, public_member_api_docs

import "dart:async";
import "dart:io";

import "package:crypto/crypto.dart" as crypto;
import "package:desktop_updater/src/app_archive.dart";
import "package:desktop_updater/src/app_paths.dart";
import "package:desktop_updater/src/release_manifest.dart";
import "package:desktop_updater/src/remote_file.dart";
import "package:desktop_updater/src/update_progress.dart";
import "package:path/path.dart" as path;

typedef ProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);

class MacOSAppIdentity {
  const MacOSAppIdentity({
    required this.bundleIdentifier,
    required this.teamIdentifier,
  });

  final String bundleIdentifier;
  final String teamIdentifier;
}

Future<ProcessResult> defaultProcessRunner(
  String executable,
  List<String> arguments,
) {
  return Process.run(executable, arguments);
}

Future<ReleaseManifest> downloadMacOSReleaseManifest({
  required String remoteUpdateFolder,
  Directory? tempDirectory,
  String manifestPath = releaseManifestFileName,
}) async {
  final ownsTempDirectory = tempDirectory == null;
  final directory = tempDirectory ??
      await Directory.systemTemp.createTemp("desktop_updater_manifest_");

  try {
    final manifestFile =
        File(path.join(directory.path, releaseManifestFileName));
    await downloadRemoteFileTo(
      base: remoteUpdateFolder,
      relativePath: manifestPath,
      destination: manifestFile,
    );
    return await readReleaseManifest(manifestFile);
  } finally {
    if (ownsTempDirectory && await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }
}

Future<ReleaseManifestDiff> diffInstalledMacOSApp({
  required ReleaseManifest targetManifest,
  Directory? installedAppDirectory,
  ProcessRunner runProcess = defaultProcessRunner,
}) async {
  final currentApp = installedAppDirectory ?? currentInstallDirectory();
  final identity = await readMacOSAppIdentity(
    appDirectory: currentApp,
    runProcess: runProcess,
  );
  verifyReleaseManifestIdentity(manifest: targetManifest, identity: identity);
  final currentManifest = await generateMacOSAppManifest(
    appDirectory: currentApp,
    version: "current",
    shortVersion: 0,
    channel: targetManifest.channel,
    bundleIdentifier: identity.bundleIdentifier,
    teamIdentifier: identity.teamIdentifier,
  );

  return diffReleaseManifests(
    current: currentManifest,
    target: targetManifest,
  );
}

List<FileHashModel> fileHashModelsForManifestDiff(ReleaseManifestDiff diff) {
  return diff.changedEntries.map((entry) {
    return FileHashModel(
      filePath: entry.path,
      calculatedHash: entry.sha256 ?? entry.symlinkTarget ?? "",
      length: entry.length,
      kind: entry.type == ReleaseManifestEntryType.file ? "file" : "symlink",
      sha256: entry.sha256,
      mode: entry.mode,
      payloadPath: entry.payloadPath,
      symlinkTarget: entry.symlinkTarget,
    );
  }).toList(growable: false);
}

Future<Stream<UpdateProgress>> updateMacOSAppFunction({
  required String remoteUpdateFolder,
  String manifestPath = releaseManifestFileName,
}) async {
  late StreamController<UpdateProgress> controller;

  controller = StreamController<UpdateProgress>(
    onListen: () {
      unawaited(
        _stageMacOSUpdate(
          controller: controller,
          remoteUpdateFolder: remoteUpdateFolder,
          manifestPath: manifestPath,
        ),
      );
    },
  );

  return controller.stream;
}

Future<void> _stageMacOSUpdate({
  required StreamController<UpdateProgress> controller,
  required String remoteUpdateFolder,
  required String manifestPath,
}) async {
  try {
    final tempDirectory = await Directory.systemTemp.createTemp(
      "desktop_updater_manifest_",
    );
    try {
      final manifest = await downloadMacOSReleaseManifest(
        remoteUpdateFolder: remoteUpdateFolder,
        tempDirectory: tempDirectory,
        manifestPath: manifestPath,
      );

      try {
        final result = await stageMacOSDeltaUpdate(
          remoteUpdateFolder: remoteUpdateFolder,
          manifest: manifest,
          onProgress: (progress) => controller.add(progress),
        );
        _addCompletedProgress(controller, result.stagedAppDirectory.path);
      } catch (_) {
        final result = await stageMacOSFullArchiveFallback(
          remoteUpdateFolder: remoteUpdateFolder,
          manifest: manifest,
          onProgress: (progress) => controller.add(progress),
        );
        _addCompletedProgress(controller, result.stagedAppDirectory.path);
      }
    } finally {
      if (await tempDirectory.exists()) {
        await tempDirectory.delete(recursive: true);
      }
    }
  } catch (error, stackTrace) {
    controller.addError(error, stackTrace);
  } finally {
    await controller.close();
  }
}

class MacOSStageResult {
  const MacOSStageResult({required this.stagedAppDirectory});

  final Directory stagedAppDirectory;
}

Future<MacOSStageResult> stageMacOSDeltaUpdate({
  required String remoteUpdateFolder,
  required ReleaseManifest manifest,
  Directory? installedAppDirectory,
  ProcessRunner runProcess = defaultProcessRunner,
  void Function(UpdateProgress progress)? onProgress,
}) async {
  final installedApp = installedAppDirectory ?? currentInstallDirectory();
  final identity = await readMacOSAppIdentity(
    appDirectory: installedApp,
    runProcess: runProcess,
  );
  verifyReleaseManifestIdentity(manifest: manifest, identity: identity);
  final stagingRoot = await Directory(
    path.join(installedApp.parent.path, ".desktop_updater_macos_delta_"),
  ).createTemp();
  final stagedApp = Directory(path.join(stagingRoot.path, manifest.appName));

  try {
    await runDittoCopy(
      source: installedApp.path,
      destination: stagedApp.path,
      runProcess: runProcess,
    );

    final diff = await diffInstalledMacOSApp(
      targetManifest: manifest,
      installedAppDirectory: installedApp,
      runProcess: runProcess,
    );

    for (final removedPath in diff.removedPaths.reversed) {
      await deletePathIfExists(
        localPathForArchivePath(stagedApp.path, removedPath),
      );
    }

    final changedRegularFiles = diff.changedEntries
        .where((entry) => entry.type == ReleaseManifestEntryType.file)
        .toList(growable: false);
    final totalBytes = changedRegularFiles.fold<int>(
      0,
      (total, entry) => total + entry.length,
    );
    var completedBytes = 0;
    var completedFiles = 0;

    for (final entry in diff.changedEntries) {
      if (entry.type == ReleaseManifestEntryType.file) {
        await _downloadAndInstallPayload(
          remoteUpdateFolder: remoteUpdateFolder,
          entry: entry,
          stagedApp: stagedApp,
          runProcess: runProcess,
          onProgress: (receivedBytes, total) {
            onProgress?.call(
              UpdateProgress(
                totalBytes: totalBytes.toDouble(),
                receivedBytes: (completedBytes + receivedBytes).toDouble(),
                currentFile: entry.path,
                totalFiles: diff.changedEntries.length,
                completedFiles: completedFiles,
                stagingDirectory: stagedApp.path,
              ),
            );
          },
        );
        completedBytes += entry.length;
      } else {
        final destination = localPathForArchivePath(stagedApp.path, entry.path);
        await deletePathIfExists(destination);
        validateSymlinkTarget(
          appRoot: stagedApp.path,
          linkRelativePath: entry.path,
          target: entry.symlinkTarget ?? "",
        );
        await Directory(path.dirname(destination)).create(recursive: true);
        await Link(destination).create(entry.symlinkTarget!);
      }

      completedFiles += 1;
      onProgress?.call(
        UpdateProgress(
          totalBytes: totalBytes.toDouble(),
          receivedBytes: completedBytes.toDouble(),
          currentFile: entry.path,
          totalFiles: diff.changedEntries.length,
          completedFiles: completedFiles,
          stagingDirectory: stagedApp.path,
        ),
      );
    }

    await verifyStagedAppManifest(
      appDirectory: stagedApp,
      manifest: manifest,
    );
    await verifyMacOSNativeGates(
      appDirectory: stagedApp,
      expectedBundleIdentifier: identity.bundleIdentifier,
      expectedTeamIdentifier: identity.teamIdentifier,
      runProcess: runProcess,
    );
    await writeStagedManifestSidecar(stagedApp, manifest);
    return MacOSStageResult(stagedAppDirectory: stagedApp);
  } catch (_) {
    if (await stagingRoot.exists()) {
      await stagingRoot.delete(recursive: true);
    }
    rethrow;
  }
}

Future<MacOSStageResult> stageMacOSFullArchiveFallback({
  required String remoteUpdateFolder,
  required ReleaseManifest manifest,
  ProcessRunner runProcess = defaultProcessRunner,
  void Function(UpdateProgress progress)? onProgress,
}) async {
  final archive = manifest.fullArchive;
  if (archive == null) {
    throw const FormatException("macOS release manifest has no full archive.");
  }

  final installedApp = currentInstallDirectory();
  final identity = await readMacOSAppIdentity(
    appDirectory: installedApp,
    runProcess: runProcess,
  );
  verifyReleaseManifestIdentity(manifest: manifest, identity: identity);
  final stagingRoot = await Directory(
    path.join(installedApp.parent.path, ".desktop_updater_macos_full_"),
  ).createTemp();
  final archiveFile = File(path.join(stagingRoot.path, "full.zip"));
  final extractRoot = stagingRoot;

  try {
    await downloadRemoteFileTo(
      base: remoteUpdateFolder,
      relativePath: archive.path,
      destination: archiveFile,
      onProgress: (receivedBytes, _) {
        onProgress?.call(
          UpdateProgress(
            totalBytes: archive.length.toDouble(),
            receivedBytes: receivedBytes.toDouble(),
            currentFile: archive.path,
            totalFiles: 1,
            completedFiles: 0,
            stagingDirectory: extractRoot.path,
          ),
        );
      },
    );

    if (await archiveFile.length() != archive.length) {
      throw FileSystemException(
        "Full archive length does not match manifest",
        archiveFile.path,
      );
    }
    final actualHash = await sha256File(archiveFile);
    if (actualHash != archive.sha256) {
      throw FileSystemException(
        "Full archive SHA-256 does not match manifest",
        archiveFile.path,
      );
    }

    await extractRoot.create(recursive: true);
    await runDittoExtractZip(
      archivePath: archiveFile.path,
      destination: extractRoot.path,
      runProcess: runProcess,
    );

    final stagedApp = Directory(path.join(extractRoot.path, manifest.appName));
    if (!await stagedApp.exists()) {
      throw FileSystemException(
        "Full archive did not contain the expected app bundle",
        stagedApp.path,
      );
    }

    await verifyStagedAppManifest(
      appDirectory: stagedApp,
      manifest: manifest,
    );
    await verifyMacOSNativeGates(
      appDirectory: stagedApp,
      expectedBundleIdentifier: identity.bundleIdentifier,
      expectedTeamIdentifier: identity.teamIdentifier,
      runProcess: runProcess,
    );
    await writeStagedManifestSidecar(stagedApp, manifest);
    return MacOSStageResult(stagedAppDirectory: stagedApp);
  } catch (_) {
    if (await stagingRoot.exists()) {
      await stagingRoot.delete(recursive: true);
    }
    rethrow;
  }
}

Future<ReleaseManifest> createMacOSReleaseArtifacts({
  required Directory appDirectory,
  required Directory outputDirectory,
  required String version,
  required int shortVersion,
  String channel = "stable",
  ProcessRunner runProcess = defaultProcessRunner,
}) async {
  if (!Platform.isMacOS) {
    throw UnsupportedError("macOS release artifacts must be created on macOS.");
  }
  if (!await appDirectory.exists() || !appDirectory.path.endsWith(".app")) {
    throw FileSystemException(
      "Expected a macOS .app bundle",
      appDirectory.path,
    );
  }

  if (await outputDirectory.exists()) {
    await outputDirectory.delete(recursive: true);
  }
  await outputDirectory.create(recursive: true);

  final identity = await readMacOSAppIdentity(
    appDirectory: appDirectory,
    runProcess: runProcess,
  );
  await verifyMacOSNativeGates(
    appDirectory: appDirectory,
    expectedBundleIdentifier: identity.bundleIdentifier,
    expectedTeamIdentifier: identity.teamIdentifier,
    runProcess: runProcess,
  );
  final payloadDirectory =
      Directory(path.join(outputDirectory.path, "payloads"));

  var manifest = await generateMacOSAppManifest(
    appDirectory: appDirectory,
    version: version,
    shortVersion: shortVersion,
    channel: channel,
    bundleIdentifier: identity.bundleIdentifier,
    teamIdentifier: identity.teamIdentifier,
    payloadDirectory: payloadDirectory,
  );

  final archivePath = "${path.basenameWithoutExtension(appDirectory.path)}.zip";
  final archiveFile = File(path.join(outputDirectory.path, archivePath));
  await runDittoCreateZip(
    appPath: appDirectory.path,
    archivePath: archiveFile.path,
    runProcess: runProcess,
  );

  manifest = manifest.copyWith(
    fullArchive: ReleaseFullArchive(
      path: archivePath,
      sha256: await sha256File(archiveFile),
      length: await archiveFile.length(),
    ),
  );
  await writeReleaseManifest(
    File(path.join(outputDirectory.path, releaseManifestFileName)),
    manifest,
  );
  return manifest;
}

Future<void> writeStagedManifestSidecar(
  Directory stagedApp,
  ReleaseManifest manifest,
) async {
  await writeReleaseManifest(
    File(path.join(stagedApp.parent.path, stagedReleaseManifestFileName)),
    manifest,
  );
}

Future<MacOSAppIdentity> readMacOSAppIdentity({
  required Directory appDirectory,
  ProcessRunner runProcess = defaultProcessRunner,
}) async {
  return MacOSAppIdentity(
    bundleIdentifier: await readBundleIdentifier(
      appDirectory: appDirectory,
      runProcess: runProcess,
    ),
    teamIdentifier: await readCodeSignTeamIdentifier(
      appDirectory: appDirectory,
      runProcess: runProcess,
    ),
  );
}

void verifyReleaseManifestIdentity({
  required ReleaseManifest manifest,
  required MacOSAppIdentity identity,
}) {
  if (manifest.bundleIdentifier != identity.bundleIdentifier) {
    throw StateError(
      "Release manifest bundleIdentifier mismatch: expected "
      "${identity.bundleIdentifier}, got ${manifest.bundleIdentifier}",
    );
  }
  if (manifest.teamIdentifier != identity.teamIdentifier) {
    throw StateError(
      "Release manifest teamIdentifier mismatch: expected "
      "${identity.teamIdentifier}, got ${manifest.teamIdentifier}",
    );
  }
}

Future<void> verifyMacOSNativeGates({
  required Directory appDirectory,
  required String expectedBundleIdentifier,
  required String expectedTeamIdentifier,
  ProcessRunner runProcess = defaultProcessRunner,
}) async {
  await _runChecked(
    "/usr/bin/codesign",
    ["--verify", "--deep", "--strict", "--verbose=2", appDirectory.path],
    runProcess,
  );
  await _runChecked(
    "/usr/sbin/spctl",
    ["--assess", "--type", "execute", "--verbose=2", appDirectory.path],
    runProcess,
  );
  await _runChecked(
    "/usr/bin/xcrun",
    ["stapler", "validate", appDirectory.path],
    runProcess,
  );

  final bundleIdentifier = await readBundleIdentifier(
    appDirectory: appDirectory,
    runProcess: runProcess,
  );
  if (bundleIdentifier != expectedBundleIdentifier) {
    throw StateError(
      "CFBundleIdentifier mismatch: expected $expectedBundleIdentifier, "
      "got $bundleIdentifier",
    );
  }

  final teamIdentifier = await readCodeSignTeamIdentifier(
    appDirectory: appDirectory,
    runProcess: runProcess,
  );
  if (teamIdentifier != expectedTeamIdentifier) {
    throw StateError(
      "TeamIdentifier mismatch: expected $expectedTeamIdentifier, "
      "got $teamIdentifier",
    );
  }
}

Future<String> readBundleIdentifier({
  required Directory appDirectory,
  ProcessRunner runProcess = defaultProcessRunner,
}) async {
  final result = await _runChecked(
    "/usr/bin/plutil",
    [
      "-extract",
      "CFBundleIdentifier",
      "raw",
      "-o",
      "-",
      path.join(appDirectory.path, "Contents", "Info.plist"),
    ],
    runProcess,
  );
  return result.stdout.toString().trim();
}

Future<String> readCodeSignTeamIdentifier({
  required Directory appDirectory,
  ProcessRunner runProcess = defaultProcessRunner,
}) async {
  final result = await _runChecked(
    "/usr/bin/codesign",
    ["-dv", "--verbose=4", appDirectory.path],
    runProcess,
  );
  final output = "${result.stdout}\n${result.stderr}";
  final match =
      RegExp(r"^TeamIdentifier=(.+)$", multiLine: true).firstMatch(output);
  final teamIdentifier = match?.group(1)?.trim();
  if (teamIdentifier == null || teamIdentifier.isEmpty) {
    throw StateError("codesign output did not contain TeamIdentifier.");
  }
  return teamIdentifier;
}

Future<void> runDittoCreateZip({
  required String appPath,
  required String archivePath,
  ProcessRunner runProcess = defaultProcessRunner,
}) async {
  await _runChecked(
    "/usr/bin/ditto",
    ["-c", "-k", "--keepParent", "--sequesterRsrc", appPath, archivePath],
    runProcess,
  );
}

Future<void> runDittoExtractZip({
  required String archivePath,
  required String destination,
  ProcessRunner runProcess = defaultProcessRunner,
}) async {
  await _runChecked(
    "/usr/bin/ditto",
    ["-x", "-k", archivePath, destination],
    runProcess,
  );
}

Future<void> runDittoCopy({
  required String source,
  required String destination,
  ProcessRunner runProcess = defaultProcessRunner,
}) async {
  await _runChecked("/usr/bin/ditto", [source, destination], runProcess);
}

Future<void> deletePathIfExists(String filePath) async {
  final type = FileSystemEntity.typeSync(filePath, followLinks: false);
  if (type == FileSystemEntityType.notFound) {
    return;
  }
  if (type == FileSystemEntityType.directory) {
    await Directory(filePath).delete(recursive: true);
  } else if (type == FileSystemEntityType.link) {
    await Link(filePath).delete();
  } else {
    await File(filePath).delete();
  }
}

Future<void> _downloadAndInstallPayload({
  required String remoteUpdateFolder,
  required ReleaseManifestEntry entry,
  required Directory stagedApp,
  required ProcessRunner runProcess,
  void Function(int receivedBytes, int? totalBytes)? onProgress,
}) async {
  final payloadPath = entry.payloadPath;
  if (payloadPath == null || payloadPath.isEmpty) {
    throw FormatException("Missing payload path for ${entry.path}");
  }

  final payloadFile = File(
    path.join(
      stagedApp.parent.path,
      "payload-downloads",
      path.basename(payloadPath),
    ),
  );
  await downloadRemoteFileTo(
    base: remoteUpdateFolder,
    relativePath: payloadPath,
    destination: payloadFile,
    onProgress: onProgress,
  );

  final bytes = gzip.decode(await payloadFile.readAsBytes());
  if (bytes.length != entry.length) {
    throw FileSystemException(
      "Payload length does not match manifest",
      payloadFile.path,
    );
  }
  final digest = cryptoSha256(bytes);
  if (digest != entry.sha256) {
    throw FileSystemException(
      "Payload SHA-256 does not match manifest",
      payloadFile.path,
    );
  }

  final destination = File(localPathForArchivePath(stagedApp.path, entry.path));
  await deletePathIfExists(destination.path);
  await destination.parent.create(recursive: true);
  await destination.writeAsBytes(bytes, flush: true);
  await _runChecked("/bin/chmod", [entry.mode!, destination.path], runProcess);
}

String cryptoSha256(List<int> bytes) {
  return crypto.sha256.convert(bytes).toString();
}

Future<ProcessResult> _runChecked(
  String executable,
  List<String> arguments,
  ProcessRunner runProcess,
) async {
  final result = await runProcess(executable, arguments);
  if (result.exitCode != 0) {
    throw ProcessException(
      executable,
      arguments,
      "Command failed with exit ${result.exitCode}: "
      "${result.stderr}${result.stdout}",
      result.exitCode,
    );
  }
  return result;
}

void _addCompletedProgress(
  StreamController<UpdateProgress> controller,
  String stagedAppPath,
) {
  controller.add(
    UpdateProgress(
      totalBytes: 1,
      receivedBytes: 1,
      currentFile: "",
      totalFiles: 1,
      completedFiles: 1,
      stagingDirectory: stagedAppPath,
    ),
  );
}
