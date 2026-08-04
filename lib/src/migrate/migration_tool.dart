// ignore_for_file: public_member_api_docs

import "dart:io";

import "package:path/path.dart" as path;

const desktopUpdaterMigrationGuideV1To2 =
    "https://github.com/MarlonJD/flutter_desktop_updater/blob/main/docs/migration/1.x-to-2.0.md";
const desktopUpdaterMigrationGuideV2To3 =
    "https://github.com/MarlonJD/flutter_desktop_updater/blob/main/docs/migration/2.x-to-3.0.md";

// Historical alias retained for callers that imported the 1.x guide.
const desktopUpdaterMigrationGuide = desktopUpdaterMigrationGuideV1To2;

String migrationGuideFor(int fromMajor) => fromMajor == 1
    ? desktopUpdaterMigrationGuideV1To2
    : desktopUpdaterMigrationGuideV2To3;

enum MigrationEditKind {
  pubspecConstraint,
  safeRename,
}

enum MigrationFindingKind {
  legacyGetter,
  lowLevelApi,
  oldCliCommand,
  manualReview,
  sourceMajorMismatch,
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
    required this.fromMajor,
    required this.pendingEdits,
    required this.appliedEdits,
    required this.findings,
    required List<File> changedFiles,
  }) : changedFiles = _uniqueFiles(changedFiles);

  final Directory root;
  final bool apply;
  final int fromMajor;
  final List<MigrationEdit> pendingEdits;
  final List<MigrationEdit> appliedEdits;
  final List<MigrationFinding> findings;
  final List<File> changedFiles;

  bool get hasEdits => pendingEdits.isNotEmpty || appliedEdits.isNotEmpty;
  bool get hasFindings => findings.isNotEmpty;
  bool get hasSourceMajorMismatch => findings.any(
        (finding) => finding.kind == MigrationFindingKind.sourceMajorMismatch,
      );

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
  int fromMajor = 1,
}) async {
  if (fromMajor != 1 && fromMajor != 2) {
    throw ArgumentError.value(fromMajor, "fromMajor", "Use 1 or 2.");
  }
  if (!await root.exists()) {
    throw ArgumentError.value(root.path, "root", "Directory does not exist.");
  }

  final edits = <MigrationEdit>[];
  final findings = <MigrationFinding>[];
  final changedFiles = <File>[];
  final pendingWrites = <String, File>{};
  final pendingContents = <String, String>{};

  final pubspec = File(path.join(root.path, "pubspec.yaml"));
  final isDesktopUpdaterPackageRoot = await _isDesktopUpdaterPackageRoot(
    pubspec,
  );
  if (await pubspec.exists()) {
    final updated = await _migratePubspec(
      pubspec,
      edits,
      findings,
      fromMajor,
    );
    if (updated != null) {
      pendingWrites[pubspec.path] = pubspec;
      pendingContents[pubspec.path] = updated;
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
      final updated = await _migrateDartFile(
        file,
        edits,
        findings,
        fromMajor,
      );
      if (updated != null) {
        pendingWrites[file.path] = file;
        pendingContents[file.path] = updated;
      }
    } else if (_isInspectableTextFile(file)) {
      await _scanTextFile(file, findings, fromMajor);
    }
  }

  final blocked = findings.any(
    (finding) => finding.kind == MigrationFindingKind.sourceMajorMismatch,
  );
  if (apply && !blocked) {
    for (final entry in pendingWrites.entries) {
      await entry.value.writeAsString(pendingContents[entry.key]!);
      changedFiles.add(entry.value);
    }
  }

  return MigrationResult(
    root: root,
    apply: apply,
    fromMajor: fromMajor,
    pendingEdits: apply && !blocked ? const [] : edits,
    appliedEdits: apply && !blocked ? edits : const [],
    findings: findings,
    changedFiles: changedFiles,
  );
}

