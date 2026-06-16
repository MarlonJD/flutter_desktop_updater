// ignore_for_file: public_member_api_docs

import "dart:convert";
import "dart:io";

import "package:crypto/crypto.dart" as crypto;
import "package:desktop_updater/src/io/archive_path.dart";
import "package:path/path.dart" as path;

const releaseManifestFileName = "release-manifest.json";
const stagedReleaseManifestFileName = ".desktop_updater_release_manifest.json";

class ReleaseManifest {
  ReleaseManifest({
    required this.schemaVersion,
    required this.platform,
    required this.version,
    required this.shortVersion,
    required this.channel,
    required this.appName,
    required this.bundleIdentifier,
    required this.teamIdentifier,
    required this.entries,
    this.fullArchive,
  }) {
    _validate();
  }

  factory ReleaseManifest.fromJson(Map<String, dynamic> json) {
    return ReleaseManifest(
      schemaVersion: json["schemaVersion"] as int? ?? 0,
      platform: json["platform"] as String? ?? "",
      version: json["version"] as String? ?? "",
      shortVersion: json["shortVersion"] as int? ?? 0,
      channel: json["channel"] as String? ?? "stable",
      appName: json["appName"] as String? ?? "",
      bundleIdentifier: json["bundleIdentifier"] as String? ?? "",
      teamIdentifier: json["teamIdentifier"] as String? ?? "",
      fullArchive: json["fullArchive"] == null
          ? null
          : ReleaseFullArchive.fromJson(
              json["fullArchive"] as Map<String, dynamic>,
            ),
      entries: (json["entries"] as List<dynamic>? ?? const [])
          .map(
            (entry) => ReleaseManifestEntry.fromJson(
              entry as Map<String, dynamic>,
            ),
          )
          .toList(growable: false),
    );
  }

  final int schemaVersion;
  final String platform;
  final String version;
  final int shortVersion;
  final String channel;
  final String appName;
  final String bundleIdentifier;
  final String teamIdentifier;
  final ReleaseFullArchive? fullArchive;
  final List<ReleaseManifestEntry> entries;

  Map<String, dynamic> toJson() {
    return {
      "schemaVersion": schemaVersion,
      "platform": platform,
      "version": version,
      "shortVersion": shortVersion,
      "channel": channel,
      "appName": appName,
      "bundleIdentifier": bundleIdentifier,
      "teamIdentifier": teamIdentifier,
      if (fullArchive != null) "fullArchive": fullArchive!.toJson(),
      "entries": entries.map((entry) => entry.toJson()).toList(),
    };
  }

  ReleaseManifest copyWith({ReleaseFullArchive? fullArchive}) {
    return ReleaseManifest(
      schemaVersion: schemaVersion,
      platform: platform,
      version: version,
      shortVersion: shortVersion,
      channel: channel,
      appName: appName,
      bundleIdentifier: bundleIdentifier,
      teamIdentifier: teamIdentifier,
      fullArchive: fullArchive ?? this.fullArchive,
      entries: entries,
    );
  }

  void _validate() {
    if (schemaVersion != 2) {
      throw const FormatException(
        "Unsupported release manifest schema version.",
      );
    }
    if (platform != "macos") {
      throw FormatException("Unsupported release manifest platform: $platform");
    }
    if (!appName.endsWith(".app")) {
      throw const FormatException("macOS release appName must end with .app.");
    }
    if (bundleIdentifier.trim().isEmpty) {
      throw const FormatException("Missing bundleIdentifier in manifest.");
    }
    if (teamIdentifier.trim().isEmpty) {
      throw const FormatException("Missing teamIdentifier in manifest.");
    }
    if (entries.isEmpty) {
      throw const FormatException("Release manifest must contain entries.");
    }

    final seenPaths = <String>{};
    for (final entry in entries) {
      final normalizedPath = normalizeArchivePath(entry.path);
      if (normalizedPath != entry.path) {
        throw FormatException("Manifest path is not normalized: ${entry.path}");
      }
      if (!seenPaths.add(entry.path)) {
        throw FormatException("Duplicate manifest path: ${entry.path}");
      }
    }
  }
}

