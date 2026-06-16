import "dart:io";

import "package:desktop_updater/src/release_cli/publish_manifest.dart";
import "package:desktop_updater/src/release_cli/release_publish_config.dart";
import "package:desktop_updater/src/release_cli/upload/upload_provider.dart";
import "package:path/path.dart" as path;

abstract interface class SftpRemoteFileClient {
  Future<void> writeFile({
    required File file,
    required String remotePath,
    required SftpUploadConfig config,
  });
}

class SftpRemoteWrite {
  const SftpRemoteWrite({
    required this.file,
    required this.remotePath,
  });

  final File file;
  final String remotePath;
}

class SftpUploadProvider implements OrderedUploadProvider {
  const SftpUploadProvider({this.client = const CurlSftpRemoteFileClient()});

  final SftpRemoteFileClient client;

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
    final sftpConfig = _sftpConfig(config);
    for (final file in _versionedUploadFiles(localRoot, manifest)) {
      await client.writeFile(
        file: file.file,
        remotePath: _remotePath(sftpConfig.remotePath, file.relativePath),
        config: sftpConfig,
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
    final sftpConfig = _sftpConfig(config);
    await client.writeFile(
      file: File(path.join(localRoot.path, manifest.appArchive.path)),
      remotePath: _remotePath(sftpConfig.remotePath, manifest.appArchive.path),
      config: sftpConfig,
    );
  }
}

class CurlSftpRemoteFileClient implements SftpRemoteFileClient {
  const CurlSftpRemoteFileClient();

  @override
  Future<void> writeFile({
    required File file,
    required String remotePath,
    required SftpUploadConfig config,
  }) async {
    final password = Platform.environment["DESKTOP_UPDATER_SFTP_PASSWORD"];
    final privateKey = Platform.environment["DESKTOP_UPDATER_SFTP_PRIVATE_KEY"];
    if ((password == null || password.isEmpty) &&
        (privateKey == null || privateKey.isEmpty)) {
      throw StateError(
        "Set DESKTOP_UPDATER_SFTP_PASSWORD or DESKTOP_UPDATER_SFTP_PRIVATE_KEY for SFTP upload.",
      );
    }

    final tempDir =
        await Directory.systemTemp.createTemp("desktop_updater_sftp_");
    final curlConfig = File(path.join(tempDir.path, "curl.conf"));
    try {
      await curlConfig.writeAsString(
        [
          'url = "${_escapeCurlConfig(_remoteUri(config, remotePath).toString())}"',
          'upload-file = "${_escapeCurlConfig(file.path)}"',
          "ftp-create-dirs",
          if (sftpCurlConfigAllowsUnknownHost(config)) "insecure",
          'user = "${_escapeCurlConfig("${config.username}:${password ?? ""}")}"',
          if (privateKey != null && privateKey.isNotEmpty)
            'key = "${_escapeCurlConfig(privateKey)}"',
        ].join("\n"),
      );
      final curlExecutable = defaultSftpCurlExecutable();
      final result = await Process.run(
        curlExecutable,
        ["--config", curlConfig.path],
      );
      if (result.exitCode != 0) {
        throw ProcessException(
          curlExecutable,
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

String defaultSftpCurlExecutable({
  bool Function(String path) exists = _fileExists,
}) {
  const homebrewCurl = "/opt/homebrew/opt/curl/bin/curl";
  if (exists(homebrewCurl)) {
    return homebrewCurl;
  }
  return "curl";
}

bool sftpCurlConfigAllowsUnknownHost(SftpUploadConfig config) {
  return config.host == "127.0.0.1" ||
      config.host == "localhost" ||
      config.host == "::1";
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

SftpUploadConfig _sftpConfig(UploadConfig config) {
  if (config is! SftpUploadConfig) {
    throw const FormatException(
      "SftpUploadProvider requires SftpUploadConfig.",
    );
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

Uri _remoteUri(SftpUploadConfig config, String remotePath) {
  return Uri(
    scheme: "sftp",
    host: config.host,
    port: config.port,
    path: remotePath,
  );
}

String _escapeCurlConfig(String value) {
  return value.replaceAll(r"\", r"\\").replaceAll('"', r'\"');
}

bool _fileExists(String path) => File(path).existsSync();