Future<String?> _migratePubspec(
  File file,
  List<MigrationEdit> edits,
  List<MigrationFinding> findings,
  int fromMajor,
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
      final major = _simpleConstraintMajor(current);
      final target = fromMajor == 1 ? "^2.0.0" : "^3.0.0";
      final supportedSource = fromMajor == 1 ? 1 : 2;
      final idempotent = fromMajor == 1 ? "^2.0.0" : "^3.0.0";
      if (major == null) {
        _addManualDependencyFinding(
          file,
          i + 1,
          findings,
          "desktop_updater uses a non-simple dependency constraint.",
          "Review the dependency manually and migrate it to $target.",
        );
      } else if (major == supportedSource) {
        lines[i] =
            "${scalarMatch.group(1)}desktop_updater: $target${scalarMatch.group(3)}";
        changed = true;
        edits.add(
          MigrationEdit(
            kind: MigrationEditKind.pubspecConstraint,
            location: MigrationLocation(file: file, line: i + 1, column: 1),
            description:
                "Update desktop_updater dependency constraint to $target.",
          ),
        );
      } else if (current != idempotent) {
        findings.add(
          MigrationFinding(
            kind: MigrationFindingKind.sourceMajorMismatch,
            location: MigrationLocation(file: file, line: i + 1, column: 1),
            description:
                "desktop_updater constraint $current does not belong to the requested --from $fromMajor lane.",
            recommendation:
                "Run the migrator with the dependency's actual source major, or choose $target only after reviewing the breaking migration.",
          ),
        );
      }
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
              "Review this dependency manually and point it at desktop_updater ${fromMajor == 1 ? "^2.0.0" : "^3.0.0"} when ready.",
        ),
      );
    }
  }

  if (!changed) {
    return null;
  }
  return lines.join("\n");
}

int? _simpleConstraintMajor(String value) {
  final match =
      RegExp(r"^\^(\d+)\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$").firstMatch(value);
  return match == null ? null : int.tryParse(match.group(1)!);
}

void _addManualDependencyFinding(
  File file,
  int line,
  List<MigrationFinding> findings,
  String description,
  String recommendation,
) {
  findings.add(
    MigrationFinding(
      kind: MigrationFindingKind.manualReview,
      location: MigrationLocation(file: file, line: line, column: 1),
      description: description,
      recommendation: recommendation,
    ),
  );
}

Future<String?> _migrateDartFile(
  File file,
  List<MigrationEdit> edits,
  List<MigrationFinding> findings,
  int fromMajor,
) async {
  final content = await file.readAsString();
  var updated = content;
  var changed = false;

  final safeReplacements = fromMajor == 1
      ? <String, String>{
          "skipCheckVersion:": "skipInitialVersionCheck:",
          "getSkipCheckVersion": "skipInitialVersionCheck",
        }
      : const <String, String>{};

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

  _scanDartFindings(file, updated, findings, fromMajor);

  return changed ? updated : null;
}

void _scanDartFindings(
  File file,
  String content,
  List<MigrationFinding> findings,
  int fromMajor,
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
              "${entry.value} See the typed state migration section: ${migrationGuideFor(fromMajor)}",
        ),
      );
    }
  }

  const lowLevelApis = <String, String>{
    "prepareUpdateApp":
        "Prefer the current DesktopUpdaterController or UpdateClient flow.",
    "updateApp":
        "Prefer `dart run desktop_updater:package` for publishing and controller download/install APIs at runtime.",
    "versionCheck": "Prefer DesktopUpdaterController.checkVersion or "
        "DesktopUpdater().createZipFirstUpdateSession(...).checkForUpdate().",
  };
  for (final entry in lowLevelApis.entries) {
    final matches = RegExp("\\b${entry.key}\\b").allMatches(content);
    for (final match in matches) {
      findings.add(
        MigrationFinding(
          kind: MigrationFindingKind.lowLevelApi,
          location: _offsetLocation(file, content, match.start),
          description: "Low-level 1.x-style API `${entry.key}` is in use.",
          recommendation: "${entry.value} See ${migrationGuideFor(fromMajor)}",
        ),
      );
    }
  }

  if (fromMajor == 2) {
    const removed = <String, String>{
      "diagnosticsLogPath":
          "Diagnostics are app-owned in 3.0; remove the native diagnostics path.",
      "requireIndexSignature":
          "Pinned release keys are mandatory in 3.0; remove the optional flag.",
      "requireDescriptorSignature":
          "Pinned release keys are mandatory in 3.0; remove the optional flag.",
      "checkZipFirstUpdate":
          "Use one createZipFirstUpdateSession(...), then call checkForUpdate().",
      "downloadZipFirstUpdate":
          "Use the same session's downloadVerifyAndStage(checkResult: ...) flow.",
      "allowUnsignedMacOSUpdates":
          "Remove unsigned macOS updates; sign and notarize the production artifact.",
      "allowUnsignedUpdates":
          "Remove unsigned updates and configure trustedReleasePublicKeys.",
      "stagingPath":
          "Do not install a raw staged path; stage through the owner session and call controller.restartApp().",
      "installUpdate":
          "Remove raw staged installation and call controller.restartApp() only after a verified stage.",
      "installAndRelaunch":
          "Use explicit prepare, commit-after-exit, cancel, and query operations.",
      "scheduleInstallAndRelaunch":
          "Use explicit prepare, commit-after-exit, cancel, and query operations.",
      "RecoverPendingInstall":
          "Use the platform's explicit resolve-after-exit operation.",
      "allowedSignerThumbprints":
          "Signer policy is installer-owned; remove caller-provided signer lists.",
      "requiresElevation":
          "Elevation policy is installer-owned; remove caller-provided elevation controls.",
      "desktop_updater_schedule_install":
          "The native schedule ABI was removed; migrate to explicit transaction calls.",
      "desktop_updater_schedule_install_and_relaunch_v1":
          "The native schedule ABI was removed; migrate to ABI2 prepare/commit/query operations.",
      "desktop_updater_prepare_install_v2":
          "The ABI1 tombstone is not a 3.0 public API; migrate to the versioned ABI2 surface.",
    };
    for (final entry in removed.entries) {
      for (final match in RegExp("\\b${entry.key}\\b").allMatches(content)) {
        findings.add(
          MigrationFinding(
            kind: MigrationFindingKind.manualReview,
            location: _offsetLocation(file, content, match.start),
            description:
                "2.x API or native contract `${entry.key}` needs a 3.0 review.",
            recommendation: _migrationRecommendation(
              file: file,
              api: entry.key,
              text: entry.value,
            ),
          ),
        );
      }
    }
  }
}

