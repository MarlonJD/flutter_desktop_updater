import "dart:io";

import "package:desktop_updater/src/cli/desktop_updater_cli.dart";

Future<void> main(List<String> args) async {
  final exitCode = await runDesktopUpdaterCli(args);
  if (exitCode != 0) {
    exit(exitCode);
  }
}
