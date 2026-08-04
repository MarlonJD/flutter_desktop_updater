import "dart:collection";
import "dart:convert";
import "dart:io";
import "dart:math";

import "package:crypto/crypto.dart";
import "package:path/path.dart" as path;

/// File written into every updater-owned staging directory.
const String stagedUpdateProvenanceFileName =
    ".desktop_updater_stage_provenance.json";

/// Prefix for nonce children owned by the updater.
const String desktopUpdaterStagingPrefix = "desktop_updater_stage_";

const int _stagedUpdateProvenanceSchemaVersion = 1;
final RegExp _noncePattern = RegExp(
  r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
);
final RegExp _sha256Pattern = RegExp(r"^[0-9a-f]{64}$");

/// One immutable filesystem entry recorded in stage provenance.
class StagedUpdateProvenanceEntry {
  /// Creates a validated inventory entry.
  const StagedUpdateProvenanceEntry({
    required this.path,
    required this.kind,
    required this.length,
    this.sha256,
    this.target,
  });

  /// Canonical forward-slash path relative to the stage root.
  final String path;

  /// `file`, `directory`, or `symlink`.
  final String kind;

  /// File length, or zero for directories and symbolic links.
  final int length;

  /// Lowercase SHA-256 for a regular file.
  final String? sha256;

  /// Canonical relative target for a symbolic link.
  final String? target;

  /// Canonical marker representation.
  Map<String, dynamic> toJson() => <String, dynamic>{
        "path": path,
        "kind": kind,
        "length": length,
        if (sha256 != null) "sha256": sha256,
        if (target != null) "target": target,
      };

  /// Parses and validates one marker inventory entry.
  static StagedUpdateProvenanceEntry fromJson(Object? value) {
    final json = _stringKeyedMap(value, "provenance entry");
    final entryPath = _requiredString(json, "path");
    _validateRelativePath(entryPath, field: "entry path");
    final kind = _requiredString(json, "kind");
    final length = json["length"];
    if (length is! int || length < 0) {
      throw const FormatException("Provenance entry length is invalid.");
    }
    final hash = json["sha256"];
    final target = json["target"];
    switch (kind) {
      case "file":
        if (hash is! String ||
            !_sha256Pattern.hasMatch(hash) ||
            target != null) {
          throw const FormatException("Provenance file entry is invalid.");
        }
      case "directory":
        if (length != 0 || hash != null || target != null) {
          throw const FormatException("Provenance directory entry is invalid.");
        }
      case "symlink":
        if (length != 0 || hash != null || target is! String) {
          throw const FormatException("Provenance symlink entry is invalid.");
        }
        _validateRelativePath(target, field: "symlink target");
      default:
        throw FormatException("Unsupported provenance entry kind: $kind");
    }
    return StagedUpdateProvenanceEntry(
      path: entryPath,
      kind: kind,
      length: length,
      sha256: hash as String?,
      target: target as String?,
    );
  }
}

/// Canonical immutable description of a verified staging tree.
class StagedUpdateProvenance {
  /// Creates stage provenance.
  const StagedUpdateProvenance({
    required this.nonce,
    required this.packageId,
    required this.descriptorSha256,
    required this.artifactSha256,
    required this.entries,
  });

  /// Lowercase RFC 4122 version-4 nonce used in the owned child name.
  final String nonce;

  /// Verified application package identity.
  final String packageId;

  /// SHA-256 of the verified normalized descriptor.
  final String descriptorSha256;

  /// SHA-256 of the verified downloaded artifact.
  final String artifactSha256;

  /// Complete marker-excluding filesystem inventory.
  final List<StagedUpdateProvenanceEntry> entries;

  /// Canonical JSON bytes represented as a string without trailing whitespace.
  String get canonicalJson => _canonicalJson(<String, dynamic>{
        "schemaVersion": _stagedUpdateProvenanceSchemaVersion,
        "nonce": nonce,
        "packageId": packageId,
        "descriptorSha256": descriptorSha256,
        "artifactSha256": artifactSha256,
        "entries": entries.map((entry) => entry.toJson()).toList(),
      });

