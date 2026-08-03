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

  Future<IndexPublishReceipt> uploadAppArchive({
    required Directory localRoot,
    required PublishManifest manifest,
    required UploadConfig config,
    required StringSink output,
    required RemoteIndexRevision expectedRevision,
  });
}

class UploadResult {
  const UploadResult({required this.uploaded});

  final bool uploaded;
}

final class RemoteIndexRevision {
  const RemoteIndexRevision.present({
    required this.sha256,
    required this.etag,
  }) : absent = false;

  const RemoteIndexRevision.absent()
      : absent = true,
        sha256 = null,
        etag = null;

  final bool absent;
  final String? sha256;
  final String? etag;

  @override
  bool operator ==(Object other) {
    return other is RemoteIndexRevision &&
        absent == other.absent &&
        sha256 == other.sha256 &&
        etag == other.etag;
  }

  @override
  int get hashCode => Object.hash(absent, sha256, etag);

  @override
  String toString() {
    if (absent) {
      return "absent";
    }
    return "sha256=$sha256 etag=${etag ?? "<none>"}";
  }
}

final class IndexPublishReceipt {
  const IndexPublishReceipt({
    required this.observedPriorRevision,
    required this.publishedSha256,
    required this.mechanism,
    required this.leaseEvidenceSha256,
  });

  final RemoteIndexRevision observedPriorRevision;
  final String publishedSha256;
  final IndexPublishMechanism mechanism;
  final String? leaseEvidenceSha256;
}

enum IndexPublishMechanism { conditionalWrite, exclusiveLease }
