import "dart:io";

import "package:desktop_updater/src/cli/package_command.dart";
import "package:desktop_updater/src/cli/verify_command.dart";
import "package:desktop_updater/src/package/app_archive_command.dart";
import "package:desktop_updater/src/package_version.dart";
import "package:desktop_updater/src/release_cli/release_command.dart";

/// Runs the standalone Desktop Updater command-line interface.
Future<int> runDesktopUpdaterCli(
  List<String> args, {
  Directory? projectRoot,
  StringSink? output,
  Map<String, String>? environment,
}) async {
  final out = output ?? stdout;
  if (args.isEmpty || (args.length == 1 && _isHelp(args.single))) {
    out.writeln(_usage);
    return 0;
  }
  if (args.length == 1 && args.single == "--version") {
    out.writeln("desktop-updater $desktopUpdaterPackageVersion");
    return 0;
  }

  final command = args.first;
  final commandArgs = args.sublist(1);
  try {
    switch (command) {
      case "release":
        return await runReleaseCommand(
          commandArgs,
          projectRoot: projectRoot ?? Directory.current,
          output: out,
          environment: environment,
        );
      case "package":
        return await runPackageCommand(commandArgs, output: out);
      case "verify":
        return await runVerifyCommand(
          commandArgs,
          output: out,
          projectRoot: projectRoot ?? Directory.current,
        );
      case "app-archive":
        await runAppArchiveCommand(commandArgs, output: out);
        return 0;
    }
    out.writeln("Unsupported command: $command");
    return 64;
  } on FormatException catch (error) {
    out.writeln(error.message);
    return 64;
  } on Object catch (error) {
    out.writeln(error);
    return 1;
  }
}

bool _isHelp(String value) => value == "--help" || value == "-h";

const _usage = """
Desktop Updater standalone CLI.

Usage:
  desktop-updater <command> [arguments]
  desktop-updater --version

Commands:
  release        Publish, sign, validate, and diagnose releases.
  package        Package a complete desktop application artifact.
  verify         Verify a release descriptor and downloaded artifact.
  app-archive    Create or update app-archive.json metadata.
""";
