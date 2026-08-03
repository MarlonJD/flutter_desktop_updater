import "dart:convert";
import "dart:io";

import "package:desktop_updater/src/release_cli/publish_manifest.dart";
import "package:desktop_updater/src/release_cli/release_publish_config.dart";
import "package:desktop_updater/src/release_cli/upload/upload_provider.dart";
import "package:desktop_updater/src/release_manifest.dart";
import "package:path/path.dart" as path;

/// Runs the shell process used by [CustomCommandUploadProvider].
typedef CustomCommandProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments, {
  Map<String, String>? environment,
});

/// Upload provider that delegates ordered publishing to a user command.
class CustomCommandUploadProvider implements OrderedUploadProvider {
  /// Creates a custom command upload provider.
  const CustomCommandUploadProvider({
    CustomCommandProcessRunner runProcess = defaultCustomCommandProcessRunner,
    bool? isWindows,
  })  : _runProcess = runProcess,
        _isWindows = isWindows;

  final CustomCommandProcessRunner _runProcess;
  final bool? _isWindows;

  @override
  Future<UploadResult> upload({
    required Directory localRoot,
    required PublishManifest manifest,
    required UploadConfig config,
    required StringSink output,
  }) async {
    await uploadVersionedFiles(
      localRoot: localRoot,
      manifest: manifest,
      config: config,
      output: output,
    );
    await uploadAppArchive(
      localRoot: localRoot,
      manifest: manifest,
      config: config,
      output: output,
      expectedRevision: const RemoteIndexRevision.absent(),
    );
    return const UploadResult(uploaded: true);
  }

  @override
  Future<void> uploadVersionedFiles({
    required Directory localRoot,
    required PublishManifest manifest,
    required UploadConfig config,
    required StringSink output,
  }) async {
    final customConfig = _customConfig(config);
    final tempDir =
        await Directory.systemTemp.createTemp("desktop_updater_upload_");
    try {
      final phaseRoot = Directory(path.join(tempDir.path, "versioned-root"));
      final phaseManifest = await _createPhaseRoot(
        sourceRoot: localRoot,
        phaseRoot: phaseRoot,
        manifest: manifest,
        phase: _UploadPhase.versioned,
      );
      await _runCustomCommand(
        command: customConfig.command,
        environment: _phaseEnvironment(
          phase: _UploadPhase.versioned,
          phaseRoot: phaseRoot,
          phaseManifest: phaseManifest,
          manifest: manifest,
          expectedRevision: null,
          receiptFile: null,
        ),
        output: output,
      );
    } finally {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    }
  }

  @override
  Future<IndexPublishReceipt> uploadAppArchive({
    required Directory localRoot,
    required PublishManifest manifest,
    required UploadConfig config,
    required StringSink output,
    required RemoteIndexRevision expectedRevision,
  }) async {
    final customConfig = _customConfig(config);
    final tempDir =
        await Directory.systemTemp.createTemp("desktop_updater_upload_");
    try {
      final phaseRoot = Directory(path.join(tempDir.path, "index-root"));
      final controlDir = Directory(path.join(tempDir.path, "control"));
      await controlDir.create(recursive: true);
      final receiptFile = File(path.join(controlDir.path, "receipt.json"));
      final phaseManifest = await _createPhaseRoot(
        sourceRoot: localRoot,
        phaseRoot: phaseRoot,
        manifest: manifest,
        phase: _UploadPhase.indexFile,
      );
      await _runCustomCommand(
        command: customConfig.command,
        environment: _phaseEnvironment(
          phase: _UploadPhase.indexFile,
          phaseRoot: phaseRoot,
          phaseManifest: phaseManifest,
          manifest: manifest,
          expectedRevision: expectedRevision,
          receiptFile: receiptFile,
        ),
        output: output,
      );
      final receipt = await readStrictIndexPublishReceipt(
        receiptFile,
        expectedControlDirectory: controlDir,
      );
      final publishedSha256 = await sha256File(
        File(path.join(localRoot.path, manifest.appArchive.path)),
      );
      _verifyReceipt(
        receipt: receipt,
        expectedRevision: expectedRevision,
        expectedPublishedSha256: publishedSha256,
      );
      return receipt;
    } finally {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    }
  }

