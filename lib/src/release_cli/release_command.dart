import "dart:io";

import "package:args/args.dart";
import "package:desktop_updater/src/release_cli/publish_command.dart";
import "package:desktop_updater/src/release_cli/validate_command.dart";

Future<int> runReleaseCommand(
  List<String> args, {
  Directory? projectRoot,
  StringSink? output,
}) async {
  final out = output ?? stdout;
  final parser = ArgParser()
    ..addFlag("help", abbr: "h", negatable: false)
    ..addCommand("publish", buildPublishParser())
    ..addCommand("validate", buildValidateParser());

  try {
    final results = parser.parse(args);
    if (results["help"] as bool || results.command == null) {
      out.writeln(_usage(parser));
      return 0;
    }

    final command = results.command!;
    switch (command.name) {
      case "publish":
        return await runPublishCommand(
          command,
          projectRoot: projectRoot ?? Directory.current,
          output: out,
        );
      case "validate":
        return await runValidateCommand(command, output: out);
    }
    out.writeln("Unsupported release command: ${command.name}");
    return 64;
  } on FormatException catch (error) {
    out.writeln(error.message);
    return 64;
  } on Object catch (error) {
    out.writeln(error);
    return 1;
  }
}

String _usage(ArgParser parser) {
  return """
Publish and validate desktop updater releases.

Usage:
  dart run desktop_updater:release publish --platform macos
  dart run desktop_updater:release validate --manifest dist/desktop_updater/.desktop_updater_publish.json

${parser.usage}
""";
}
