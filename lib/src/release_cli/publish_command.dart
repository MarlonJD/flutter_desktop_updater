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
    ..addMultiOption(
      "dart-define",
      splitCommas: false,
      valueHelp: "key=value",
      help: "Forward a build-time environment value to flutter build. "
          "Repeat for multiple values.",
    )
    ..addFlag(
      "mandatory",
      negatable: false,
      help: "Mark this release as mandatory in app-archive.json. "
          "Ready-made UI hides skip actions and keeps prompting until "
          "installed.",
    )
    ..addOption(
      "minimum-supported-version",
      help: "Top-level supportPolicy minimum app version. Requires "
          "--enforced-after.",
    )
    ..addOption(
      "enforced-after",
      help: "Top-level supportPolicy enforcement deadline as ISO-8601 UTC. "
          "Requires --minimum-supported-version.",
    )
    ..addOption(
      "fresh-install-url",
      help: "Item-level freshInstall download URL. When present, ready-made "
          "UI sends users to a fresh download instead of in-app install.",
    )
    ..addOption(
      "fresh-install-message",
      help: "Optional release-specific freshInstall explanation. Requires "
          "--fresh-install-url.",
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
  final minimumSupportedVersion =
      results["minimum-supported-version"] as String?;
  final enforcedAfterValue = results["enforced-after"] as String?;
  if ((minimumSupportedVersion == null) != (enforcedAfterValue == null)) {
    throw const FormatException(
      "--minimum-supported-version and --enforced-after must be provided "
      "together.",
    );
  }

  final freshInstallUrlValue = results["fresh-install-url"] as String?;
  final freshInstallMessage = results["fresh-install-message"] as String?;
  if (freshInstallMessage != null && freshInstallUrlValue == null) {
    throw const FormatException(
      "--fresh-install-message requires --fresh-install-url.",
    );
  }

  final overrides = ReleasePublishOverrides(
    configPath: results["config"] as String?,
    baseUrl: results["base-url"] as String?,
    outputPath: results["output"] as String?,
    channel: results["channel"] as String?,
    version: results["version"] as String?,
    buildNumber: _optionalInt(results, "build-number"),
    packageId: results["package-id"] as String?,
    appName: results["app-name"] as String?,
    dartDefines: List<String>.unmodifiable(
      results["dart-define"] as List<String>,
    ),
    mandatory: results["mandatory"] as bool,
    minimumSupportedVersion: minimumSupportedVersion,
    enforcedAfter: enforcedAfterValue == null
        ? null
        : DateTime.parse(enforcedAfterValue).toUtc(),
    freshInstallUrl:
        freshInstallUrlValue == null ? null : Uri.parse(freshInstallUrlValue),
    freshInstallMessage: freshInstallMessage,
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
