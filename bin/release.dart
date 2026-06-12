import "dart:io";

import "package:desktop_updater/src/release_cli/release_command.dart";

Future<void> main(List<String> args) async {
  final exitCode = await runReleaseCommand(args);
  if (exitCode != 0) {
    exit(exitCode);
  }
}