class ReleaseFullArchive {
  ReleaseFullArchive({
    required this.path,
    required this.sha256,
    required this.length,
  }) {
    normalizeArchivePath(path);
    _validateSha256(sha256);
    if (length < 0) {
      throw const FormatException("Archive length cannot be negative.");
    }
  }

  factory ReleaseFullArchive.fromJson(Map<String, dynamic> json) {
    return ReleaseFullArchive(
      path: json["path"] as String? ?? "",
      sha256: json["sha256"] as String? ?? "",
      length: json["length"] as int? ?? 0,
    );
  }

  final String path;
  final String sha256;
  final int length;

  Map<String, dynamic> toJson() {
    return {"path": path, "sha256": sha256, "length": length};
  }
}

class ReleaseManifestEntry {
  ReleaseManifestEntry.file({
    required this.path,
    required String this.sha256,
    required this.length,
    required String this.mode,
    required String this.payloadPath,
  })  : type = ReleaseManifestEntryType.file,
        symlinkTarget = null {
    _validate();
  }

  ReleaseManifestEntry.symlink({
    required this.path,
    required String this.symlinkTarget,
  })  : type = ReleaseManifestEntryType.symlink,
        sha256 = null,
        length = 0,
        mode = null,
        payloadPath = null {
    _validate();
  }

  factory ReleaseManifestEntry.fromJson(Map<String, dynamic> json) {
    final type = json["type"] as String? ?? "";
    if (type == "file") {
      return ReleaseManifestEntry.file(
        path: json["path"] as String? ?? "",
        sha256: json["sha256"] as String? ?? "",
        length: json["length"] as int? ?? 0,
        mode: json["mode"] as String? ?? "",
        payloadPath: json["payload"] as String? ?? "",
      );
    }
    if (type == "symlink") {
      return ReleaseManifestEntry.symlink(
        path: json["path"] as String? ?? "",
        symlinkTarget: json["target"] as String? ?? "",
      );
    }

    throw FormatException("Unsupported manifest entry type: $type");
  }

  final ReleaseManifestEntryType type;
  final String path;
  final String? sha256;
  final int length;
  final String? mode;
  final String? payloadPath;
  final String? symlinkTarget;

  Map<String, dynamic> toJson() {
    if (type == ReleaseManifestEntryType.file) {
      return {
        "type": "file",
        "path": path,
        "sha256": sha256,
        "length": length,
        "mode": mode,
        "payload": payloadPath,
      };
    }

    return {"type": "symlink", "path": path, "target": symlinkTarget};
  }

  String get comparisonKey {
    if (type == ReleaseManifestEntryType.file) {
      return "file:$sha256:$length:$mode:$payloadPath";
    }

    return "symlink:$symlinkTarget";
  }

  void _validate() {
    normalizeArchivePath(path);
    if (path.isEmpty) {
      throw const FormatException("Manifest entry path cannot be empty.");
    }

    if (type == ReleaseManifestEntryType.file) {
      _validateSha256(sha256 ?? "");
      if (length < 0) {
        throw FormatException("File length cannot be negative: $path");
      }
      if (!_modePattern.hasMatch(mode ?? "")) {
        throw FormatException("Invalid file mode for $path: $mode");
      }
      normalizeArchivePath(payloadPath ?? "");
      if ((payloadPath ?? "").isEmpty) {
        throw FormatException("Missing payload path for $path");
      }
      if (payloadPath != "payloads/$sha256.gz") {
        throw FormatException(
          "Payload path must be content-addressed for $path.",
        );
      }
      return;
    }

    if ((symlinkTarget ?? "").isEmpty) {
      throw FormatException("Missing symlink target for $path");
    }
    _validateSymlinkTargetSyntax(path: path, target: symlinkTarget!);
  }
}

enum ReleaseManifestEntryType { file, symlink }

class ReleaseManifestDiff {
  const ReleaseManifestDiff({
    required this.changedEntries,
    required this.removedPaths,
  });

