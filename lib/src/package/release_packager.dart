import "dart:io";

import "package:desktop_updater/src/core/release_descriptor.dart";

abstract interface class ReleasePackager {
  Future<ReleasePackageResult> package(ReleasePackageRequest request);
}

class ReleasePackageRequest {
  const ReleasePackageRequest({
    required this.input,
    required this.outputDirectory,
    required this.packageId,
    required this.appName,
    required this.version,
    required this.buildNumber,
    required this.platform,
    required this.channel,
    required this.artifactUrl,
    required this.installStrategy,
    this.minimumUpdaterVersion = "2.0.0",
  });

  final FileSystemEntity input;
  final Directory outputDirectory;
  final String packageId;
  final String appName;
  final String version;
  final int buildNumber;
  final String platform;
  final String channel;
  final Uri artifactUrl;
  final String installStrategy;
  final String minimumUpdaterVersion;
}

class ReleasePackageResult {
  const ReleasePackageResult({
    required this.artifact,
    required this.releaseFile,
    required this.descriptor,
  });

  final File artifact;
  final File releaseFile;
  final ReleaseDescriptor descriptor;
}
