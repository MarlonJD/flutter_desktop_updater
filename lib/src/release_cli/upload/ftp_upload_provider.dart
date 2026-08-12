import "dart:convert";
import "dart:io";

import "package:crypto/crypto.dart";
import "package:desktop_updater/src/release_cli/publish_manifest.dart";
import "package:desktop_updater/src/release_cli/release_publish_config.dart";
import "package:desktop_updater/src/release_cli/upload/upload_provider.dart";
import "package:path/path.dart" as path;

/// Writes release files to an FTP-backed update host.
abstract interface class FtpRemoteFileClient {
  /// Writes one non-index release file to [remotePath].
  Future<void> writeFile({
    required File file,
    required String remotePath,
    required FtpUploadConfig config,
  });
}

/// Performs the FTP operations needed by [CurlFtpRemoteFileClient].
///
/// This is the internal seam for testing the lease protocol without making
/// network calls. The default implementation delegates to the system curl
/// executable.
abstract interface class FtpRemoteOperations {
  /// Uploads [file] to [remotePath].
  Future<void> upload(
    File file,
    String remotePath,
    FtpUploadConfig config,
  );

  /// Reads [remotePath], or returns null when the remote file is absent.
  Future<List<int>?> read(
    String remotePath,
    FtpUploadConfig config,
  );

  /// Atomically claims [remotePath] as an exclusive lease directory.
  Future<void> makeDirectory(
    String remotePath,
    FtpUploadConfig config,
  );

  /// Releases a previously claimed lease directory.
  Future<void> removeDirectory(
    String remotePath,
    FtpUploadConfig config,
  );

  /// Removes a temporary remote file.
  Future<void> removeFile(
    String remotePath,
    FtpUploadConfig config,
  );

  /// Renames [from] to [to] on the FTP host.
  Future<void> rename(
    String from,
    String to,
    FtpUploadConfig config,
  );
}

/// Adds conditional index publication to [FtpRemoteFileClient].
abstract interface class ExclusiveLeaseFtpRemoteFileClient
    implements FtpRemoteFileClient {
  /// Publishes [file] after proving [expectedRevision] is still current.
  Future<IndexPublishReceipt> writeIndexFileWithLease({
    required File file,
    required String remotePath,
    required FtpUploadConfig config,
    required RemoteIndexRevision expectedRevision,
  });
}

/// Records one versioned FTP write for provider tests and diagnostics.
class FtpRemoteWrite {
  /// Creates a write record.
  const FtpRemoteWrite({
    required this.file,
    required this.remotePath,
  });

  /// The local file that was written.
  final File file;

  /// The remote path that received the file.
  final String remotePath;
}

/// Uploads versioned files before publishing the signed index over FTP.
class FtpUploadProvider implements OrderedUploadProvider {
  /// Creates an ordered FTP upload provider.
  const FtpUploadProvider({this.client = const CurlFtpRemoteFileClient()});

  /// The adapter used to write files and publish the index.
  final FtpRemoteFileClient client;

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
    final ftpConfig = _ftpConfig(config);
    output.writeln("FTP is insecure. Prefer SFTP or S3-compatible upload.");
    for (final file in _versionedUploadFiles(localRoot, manifest)) {
      await client.writeFile(
        file: file.file,
        remotePath: _remotePath(ftpConfig.remotePath, file.relativePath),
        config: ftpConfig,
      );
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
    final leaseClient = client;
    if (leaseClient is! ExclusiveLeaseFtpRemoteFileClient) {
      throw const FormatException(
        "FTP upload requires a conditional index write or tested exclusive "
        "publication lease before publishing app-archive.json.",
      );
    }
    final ftpConfig = _ftpConfig(config);
    final receipt = await leaseClient.writeIndexFileWithLease(
      file: File(path.join(localRoot.path, manifest.appArchive.path)),
      remotePath: _remotePath(ftpConfig.remotePath, manifest.appArchive.path),
      config: ftpConfig,
      expectedRevision: expectedRevision,
    );
    await verifyOrderedIndexPublishReceipt(
      localRoot: localRoot,
      manifest: manifest,
      expectedRevision: expectedRevision,
      receipt: receipt,
    );
    return receipt;
  }
}

/// Implements ordered FTP publication using curl and an exclusive lease.
class CurlFtpRemoteFileClient implements ExclusiveLeaseFtpRemoteFileClient {
  /// Creates a curl-backed FTP client.
  const CurlFtpRemoteFileClient({
    this.operations = const CurlFtpRemoteOperations(),
  });

  /// The external FTP operations adapter.
  final FtpRemoteOperations operations;

  @override
  Future<void> writeFile({
    required File file,
    required String remotePath,
    required FtpUploadConfig config,
  }) async {
    await operations.upload(file, remotePath, config);
  }

