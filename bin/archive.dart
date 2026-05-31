import "dart:convert";
import "dart:io";

import "package:args/args.dart";
import "package:cryptography_plus/cryptography_plus.dart";
import "package:desktop_updater/src/app_archive.dart";
import "package:desktop_updater/src/macos_update.dart";
import "package:desktop_updater/src/remote_file.dart";
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
  final buildName =
      "${parsed.version?.major}.${parsed.version?.minor}.${parsed.version?.patch}";
  final buildNumber = parsed.version?.build.firstOrNull.toString();
  if (buildNumber == null || buildNumber.isEmpty) {
    print("pubspec.yaml version must include a build number.");
    exit(1);
  }
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
      outputPath ??
          path.join("dist", buildNumber, "$buildName+$buildNumber-macos"),
    );
    final manifest = await createMacOSReleaseArtifacts(
      appDirectory: buildApp,
      outputDirectory: outputDirectory,
      version: buildName,
      shortVersion: int.parse(buildNumber),
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

  /// Sort folders by name, it will be the build number,
  /// and get the last one, biggest build number
  final folders = await distDir.list().toList();
  folders.sort((a, b) => a.path.compareTo(b.path));

  final lastBuildNumberFolder = folders.last;

  // Get all files in the last folder path
  final files = await Directory(lastBuildNumberFolder.path).list().toList();

  var platformFound = false;
  String? foundDirectory;
  String? foundVersion;
  String? foundBuildNumber;

  /// Check if there is a file in given platform
  for (final file in files) {
    if (file is Directory) {
      // desktop_updater_example-0.1.1+2-macos.app
      // version is 0.1.1, build number is 2, platform is macos, name is appNamePubspec variable
      final version = file.path.split("-").elementAt(1).split("+").first;
      final buildNumber =
          file.path.split("-").elementAt(1).split("+").last.split("-").first;
      final foundPlatform = file.path.split("-").last.split(".").first;

      if (foundPlatform == platform) {
        platformFound = true;
        foundDirectory = file.path;
        foundVersion = version;
        foundBuildNumber = buildNumber;
      }
    }
  }

  if (!platformFound || foundDirectory == null) {
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
        "${lastBuildNumberFolder.path}${Platform.pathSeparator}$foundVersion+$foundBuildNumber-$platform",
      ),
    );
  } else if (platform == "linux") {
    await copyDirectory(
      Directory(foundDirectory),
      Directory(
        "${lastBuildNumberFolder.path}/$foundVersion+$foundBuildNumber-$platform",
      ),
    );
  }

  await genFileHashes(
    path:
        "${lastBuildNumberFolder.path}${Platform.pathSeparator}$foundVersion+$foundBuildNumber-$platform",
  );

  return;
}
