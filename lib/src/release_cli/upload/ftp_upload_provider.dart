import "dart:io";

import "package:desktop_updater/src/release_cli/publish_manifest.dart";
import "package:desktop_updater/src/release_cli/release_publish_config.dart";
import "package:desktop_updater/src/release_cli/upload/upload_provider.dart";
import "package:path/path.dart" as path;

abstract interface class FtpRemoteFileClient {
  Future<void> writeFile({
    required File file,
    required String remotePath,
    required FtpUploadConfig config,
  });
}

class FtpRemoteWrite {
  const FtpRemoteWrite({
    required this.file,
    required this.remotePath,
  });

  final File file;
  final String remotePath;
}

class FtpUploadProvider implements OrderedUploadProvider {
  const FtpUploadProvider({this.client = const CurlFtpRemoteFileClient()});

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
  Future<void> uploadAppArchive({
    required Directory localRoot,
    required PublishManifest manifest,
    required UploadConfig config,
    required StringSink output,
  }) async {
    final ftpConfig = _ftpConfig(config);
    await client.writeFile(
      file: File(path.join(localRoot.path, manifest.appArchive.path)),
      remotePath: _remotePath(ftpConfig.remotePath, manifest.appArchive.path),
      config: ftpConfig,
    );
  }
}

class CurlFtpRemoteFileClient implements FtpRemoteFileClient {
  const CurlFtpRemoteFileClient();

  @override
  Future<void> writeFile({
    required File file,
    required String remotePath,
    required FtpUploadConfig config,
  }) async {
    final password = Platform.environment["DESKTOP_UPDATER_FTP_PASSWORD"];
    if (password == null || password.isEmpty) {
      throw StateError("Set DESKTOP_UPDATER_FTP_PASSWORD for FTP upload.");
    }

    final tempDir =
        await Directory.systemTemp.createTemp("desktop_updater_ftp_");
    final curlConfig = File(path.join(tempDir.path, "curl.conf"));
    try {
      await curlConfig.writeAsString(
        [
          'url = "${_escapeCurlConfig(_remoteUri(config, remotePath).toString())}"',
          'upload-file = "${_escapeCurlConfig(file.path)}"',
          "ftp-create-dirs",
          'user = "${_escapeCurlConfig("${config.username}:$password")}"',
        ].join("\n"),
      );
      final result = await Process.run("curl", ["--config", curlConfig.path]);
      if (result.exitCode != 0) {
        throw ProcessException(
          "curl",
          const ["--config", "<redacted>"],
          "${result.stdout}\n${result.stderr}",
          result.exitCode,
        );
      }
    } finally {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    }
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
            path.join(localRoot.path, path.fromUri(Uri(path: relativePath)))),
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
  final cleanRoot = root.replaceAll("\\", "/").replaceAll(RegExp(r"/+$"), "");
  final cleanRelative = relativePath.replaceAll("\\", "/");
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
  return value.replaceAll("\\", r"\\").replaceAll('"', r'\"');
}
