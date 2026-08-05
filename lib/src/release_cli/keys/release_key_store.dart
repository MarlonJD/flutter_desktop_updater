import "dart:async";
import "dart:convert";
import "dart:io";

import "package:desktop_updater/src/json/strict_json.dart";
import "package:path/path.dart" as path;

/// Machine-local storage for private Ed25519 seeds.
abstract interface class ReleaseKeySecretStore {
  String get description;

  Future<List<int>?> read({required String profileId, required String keyId});

  Future<void> write({
    required String profileId,
    required String keyId,
    required List<int> seed,
  });

  Future<void> delete({required String profileId, required String keyId});
}

/// A permission-conscious local-file store used on macOS and Linux.
///
/// The file is protected by the current account's filesystem permissions. It
/// is intentionally not described as Keychain or Secret Service storage.
final class LocalFileReleaseKeyStore implements ReleaseKeySecretStore {
  LocalFileReleaseKeyStore({Directory? rootDirectory})
      : rootDirectory = rootDirectory ?? _defaultPosixRoot();

  final Directory rootDirectory;

  @override
  String get description => "protected local file (0600)";

  @override
  Future<List<int>?> read({
    required String profileId,
    required String keyId,
  }) async {
    return _withLock(profileId, () async {
      final values = await _readValues(profileId);
      final encoded = values[keyId];
      if (encoded == null) return null;
      try {
        final seed = base64Decode(encoded);
        if (seed.length != 32) {
          throw const FormatException(
              "Stored release seed has invalid length.");
        }
        return seed;
      } on FormatException {
        throw StateError("Stored release key data is invalid.");
      }
    });
  }

  @override
  Future<void> write({
    required String profileId,
    required String keyId,
    required List<int> seed,
  }) async {
    if (seed.length != 32) {
      throw const FormatException(
          "Ed25519 private seeds must contain 32 bytes.");
    }
    final encoded = base64Encode(seed);
    await _withLock(profileId, () async {
      final values = await _readValues(profileId);
      final previous = values[keyId];
      if (previous != null && previous != encoded) {
        throw StateError("A different private key already exists.");
      }
      values[keyId] = encoded;
      await _writeValues(profileId, values);
    });
  }

  @override
  Future<void> delete({
    required String profileId,
    required String keyId,
  }) async {
    await _withLock(profileId, () async {
      final values = await _readValues(profileId);
      if (values.remove(keyId) != null) {
        if (values.isEmpty) {
          final file = _profileFile(profileId);
          if (await file.exists()) await file.delete();
        } else {
          await _writeValues(profileId, values);
        }
      }
    });
  }

  Future<Map<String, String>> _readValues(String profileId) async {
    final file = _profileFile(profileId);
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return <String, String>{};
    if (type != FileSystemEntityType.file) {
      throw StateError("Release key store path is not a regular file.");
    }
    if (Platform.isLinux || Platform.isMacOS) await _checkFilePermissions(file);
    final bytes = await file.readAsBytes();
    if (bytes.length > 256 * 1024) {
      throw StateError("Release key store file is too large.");
    }
    late final String source;
    try {
      source = utf8.decode(bytes);
    } on FormatException {
      throw StateError("Release key store is not valid UTF-8.");
    }
    final decoded = parseStrictJson(source);
    if (decoded is! Map<String, Object?> ||
        decoded.length != 2 ||
        decoded["schemaVersion"] != 1 ||
        decoded["keys"] is! Map<String, Object?>) {
      throw StateError("Release key store has an unsupported format.");
    }
    final rawKeys = decoded["keys"]! as Map<String, Object?>;
    final values = <String, String>{};
    for (final entry in rawKeys.entries) {
      if (!_safeKeyId.hasMatch(entry.key) || entry.value is! String) {
        throw StateError("Release key store contains invalid key data.");
      }
      values[entry.key] = entry.value! as String;
    }
    return values;
  }