  /// Parses and validates a complete marker.
  static StagedUpdateProvenance fromJson(Object? value) {
    final json = _stringKeyedMap(value, "stage provenance");
    if (json["schemaVersion"] != _stagedUpdateProvenanceSchemaVersion) {
      throw const FormatException("Unsupported stage provenance schema.");
    }
    final nonce = _requiredString(json, "nonce");
    final packageId = _requiredString(json, "packageId");
    final descriptorSha256 = _requiredString(json, "descriptorSha256");
    final artifactSha256 = _requiredString(json, "artifactSha256");
    if (!_noncePattern.hasMatch(nonce) || packageId.trim().isEmpty) {
      throw const FormatException("Stage provenance identity is invalid.");
    }
    if (!_sha256Pattern.hasMatch(descriptorSha256) ||
        !_sha256Pattern.hasMatch(artifactSha256)) {
      throw const FormatException("Stage provenance SHA-256 is invalid.");
    }
    final rawEntries = json["entries"];
    if (rawEntries is! List) {
      throw const FormatException("Stage provenance entries are invalid.");
    }
    final entries = rawEntries
        .map(StagedUpdateProvenanceEntry.fromJson)
        .toList(growable: false);
    final paths = <String>{};
    for (var index = 0; index < entries.length; index += 1) {
      final entry = entries[index];
      if (!paths.add(entry.path)) {
        throw FormatException("Duplicate provenance path: ${entry.path}");
      }
      if (index > 0 && _compareUtf8(entries[index - 1].path, entry.path) >= 0) {
        throw const FormatException("Stage provenance entries are not sorted.");
      }
    }
    return StagedUpdateProvenance(
      nonce: nonce,
      packageId: packageId,
      descriptorSha256: descriptorSha256,
      artifactSha256: artifactSha256,
      entries: List.unmodifiable(entries),
    );
  }
}

/// Provenance plus the digest retained in verified client state.
class StagedUpdateProvenanceState {
  /// Creates immutable stage state.
  const StagedUpdateProvenanceState({
    required this.provenance,
    required this.markerSha256,
  });

  /// Parsed canonical provenance.
  final StagedUpdateProvenance provenance;

  /// SHA-256 of the exact canonical marker bytes.
  final String markerSha256;
}

/// Returns SHA-256 of recursively key-sorted compact JSON.
String canonicalJsonSha256(Object? value) =>
    sha256.convert(utf8.encode(_canonicalJson(value))).toString();

/// Exclusively creates `desktop_updater_stage_<nonce>` below [parent].
Future<Directory> createOwnedStagingDirectory({
  required Directory parent,
  String? nonce,
}) async {
  final canonicalParent = await _canonicalRealDirectory(
    parent,
    field: "staging parent",
  );
  if (path.dirname(canonicalParent) == canonicalParent) {
    throw FileSystemException(
      "Filesystem roots cannot be staging parents.",
      parent.path,
    );
  }
  final ownedNonce = nonce ?? _createNonce();
  if (!_noncePattern.hasMatch(ownedNonce)) {
    throw FormatException("Invalid owned staging nonce: $ownedNonce");
  }
  final childPath = path.join(
    canonicalParent,
    "$desktopUpdaterStagingPrefix$ownedNonce",
  );
  if (!_isDirectChild(parent: canonicalParent, child: childPath)) {
    throw FileSystemException(
      "Owned staging child escapes its canonical parent.",
      childPath,
    );
  }
  if (await FileSystemEntity.type(childPath, followLinks: false) !=
      FileSystemEntityType.notFound) {
    throw FileSystemException("Owned staging child already exists.", childPath);
  }
  final result = Platform.isWindows
      ? await Process.run("cmd.exe", ["/d", "/c", "mkdir", childPath])
      : await Process.run("/bin/mkdir", ["--", childPath]);
  if (result.exitCode != 0) {
    throw FileSystemException(
      "Unable to exclusively create owned staging child.",
      childPath,
    );
  }
  return Directory(childPath);
}

/// Writes the canonical marker after inventorying the complete stage tree.
Future<StagedUpdateProvenanceState> writeStagedUpdateProvenance({
  required Directory stageRoot,
  required String nonce,
  required String packageId,
  required String descriptorSha256,
  required String artifactSha256,
}) async {
  final canonicalRoot = await _canonicalRealDirectory(
    stageRoot,
    field: "stage root",
  );
  _validateOwnedStageName(canonicalRoot, nonce);
  if (packageId.trim().isEmpty ||
      !_sha256Pattern.hasMatch(descriptorSha256) ||
      !_sha256Pattern.hasMatch(artifactSha256)) {
    throw const FormatException("Stage provenance metadata is invalid.");
  }
  final marker = File(path.join(canonicalRoot, stagedUpdateProvenanceFileName));
  if (await FileSystemEntity.type(marker.path, followLinks: false) !=
      FileSystemEntityType.notFound) {
    throw FileSystemException(
        "Stage provenance marker already exists.", marker.path);
  }
  final provenance = StagedUpdateProvenance(
    nonce: nonce,
    packageId: packageId,
    descriptorSha256: descriptorSha256,
    artifactSha256: artifactSha256,
    entries: await _inventory(Directory(canonicalRoot)),
  );
  final bytes = utf8.encode(provenance.canonicalJson);
  await marker.writeAsBytes(bytes, flush: true);
  return StagedUpdateProvenanceState(
    provenance: provenance,
    markerSha256: sha256.convert(bytes).toString(),
  );
}