  @override
  Future<IndexPublishReceipt> writeIndexFileWithLease({
    required File file,
    required String remotePath,
    required FtpUploadConfig config,
    required RemoteIndexRevision expectedRevision,
  }) async {
    final leasePath = _leasePath(remotePath);
    final artifactName = path.posix.basename(remotePath);
    final leaseToken = DateTime.now().microsecondsSinceEpoch.toString();
    final temporaryPath = path.posix.join(
      leasePath,
      "$artifactName.$leaseToken.tmp",
    );
    final localSha256 = sha256.convert(await file.readAsBytes()).toString();

    await operations.makeDirectory(leasePath, config);
    var temporaryFileExists = false;
    var publicationSucceeded = false;
    try {
      _assertExpectedRevision(
        remotePath: remotePath,
        expectedRevision: expectedRevision,
        actualBytes: await operations.read(remotePath, config),
      );

      // An FTP server may leave a partial file behind even when the upload
      // command reports an error. Mark it for cleanup before starting the
      // transfer so a failed publication cannot strand a lease artifact.
      temporaryFileExists = true;
      await operations.upload(file, temporaryPath, config);

      _assertExpectedRevision(
        remotePath: remotePath,
        expectedRevision: expectedRevision,
        actualBytes: await operations.read(remotePath, config),
      );
      await operations.rename(temporaryPath, remotePath, config);
      temporaryFileExists = false;

      final publishedBytes = await operations.read(remotePath, config);
      final publishedSha256 = publishedBytes == null
          ? null
          : sha256.convert(publishedBytes).toString();
      if (publishedSha256 != localSha256) {
        throw StateError(
          "FTP index publish digest mismatch for $remotePath: "
          "$publishedSha256 != $localSha256.",
        );
      }

      final receipt = IndexPublishReceipt(
        observedPriorRevision: expectedRevision,
        publishedSha256: localSha256,
        mechanism: IndexPublishMechanism.exclusiveLease,
        leaseEvidenceSha256:
            sha256.convert(utf8.encode("$leasePath|$leaseToken")).toString(),
      );
      publicationSucceeded = true;
      return receipt;
    } finally {
      if (temporaryFileExists) {
        await _bestEffort(() => operations.removeFile(temporaryPath, config));
      }
      if (publicationSucceeded) {
        await _releasePublishedLease(
          operations: operations,
          leasePath: leasePath,
          config: config,
        );
      } else {
        await _bestEffort(() => operations.removeDirectory(leasePath, config));
      }
    }
  }
}

/// Implements [FtpRemoteOperations] with the system curl executable.
class CurlFtpRemoteOperations implements FtpRemoteOperations {
  /// Creates a system-curl FTP operations adapter.
  const CurlFtpRemoteOperations();

  @override
  Future<void> upload(
    File file,
    String remotePath,
    FtpUploadConfig config,
  ) async {
    await _runCurl(
      config,
      [
        'url = "${_escapeCurlConfig(_remoteUri(config, remotePath).toString())}"',
        'upload-file = "${_escapeCurlConfig(file.path)}"',
        "ftp-create-dirs",
      ],
    );
  }

  @override
  Future<List<int>?> read(
    String remotePath,
    FtpUploadConfig config,
  ) async {
    final tempDir =
        await Directory.systemTemp.createTemp("desktop_updater_ftp_read_");
    final outputFile = File(path.join(tempDir.path, "remote-file"));
    try {
      final result = await _runCurl(
        config,
        [
          'url = "${_escapeCurlConfig(_remoteUri(config, remotePath).toString())}"',
          'output = "${_escapeCurlConfig(outputFile.path)}"',
          "fail",
        ],
        tempDir: tempDir,
      );
      if (result.exitCode != 0) {
        if (_isRemoteNotFound(result)) return null;
        _throwCurlError(result);
      }
      return await outputFile.readAsBytes();
    } finally {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    }
  }

  @override
  Future<void> makeDirectory(
    String remotePath,
    FtpUploadConfig config,
  ) async {
    await _runFtpQuote(config, "MKD ${_ftpQuotePath(remotePath)}");
  }

  @override
  Future<void> removeDirectory(
    String remotePath,
    FtpUploadConfig config,
  ) async {
    await _runFtpQuote(config, "RMD ${_ftpQuotePath(remotePath)}");
  }

  @override
  Future<void> removeFile(
    String remotePath,
    FtpUploadConfig config,
  ) async {
    await _runFtpQuote(config, "DELE ${_ftpQuotePath(remotePath)}");
  }

  @override
  Future<void> rename(
    String from,
    String to,
    FtpUploadConfig config,
  ) async {
    await _runFtpQuotes(config, [
      "RNFR ${_ftpQuotePath(from)}",
      "RNTO ${_ftpQuotePath(to)}",
    ]);
  }

  Future<ProcessResult> _runFtpQuote(
    FtpUploadConfig config,
    String command,
  ) {
    return _runFtpQuotes(config, [command]);
  }

  Future<ProcessResult> _runFtpQuotes(
    FtpUploadConfig config,
    List<String> commands,
  ) {
    return _runCurl(
      config,
      [
        'url = "${_escapeCurlConfig(_remoteUri(config, "/").toString())}"',
        for (final command in commands)
          'quote = "${_escapeCurlConfig(command)}"',
      ],
    );
  }

