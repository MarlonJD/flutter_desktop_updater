import "dart:io";

import "package:desktop_updater/src/cli/verify_command.dart";

Future<void> main(List<String> args) async {
  final exitCode = await runVerifyCommand(args);
  if (exitCode != 0) {
    exit(exitCode);
  }
}
