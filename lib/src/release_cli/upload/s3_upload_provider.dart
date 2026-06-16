import "dart:io";

import "package:desktop_updater/src/release_cli/publish_manifest.dart";
import "package:desktop_updater/src/release_cli/release_publish_config.dart";
import "package:desktop_updater/src/release_cli/upload/upload_provider.dart";
import "package:path/path.dart" as path;

abstract interface class ObjectStorageClient {
  Future<void> putFile({
    required File file,
    required String bucket,
    required String key,
    required S3UploadConfig config,
  });
}

class S3UploadProvider implements OrderedUploadProvider {
  const S3UploadProvider({this.client = const AwsCliObjectStorageClient()});

  final ObjectStorageClient client;

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
    final s3Config = _s3Config(config);
    for (final file in _versionedUploadFiles(localRoot, manifest)) {
      await client.putFile(
        file: file.file,
        bucket: s3Config.bucket,
        key: _s3Key(s3Config.prefix, file.relativePath),
        config: s3Config,
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
    final s3Config = _s3Config(config);
    await client.putFile(
      file: File(path.join(localRoot.path, manifest.appArchive.path)),
      bucket: s3Config.bucket,
      key: _s3Key(s3Config.prefix, manifest.appArchive.path),
      config: s3Config,
    );
  }
}

class AwsCliObjectStorageClient implements ObjectStorageClient {
  const AwsCliObjectStorageClient();

  @override
  Future<void> putFile({
    required File file,
    required String bucket,
    required String key,
    required S3UploadConfig config,
  }) async {
    final args = [
      "s3",
      "cp",
      file.path,
      "s3://$bucket/$key",
      if (_selectedProfile(config) != null) ...[
        "--profile",
        _selectedProfile(config)!,
      ],
      if (config.endpoint != null) ...[
        "--endpoint-url",
        config.endpoint!,
      ],
      if (config.region != null) ...[
        "--region",
        config.region!,
      ],
    ];

    ProcessResult result;
    try {
      result = await Process.run("aws", args);
    } on ProcessException catch (error) {
      throw StateError(
        "AWS CLI executable not found. Install aws or configure a different upload provider. $error",
      );
    }
    if (result.exitCode != 0) {
      throw ProcessException(
        "aws",
        args,
        "${result.stdout}\n${result.stderr}",
        result.exitCode,
      );
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
          path.join(localRoot.path, path.fromUri(Uri(path: relativePath))),
        ),
      ),
  ];
}

S3UploadConfig _s3Config(UploadConfig config) {
  if (config is! S3UploadConfig) {
    throw const FormatException("S3UploadProvider requires S3UploadConfig.");
  }
  return config;
}

String _s3Key(String? prefix, String relativePath) {
  final normalizedPath = relativePath.replaceAll(r"\", "/");
  final trimmedPrefix = prefix?.trim().replaceAll(r"\", "/");
  if (trimmedPrefix == null || trimmedPrefix.isEmpty) {
    return normalizedPath;
  }
  return "${trimmedPrefix.replaceAll(RegExp(r"/+$"), "")}/$normalizedPath";
}

String? _selectedProfile(S3UploadConfig config) {
  final profile = config.profile?.trim();
  if (profile != null && profile.isNotEmpty) {
    return profile;
  }
  final envProfile = Platform.environment["AWS_PROFILE"]?.trim();
  if (envProfile != null && envProfile.isNotEmpty) {
    return envProfile;
  }
  return null;
}
