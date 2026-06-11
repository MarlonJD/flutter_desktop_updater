import "dart:io";

import "package:args/args.dart";
import "package:desktop_updater/src/package/release_packager.dart";
import "package:desktop_updater/src/package/zip_release_packager.dart";

Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addFlag("help", abbr: "h", negatable: false)
    ..addOption("input", help: "Path to the app bundle or directory to zip.")
    ..addOption("output", help: "Directory that receives release.json and zip.")
    ..addOption("package-id", help: "Bundle identifier or package id.")
    ..addOption("app-name", help: "App name inside the artifact.")
    ..addOption("version", help: "Release semantic version.")
    ..addOption("build-number", help: "Optional monotonic build number.")
    ..addOption("platform", allowed: ["macos", "windows", "linux"])
    ..addOption("channel", defaultsTo: "stable")
    ..addOption("artifact-url", help: "Exact URL clients will fetch.")
    ..addOption("install-strategy", defaultsTo: "wholeDirectoryReplace");

  final results = parser.parse(args);
  if (results["help"] as bool) {
    stdout.writeln(parser.usage);
    return;
  }

  final inputPath = _required(results, "input");
  final outputPath = _required(results, "output");
  final appName = _required(results, "app-name");
  final platform = _required(results, "platform");
  final request = ReleasePackageRequest(
    input: FileSystemEntity.isDirectorySync(inputPath)
        ? Directory(inputPath)
        : File(inputPath),
    outputDirectory: Directory(outputPath),
    packageId: _required(results, "package-id"),
    appName: appName,
    version: _required(results, "version"),
    buildNumber: _optionalInt(results, "build-number"),
    platform: platform,
    channel: results["channel"] as String,
    artifactUrl: Uri.parse(_required(results, "artifact-url")),
    installStrategy: results["install-strategy"] as String,
  );

  final result = await const ZipReleasePackager().package(request);
  stdout
    ..writeln("Artifact: ${result.artifact.path}")
    ..writeln("Release: ${result.releaseFile.path}")
    ..writeln("app-archive.json item release: ${result.releaseFile.uri}");
}

int? _optionalInt(ArgResults results, String name) {
  final value = results[name] as String?;
  if (value == null || value.trim().isEmpty) {
    return null;
  }
  return int.parse(value);
}

String _required(ArgResults results, String name) {
  final value = results[name] as String?;
  if (value == null || value.trim().isEmpty) {
    throw FormatException("Missing --$name.");
  }
  return value;
}