  Future<ProcessResult> _runCurl(
    FtpUploadConfig config,
    List<String> directives, {
    Directory? tempDir,
  }) async {
    final password = Platform.environment["DESKTOP_UPDATER_FTP_PASSWORD"];
    if (password == null || password.isEmpty) {
      throw StateError("Set DESKTOP_UPDATER_FTP_PASSWORD for FTP upload.");
    }

    final ownsTempDir = tempDir == null;
    final directory = tempDir ??
        await Directory.systemTemp.createTemp("desktop_updater_ftp_");
    final curlConfig = File(path.join(directory.path, "curl.conf"));
    try {
      await curlConfig.writeAsString(
        [
          ...directives,
          'user = "${_escapeCurlConfig("${config.username}:$password")}"',
        ].join("\n"),
      );
      final result = await Process.run("curl", ["--config", curlConfig.path]);
      if (result.exitCode != 0 && !ownsTempDir) return result;
      if (result.exitCode != 0) _throwCurlError(result);
      return result;
    } finally {
      if (ownsTempDir && await directory.exists()) {
        await directory.delete(recursive: true);
      }
    }
  }

  void _throwCurlError(ProcessResult result) {
    throw ProcessException(
      "curl",
      const ["--config", "<redacted>"],
      "${result.stdout}\n${result.stderr}",
      result.exitCode,
    );
  }

  bool _isRemoteNotFound(ProcessResult result) {
    final output = "${result.stdout}\n${result.stderr}".toLowerCase();
    return result.exitCode == 78 &&
        (output.contains("550") ||
            output.contains("not found") ||
            output.contains("does not exist"));
  }
}

void _assertExpectedRevision({
  required String remotePath,
  required RemoteIndexRevision expectedRevision,
  required List<int>? actualBytes,
}) {
  if (expectedRevision.absent) {
    if (actualBytes != null) {
      throw StateError(
        "FTP index changed before publish: expected $remotePath to be absent.",
      );
    }
    return;
  }
  if (actualBytes == null) {
    throw StateError(
      "FTP index changed before publish: $remotePath is missing.",
    );
  }
  final actualSha256 = sha256.convert(actualBytes).toString();
  if (actualSha256 != expectedRevision.sha256) {
    throw StateError(
      "FTP index changed before publish: $actualSha256 != "
      "${expectedRevision.sha256}.",
    );
  }
}

String _leasePath(String remotePath) {
  final directory = path.posix.dirname(remotePath);
  final fileName = path.posix.basename(remotePath);
  return path.posix.join(directory, ".$fileName.desktop_updater.lock");
}

String _ftpQuotePath(String remotePath) {
  return remotePath.replaceFirst(RegExp(r"^/+"), "");
}

Future<void> _releasePublishedLease({
  required FtpRemoteOperations operations,
  required String leasePath,
  required FtpUploadConfig config,
}) async {
  try {
    await operations.removeDirectory(leasePath, config);
  } on Object catch (error) {
    throw StateError(
      "FTP index was published, but the lease at $leasePath could not be "
      "released. Remove the stale lease directory before publishing again. "
      "Cleanup error: $error",
    );
  }
}

Future<void> _bestEffort(Future<void> Function() action) async {
  try {
    await action();
  } on Object {
    // Preserve the original publication failure and leave diagnostics to the
    // caller. A stale lock is safer than an unverified index replacement.
  }
}

class _UploadFile {
  const _UploadFile({
    required this.relativePath,
    required this.file,
  });

  final String relativePath;
  final File file;
}

List<_UploadFile> _versionedUploadFiles(
  Directory localRoot,
  PublishManifest manifest,
) {
  final files = [
    ".desktop_updater_publish.json",
    manifest.release.path,
    manifest.artifact.path,
  ]..sort();
  return [
    for (final relativePath in files)
      _UploadFile(
        relativePath: relativePath,
        file: File(
          path.join(localRoot.path, path.fromUri(Uri(path: relativePath))),
        ),
      ),
  ];
}

FtpUploadConfig _ftpConfig(UploadConfig config) {
  if (config is! FtpUploadConfig) {
    throw const FormatException("FtpUploadProvider requires FtpUploadConfig.");
  }
  if (!config.allowInsecure) {
    throw const FormatException("ftp.allowInsecure: true is required.");
  }
  return config;
}

String _remotePath(String root, String relativePath) {
  final cleanRoot = root.replaceAll(r"\", "/").replaceAll(RegExp(r"/+$"), "");
  final cleanRelative = relativePath.replaceAll(r"\", "/");
  if (cleanRoot.isEmpty) {
    return "/$cleanRelative";
  }
  return "$cleanRoot/$cleanRelative";
}

Uri _remoteUri(FtpUploadConfig config, String remotePath) {
  return Uri(
    scheme: "ftp",
    host: config.host,
    port: config.port,
    path: remotePath,
  );
}

String _escapeCurlConfig(String value) {
  return value.replaceAll(r"\", r"\\").replaceAll('"', r'\"');
}