  Future<void> _runCustomCommand({
    required String command,
    required Map<String, String> environment,
    required StringSink output,
  }) async {
    final result = await _runShellCommand(command, environment);
    if (result.stdout.toString().isNotEmpty) {
      output.write(result.stdout);
    }
    if (result.stderr.toString().isNotEmpty) {
      output.write(result.stderr);
    }
    if (result.exitCode != 0) {
      throw ProcessException(
        "customCommand",
        [command],
        "${result.stdout}\n${result.stderr}",
        result.exitCode,
      );
    }
  }

  Future<ProcessResult> _runShellCommand(
    String command,
    Map<String, String> environment,
  ) {
    if (_isWindows ?? Platform.isWindows) {
      return _runWindowsCommand(command, environment);
    }
    return _runProcess("/bin/sh", ["-c", command], environment: environment);
  }

  Future<ProcessResult> _runWindowsCommand(
    String command,
    Map<String, String> environment,
  ) async {
    final tempDir =
        await Directory.systemTemp.createTemp("desktop_updater_upload_cmd_");
    try {
      final script = File(path.join(tempDir.path, "upload.cmd"));
      await script.writeAsString("@echo off\r\n$command\r\n");
      return await _runProcess(
        "cmd",
        ["/d", "/e:on", "/v:off", "/c", script.path],
        environment: environment,
      );
    } finally {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    }
  }
}

Future<IndexPublishReceipt> readStrictIndexPublishReceipt(
  File file, {
  Directory? expectedControlDirectory,
}) async {
  final controlDirectory = expectedControlDirectory == null
      ? null
      : path.normalize(expectedControlDirectory.absolute.path);
  final normalizedPath = path.normalize(file.absolute.path);
  if (controlDirectory != null &&
      !path.equals(path.dirname(normalizedPath), controlDirectory)) {
    throw const FormatException(
      "Index publish receipt must be written inside the publisher control directory.",
    );
  }
  final type = await FileSystemEntity.type(file.path, followLinks: false);
  if (type != FileSystemEntityType.file) {
    throw const FormatException(
      "Index publish receipt must be a regular file.",
    );
  }
  final bytes = await file.readAsBytes();
  if (bytes.length > 16 * 1024) {
    throw const FormatException("Index publish receipt is larger than 16 KiB.");
  }
  if (bytes.length >= 3 &&
      bytes[0] == 0xef &&
      bytes[1] == 0xbb &&
      bytes[2] == 0xbf) {
    throw const FormatException(
        "Index publish receipt must not contain a BOM.");
  }
  late final String text;
  try {
    text = utf8.decode(bytes);
  } on FormatException {
    throw const FormatException(
      "Index publish receipt must be strict UTF-8 JSON.",
    );
  }
  final decoded = _StrictJsonParser(text).parse();
  if (decoded is! Map<String, Object?>) {
    throw const FormatException("Index publish receipt must be a JSON object.");
  }
  _expectKeys(
    decoded,
    const {
      "schemaVersion",
      "observedPriorRevision",
      "publishedSha256",
      "mechanism",
      "leaseEvidenceSha256",
    },
    "receipt",
  );
  if (decoded["schemaVersion"] != 1) {
    throw const FormatException(
        "Index publish receipt schemaVersion must be 1.");
  }
  final revisionJson = decoded["observedPriorRevision"];
  if (revisionJson is! Map<String, Object?>) {
    throw const FormatException(
      "observedPriorRevision must be a JSON object.",
    );
  }
  final revision = _readRemoteIndexRevision(revisionJson);
  final publishedSha256 = _requiredDigest(
    decoded["publishedSha256"],
    "publishedSha256",
  );
  final mechanismValue = decoded["mechanism"];
  if (mechanismValue is! String) {
    throw const FormatException("mechanism must be a string.");
  }
  final mechanism = switch (mechanismValue) {
    "conditionalWrite" => IndexPublishMechanism.conditionalWrite,
    "exclusiveLease" => IndexPublishMechanism.exclusiveLease,
    _ => throw const FormatException(
        "mechanism must be conditionalWrite or exclusiveLease.",
      ),
  };
  final leaseEvidenceValue = decoded["leaseEvidenceSha256"];
  final leaseEvidenceSha256 = switch (mechanism) {
    IndexPublishMechanism.conditionalWrite => leaseEvidenceValue == null
        ? null
        : throw const FormatException(
            "conditionalWrite receipts must not include lease evidence.",
          ),
    IndexPublishMechanism.exclusiveLease => _requiredDigest(
        leaseEvidenceValue,
        "leaseEvidenceSha256",
      ),
  };
  return IndexPublishReceipt(
    observedPriorRevision: revision,
    publishedSha256: publishedSha256,
    mechanism: mechanism,
    leaseEvidenceSha256: leaseEvidenceSha256,
  );
}

