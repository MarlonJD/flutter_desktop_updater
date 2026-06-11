import "dart:convert";
import "dart:io";

import "package:args/args.dart";
import "package:cryptography_plus/cryptography_plus.dart";
import "package:desktop_updater/src/app_archive.dart";
import "package:desktop_updater/src/macos_update.dart";
import "package:desktop_updater/src/remote_file.dart";
import "package:desktop_updater/src/version_info.dart";
import "package:path/path.dart" as path;
import "package:pubspec_parse/pubspec_parse.dart";

import "helper/copy.dart";

Future<String> getFileHash(File file) async {
  try {
    final List<int> fileBytes = await file.readAsBytes();
    final hash = await Blake2b().hash(fileBytes);
    return base64.encode(hash.bytes);
  } catch (e) {
    print("Error reading file ${file.path}: $e");
    return "";
  }
}

Future<String?> genFileHashes({required String? path}) async {
  print("Generating file hashes for $path");

  if (path == null) {
    throw Exception("Desktop Updater: Executable path is null");
  }

  final dir = Directory(path);

  print("Directory path: ${dir.path}");

  if (await dir.exists()) {
    final outputFile = File("${dir.path}${Platform.pathSeparator}hashes.json");
    final sink = outputFile.openWrite();
    var hashList = <FileHashModel>[];

    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File &&
          !entity.path.endsWith("hashes.json") &&
          !entity.path.endsWith(".DS_Store")) {
        final hash = await getFileHash(entity);
        final foundPath = normalizeArchivePath(
          entity.path.substring(dir.path.length + 1),
        );

        if (hash.isNotEmpty) {
          final hashObj = FileHashModel(
            filePath: foundPath,
            calculatedHash: hash,
            length: entity.lengthSync(),
          );
          hashList.add(hashObj);
        }
      }
    }

    hashList.sort((a, b) => a.filePath.compareTo(b.filePath));
    sink.write(const JsonEncoder.withIndent("  ").convert(hashList));
    await sink.close();
    return outputFile.path;
  } else {
    throw Exception("Desktop Updater: Directory does not exist");
  }
}

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    print("PLATFORM must be specified: macos, windows, linux");
    exit(1);
  }

  final platform = args[0];

  if (platform != "macos" && platform != "windows" && platform != "linux") {
    print("PLATFORM must be specified: macos, windows, linux");
    exit(1);
  }

  final parsed = Pubspec.parse(await File("pubspec.yaml").readAsString());
  final packageVersion = parsed.version;
  if (packageVersion == null) {
    print("pubspec.yaml version must include a version.");
    exit(1);
  }
  final releaseVersion = DesktopVersionInfo.parse(packageVersion.toString());
  final buildName = releaseVersion.versionName!;
  final buildNumber = releaseVersion.buildNumber;
  final versionLabel = releaseVersionLabel(releaseVersion);
  final versionFolder = releaseVersionFolder(releaseVersion);

  if (platform == "macos") {
    final appNamePubspec = parsed.name;
    final parser = ArgParser()
      ..addOption(
        "app",
        help: "Path to the signed, notarized, stapled .app bundle.",
      )
      ..addOption(
        "channel",
        defaultsTo: "stable",
        help: "Release channel to store in release-manifest.json.",
      )
      ..addOption(
        "output",
        help: "Output artifact directory. Defaults to dist/<build>/<version>.",
      );
    final options = parser.parse(args.sublist(1));
    if (options.rest.length > 1) {
      stderr.writeln("Unexpected arguments: ${options.rest.join(" ")}");
      stderr.writeln(parser.usage);
      exit(64);
    }
    final channel = options.rest.firstOrNull ?? (options["channel"] as String);
    final appPath = options["app"] as String?;
    final outputPath = options["output"] as String?;
    final buildApp = Directory(
      appPath ??
          path.join(
            "build",
            "macos",
            "Build",
            "Products",
            "Release",
            "$appNamePubspec.app",
          ),
    );
    if (!await buildApp.exists()) {
      print("macOS build app not found: ${buildApp.path}");
      exit(1);
    }

    final outputDirectory = Directory(
      outputPath ?? path.join("dist", versionFolder, "$versionLabel-macos"),
    );
    final manifest = await createMacOSReleaseArtifacts(
      appDirectory: buildApp,
      outputDirectory: outputDirectory,
      version: buildName,
      shortVersion: buildNumber ?? 0,
      channel: channel,
    );

    print("macOS release artifacts created at ${outputDirectory.path}");
    print(
      "Manifest: ${path.join(outputDirectory.path, "release-manifest.json")}",
    );
    print("Full archive: ${manifest.fullArchive?.path}");
    print("Payload directory: ${path.join(outputDirectory.path, "payloads")}");
    return;
  }

  // Go to dist directory and get all folder names
  final distDir = Directory("dist");

  if (!await distDir.exists()) {
    print("dist folder could not be found");
    exit(1);
  }

  final folders = await distDir.list().toList();

  String? foundDirectory;
  String? foundVersionLabel;
  String? foundParentDirectory;
  DesktopVersionInfo? foundVersionInfo;

  /// Check if there is a file in given platform
  for (final folder in folders) {
    if (folder is! Directory) {
      continue;
    }

    final files = await folder.list().toList();
    for (final file in files) {
      if (file is! Directory) {
        continue;
      }

      final versionLabel = archiveVersionLabelFromName(
        archiveName: path.basename(file.path),
        appName: parsed.name,
        platform: platform,
      );
      if (versionLabel == null) {
        continue;
      }

      final versionInfo = DesktopVersionInfo.parse(versionLabel);
      if (foundVersionInfo == null ||
          compareDesktopVersions(versionInfo, foundVersionInfo) > 0) {
        foundDirectory = file.path;
        foundVersionLabel = versionLabel;
        foundParentDirectory = folder.path;
        foundVersionInfo = versionInfo;
      }
    }
  }

  if (foundDirectory == null ||
      foundVersionLabel == null ||
      foundParentDirectory == null) {
    print("File not found for platform: $platform");
    exit(1);
  } else {
    print("Using archive: $foundDirectory");
  }

  /// Check if the file is a zip file
  // if (!foundDirectory.endsWith(".app")) {
  //   print("File is not a zip file");
  //   exit(1);
  // }

  if (platform == "windows") {
    await copyDirectory(
      Directory(foundDirectory),
      Directory(
        "$foundParentDirectory${Platform.pathSeparator}$foundVersionLabel-$platform",
      ),
    );
  } else if (platform == "linux") {
    await copyDirectory(
      Directory(foundDirectory),
      Directory(
        "$foundParentDirectory/$foundVersionLabel-$platform",
      ),
    );
  }

  await genFileHashes(
    path:
        "$foundParentDirectory${Platform.pathSeparator}$foundVersionLabel-$platform",
  );

  return;
}
