import "dart:convert";
import "dart:io";

import "package:desktop_updater/src/core/artifact_verifier.dart";
import "package:desktop_updater/src/core/macos_staged_app_validator.dart";
import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:desktop_updater/src/core/release_index.dart";
import "package:desktop_updater/src/core/safe_zip_extractor.dart";
import "package:desktop_updater/src/core/update_telemetry.dart";
import "package:desktop_updater/src/io/composite_update_transport.dart";
import "package:desktop_updater/src/io/http_update_transport.dart"
    show UpdateRequestHeadersProvider;
import "package:desktop_updater/src/io/update_transport.dart";
import "package:desktop_updater/src/macos_update.dart";
import "package:desktop_updater/src/package_version.dart";
import "package:desktop_updater/src/release_manifest.dart"
    show stagedReleaseManifestFileName;
import "package:desktop_updater/src/version_info.dart";
import "package:path/path.dart" as path;

/// App-owned policy callback for descriptor `minimumOS` checks.
typedef MinimumOSSupportChecker = bool Function({
  required String platform,
  required String minimumOS,
});

/// Low-level zip-first update client used by the controller and direct APIs.
///
/// The client reads an `app-archive.json`, selects the newest eligible release,
/// validates the release descriptor, downloads the artifact, verifies it, and
/// stages it for the native install handoff.
class UpdateClient {
  /// Creates a client for one app archive and currently installed app version.
  UpdateClient({
    required this.appArchiveUrl,
    required this.currentVersion,
    DesktopVersionInfo? currentUpdaterVersion,
    String? platform,
    this.channel = "stable",
    UpdateRequestHeadersProvider? requestHeadersProvider,
    UpdateTransport? transport,
    ArtifactVerifier verifier = const ArtifactVerifier(),
    SafeZipExtractor extractor = const SafeZipExtractor(),
    Directory? stagingParent,
    ProcessRunner runProcess = defaultProcessRunner,
    MinimumOSSupportChecker? isMinimumOSSupported,
    DesktopUpdaterTelemetry? telemetry,
    this.installationIdentity,
  })  : platform = platform ?? Platform.operatingSystem,
        _currentUpdaterVersion = currentUpdaterVersion ??
            DesktopVersionInfo.parse(desktopUpdaterPackageVersion),
        _transport = transport ??
            CompositeUpdateTransport(
              requestHeadersProvider: requestHeadersProvider,
            ),
        _verifier = verifier,
        _extractor = extractor,
        _stagingParent = stagingParent,
        _runProcess = runProcess,
        _isMinimumOSSupported = isMinimumOSSupported,
        _telemetry = telemetry;

  /// Hosted `app-archive.json` URL.
  final Uri appArchiveUrl;

  /// Version currently installed on this machine.
  final DesktopVersionInfo currentVersion;

  final DesktopVersionInfo _currentUpdaterVersion;

  /// Platform identifier used for release selection.
  final String platform;

  /// Release channel used for release selection.
  final String channel;

  /// Stable app-owned identity used for deterministic staged rollouts.
  final String? installationIdentity;
  final UpdateTransport _transport;
  final ArtifactVerifier _verifier;
  final SafeZipExtractor _extractor;
  final Directory? _stagingParent;
  final ProcessRunner _runProcess;
  final MinimumOSSupportChecker? _isMinimumOSSupported;
  final DesktopUpdaterTelemetry? _telemetry;

  /// Checks the archive and returns the newest eligible release, if any.
  Future<UpdateCheckResult?> checkForUpdate() async {
    final tempDir = await Directory.systemTemp.createTemp(
      "desktop_updater_index_",
    );

    try {
      final indexFile = File(path.join(tempDir.path, "app-archive.json"));
      await _transport.download(appArchiveUrl, indexFile);
      final index = ReleaseIndex.fromJson(
        jsonDecode(await indexFile.readAsString()) as Map<String, dynamic>,
      );

      final item = selectReleaseIndexItem(
        index: index,
        platform: platform,
        currentVersion: currentVersion,
        channel: channel,
        installationIdentity: installationIdentity,
      );
      if (item == null) {
        return null;
      }

      final descriptorFile = File(path.join(tempDir.path, "release.json"));
      await _transport.download(item.release, descriptorFile);
      final descriptor = ReleaseDescriptor.fromJson(
        jsonDecode(await descriptorFile.readAsString()) as Map<String, dynamic>,
      );
      await _verifier.verifyDescriptor(descriptor);

      if (descriptor.platform != platform || descriptor.channel != channel) {
        return null;
      }
      _verifyDescriptorMatchesIndexItem(item: item, descriptor: descriptor);
      if (!_descriptorPolicyAllowsUpdate(descriptor)) {
        return null;
      }

      return UpdateCheckResult(
        index: index,
        item: item,
        descriptor: descriptor,
      );
    } finally {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    }
  }