Future<File> _createPhaseRoot({
  required Directory sourceRoot,
  required Directory phaseRoot,
  required PublishManifest manifest,
  required _UploadPhase phase,
}) async {
  final files = switch (phase) {
    _UploadPhase.versioned => <String>[
        ".desktop_updater_publish.json",
        manifest.release.path,
        manifest.artifact.path,
      ],
    _UploadPhase.indexFile => <String>[manifest.appArchive.path],
  };
  for (final relativePath in files) {
    await _copyPhaseFile(
      sourceRoot: sourceRoot,
      phaseRoot: phaseRoot,
      relativePath: relativePath,
    );
  }
  final phaseManifestFile = File(
    path.join(phaseRoot.path, ".desktop_updater_publish.json"),
  );
  await phaseManifestFile.parent.create(recursive: true);
  await phaseManifestFile.writeAsString(
    "${const JsonEncoder.withIndent("  ").convert({
          ...manifest.toJson(),
          "localRoot": phaseRoot.path,
          "uploadPhase": _phaseName(phase),
          "allowedFiles": files,
        })}\n",
  );
  return phaseManifestFile;
}

Future<void> _copyPhaseFile({
  required Directory sourceRoot,
  required Directory phaseRoot,
  required String relativePath,
}) async {
  final normalizedRelativePath = path.normalize(relativePath);
  if (path.isAbsolute(normalizedRelativePath) ||
      normalizedRelativePath.startsWith("..${path.separator}") ||
      normalizedRelativePath == "..") {
    throw const FormatException("Publish manifest paths must stay relative.");
  }
  final source = File(path.join(sourceRoot.path, normalizedRelativePath));
  if (!await source.exists()) {
    throw FileSystemException("Publish payload file is missing", source.path);
  }
  final target = File(path.join(phaseRoot.path, normalizedRelativePath));
  await target.parent.create(recursive: true);
  await source.copy(target.path);
}

