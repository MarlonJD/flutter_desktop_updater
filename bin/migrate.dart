import "dart:io";

import "package:args/args.dart";
import "package:desktop_updater/src/migrate/migration_tool.dart";
import "package:path/path.dart" as path;

Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addFlag("help", abbr: "h", negatable: false)
    ..addOption(
      "path",
      abbr: "p",
      defaultsTo: ".",
      help: "Flutter app directory to migrate.",
    )
    ..addFlag(
      "apply",
      defaultsTo: false,
      negatable: false,
      help: "Write safe migration edits to disk.",
    )
    ..addFlag(
      "dry-run",
      defaultsTo: false,
      negatable: false,
      help: "Preview safe migration edits without writing files.",
    )
    ..addFlag(
      "check",
      defaultsTo: false,
      negatable: false,
      help: "Exit with code 1 when migration edits or findings remain.",
    );

  final results = parser.parse(args);
  if (results["help"] as bool) {
    stdout.writeln(_usage(parser));
    return;
  }

  final apply = results["apply"] as bool;
  final dryRun = results["dry-run"] as bool;
  if (apply && dryRun) {
    throw const FormatException("Use either --apply or --dry-run, not both.");
  }

  final root = Directory(results["path"] as String);
  final result = await migrateDesktopUpdaterProject(root: root, apply: apply);
  stdout.write(_formatResult(result));

  if ((results["check"] as bool) && (result.hasEdits || result.hasFindings)) {
    exitCode = 1;
  }
}

String _usage(ArgParser parser) {
  return """
Migrate a Flutter app from desktop_updater 1.x patterns to the 2.0 contract.

By default this command runs in dry-run mode. Use --apply to write safe edits.
Manual findings are reported with file and line references.

Usage:
  dart run desktop_updater:migrate --path .
  dart run desktop_updater:migrate --path . --apply
  dart run desktop_updater:migrate --path . --check

${parser.usage}
""";
}

String _formatResult(MigrationResult result) {
  final buffer = StringBuffer()
    ..writeln("desktop_updater 2.0 migration")
    ..writeln("Path: ${result.root.path}")
    ..writeln("Mode: ${result.apply ? "apply" : "dry-run"}")
    ..writeln("Guide: $desktopUpdaterMigrationGuide")
    ..writeln();

  final edits = result.apply ? result.appliedEdits : result.pendingEdits;
  if (edits.isEmpty) {
    buffer.writeln("Safe edits: none");
  } else {
    buffer
        .writeln(result.apply ? "Applied safe edits:" : "Pending safe edits:");
    for (final edit in edits) {
      buffer
        ..writeln("  - ${_location(result, edit.location)}")
        ..writeln("    ${edit.description}");
    }
  }

  buffer.writeln();
  if (result.findings.isEmpty) {
    buffer.writeln("Manual findings: none");
  } else {
    buffer.writeln("Manual findings:");
    for (final finding in result.findings) {
      buffer
        ..writeln("  - ${_location(result, finding.location)}")
        ..writeln("    ${finding.description}")
        ..writeln("    ${finding.recommendation}");
    }
  }

  if (result.apply && result.changedFiles.isNotEmpty) {
    buffer
      ..writeln()
      ..writeln("Changed files:");
    for (final file in result.changedFiles) {
      buffer.writeln("  - ${path.relative(file.path, from: result.root.path)}");
    }
  }

  buffer
    ..writeln()
    ..writeln("Next steps:")
    ..writeln("  1. Review every manual finding.")
    ..writeln("  2. Run flutter analyze and flutter test.")
    ..writeln(
      "  3. Package updates with dart run desktop_updater:package.",
    )
    ..writeln(
      "  4. Verify hosted release.json with dart run desktop_updater:verify --release <release.json>.",
    );

  return buffer.toString();
}

String _location(MigrationResult result, MigrationLocation location) {
  return "${path.relative(location.file.path, from: result.root.path)}:${location.line}:${location.column}";
}