Future<void> _scanTextFile(
  File file,
  List<MigrationFinding> findings,
  int fromMajor,
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
          description: "Old CLI command `$command` is still referenced.",
          recommendation:
              "Migrate publishing scripts to `dart run desktop_updater:package` and verify with `dart run desktop_updater:verify --release <release.json> --public-keys-env DESKTOP_UPDATER_RELEASE_PUBLIC_KEYS`. See ${migrationGuideFor(fromMajor)}.",
        ),
      );
    }
  }

  if (fromMajor != 2) {
    return;
  }

  const removedNativeApis = <String, String>{
    "checkZipFirstUpdate":
        "Use one createZipFirstUpdateSession(...), then checkForUpdate().",
    "downloadZipFirstUpdate":
        "Use the same session's downloadVerifyAndStage(checkResult: ...) flow.",
    "allowUnsignedMacOSUpdates":
        "Remove unsigned macOS updates; sign and notarize the production artifact.",
    "allowUnsignedUpdates":
        "Remove unsigned updates and configure trusted release public keys.",
    "diagnosticsLogPath":
        "Diagnostics are app-owned in 3.0; remove the native diagnostics path.",
    "stagingPath":
        "Do not install a raw staged path; use the verified controller handoff.",
    "installUpdate":
        "Remove raw staged installation and use controller.restartApp() after verification.",
    "scheduleInstallAndRelaunch":
        "Use explicit prepare/commit/query operations for the target platform.",
    "desktop_updater_schedule_install_and_relaunch_v1":
        "Use the Windows ABI2 prepare/commit/query operations.",
    "RecoverPendingInstall":
        "Use authenticated query followed by the platform-specific recovery operation.",
  };
  for (final entry in removedNativeApis.entries) {
    for (final match in RegExp("\\b${entry.key}\\b").allMatches(content)) {
      findings.add(
        MigrationFinding(
          kind: MigrationFindingKind.manualReview,
          location: _offsetLocation(file, content, match.start),
          description:
              "2.x API or native contract `${entry.key}` needs a 3.0 review.",
          recommendation: _migrationRecommendation(
            file: file,
            api: entry.key,
            text: entry.value,
          ),
        ),
      );
    }
  }
}

String _migrationRecommendation({
  required File file,
  required String api,
  required String text,
}) {
  final normalized = file.path.replaceAll("\\", "/").toLowerCase();
  final platformAdvice = api == "RecoverPendingInstall"
      ? normalized.contains("/windows/") || normalized.contains("windows-")
          ? "Windows recovery uses authenticated query and "
              "resolvePendingInstallTransactionAfterExit; do not call a mutating "
              "legacy recovery API."
          : normalized.contains("/macos/") || normalized.endsWith(".swift")
              ? "macOS recovery uses authenticated queryTransaction followed by "
                  "recoverPendingInstall; retain the marker until terminal proof."
              : normalized.contains("/linux/")
                  ? "Linux recovery uses authenticated query followed by the "
                      "platform recovery capability; retain the marker until terminal proof."
                  : "Use the platform recovery capability: Windows resolves "
                      "after exit; macOS/Linux query then recover."
      : null;
  return "${platformAdvice ?? text} See $desktopUpdaterMigrationGuideV2To3";
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
    ".swift",
    ".c",
    ".cc",
    ".cpp",
    ".h",
    ".cs",
  }.contains(extension);
}