  Future<void> _writeValues(
      String profileId, Map<String, String> values) async {
    await rootDirectory.create(recursive: true);
    if (Platform.isLinux || Platform.isMacOS) {
      await _chmod(rootDirectory, 0x1c0);
      await _checkDirectoryPermissions(rootDirectory);
    }
    final file = _profileFile(profileId);
    final existingType = await FileSystemEntity.type(
      file.path,
      followLinks: false,
    );
    if (existingType == FileSystemEntityType.link) {
      throw StateError("Release key store file must not be a symlink.");
    }
    final temporary = File(
      "${file.path}.tmp-${DateTime.now().microsecondsSinceEpoch}",
    );
    try {
      await temporary.writeAsString(
        "${const JsonEncoder.withIndent("  ").convert({
              "schemaVersion": 1,
              "keys": values,
            })}\n",
        flush: true,
      );
      if (Platform.isLinux || Platform.isMacOS) {
        await _chmod(temporary, 0x180);
        await _checkFilePermissions(temporary);
      }
      await temporary.rename(file.path);
      if (Platform.isLinux || Platform.isMacOS) {
        await _checkFilePermissions(file);
      }
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  File _profileFile(String profileId) {
    if (!_profileId.hasMatch(profileId)) {
      throw const FormatException("Invalid release key profile ID.");
    }
    return File(path.join(rootDirectory.path, "$profileId.json"));
  }

  Future<T> _withLock<T>(String profileId, Future<T> Function() action) async {
    await rootDirectory.create(recursive: true);
    if (Platform.isLinux || Platform.isMacOS) {
      await _chmod(rootDirectory, 0x1c0);
    }
    final lock = File(path.join(rootDirectory.path, "$profileId.lock"));
    final type = await FileSystemEntity.type(lock.path, followLinks: false);
    if (type == FileSystemEntityType.link) {
      throw StateError("Release key store lock must not be a symlink.");
    }
    final handle = await lock.open(mode: FileMode.append);
    try {
      if (Platform.isLinux || Platform.isMacOS) {
        await _chmod(lock, 0x180);
      }
      await handle.lock(FileLock.exclusive);
      return await action();
    } finally {
      try {
        await handle.unlock();
      } finally {
        await handle.close();
      }
    }
  }
}

/// Windows per-user DPAPI storage. It never falls back to plaintext files.
final class WindowsDpapiReleaseKeyStore implements ReleaseKeySecretStore {
  WindowsDpapiReleaseKeyStore({Directory? rootDirectory})
      : rootDirectory = rootDirectory ?? _defaultWindowsRoot();

  final Directory rootDirectory;

  @override
  String get description => "Windows DPAPI (CurrentUser)";

  @override
  Future<List<int>?> read({
    required String profileId,
    required String keyId,
  }) async {
    final values = await _readValues(profileId);
    final encoded = values[keyId];
    if (encoded == null) return null;
    final protectedBytes = _decodeBase64(encoded);
    final seed = await _runDpapi("unprotect", protectedBytes);
    if (seed.length != 32) {
      throw StateError("Windows DPAPI returned an invalid release seed.");
    }
    return seed;
  }

  @override
  Future<void> write({
    required String profileId,
    required String keyId,
    required List<int> seed,
  }) async {
    if (!Platform.isWindows) {
      throw UnsupportedError("Windows DPAPI is available only on Windows.");
    }
    if (seed.length != 32) {
      throw const FormatException(
          "Ed25519 private seeds must contain 32 bytes.");
    }
    final values = await _readValues(profileId);
    final protectedBytes = await _runDpapi("protect", seed);
    final encoded = base64Encode(protectedBytes);
    final previous = values[keyId];
    if (previous != null && previous != encoded) {
      throw StateError("A different private key already exists.");
    }
    values[keyId] = encoded;
    await _writeValues(profileId, values);
  }

  @override
  Future<void> delete({
    required String profileId,
    required String keyId,
  }) async {
    final values = await _readValues(profileId);
    if (values.remove(keyId) != null) await _writeValues(profileId, values);
  }

  Future<Map<String, String>> _readValues(String profileId) async {
    final file = _profileFile(profileId);
    if (!await file.exists()) return <String, String>{};
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw StateError("Windows DPAPI store path is not a regular file.");
    }
    final decoded = parseStrictJson(await file.readAsString());
    if (decoded is! Map<String, Object?> ||
        decoded.length != 2 ||
        decoded["schemaVersion"] != 1 ||
        decoded["keys"] is! Map<String, Object?>) {
      throw StateError("Windows DPAPI store has an unsupported format.");
    }
    final raw = decoded["keys"]! as Map<String, Object?>;
    final values = <String, String>{};
    for (final entry in raw.entries) {
      if (!_safeKeyId.hasMatch(entry.key) || entry.value is! String) {
        throw StateError("Windows DPAPI store contains invalid data.");
      }
      values[entry.key] = entry.value! as String;
    }
    return values;
  }

  Future<void> _writeValues(
      String profileId, Map<String, String> values) async {
    if (!Platform.isWindows) {
      throw UnsupportedError("Windows DPAPI is available only on Windows.");
    }
    await rootDirectory.create(recursive: true);
    final file = _profileFile(profileId);
    final temporary = File(
      "${file.path}.tmp-${DateTime.now().microsecondsSinceEpoch}",
    );
    try {
      await temporary.writeAsString(
        "${const JsonEncoder.withIndent("  ").convert({
              "schemaVersion": 1,
              "keys": values,
            })}\n",
        flush: true,
      );
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  File _profileFile(String profileId) {
    if (!_profileId.hasMatch(profileId)) {
      throw const FormatException("Invalid release key profile ID.");
    }
    return File(path.join(rootDirectory.path, "$profileId.json"));
  }

  Future<List<int>> _runDpapi(String operation, List<int> bytes) async {
    if (!Platform.isWindows) {
      throw UnsupportedError("Windows DPAPI is available only on Windows.");
    }
    final process = await Process.start(
      "powershell.exe",
      [
        "-NoLogo",
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy",
        "Bypass",
        "-EncodedCommand",
        _encodedPowerShellScript,
      ],
      environment: {
        ...Platform.environment,
        "DESKTOP_UPDATER_DPAPI_OPERATION": operation,
      },
    );
    process.stdin.write(base64Encode(bytes));
    await process.stdin.close();
    final stdout = await process.stdout.transform(utf8.decoder).join();
    final stderr = await process.stderr.transform(utf8.decoder).join();
    final exitCode = await process.exitCode;
    if (exitCode != 0) {
      // Do not include PowerShell output: it could contain sensitive data.
      throw StateError(
        "Windows DPAPI operation failed (exit code $exitCode): "
        "${stderr.trim().isEmpty ? "unknown error" : "operation rejected"}.",
      );
    }
    try {
      return _decodeBase64(stdout.trim());
    } on FormatException {
      throw StateError("Windows DPAPI returned invalid data.");
    }
  }
}

