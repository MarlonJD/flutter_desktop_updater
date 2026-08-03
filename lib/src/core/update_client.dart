import "dart:convert";
import "dart:io";

import "package:desktop_updater/src/core/artifact_verifier.dart";
import "package:desktop_updater/src/core/macos_distribution_artifacts.dart";
import "package:desktop_updater/src/core/macos_staged_app_validator.dart";
import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:desktop_updater/src/core/release_index.dart";
import "package:desktop_updater/src/core/release_index_signature_verifier.dart";
import "package:desktop_updater/src/core/release_signature_verifier.dart";
import "package:desktop_updater/src/core/safe_zip_extractor.dart";
import "package:desktop_updater/src/core/staged_update_provenance.dart";
import "package:desktop_updater/src/core/staging_directory_cleanup.dart";
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

final Map<String, RetainedVerifiedStage> _verifiedStages =
    <String, RetainedVerifiedStage>{};

/// Immutable verified stage state retained independently of its marker.
final class RetainedVerifiedStage {
  /// Creates retained proof for one verified stage.
  const RetainedVerifiedStage._({
    required this.stageRoot,
    required this.stagingPath,
    required this.state,
  });

  /// Canonical owned stage root containing the provenance marker.
  final String stageRoot;

  /// Canonical platform-specific path handed to the native helper.
  final String stagingPath;

  /// Verified marker digest and immutable provenance inventory.
  final StagedUpdateProvenanceState state;
}

Future<void> _retainVerifiedStage({
  required Directory stageRoot,
  required String stagingPath,
  required StagedUpdateProvenanceState state,
}) async {
  final canonicalRoot = path.normalize(await stageRoot.resolveSymbolicLinks());
  final canonicalStagingPath =
      path.normalize(await Directory(stagingPath).resolveSymbolicLinks());
  final retained = RetainedVerifiedStage._(
    stageRoot: canonicalRoot,
    stagingPath: canonicalStagingPath,
    state: state,
  );
  _verifiedStages[canonicalRoot] = retained;
  _verifiedStages[canonicalStagingPath] = retained;
}