Map<String, String> _phaseEnvironment({
  required _UploadPhase phase,
  required Directory phaseRoot,
  required File phaseManifest,
  required PublishManifest manifest,
  required RemoteIndexRevision? expectedRevision,
  required File? receiptFile,
}) {
  final environment = {
    ...Platform.environment,
    "DESKTOP_UPDATER_UPLOAD_PHASE": _phaseName(phase),
    "DESKTOP_UPDATER_LOCAL_ROOT": phaseRoot.path,
    "DESKTOP_UPDATER_PUBLISH_MANIFEST": phaseManifest.path,
    "DESKTOP_UPDATER_BASE_URL": manifest.baseUrl.toString(),
    "DESKTOP_UPDATER_APP_ARCHIVE_URL": manifest.appArchive.url.toString(),
    "DESKTOP_UPDATER_RELEASE_URL": manifest.release.url.toString(),
    "DESKTOP_UPDATER_ARTIFACT_URL": manifest.artifact.url.toString(),
    "DESKTOP_UPDATER_ARTIFACT_KIND": manifest.artifact.kind,
    "DESKTOP_UPDATER_PLATFORM": manifest.release.platform,
    "DESKTOP_UPDATER_VERSION": manifest.release.version,
    "DESKTOP_UPDATER_CHANNEL": manifest.release.channel,
    "PUBLISH_MANIFEST": phaseManifest.path,
    "BASE_URL": manifest.baseUrl.toString(),
    "APP_ARCHIVE_URL": manifest.appArchive.url.toString(),
    "RELEASE_URL": manifest.release.url.toString(),
    "ARTIFACT_URL": manifest.artifact.url.toString(),
    "PLATFORM": manifest.release.platform,
    "VERSION": manifest.release.version,
    "CHANNEL": manifest.release.channel,
  };
  if (expectedRevision != null) {
    environment["DESKTOP_UPDATER_EXPECTED_REMOTE_INDEX_ABSENT"] =
        expectedRevision.absent ? "true" : "false";
    if (expectedRevision.sha256 != null) {
      environment["DESKTOP_UPDATER_EXPECTED_REMOTE_INDEX_SHA256"] =
          expectedRevision.sha256!;
    }
    if (expectedRevision.etag != null) {
      environment["DESKTOP_UPDATER_EXPECTED_REMOTE_INDEX_ETAG"] =
          expectedRevision.etag!;
    }
  }
  if (receiptFile != null) {
    environment["DESKTOP_UPDATER_INDEX_PUBLISH_RECEIPT"] = receiptFile.path;
  }
  return environment;
}

void _verifyReceipt({
  required IndexPublishReceipt receipt,
  required RemoteIndexRevision expectedRevision,
  required String expectedPublishedSha256,
}) {
  if (receipt.observedPriorRevision != expectedRevision) {
    throw const FormatException(
      "Index publish receipt observed a different prior revision.",
    );
  }
  if (receipt.publishedSha256 != expectedPublishedSha256) {
    throw const FormatException(
      "Index publish receipt published SHA-256 does not match app-archive.json.",
    );
  }
}

RemoteIndexRevision _readRemoteIndexRevision(Map<String, Object?> json) {
  _expectKeys(json, const {"absent", "sha256", "etag"}, "revision");
  final absent = json["absent"];
  if (absent is! bool) {
    throw const FormatException("observedPriorRevision.absent must be a bool.");
  }
  final sha256 = json["sha256"];
  final etag = json["etag"];
  if (etag != null && etag is! String) {
    throw const FormatException("observedPriorRevision.etag must be a string.");
  }
  if (absent) {
    if (sha256 != null || etag != null) {
      throw const FormatException(
        "absent revisions must not include sha256 or etag.",
      );
    }
    return const RemoteIndexRevision.absent();
  }
  return RemoteIndexRevision.present(
    sha256: _requiredDigest(sha256, "observedPriorRevision.sha256"),
    etag: etag as String?,
  );
}

String _requiredDigest(Object? value, String name) {
  if (value is! String || !RegExp(r"^[0-9a-f]{64}$").hasMatch(value)) {
    throw FormatException("$name must be a lowercase 64-character SHA-256.");
  }
  return value;
}

void _expectKeys(
  Map<String, Object?> value,
  Set<String> allowed,
  String name,
) {
  for (final key in value.keys) {
    if (!allowed.contains(key)) {
      throw FormatException("$name contains unknown key $key.");
    }
  }
  for (final key in allowed) {
    if (!value.containsKey(key)) {
      throw FormatException("$name is missing required key $key.");
    }
  }
}

CustomCommandUploadConfig _customConfig(UploadConfig config) {
  if (config is! CustomCommandUploadConfig) {
    throw const FormatException(
      "CustomCommandUploadProvider requires CustomCommandUploadConfig.",
    );
  }
  return config;
}

enum _UploadPhase { versioned, indexFile }

