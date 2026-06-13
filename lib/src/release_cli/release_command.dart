import "dart:io";

import "package:args/args.dart";
import "package:desktop_updater/src/release_cli/doctor_command.dart";
import "package:desktop_updater/src/release_cli/publish_command.dart";
import "package:desktop_updater/src/release_cli/sign_command.dart";
import "package:desktop_updater/src/release_cli/validate_command.dart";

Future<int> runReleaseCommand(
  List<String> args, {
  Directory? projectRoot,
  StringSink? output,
  Map<String, String>? environment,
}) async {
  final out = output ?? stdout;
  final parser = ArgParser()
    ..addFlag("help", abbr: "h", negatable: false)
    ..addCommand("doctor", buildDoctorParser())
    ..addCommand("publish", buildPublishParser())
    ..addCommand("sign", buildSignParser())
    ..addCommand("validate", buildValidateParser());

  try {
    final results = parser.parse(args);
    if (results["help"] as bool || results.command == null) {
      out.writeln(_usage(parser));
      return 0;
    }

    final command = results.command!;
    switch (command.name) {
      case "doctor":
        return await runDoctorCommand(
          command,
          projectRoot: projectRoot ?? Directory.current,
          output: out,
        );
      case "publish":
        return await runPublishCommand(
          command,
          projectRoot: projectRoot ?? Directory.current,
          output: out,
        );
      case "sign":
        return await runSignCommand(
          command,
          projectRoot: projectRoot ?? Directory.current,
          output: out,
          environment: environment,
        );
      case "validate":
        return await runValidateCommand(
          command,
          output: out,
          environment: environment,
        );
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
  dart run desktop_updater:release doctor --platform macos
  dart run desktop_updater:release publish --platform macos
  dart run desktop_updater:release sign --release dist/desktop_updater/releases/2.2.0/macos/release.json --public-key-id stable-2026 --private-key-env DESKTOP_UPDATER_RELEASE_PRIVATE_KEY
  dart run desktop_updater:release validate --manifest dist/desktop_updater/.desktop_updater_publish.json

${parser.usage}
""";
}
