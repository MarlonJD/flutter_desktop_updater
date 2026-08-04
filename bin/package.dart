import "dart:io";

import "package:desktop_updater/src/cli/package_command.dart";

Future<void> main(List<String> args) async {
  final exitCode = await runPackageCommand(args);
  if (exitCode != 0) {
    exit(exitCode);
  }
}
