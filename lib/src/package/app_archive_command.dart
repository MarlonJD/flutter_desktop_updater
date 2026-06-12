import "dart:io";

import "package:args/args.dart";
import "package:desktop_updater/src/core/release_index.dart";
import "package:desktop_updater/src/package/app_archive_writer.dart";

/// Runs the `desktop_updater:app_archive` CLI command.
Future<void> runAppArchiveCommand(
  List<String> args, {
  StringSink? output,
}) async {
  final out = output ?? stdout;
  final upsertParser = _buildUpsertParser();
  final parser = ArgParser()
    ..addFlag("help", abbr: "h", negatable: false)
    ..addCommand("upsert", upsertParser);

  final results = parser.parse(args);
  if (results["help"] as bool || results.command == null) {
    out.writeln(_usage(parser));
    return;
  }

  final command = results.command!;
  if (command.name != "upsert") {
    throw FormatException("Unsupported app_archive command: ${command.name}");
  }

  if (command["help"] as bool) {
    out.writeln(_upsertUsage(upsertParser));
    return;
  }

  final archiveFile = File(_required(command, "archive"));
  final item = ReleaseIndexItem(
    version: _required(command, "version"),
    buildNumber: _optionalInt(command, "build-number"),
    platform: _required(command, "platform"),
    channel: command["channel"] as String,
    mandatory: command["mandatory"] as bool,
    release: Uri.parse(_required(command, "release-url")),
  );

  final index = await upsertAppArchive(
    archiveFile: archiveFile,
    appName: _required(command, "app-name"),
    item: item,
  );

  out
    ..writeln("app-archive.json updated: ${archiveFile.path}")
    ..writeln("Items: ${index.items.length}")
    ..writeln("Release: ${item.release}");
}

ArgParser _buildUpsertParser() {
  return ArgParser()
    ..addFlag("help", abbr: "h", negatable: false)
    ..addOption(
      "archive",
      help: "Path to app-archive.json to create or update.",
    )
    ..addOption("app-name", help: "Display app name in app-archive.json.")
    ..addOption("version", help: "Release semantic version.")
    ..addOption("build-number", help: "Optional monotonic build number.")
    ..addOption("platform", allowed: ["macos", "windows", "linux"])
    ..addOption("channel", defaultsTo: "stable")
    ..addFlag(
      "mandatory",
      defaultsTo: false,
      help: "Mark this release as mandatory.",
    )
    ..addOption(
      "release-url",
      help: "Exact hosted URL for the release.json descriptor.",
    );
}

String _usage(ArgParser parser) {
  return """
Create or update desktop_updater app-archive.json metadata.

Usage:
  dart run desktop_updater:app_archive upsert --archive dist/app-archive.json --app-name "Example App" --version 2.0.0 --platform macos --release-url https://updates.example.com/releases/2.0.0/macos/release.json

Commands:
  upsert    Create app-archive.json if needed, or replace a matching release item.

${parser.usage}
""";
}

String _upsertUsage(ArgParser parser) {
  return """
Create or update one app-archive.json release item.

Usage:
  dart run desktop_updater:app_archive upsert --archive dist/app-archive.json --app-name "Example App" --version 2.0.0 --build-number 200 --platform macos --channel stable --release-url https://updates.example.com/releases/2.0.0/macos/release.json

${parser.usage}
""";
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