/// Reads and canonicalizes a marker without trusting its inventory yet.
Future<StagedUpdateProvenanceState> readStagedUpdateProvenance({
  required Directory stageRoot,
}) async {
  final canonicalRoot = await _canonicalRealDirectory(
    stageRoot,
    field: "stage root",
  );
  final marker = File(path.join(canonicalRoot, stagedUpdateProvenanceFileName));
  final type = await FileSystemEntity.type(marker.path, followLinks: false);
  if (type != FileSystemEntityType.file) {
    throw FormatException("Stage provenance marker is missing or not a file.");
  }
  final bytes = await marker.readAsBytes();
  final value = jsonDecode(utf8.decode(bytes, allowMalformed: false));
  final provenance = StagedUpdateProvenance.fromJson(value);
  if (!const _ListEquality<int>().equals(
    bytes,
    utf8.encode(provenance.canonicalJson),
  )) {
    throw const FormatException("Stage provenance marker is not canonical.");
  }
  _validateOwnedStageName(canonicalRoot, provenance.nonce);
  return StagedUpdateProvenanceState(
    provenance: provenance,
    markerSha256: sha256.convert(bytes).toString(),
  );
}

/// Verifies the client-state marker digest and every staged filesystem entry.
Future<StagedUpdateProvenance> verifyStagedUpdateProvenance({
  required Directory stageRoot,
  required String expectedMarkerSha256,
}) async {
  if (!_sha256Pattern.hasMatch(expectedMarkerSha256)) {
    throw const FormatException("Expected provenance SHA-256 is invalid.");
  }
  final state = await readStagedUpdateProvenance(stageRoot: stageRoot);
  if (state.markerSha256 != expectedMarkerSha256) {
    throw const FormatException("Stage provenance marker digest changed.");
  }
  final actual = await _inventory(stageRoot);
  if (_canonicalJson(actual.map((entry) => entry.toJson()).toList()) !=
      _canonicalJson(
        state.provenance.entries.map((entry) => entry.toJson()).toList(),
      )) {
    throw const FormatException("Staged update inventory changed.");
  }
  return state.provenance;
}

/// Recursively deletes only a direct, marker-bound owned nonce child.
Future<void> deleteOwnedStagingDirectory({
  required Directory parent,
  required Directory stageRoot,
  required String nonce,
}) async {
  if (!_noncePattern.hasMatch(nonce)) {
    throw const FormatException("Owned staging cleanup nonce is invalid.");
  }
  final canonicalParent = await _canonicalRealDirectory(
    parent,
    field: "staging parent",
  );
  final canonicalRoot = await _canonicalRealDirectory(
    stageRoot,
    field: "stage root",
  );
  if (!_isDirectChild(parent: canonicalParent, child: canonicalRoot)) {
    throw const FormatException("Owned staging cleanup path escapes parent.");
  }
  _validateOwnedStageName(canonicalRoot, nonce);
  final state = await readStagedUpdateProvenance(stageRoot: stageRoot);
  if (state.provenance.nonce != nonce) {
    throw const FormatException("Owned staging cleanup nonce does not match.");
  }
  await verifyStagedUpdateProvenance(
    stageRoot: stageRoot,
    expectedMarkerSha256: state.markerSha256,
  );
  await stageRoot.delete(recursive: true);
}