String _phaseName(_UploadPhase phase) {
  return switch (phase) {
    _UploadPhase.versioned => "versioned",
    _UploadPhase.indexFile => "index",
  };
}

class _StrictJsonParser {
  _StrictJsonParser(this._source);

  final String _source;
  var _offset = 0;

  Object? parse() {
    final value = _parseValue();
    _skipWhitespace();
    if (_offset != _source.length) {
      throw const FormatException("Unexpected trailing JSON content.");
    }
    return value;
  }

  Object? _parseValue() {
    _skipWhitespace();
    if (_offset >= _source.length) {
      throw const FormatException("Unexpected end of JSON.");
    }
    final char = _source[_offset];
    if (char == "{") {
      return _parseObject();
    }
    if (char == "[") {
      return _parseArray();
    }
    if (char == "\"") {
      return _parseString();
    }
    if (_matches("true")) {
      _offset += 4;
      return true;
    }
    if (_matches("false")) {
      _offset += 5;
      return false;
    }
    if (_matches("null")) {
      _offset += 4;
      return null;
    }
    if (RegExp(r"[-0-9]").hasMatch(char)) {
      return _parseNumber();
    }
    throw FormatException("Unexpected JSON character $char.");
  }

  Map<String, Object?> _parseObject() {
    _expect("{");
    final result = <String, Object?>{};
    _skipWhitespace();
    if (_tryConsume("}")) {
      return result;
    }
    while (true) {
      _skipWhitespace();
      if (_offset >= _source.length || _source[_offset] != "\"") {
        throw const FormatException("JSON object keys must be strings.");
      }
      final key = _parseString();
      if (result.containsKey(key)) {
        throw FormatException("Duplicate JSON key $key.");
      }
      _skipWhitespace();
      _expect(":");
      result[key] = _parseValue();
      _skipWhitespace();
      if (_tryConsume("}")) {
        return result;
      }
      _expect(",");
    }
  }

  List<Object?> _parseArray() {
    _expect("[");
    final result = <Object?>[];
    _skipWhitespace();
    if (_tryConsume("]")) {
      return result;
    }
    while (true) {
      result.add(_parseValue());
      _skipWhitespace();
      if (_tryConsume("]")) {
        return result;
      }
      _expect(",");
    }
  }

  String _parseString() {
    final start = _offset;
    _expect("\"");
    var escaped = false;
    while (_offset < _source.length) {
      final char = _source[_offset];
      if (!escaped && char == "\"") {
        _offset += 1;
        try {
          return jsonDecode(_source.substring(start, _offset)) as String;
        } on FormatException {
          throw const FormatException("Invalid JSON string.");
        }
      }
      if (!escaped && char == r"\") {
        escaped = true;
      } else {
        escaped = false;
      }
      _offset += 1;
    }
    throw const FormatException("Unterminated JSON string.");
  }

  num _parseNumber() {
    final start = _offset;
    while (_offset < _source.length &&
        RegExp(r"[-+0-9.eE]").hasMatch(_source[_offset])) {
      _offset += 1;
    }
    final value = num.tryParse(_source.substring(start, _offset));
    if (value == null) {
      throw const FormatException("Invalid JSON number.");
    }
    return value;
  }

  void _skipWhitespace() {
    while (_offset < _source.length &&
        const {" ", "\n", "\r", "\t"}.contains(_source[_offset])) {
      _offset += 1;
    }
  }

  bool _matches(String value) {
    return _source.startsWith(value, _offset);
  }

  bool _tryConsume(String value) {
    if (!_matches(value)) {
      return false;
    }
    _offset += value.length;
    return true;
  }

  void _expect(String value) {
    if (!_tryConsume(value)) {
      throw FormatException("Expected JSON token $value.");
    }
  }
}

/// Default process runner for custom command upload scripts.
Future<ProcessResult> defaultCustomCommandProcessRunner(
  String executable,
  List<String> arguments, {
  Map<String, String>? environment,
}) {
  return Process.run(
    executable,
    arguments,
    environment: environment,
  );
}