  final List<ReleaseManifestEntry> changedEntries;
  final List<String> removedPaths;
}

Future<ReleaseManifest> readReleaseManifest(File file) async {
  return ReleaseManifest.fromJson(
    jsonDecode(await file.readAsString()) as Map<String, dynamic>,
  );
}

Future<void> writeReleaseManifest(File file, ReleaseManifest manifest) async {
  await file.parent.create(recursive: true);
  await file.writeAsString(
    const JsonEncoder.withIndent("  ").convert(manifest.toJson()),
  );
}

Future<String> sha256File(File file) async {
  final digest = await crypto.sha256.bind(file.openRead()).first;
  return digest.toString();
}

String modeString(FileStat stat) {
  return (stat.mode & 0x1ff).toRadixString(8).padLeft(3, "0");
}

Future<ReleaseManifest> generateMacOSAppManifest({
  required Directory appDirectory,
  required String version,
  required int shortVersion,
  required String channel,
  required String bundleIdentifier,
  required String teamIdentifier,
  Directory? payloadDirectory,
}) async {
  final entries = <ReleaseManifestEntry>[];

  await for (final entity in appDirectory.list(
    recursive: true,
    followLinks: false,
  )) {
    final relativePath = normalizeArchivePath(
      path.relative(entity.path, from: appDirectory.path),
    );
    if (_shouldSkipManifestPath(relativePath)) {
      continue;
    }

    if (entity is Link) {
      final target = await entity.target();
      validateSymlinkTarget(
        appRoot: appDirectory.path,
        linkRelativePath: relativePath,
        target: target,
      );
      entries.add(
        ReleaseManifestEntry.symlink(
          path: relativePath,
          symlinkTarget: target,
        ),
      );
    } else if (entity is File) {
      final sha256 = await sha256File(entity);
      final payloadPath = "payloads/$sha256.gz";
      if (payloadDirectory != null) {
        await _writeCompressedPayload(
          source: entity,
          destination: File(path.join(payloadDirectory.path, "$sha256.gz")),
        );
      }
      entries.add(
        ReleaseManifestEntry.file(
          path: relativePath,
          sha256: sha256,
          length: await entity.length(),
          mode: modeString(await entity.stat()),
          payloadPath: payloadPath,
        ),
      );
    }
  }

  entries.sort((a, b) => a.path.compareTo(b.path));
  return ReleaseManifest(
    schemaVersion: 2,
    platform: "macos",
    version: version,
    shortVersion: shortVersion,
    channel: channel,
    appName: path.basename(appDirectory.path),
    bundleIdentifier: bundleIdentifier,
    teamIdentifier: teamIdentifier,
    entries: entries,
  );
}

ReleaseManifestDiff diffReleaseManifests({
  required ReleaseManifest current,
  required ReleaseManifest target,
}) {
  final currentByPath = {
    for (final entry in current.entries) entry.path: entry,
  };
  final targetByPath = {for (final entry in target.entries) entry.path: entry};
  final changedEntries = <ReleaseManifestEntry>[];

  for (final targetEntry in target.entries) {
    final currentEntry = currentByPath[targetEntry.path];
    if (currentEntry == null ||
        currentEntry.type != targetEntry.type ||
        currentEntry.comparisonKey != targetEntry.comparisonKey) {
      changedEntries.add(targetEntry);
    }
  }

  final removedPaths = currentByPath.keys
      .where((filePath) => !targetByPath.containsKey(filePath))
      .toList(growable: false)
    ..sort();

  return ReleaseManifestDiff(
    changedEntries: changedEntries,
    removedPaths: removedPaths,
  );
}