Future<List<StagedUpdateProvenanceEntry>> _inventory(Directory root) async {
  final canonicalRoot =
      await _canonicalRealDirectory(root, field: "stage root");
  final entries = <StagedUpdateProvenanceEntry>[];
  await for (final entity in Directory(canonicalRoot).list(
    recursive: true,
    followLinks: false,
  )) {
    final relative = path
        .relative(entity.path, from: canonicalRoot)
        .replaceAll(path.separator, "/");
    _validateRelativePath(relative, field: "inventory path");
    if (relative == stagedUpdateProvenanceFileName) continue;
    final type = await FileSystemEntity.type(entity.path, followLinks: false);
    switch (type) {
      case FileSystemEntityType.file:
        final file = File(entity.path);
        entries.add(StagedUpdateProvenanceEntry(
          path: relative,
          kind: "file",
          length: await file.length(),
          sha256: (await sha256.bind(file.openRead()).first).toString(),
        ));
      case FileSystemEntityType.directory:
        entries.add(StagedUpdateProvenanceEntry(
          path: relative,
          kind: "directory",
          length: 0,
        ));
      case FileSystemEntityType.link:
        final target = (await Link(entity.path).target()).replaceAll("\\", "/");
        _validateRelativePath(target, field: "symlink target");
        final resolved = path.normalize(
          path.join(path.dirname(entity.path), target),
        );
        if (!_isWithin(parent: canonicalRoot, child: resolved)) {
          throw FormatException("Symlink target escapes stage: $relative");
        }
        entries.add(StagedUpdateProvenanceEntry(
          path: relative,
          kind: "symlink",
          length: 0,
          target: target,
        ));
      default:
        throw FileSystemException(
            "Unsupported staged filesystem entry.", entity.path);
    }
  }
  entries.sort((left, right) => _compareUtf8(left.path, right.path));
  return List.unmodifiable(entries);
}

Future<String> _canonicalRealDirectory(
  Directory directory, {
  required String field,
}) async {
  final type = await FileSystemEntity.type(directory.path, followLinks: false);
  if (type != FileSystemEntityType.directory) {
    throw FileSystemException(
        "$field must be a real directory.", directory.path);
  }
  final canonical = path.normalize(await directory.resolveSymbolicLinks());
  return canonical;
}

void _validateOwnedStageName(String stageRoot, String nonce) {
  if (!_noncePattern.hasMatch(nonce) ||
      path.basename(stageRoot) != "$desktopUpdaterStagingPrefix$nonce") {
    throw const FormatException("Stage root is not bound to its marker nonce.");
  }
}

void _validateRelativePath(String value, {required String field}) {
  if (value.isEmpty ||
      value.startsWith("/") ||
      value.endsWith("/") ||
      value.contains("\\") ||
      RegExp(r"^[A-Za-z]:").hasMatch(value)) {
    throw FormatException("Invalid $field: $value");
  }
  final segments = value.split("/");
  if (segments
      .any((segment) => segment.isEmpty || segment == "." || segment == "..")) {
    throw FormatException("Invalid $field: $value");
  }
}

bool _isDirectChild({required String parent, required String child}) {
  return path.dirname(child) == parent && child != parent;
}

bool _isWithin({required String parent, required String child}) {
  return child == parent || path.isWithin(parent, child);
}

String _createNonce() {
  final bytes = List<int>.generate(16, (_) => Random.secure().nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex =
      bytes.map((byte) => byte.toRadixString(16).padLeft(2, "0")).join();
  return "${hex.substring(0, 8)}-${hex.substring(8, 12)}-"
      "${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}";
}

String _canonicalJson(Object? value) => jsonEncode(_sortedJson(value));

Object? _sortedJson(Object? value) {
  if (value is Map) {
    return SplayTreeMap<String, Object?>()
      ..addEntries(value.entries.map(
        (entry) => MapEntry(entry.key as String, _sortedJson(entry.value)),
      ));
  }
  if (value is List) return value.map(_sortedJson).toList();
  return value;
}

Map<String, dynamic> _stringKeyedMap(Object? value, String field) {
  if (value is! Map) throw FormatException("$field must be an object.");
  return value.map((key, value) {
    if (key is! String) throw FormatException("$field keys must be strings.");
    return MapEntry(key, value);
  });
}

String _requiredString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.isEmpty) {
    throw FormatException("Stage provenance $key is invalid.");
  }
  return value;
}

int _compareUtf8(String left, String right) {
  final leftBytes = utf8.encode(left);
  final rightBytes = utf8.encode(right);
  final common = min(leftBytes.length, rightBytes.length);
  for (var index = 0; index < common; index += 1) {
    final comparison = leftBytes[index].compareTo(rightBytes[index]);
    if (comparison != 0) return comparison;
  }
  return leftBytes.length.compareTo(rightBytes.length);
}

class _ListEquality<T> {
  const _ListEquality();

  bool equals(List<T> left, List<T> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index += 1) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }
}
