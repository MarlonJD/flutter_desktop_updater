import "dart:io";

import "sync_versions.dart";

Future<void> main(List<String> args) async {
  if (args.isNotEmpty) {
    stderr.writeln("version_check.dart does not accept options.");
    exitCode = 64;
    return;
  }

  final (versions, changes) = await planVersionSync();
  if (changes.isEmpty) {
    stdout.writeln(
      "Native SDK versions match pubspec.yaml: ${versions.canonical}",
    );
    return;
  }

  stderr.writeln(
    "Native SDK version mismatch for ${changes.length} generated surface(s):",
  );
  for (final change in changes) {
    stderr.writeln("- ${change.path}");
  }
  stderr.writeln("Run: dart run tool/sync_versions.dart");
  exitCode = 1;
}
