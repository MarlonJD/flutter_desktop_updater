// ignore_for_file: public_member_api_docs

import "dart:io";

import "package:path/path.dart" as path;

const desktopUpdaterMigrationGuide =
    "https://github.com/MarlonJD/flutter_desktop_updater/blob/main/docs/migration/1.x-to-2.0.md";

enum MigrationEditKind {
  pubspecConstraint,
  safeRename,
}

enum MigrationFindingKind {
  legacyGetter,
  lowLevelApi,
  oldCliCommand,
  manualReview,
}

class MigrationLocation {
  const MigrationLocation({
    required this.file,
    required this.line,
    required this.column,
  });

  final File file;
  final int line;
  final int column;
}

class MigrationEdit {
  const MigrationEdit({
    required this.kind,
    required this.location,
    required this.description,
  });

  final MigrationEditKind kind;
  final MigrationLocation location;
  final String description;
}

class MigrationFinding {
  const MigrationFinding({
    required this.kind,
    required this.location,
    required this.description,
    required this.recommendation,
  });

  final MigrationFindingKind kind;
  final MigrationLocation location;
  final String description;
  final String recommendation;
}

class MigrationResult {
  MigrationResult({
    required this.root,
    required this.apply,
    required this.pendingEdits,
    required this.appliedEdits,
    required this.findings,
    required List<File> changedFiles,
  }) : changedFiles = _uniqueFiles(changedFiles);

  final Directory root;
  final bool apply;
  final List<MigrationEdit> pendingEdits;
  final List<MigrationEdit> appliedEdits;
  final List<MigrationFinding> findings;
  final List<File> changedFiles;

  bool get hasEdits => pendingEdits.isNotEmpty || appliedEdits.isNotEmpty;
  bool get hasFindings => findings.isNotEmpty;

  static List<File> _uniqueFiles(List<File> files) {
    final seen = <String>{};
    final unique = <File>[];
    for (final file in files) {
      if (seen.add(file.path)) {
        unique.add(file);
      }
    }
    return unique;
  }
}

Future<MigrationResult> migrateDesktopUpdaterProject({
  required Directory root,
  bool apply = false,
}) async {
  if (!await root.exists()) {
    throw ArgumentError.value(root.path, "root", "Directory does not exist.");
  }

  final edits = <MigrationEdit>[];
  final findings = <MigrationFinding>[];
  final changedFiles = <File>[];

  final pubspec = File(path.join(root.path, "pubspec.yaml"));
  final isDesktopUpdaterPackageRoot = await _isDesktopUpdaterPackageRoot(
    pubspec,
  );
  if (await pubspec.exists()) {
    final updated = await _migratePubspec(pubspec, edits, findings);
    if (updated != null && apply) {
      await pubspec.writeAsString(updated);
      changedFiles.add(pubspec);
    }
  } else {
    findings.add(
      MigrationFinding(
        kind: MigrationFindingKind.manualReview,
        location: MigrationLocation(file: pubspec, line: 1, column: 1),
        description: "pubspec.yaml was not found.",
        recommendation:
            "Run this command from the root of the Flutter app that depends on desktop_updater.",
      ),
    );
  }

  await for (final file in root.list(recursive: true, followLinks: false)) {
    if (file is! File ||
        _isIgnoredPath(root, file, isDesktopUpdaterPackageRoot)) {
      continue;
    }

    if (file.path.endsWith(".dart")) {
      if (_isGeneratedDart(file)) {
        continue;
      }
      final updated = await _migrateDartFile(file, edits, findings);
      if (updated != null && apply) {
        await file.writeAsString(updated);
        changedFiles.add(file);
      }
    } else if (_isInspectableTextFile(file)) {
      await _scanTextFile(file, findings);
    }
  }

  return MigrationResult(
    root: root,
    apply: apply,
    pendingEdits: apply ? const [] : edits,
    appliedEdits: apply ? edits : const [],
    findings: findings,
    changedFiles: changedFiles,
  );
}