/// Selects the only supported storage backend for the current host.
ReleaseKeySecretStore defaultReleaseKeySecretStore() {
  if (Platform.isWindows) return WindowsDpapiReleaseKeyStore();
  return LocalFileReleaseKeyStore();
}

Directory _defaultPosixRoot() {
  final home = Platform.environment["HOME"];
  if (home == null || home.isEmpty) {
    throw StateError("HOME is required for local release key storage.");
  }
  if (Platform.isMacOS) {
    return Directory(
      path.join(home, "Library", "Application Support", "desktop_updater",
          "release-keys"),
    );
  }
  return Directory(
    path.join(
      Platform.environment["XDG_DATA_HOME"] ??
          path.join(home, ".local", "share"),
      "desktop_updater",
      "release-keys",
    ),
  );
}

Directory _defaultWindowsRoot() {
  final root =
      Platform.environment["LOCALAPPDATA"] ?? Platform.environment["APPDATA"];
  if (root == null || root.isEmpty) {
    throw StateError("LOCALAPPDATA is required for Windows key storage.");
  }
  return Directory(path.join(root, "desktop_updater", "release-keys"));
}

final _profileId = RegExp(r"^[0-9a-f]{32}$");
final _safeKeyId = RegExp(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$");

List<int> _decodeBase64(String value) {
  try {
    return base64Decode(value);
  } on FormatException {
    throw const FormatException("Release key store contains invalid base64.");
  }
}

Future<void> _chmod(FileSystemEntity entity, int mode) async {
  final result = await Process.run("/bin/chmod", [
    mode.toRadixString(8),
    entity.path,
  ]);
  if (result.exitCode != 0) {
    throw StateError("Unable to apply permissions to release key storage.");
  }
}

Future<void> _checkDirectoryPermissions(Directory directory) async {
  final mode = (await directory.stat()).mode & 0x1ff;
  if (mode != 0x1c0) {
    throw StateError("Release key storage directory permissions are unsafe.");
  }
}

Future<void> _checkFilePermissions(File file) async {
  final mode = (await file.stat()).mode & 0x1ff;
  if (mode & 0x1ff != 0x180) {
    throw StateError("Release key storage file permissions are unsafe.");
  }
}

const _dpapiScript = r'''
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security
$encoded = [Console]::In.ReadToEnd().Trim()
$inputBytes = [Convert]::FromBase64String($encoded)
if ($env:DESKTOP_UPDATER_DPAPI_OPERATION -eq 'protect') {
  $outputBytes = [System.Security.Cryptography.ProtectedData]::Protect(
    $inputBytes,
    $null,
    [System.Security.Cryptography.DataProtectionScope]::CurrentUser
  )
} elseif ($env:DESKTOP_UPDATER_DPAPI_OPERATION -eq 'unprotect') {
  $outputBytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
    $inputBytes,
    $null,
    [System.Security.Cryptography.DataProtectionScope]::CurrentUser
  )
} else {
  throw 'Unsupported DPAPI operation'
}
[Console]::Out.Write([Convert]::ToBase64String($outputBytes))
''';

final _encodedPowerShellScript = base64Encode(
  _dpapiScript.codeUnits
      .expand((unit) => <int>[unit & 0xff, unit >> 8])
      .toList(),
);
