import "dart:io";

import "package:desktop_updater/src/release_cli/publish_manifest.dart";
import "package:desktop_updater/src/release_cli/release_publish_config.dart";

abstract interface class UploadProvider {
  Future<UploadResult> upload({
    required Directory localRoot,
    required PublishManifest manifest,
    required UploadConfig config,
    required StringSink output,
  });
}

abstract interface class OrderedUploadProvider implements UploadProvider {
  Future<void> uploadVersionedFiles({
    required Directory localRoot,
    required PublishManifest manifest,
    required UploadConfig config,
    required StringSink output,
  });

  Future<void> uploadAppArchive({
    required Directory localRoot,
    required PublishManifest manifest,
    required UploadConfig config,
    required StringSink output,
  });
}

class UploadResult {
  const UploadResult({required this.uploaded});

  final bool uploaded;
}