  /// Downloads, verifies, extracts, and stages [descriptor].
  Future<UpdateStageResult> downloadVerifyAndStage({
    required ReleaseDescriptor descriptor,
    void Function(int receivedBytes, int? totalBytes)? onProgress,
  }) async {
    await _verifier.verifyDescriptor(descriptor);
    _ensureDescriptorPolicyAllowsDownload(descriptor);

    final stagingRoot = await (_stagingParent ?? Directory.systemTemp)
        .createTemp("desktop_updater_stage_");
    final artifactFile = File(path.join(stagingRoot.path, "artifact.zip"));

    try {
      await _transport.download(
        descriptor.artifact.url,
        artifactFile,
        onProgress: onProgress,
      );
      await _verifier.verifyArtifactFile(
        artifact: descriptor.artifact,
        file: artifactFile,
      );
      emitUpdateTelemetry(
        _telemetry,
        UpdateTelemetryEvent.artifactVerified(
          source: descriptor.artifact.url,
          version: descriptor.version,
          channel: descriptor.channel,
          platform: descriptor.platform,
        ),
      );

      if (descriptor.platform == "macos") {
        await runDittoExtractZip(
          archivePath: artifactFile.path,
          destination: stagingRoot.path,
          runProcess: _runProcess,
        );
      } else {
        await _extractor.extract(
          archiveFile: artifactFile,
          destination: stagingRoot,
          platform: descriptor.platform,
        );
      }

      final stagedPath = descriptor.platform == "macos"
          ? path.join(stagingRoot.path, descriptor.appName)
          : stagingRoot.path;
      if (descriptor.platform == "macos") {
        await rejectTopLevelMacOSAppSymlink(stagedPath);
        await File(
          path.join(stagingRoot.path, stagedReleaseManifestFileName),
        ).writeAsString(
          const JsonEncoder.withIndent("  ").convert(descriptor.toJson()),
        );
      } else if (descriptor.platform == "windows") {
        await File(
          path.join(stagingRoot.path, stagedReleaseManifestFileName),
        ).writeAsString(
          const JsonEncoder.withIndent("  ").convert(descriptor.toJson()),
        );
      }

      return UpdateStageResult(
        descriptor: descriptor,
        stagingPath: stagedPath,
      );
    } catch (_) {
      if (await stagingRoot.exists()) {
        await stagingRoot.delete(recursive: true);
      }
      rethrow;
    }
  }

  bool _descriptorPolicyAllowsUpdate(ReleaseDescriptor descriptor) {
    return _supportsRequiredUpdaterVersion(descriptor) &&
        _supportsMinimumOS(descriptor);
  }

  void _ensureDescriptorPolicyAllowsDownload(ReleaseDescriptor descriptor) {
    if (!_supportsRequiredUpdaterVersion(descriptor)) {
      throw UnsupportedError(
        "release.json requires desktop_updater "
        "${descriptor.minimumUpdaterVersion} or newer.",
      );
    }
    if (!_supportsMinimumOS(descriptor)) {
      final minimumOS = descriptor.minimumOSForPlatform(platform);
      throw UnsupportedError(
        "release.json requires $platform $minimumOS or newer.",
      );
    }
  }

  bool _supportsRequiredUpdaterVersion(ReleaseDescriptor descriptor) {
    final requiredVersion = descriptor.minimumUpdaterVersion.trim();
    if (requiredVersion.isEmpty) {
      return true;
    }

    return compareDesktopVersions(
          _currentUpdaterVersion,
          DesktopVersionInfo.parse(requiredVersion),
        ) >=
        0;
  }

  bool _supportsMinimumOS(ReleaseDescriptor descriptor) {
    final minimumOS = descriptor.minimumOSForPlatform(platform);
    if (minimumOS == null) {
      return true;
    }

    final checker = _isMinimumOSSupported;
    if (checker == null) {
      return true;
    }

    return checker(platform: platform, minimumOS: minimumOS);
  }
}

void _verifyDescriptorMatchesIndexItem({
  required ReleaseIndexItem item,
  required ReleaseDescriptor descriptor,
}) {
  if (descriptor.version != item.version) {
    throw FormatException(
      "release.json version does not match app-archive.json: "
      "expected ${item.version}, got ${descriptor.version}.",
    );
  }
  if (descriptor.buildNumber != item.buildNumber) {
    throw FormatException(
      "release.json buildNumber does not match app-archive.json: "
      "expected ${item.buildNumber}, got ${descriptor.buildNumber}.",
    );
  }
  if (descriptor.platform != item.platform) {
    throw FormatException(
      "release.json platform does not match app-archive.json: "
      "expected ${item.platform}, got ${descriptor.platform}.",
    );
  }
  if (descriptor.channel != item.channel) {
    throw FormatException(
      "release.json channel does not match app-archive.json: "
      "expected ${item.channel}, got ${descriptor.channel}.",
    );
  }
}

/// Successful update-check result with the selected index item and descriptor.
class UpdateCheckResult {
  /// Creates an update-check result.
  const UpdateCheckResult({
    required this.index,
    required this.item,
    required this.descriptor,
  });

  /// App archive that contained the selected release.
  final ReleaseIndex index;

  /// Selected release index item.
  final ReleaseIndexItem item;

  /// Versioned release descriptor selected for download.
  final ReleaseDescriptor descriptor;
}

/// Result returned after a release artifact has been verified and staged.
class UpdateStageResult {
  /// Creates a staged update result.
  const UpdateStageResult({
    required this.descriptor,
    required this.stagingPath,
  });

  /// Descriptor that was downloaded and staged.
  final ReleaseDescriptor descriptor;

  /// Platform-specific path handed to the native install helper.
  final String stagingPath;
}
