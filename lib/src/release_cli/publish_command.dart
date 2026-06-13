import "dart:io";

import "package:args/args.dart";
import "package:desktop_updater/src/release_cli/release_publish_config.dart";
import "package:desktop_updater/src/release_cli/release_publisher.dart";

ArgParser buildPublishParser() {
  return ArgParser()
    ..addFlag("help", abbr: "h", negatable: false)
    ..addOption("platform", allowed: ["macos", "windows", "linux"])
    ..addOption("base-url")
    ..addOption("config")
    ..addOption("output")
    ..addOption("channel")
    ..addOption("version")
    ..addOption("build-number")
    ..addOption("package-id")
    ..addOption("app-name")
    ..addFlag(
      "mandatory",
      negatable: false,
      help: "Mark this release as mandatory in app-archive.json.",
    )
    ..addFlag("notarize", negatable: false)
    ..addFlag("skip-build-for-test", negatable: false);
}

Future<int> runPublishCommand(
  ArgResults results, {
  required Directory projectRoot,
  required StringSink output,
}) async {
  if (results["help"] as bool) {
    output.writeln(buildPublishParser().usage);
    return 0;
  }

  final platform = _required(results, "platform");
  final overrides = ReleasePublishOverrides(
    configPath: results["config"] as String?,
    baseUrl: results["base-url"] as String?,
    outputPath: results["output"] as String?,
    channel: results["channel"] as String?,
    version: results["version"] as String?,
    buildNumber: _optionalInt(results, "build-number"),
    packageId: results["package-id"] as String?,
    appName: results["app-name"] as String?,
    mandatory: results["mandatory"] as bool,
    notarize: results["notarize"] as bool,
  );
  final publisher = ReleasePublisher(
    skipBuild: results["skip-build-for-test"] as bool,
  );
  await publisher.publish(
    projectRoot: projectRoot,
    platform: platform,
    overrides: overrides,
    output: output,
  );
  return 0;
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