Future<String?> _migratePubspec(
  File file,
  List<MigrationEdit> edits,
  List<MigrationFinding> findings,
) async {
  final content = await file.readAsString();
  final lines = content.split("\n");
  var inDependencies = false;
  var changed = false;

  for (var i = 0; i < lines.length; i += 1) {
    final line = lines[i];
    if (RegExp(r"^\S[^:]*:").hasMatch(line)) {
      inDependencies = line.trim() == "dependencies:";
    }
    if (!inDependencies) {
      continue;
    }

    final scalarMatch = RegExp(
      r"^(\s*)desktop_updater:\s*([^#\s][^#]*?)(\s*(#.*)?)$",
    ).firstMatch(line);
    if (scalarMatch != null) {
      final current = scalarMatch.group(2)!.trim();
      if (current == "^2.0.0") {
        continue;
      }
      lines[i] =
          "${scalarMatch.group(1)}desktop_updater: ^2.0.0${scalarMatch.group(3)}";
      changed = true;
      edits.add(
        MigrationEdit(
          kind: MigrationEditKind.pubspecConstraint,
          location: MigrationLocation(file: file, line: i + 1, column: 1),
          description:
              "Update desktop_updater dependency constraint to ^2.0.0.",
        ),
      );
      continue;
    }

    final nestedMatch =
        RegExp(r"^\s*desktop_updater:\s*(#.*)?$").firstMatch(line);
    if (nestedMatch != null) {
      findings.add(
        MigrationFinding(
          kind: MigrationFindingKind.manualReview,
          location: MigrationLocation(file: file, line: i + 1, column: 1),
          description: "desktop_updater dependency uses a nested declaration.",
          recommendation:
              "Review this dependency manually and point it at desktop_updater ^2.0.0 when ready.",
        ),
      );
    }
  }

  if (!changed) {
    return null;
  }
  return lines.join("\n");
}

Future<String?> _migrateDartFile(
  File file,
  List<MigrationEdit> edits,
  List<MigrationFinding> findings,
) async {
  final content = await file.readAsString();
  var updated = content;
  var changed = false;

  final safeReplacements = <String, String>{
    "skipCheckVersion:": "skipInitialVersionCheck:",
    "getSkipCheckVersion": "skipInitialVersionCheck",
  };

  for (final entry in safeReplacements.entries) {
    if (updated.contains(entry.key)) {
      final location = _firstLocation(file, updated, entry.key);
      updated = updated.replaceAll(entry.key, entry.value);
      changed = true;
      if (!edits.any(
        (edit) =>
            edit.kind == MigrationEditKind.safeRename &&
            edit.location.file.path == file.path,
      )) {
        edits.add(
          MigrationEdit(
            kind: MigrationEditKind.safeRename,
            location: location,
            description:
                "Rename deprecated desktop_updater 1.x API aliases to their 2.0 names.",
          ),
        );
      }
    }
  }

  _scanDartFindings(file, updated, findings);

  return changed ? updated : null;
}