Future<void> verifyStagedAppManifest({
  required Directory appDirectory,
  required ReleaseManifest manifest,
}) async {
  final expectedByPath = {
    for (final entry in manifest.entries) entry.path: entry,
  };
  final seenPaths = <String>{};

  await for (final entity in appDirectory.list(
    recursive: true,
    followLinks: false,
  )) {
    final relativePath = normalizeArchivePath(
      path.relative(entity.path, from: appDirectory.path),
    );
    if (_shouldSkipManifestPath(relativePath)) {
      continue;
    }
    if (entity is! File && entity is! Link) {
      continue;
    }

    final expected = expectedByPath[relativePath];
    if (expected == null) {
      throw FileSystemException(
        "Unexpected file in staged app",
        entity.path,
      );
    }
    seenPaths.add(relativePath);

    if (expected.type == ReleaseManifestEntryType.file) {
      if (entity is! File) {
        throw FileSystemException(
          "Manifest expected a regular file",
          entity.path,
        );
      }
      final actualHash = await sha256File(entity);
      if (actualHash != expected.sha256) {
        throw FileSystemException(
          "Staged file SHA-256 does not match manifest",
          entity.path,
        );
      }
      if (await entity.length() != expected.length) {
        throw FileSystemException(
          "Staged file length does not match manifest",
          entity.path,
        );
      }
      final actualMode = modeString(await entity.stat());
      if (actualMode != expected.mode) {
        throw FileSystemException(
          "Staged file mode does not match manifest",
          entity.path,
        );
      }
    } else {
      if (entity is! Link) {
        throw FileSystemException(
          "Manifest expected a symlink",
          entity.path,
        );
      }
      final actualTarget = await entity.target();
      if (actualTarget != expected.symlinkTarget) {
        throw FileSystemException(
          "Staged symlink target does not match manifest",
          entity.path,
        );
      }
      validateSymlinkTarget(
        appRoot: appDirectory.path,
        linkRelativePath: relativePath,
        target: actualTarget,
      );
    }
  }

  final missingPaths = expectedByPath.keys
      .where((filePath) => !seenPaths.contains(filePath))
      .toList(growable: false);
  if (missingPaths.isNotEmpty) {
    throw FileSystemException(
      "Staged app is missing manifest entries",
      missingPaths.join(", "),
    );
  }
}

void validateSymlinkTarget({
  required String appRoot,
  required String linkRelativePath,
  required String target,
}) {
  final normalizedLinkPath = normalizeArchivePath(linkRelativePath);
  _validateSymlinkTargetSyntax(path: normalizedLinkPath, target: target);

  final rootPath = path.normalize(path.absolute(appRoot));
  final linkDirectory = path.dirname(path.join(rootPath, normalizedLinkPath));
  final resolvedTarget = path.normalize(path.join(linkDirectory, target));

  if (!_isWithin(rootPath, resolvedTarget)) {
    throw FormatException(
      "Symlink target resolves outside staged app: $normalizedLinkPath",
    );
  }
}

void _validateSymlinkTargetSyntax({
  required String path,
  required String target,
}) {
  final normalizedTarget = target.replaceAll(r"\", "/");
  final targetSegments = normalizedTarget
      .split("/")
      .where((segment) => segment.isNotEmpty)
      .toList(growable: false);

  if (target.trim().isEmpty ||
      normalizedTarget.startsWith("/") ||
      RegExp(r"^[a-zA-Z]:").hasMatch(normalizedTarget) ||
      targetSegments.any((segment) => segment == "..")) {
    throw FormatException(
      "Unsafe symlink target for $path: $target",
    );
  }
}

bool _isWithin(String root, String child) {
  final relative = path.relative(child, from: root);
  return relative == "." ||
      (!relative.startsWith("..${path.separator}") && relative != "..");
}

Future<void> _writeCompressedPayload({
  required File source,
  required File destination,
}) async {
  if (await destination.exists()) {
    return;
  }

  await destination.parent.create(recursive: true);
  final encoded = gzip.encode(await source.readAsBytes());
  await destination.writeAsBytes(encoded, flush: true);
}

bool _shouldSkipManifestPath(String relativePath) {
  return relativePath == stagedReleaseManifestFileName ||
      relativePath == releaseManifestFileName;
}

void _validateSha256(String value) {
  if (!RegExp(r"^[a-f0-9]{64}$").hasMatch(value)) {
    throw FormatException("Invalid SHA-256 digest: $value");
  }
}

final _modePattern = RegExp(r"^[0-7]{3,4}$");