/// Atomically claims retained stage proof for one native dispatch attempt.
///
/// This package-internal API is misuse resistance for Dart callers. Native
/// plugins still reload and validate descriptor/provenance/target evidence
/// independently before privileged mutation.
Future<RetainedVerifiedStage> claimRetainedVerifiedStageForDispatch({
  required UpdateStageResult stageResult,
  required String expectedPackageId,
}) async {
  if (stageResult._claimedForDispatch) {
    throw StateError("Staged update has already been claimed for dispatch.");
  }
  stageResult._claimedForDispatch = true;
  if (stageResult.descriptor.packageId != expectedPackageId) {
    throw StateError(
      "Staged update package identity does not match the persisted request.",
    );
  }
  final type = await FileSystemEntity.type(
    stageResult.stagingPath,
    followLinks: false,
  );
  if (type != FileSystemEntityType.directory) {
    throw StateError("Staged update path is not a directory.");
  }
  final canonical = path.normalize(
    await Directory(stageResult.stagingPath).resolveSymbolicLinks(),
  );
  final retained = _verifiedStages[canonical];
  if (retained == null ||
      retained.state.markerSha256 != stageResult.stageProvenanceSha256 ||
      retained.state.provenance.canonicalJson !=
          stageResult.stageProvenance.canonicalJson) {
    throw StateError("Retained verified stage provenance is unavailable.");
  }
  return retained;
}

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
    required String expectedPackageId,
    required Map<String, String> trustedReleasePublicKeys,
    DesktopVersionInfo? currentUpdaterVersion,
    String? platform,
    this.channel = "stable",
    UpdateRequestHeadersProvider? requestHeadersProvider,
    UpdateTransport? transport,
    ArtifactVerifier? verifier,
    SafeZipExtractor extractor = const SafeZipExtractor(),
    Directory? stagingParent,
    ProcessRunner runProcess = defaultProcessRunner,
    MacOSDistributionVerifier macosDistributionVerifier =
        const MacOSDistributionVerifier(),
    MinimumOSSupportChecker? isMinimumOSSupported,
    DesktopUpdaterTelemetry? telemetry,
    this.installationIdentity,
  })  : expectedPackageId = _normalizeExpectedPackageId(expectedPackageId),
        trustedReleasePublicKeys =
            normalizeReleasePublicKeys(trustedReleasePublicKeys),
        platform = platform ?? Platform.operatingSystem,
        _currentUpdaterVersion = currentUpdaterVersion ??
            DesktopVersionInfo.parse(desktopUpdaterPackageVersion),
        _transport = transport ??
            CompositeUpdateTransport(
              requestHeadersProvider: requestHeadersProvider,
            ),
        _verifier = verifier ??
            ArtifactVerifier(
              policy: ArtifactVerificationPolicy.requireEd25519Signature(
                publicKeys: normalizeReleasePublicKeys(
                  trustedReleasePublicKeys,
                ),
              ),
            ),
        _extractor = extractor,
        _stagingParent = stagingParent,
        _runProcess = runProcess,
        _macosDistributionVerifier = macosDistributionVerifier,
        _isMinimumOSSupported = isMinimumOSSupported,
        _telemetry = telemetry,
        _indexSignatureVerifier = Ed25519ReleaseIndexSignatureVerifier(
          trustedReleasePublicKeys,
        );

  /// Hosted `app-archive.json` URL.
  final Uri appArchiveUrl;

  /// Version currently installed on this machine.
  final DesktopVersionInfo currentVersion;

  final DesktopVersionInfo _currentUpdaterVersion;

  /// Platform identifier used for release selection.
  final String platform;

  /// Release channel used for release selection.
  final String channel;

  /// App-owned expected package identity.
  final String expectedPackageId;

  /// Normalized trusted Ed25519 public keys.
  final Map<String, String> trustedReleasePublicKeys;

  /// Stable app-owned identity used for deterministic staged rollouts.
  final String? installationIdentity;

  final Object _ownerToken = Object();
  int _checkGeneration = 0;

  final Ed25519ReleaseIndexSignatureVerifier _indexSignatureVerifier;
  final UpdateTransport _transport;
  final ArtifactVerifier _verifier;
  final SafeZipExtractor _extractor;
  final Directory? _stagingParent;
  final ProcessRunner _runProcess;
  final MacOSDistributionVerifier _macosDistributionVerifier;
  final MinimumOSSupportChecker? _isMinimumOSSupported;
  final DesktopUpdaterTelemetry? _telemetry;

  /// Checks the archive and returns the newest eligible release, if any.
  Future<UpdateCheckResult?> checkForUpdate() async {
    _checkGeneration += 1;
    final generation = _checkGeneration;
    final tempDir = await Directory.systemTemp.createTemp(
      "desktop_updater_index_",
    );

    try {
      final indexFile = File(path.join(tempDir.path, "app-archive.json"));
      await _downloadMetadata(appArchiveUrl, indexFile);
      final index = ReleaseIndex.fromJson(
        jsonDecode(await indexFile.readAsString()) as Map<String, dynamic>,
      );
      if (!await _indexSignatureVerifier.verify(index)) {
        throw const FormatException(
          "app-archive.json signature verification failed.",
        );
      }

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
      await _downloadMetadata(item.release, descriptorFile);
      final descriptor = ReleaseDescriptor.fromJson(
        jsonDecode(await descriptorFile.readAsString()) as Map<String, dynamic>,
      );
      await _verifier.verifyDescriptor(descriptor);

      if (descriptor.platform != platform || descriptor.channel != channel) {
        return null;
      }
      if (descriptor.packageId != expectedPackageId) {
        throw FormatException(
          "release.json packageId does not match expected package identity: "
          "expected $expectedPackageId, got ${descriptor.packageId}.",
        );
      }
      _verifyDescriptorMatchesIndexItem(item: item, descriptor: descriptor);
      if (!_descriptorPolicyAllowsUpdate(descriptor)) {
        return null;
      }

      return UpdateCheckResult._(
        ownerToken: _ownerToken,
        generation: generation,
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

  Future<void> _downloadMetadata(Uri source, File destination) async {
    final transport = _transport;
    if (transport is BoundedUpdateTransport) {
      await transport.downloadBounded(
        source,
        destination,
        maximumBytes: maximumStableMetadataBytes,
      );
      return;
    }

    await transport.download(source, destination);
    final downloadedBytes = await destination.length();
    if (downloadedBytes <= maximumStableMetadataBytes) {
      return;
    }
    await destination.delete();
    throw UpdateDownloadSizeLimitException(
      source: source,
      maximumBytes: maximumStableMetadataBytes,
      actualBytes: downloadedBytes,
    );
  }

  Future<void> _downloadArtifact(
    ReleaseArtifact artifact,
    File destination, {
    void Function(int receivedBytes, int? totalBytes)? onProgress,
  }) async {
    final transport = _transport;
    if (transport is BoundedUpdateTransport) {
      await transport.downloadBounded(
        artifact.url,
        destination,
        maximumBytes: artifact.length,
        onProgress: onProgress,
      );
      return;
    }

    await transport.download(
      artifact.url,
      destination,
      onProgress: onProgress,
    );
    final downloadedBytes = await destination.length();
    if (downloadedBytes <= artifact.length) {
      return;
    }
    await destination.delete();
    throw UpdateDownloadSizeLimitException(
      source: artifact.url,
      maximumBytes: artifact.length,
      actualBytes: downloadedBytes,
    );
  }

  /// Downloads, verifies, extracts, and stages [checkResult].
  Future<UpdateStageResult> downloadVerifyAndStage({
    required UpdateCheckResult checkResult,
    void Function(int receivedBytes, int? totalBytes)? onProgress,
  }) async {
    final descriptor = _claimCheckResult(checkResult).descriptor;
    await _verifier.verifyDescriptor(descriptor);
    if (descriptor.packageId != expectedPackageId) {
      throw StateError(
        "Checked release package identity no longer matches this client.",
      );
    }
    _ensureDescriptorPolicyAllowsDownload(descriptor);

    final stagingParent = _stagingParent ?? Directory.systemTemp;
    await cleanupStaleDesktopUpdaterStagingDirectories(parent: stagingParent);
    final stagingRoot =
        await createOwnedStagingDirectory(parent: stagingParent);
    final stagingNonce = path
        .basename(stagingRoot.path)
        .substring(desktopUpdaterStagingPrefix.length);
    final artifactFile = File(
      path.join(
        stagingRoot.path,
        switch (descriptor.artifact.kind) {
          "dmg" => "artifact.dmg",
          "pkgInstaller" => "artifact.pkg",
          "innoInstaller" => "artifact.exe",
          _ => ".desktop_updater_artifact.zip",
        },
      ),
    );

    try {
      await _downloadArtifact(
        descriptor.artifact,
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
          artifactKind: descriptor.artifact.kind,
          installStrategy: descriptor.install.strategy,
        ),
      );

      if (descriptor.artifact.kind == "innoInstaller") {
        if (descriptor.platform != "windows" || platform != "windows") {
          throw UnsupportedError(
            "Inno installer updates are only supported on Windows.",
          );
        }
        final installerFile =
            File(path.join(stagingRoot.path, "installer.exe"));
        await artifactFile.rename(installerFile.path);
        await File(
          path.join(stagingRoot.path, stagedReleaseManifestFileName),
        ).writeAsString(
          jsonEncode(sortJsonValue(descriptor.toJson())),
        );
        return await _finalizeStage(
          descriptor: descriptor,
          stagingRoot: stagingRoot,
          stagingPath: stagingRoot.path,
          nonce: stagingNonce,
        );
      }

      if (descriptor.artifact.kind == "dmg") {
        if (descriptor.platform != "macos" || platform != "macos") {
          throw UnsupportedError("DMG updates are only supported on macOS.");
        }
        final dmg = descriptor.install.macosDmg!;
        final stagedApp =
            await _macosDistributionVerifier.withMountedVerifiedDmg<Directory>(
          dmg: artifactFile,
          verifyPrimarySignature: dmg.verifyPrimarySignature,
          body: (mounted) {
            return _macosDistributionVerifier.copyAppFromMountedDmg(
              mounted: mounted,
              appBundleName: dmg.appBundleName,
              destinationParent: stagingRoot,
            );
          },
        );
        await rejectTopLevelMacOSAppSymlink(stagedApp.path);
        await File(
          path.join(stagingRoot.path, stagedReleaseManifestFileName),
        ).writeAsString(
          jsonEncode(sortJsonValue(descriptor.toJson())),
        );
        return await _finalizeStage(
          descriptor: descriptor,
          stagingRoot: stagingRoot,
          stagingPath: stagedApp.path,
          nonce: stagingNonce,
        );
      }

      if (descriptor.artifact.kind == "pkgInstaller") {
        if (descriptor.platform != "macos" || platform != "macos") {
          throw UnsupportedError(
            "PKG installer updates are only supported on macOS.",
          );
        }
        await _macosDistributionVerifier.verifyPkgInstaller(
          pkg: artifactFile,
          expectedPackageIds: descriptor.install.macosPkg!.expectedPackageIds,
        );
        final installerFile =
            File(path.join(stagingRoot.path, "installer.pkg"));
        await artifactFile.rename(installerFile.path);
        await File(
          path.join(stagingRoot.path, stagedReleaseManifestFileName),
        ).writeAsString(
          jsonEncode(sortJsonValue(descriptor.toJson())),
        );
        return await _finalizeStage(
          descriptor: descriptor,
          stagingRoot: stagingRoot,
          stagingPath: stagingRoot.path,
          nonce: stagingNonce,
        );
      }

      if (descriptor.platform == "macos") {
        await _extractor.preflight(artifactFile);
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
          jsonEncode(sortJsonValue(descriptor.toJson())),
        );
      } else if (descriptor.platform == "windows" ||
          descriptor.platform == "linux") {
        await File(
          path.join(stagingRoot.path, stagedReleaseManifestFileName),
        ).writeAsString(
          jsonEncode(sortJsonValue(descriptor.toJson())),
        );
      }

      return await _finalizeStage(
        descriptor: descriptor,
        stagingRoot: stagingRoot,
        stagingPath: stagedPath,
        nonce: stagingNonce,
      );
    } catch (_) {
      if (await stagingRoot.exists()) {
        await stagingRoot.delete(recursive: true);
      }
      rethrow;
    }
  }

  Future<UpdateStageResult> _finalizeStage({
    required ReleaseDescriptor descriptor,
    required Directory stagingRoot,
    required String stagingPath,
    required String nonce,
  }) async {
    final state = await writeStagedUpdateProvenance(
      stageRoot: stagingRoot,
      nonce: nonce,
      packageId: descriptor.packageId,
      descriptorSha256: canonicalJsonSha256(descriptor.toJson()),
      artifactSha256: descriptor.artifact.sha256,
    );
    await _retainVerifiedStage(
      stageRoot: stagingRoot,
      stagingPath: stagingPath,
      state: state,
    );
    return UpdateStageResult._(
      descriptor: descriptor,
      stagingPath: stagingPath,
      stageProvenanceSha256: state.markerSha256,
      stageProvenance: state.provenance,
    );
  }

  UpdateCheckResult _claimCheckResult(UpdateCheckResult result) {
    if (!identical(result._ownerToken, _ownerToken)) {
      result._claimed = true;
      throw StateError(
        "Update check result was created by a different UpdateClient.",
      );
    }
    if (result._generation != _checkGeneration) {
      result._claimed = true;
      throw StateError("Update check result is stale.");
    }
    if (result._claimed) {
      throw StateError("Update check result has already been used.");
    }
    result._claimed = true;
    return result;
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
final class UpdateCheckResult {
  /// Creates an update-check result.
  UpdateCheckResult._({
    required Object ownerToken,
    required int generation,
    required this.index,
    required this.item,
    required this.descriptor,
  })  : _ownerToken = ownerToken,
        _generation = generation;

  final Object _ownerToken;
  final int _generation;
  bool _claimed = false;

  /// App archive that contained the selected release.
  final ReleaseIndex index;

  /// Selected release index item.
  final ReleaseIndexItem item;

  /// Versioned release descriptor selected for download.
  final ReleaseDescriptor descriptor;
}

/// Result returned after a release artifact has been verified and staged.
final class UpdateStageResult {
  /// Creates a staged update result.
  UpdateStageResult._({
    required this.descriptor,
    required this.stagingPath,
    required this.stageProvenanceSha256,
    required this.stageProvenance,
  });

  bool _claimedForDispatch = false;

  /// Descriptor that was downloaded and staged.
  final ReleaseDescriptor descriptor;

  /// Platform-specific path handed to the native install helper.
  final String stagingPath;

  /// Digest retained by the verified client and required by install helpers.
  final String stageProvenanceSha256;

  /// Immutable inventory retained with the verified stage state.
  final StagedUpdateProvenance stageProvenance;
}

String _normalizeExpectedPackageId(String value) {
  final normalized = value.trim();
  if (normalized.isEmpty) {
    throw ArgumentError.value(
      value,
      "expectedPackageId",
      "must not be blank",
    );
  }
  return normalized;
}