void _scanDartFindings(
  File file,
  String content,
  List<MigrationFinding> findings,
) {
  const legacyGetters = <String, String>{
    "needUpdate":
        "Prefer controller.state is UpdateAvailable/UpdateReadyToInstall.",
    "isDownloading": "Prefer controller.state is UpdateDownloading.",
    "isDownloaded": "Prefer controller.state is UpdateReadyToInstall.",
    "downloadProgress":
        "Prefer UpdateDownloading.receivedBytes and totalBytes.",
    "downloadedSize": "Prefer UpdateDownloading.receivedBytes.",
    "downloadSize": "Prefer UpdateDownloading.totalBytes.",
  };

  for (final entry in legacyGetters.entries) {
    final matches = RegExp("\\b${entry.key}\\b").allMatches(content);
    for (final match in matches) {
      findings.add(
        MigrationFinding(
          kind: MigrationFindingKind.legacyGetter,
          location: _offsetLocation(file, content, match.start),
          description:
              "Legacy compatibility getter `${entry.key}` is still in use.",
          recommendation:
              "${entry.value} See the typed state migration section: $desktopUpdaterMigrationGuide",
        ),
      );
    }
  }

  const lowLevelApis = <String, String>{
    "prepareUpdateApp":
        "Prefer DesktopUpdaterController or the 2.0 zip-first UpdateClient flow.",
    "updateApp":
        "Prefer `dart run desktop_updater:package` for publishing and controller download/install APIs at runtime.",
    "versionCheck":
        "Prefer DesktopUpdaterController.checkVersion or checkZipFirstUpdate.",
  };
  for (final entry in lowLevelApis.entries) {
    final matches = RegExp("\\b${entry.key}\\b").allMatches(content);
    for (final match in matches) {
      findings.add(
        MigrationFinding(
          kind: MigrationFindingKind.lowLevelApi,
          location: _offsetLocation(file, content, match.start),
          description: "Low-level 1.x-style API `${entry.key}` is in use.",
          recommendation: "${entry.value} See $desktopUpdaterMigrationGuide",
        ),
      );
    }
  }
}

Future<void> _scanTextFile(
  File file,
  List<MigrationFinding> findings,
) async {
  final content = await file.readAsString();
  final oldCommands = <String>[
    "desktop_updater:release",
    "desktop_updater:archive",
  ];
  for (final command in oldCommands) {
    final matches = command.allMatches(content);
    for (final match in matches) {
      findings.add(
        MigrationFinding(
          kind: MigrationFindingKind.oldCliCommand,
          location: _offsetLocation(file, content, match.start),
          description: "Old 1.x CLI command `$command` is still referenced.",
          recommendation:
              "Migrate publishing scripts to `dart run desktop_updater:package` and verify with `dart run desktop_updater:verify --release <release.json>`.",
        ),
      );
    }
  }
}

MigrationLocation _firstLocation(File file, String content, String needle) {
  final offset = content.indexOf(needle);
  return _offsetLocation(file, content, offset < 0 ? 0 : offset);
}

MigrationLocation _offsetLocation(File file, String content, int offset) {
  var line = 1;
  var column = 1;
  for (var i = 0; i < offset && i < content.length; i += 1) {
    if (content.codeUnitAt(i) == 10) {
      line += 1;
      column = 1;
    } else {
      column += 1;
    }
  }
  return MigrationLocation(file: file, line: line, column: column);
}

Future<bool> _isDesktopUpdaterPackageRoot(File pubspec) async {
  if (!await pubspec.exists()) {
    return false;
  }
  final content = await pubspec.readAsString();
  return RegExp(r"^name:\s*desktop_updater\s*$", multiLine: true).hasMatch(
    content,
  );
}

bool _isIgnoredPath(
  Directory root,
  File file,
  bool isDesktopUpdaterPackageRoot,
) {
  final relative = path.relative(file.path, from: root.path);
  final segments = path.split(relative);
  if (isDesktopUpdaterPackageRoot &&
      (relative == path.join("lib", "src", "migrate", "migration_tool.dart") ||
          relative == path.join("test", "migration_tool_test.dart"))) {
    return true;
  }
  return segments.any(
    (segment) =>
        segment == ".git" ||
        segment == ".dart_tool" ||
        segment == "build" ||
        segment == ".pub" ||
        segment == ".idea",
  );
}

bool _isGeneratedDart(File file) {
  final name = path.basename(file.path);
  return name.endsWith(".g.dart") ||
      name.endsWith(".freezed.dart") ||
      name.endsWith(".gr.dart") ||
      name.endsWith(".mocks.dart");
}

bool _isInspectableTextFile(File file) {
  final extension = path.extension(file.path).toLowerCase();
  return const {
    ".md",
    ".txt",
    ".yaml",
    ".yml",
    ".json",
    ".sh",
    ".bash",
    ".zsh",
    ".ps1",
    ".bat",
    ".cmd",
  }.contains(extension);
}
