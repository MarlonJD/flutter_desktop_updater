import "dart:convert";
import "dart:io";

import "package:crypto/crypto.dart" as crypto;
import "package:cryptography_plus/cryptography_plus.dart";
import "package:desktop_updater/src/core/artifact_verifier.dart";
import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:desktop_updater/src/core/release_index.dart";
import "package:desktop_updater/src/core/release_index_signature_verifier.dart";
import "package:desktop_updater/src/core/release_signature_verifier.dart";
import "package:desktop_updater/src/macos_update.dart";
import "package:desktop_updater/src/package/app_archive_writer.dart";
import "package:desktop_updater/src/package/release_packager.dart";
import "package:desktop_updater/src/package/zip_release_packager.dart";
import "package:desktop_updater/src/release_cli/cmake_project_adapter.dart";
import "package:desktop_updater/src/release_cli/flutter_project_adapter.dart";
import "package:desktop_updater/src/release_cli/inno/inno_installer_packager.dart";
import "package:desktop_updater/src/release_cli/inno/inno_output_name.dart";
import "package:desktop_updater/src/release_cli/macos/dmg_packager.dart";
import "package:desktop_updater/src/release_cli/macos/macos_artifact_config.dart";
import "package:desktop_updater/src/release_cli/macos/macos_release_trust.dart";
import "package:desktop_updater/src/release_cli/macos/pkg_packager.dart";
import "package:desktop_updater/src/release_cli/manual_project_adapter.dart";
import "package:desktop_updater/src/release_cli/platform_release_profile.dart";
import "package:desktop_updater/src/release_cli/project_adapter.dart";
import "package:desktop_updater/src/release_cli/project_metadata_resolver.dart";
import "package:desktop_updater/src/release_cli/publish_layout.dart";
import "package:desktop_updater/src/release_cli/publish_manifest.dart";
import "package:desktop_updater/src/release_cli/release_publish_config.dart";
import "package:desktop_updater/src/release_cli/sign_command.dart";
import "package:desktop_updater/src/release_cli/upload/custom_command_upload_provider.dart";
import "package:desktop_updater/src/release_cli/upload/ftp_upload_provider.dart";
import "package:desktop_updater/src/release_cli/upload/manual_upload_provider.dart";
import "package:desktop_updater/src/release_cli/upload/s3_upload_provider.dart";
import "package:desktop_updater/src/release_cli/upload/sftp_upload_provider.dart";
import "package:desktop_updater/src/release_cli/upload/upload_provider.dart";
import "package:desktop_updater/src/release_cli/validate_command.dart";
import "package:desktop_updater/src/release_cli/xcode_project_adapter.dart";
import "package:desktop_updater/src/release_manifest.dart";
import "package:http/http.dart" as http;
import "package:path/path.dart" as path;

export "package:desktop_updater/src/release_cli/project_adapter.dart"
    show
        BuildProcess,
        BuildProcessStarter,
        StartedBuildProcess,
        defaultBuildProcessStarter;

/// Runs a configured release hook command.
typedef ReleaseHookCommandRunner = Future<ProcessResult> Function(
  String command, {
  required Map<String, String> environment,
});

/// Ephemeral key material used to sign the final app archive after hooks.
class ReleaseSigningOptions {
  /// Creates ephemeral signing options for one publication.
  ReleaseSigningOptions({
    required this.publicKeyId,
    required this.privateKeyBase64,
    required Map<String, String> trustedReleasePublicKeys,
  }) : trustedReleasePublicKeys = normalizeReleasePublicKeys(
         trustedReleasePublicKeys,
       );

  /// Pinned key identifier written to the signature envelope.
  final String publicKeyId;

  /// Base64-encoded raw 32-byte Ed25519 private seed.
  final String privateKeyBase64;

  /// Normalized trusted release public key map used for publication validation.
  final Map<String, String> trustedReleasePublicKeys;
}

class ReleasePublisher {
  const ReleasePublisher({
    this.skipBuild = false,
    this.packager = const ZipReleasePackager(),
    this.innoPackager = const InnoInstallerPackager(),
    this.dmgPackager = const DmgPackager(),
    this.pkgPackager = const PkgPackager(),
    this.metadataResolver = const ProjectMetadataResolver(),
    this.projectAdapters = const [],
    this.runProcess = defaultProcessRunner,
    this.runHookCommand = defaultReleaseHookCommandRunner,
    this.httpClient,
    this.isMacOSHost,
    this.macOSReleaseTrust,
    BuildProcessStarter startBuildProcess = defaultBuildProcessStarter,
  }) : _startBuildProcess = startBuildProcess;

  final bool skipBuild;
  final ReleasePackager packager;
  final InnoInstallerPackager innoPackager;
  final DmgPackager dmgPackager;
  final PkgPackager pkgPackager;
  final ProjectMetadataResolver metadataResolver;

  /// Optional native adapter overrides available for selection.
  final List<ProjectAdapter> projectAdapters;
  final ProcessRunner runProcess;
  final ReleaseHookCommandRunner runHookCommand;
  final http.Client? httpClient;
  final bool? isMacOSHost;
  final MacOSReleaseTrust? macOSReleaseTrust;
  final BuildProcessStarter _startBuildProcess;

  Future<PublishManifest> publish({
    required Directory projectRoot,
    required String platform,
    required ReleasePublishOverrides overrides,
    ReleaseSigningOptions? signing,
    ReleasePublishConfig? loadedConfig,
    required StringSink output,
  }) async {
    final config =
        loadedConfig ??
        await ReleasePublishConfig.load(
          projectRoot: projectRoot,
          cliOverrides: overrides,
        );
    if (overrides.notarize && platform != "macos") {
      throw const FormatException(
        "--notarize is only supported with --platform macos.",
      );
    }
    final signedHistory = signing == null
        ? null
        : await _acquireSignedPublicationHistory(
            projectRoot: projectRoot,
            appArchiveUrl: config.baseUrl.resolve("app-archive.json"),
            overrides: overrides,
            signing: signing,
            client: httpClient ?? http.Client(),
          );
    final flutterAdapter = FlutterProjectAdapter(
      overrides: overrides,
      output: output,
      skipBuild: skipBuild,
      metadataResolver: metadataResolver,
      startBuildProcess: _startBuildProcess,
    );
    final xcodeAdapter = XcodeProjectAdapter(
      projectPath: overrides.xcodeProject,
      workspacePath: overrides.xcodeWorkspace,
      scheme: overrides.xcodeScheme,
      derivedDataPath: overrides.xcodeDerivedDataPath,
      overrides: overrides,
      output: output,
      skipBuild: skipBuild,
      runProcess: runProcess,
    );
    final cmakeAdapter = CMakeProjectAdapter(
      sourceDirectory: overrides.cmakeSourceDirectory,
      buildDirectory: overrides.cmakeBuildDirectory,
      buildTarget: overrides.cmakeBuildTarget,
      installedArtifactRoot: overrides.artifactRoot,
      executableRelativePath: overrides.executableRelativePath,
      overrides: overrides,
      output: output,
      skipBuild: skipBuild,
      runProcess: runProcess,
    );
    final adapter =
        DefaultProjectAdapterSelector(
          adapters: [
            flutterAdapter,
            if (!projectAdapters.any((adapter) => adapter.type == "xcode"))
              xcodeAdapter,
            if (!projectAdapters.any((adapter) => adapter.type == "cmake"))
              cmakeAdapter,
            ...projectAdapters,
          ],
        ).select(
          ProjectAdapterSelectionRequest(
            projectRoot: projectRoot,
            explicitType: overrides.projectType,
            manualArtifactRoot: _resolveManualArtifactRoot(
              projectRoot,
              overrides.artifactRoot,
            ),
            manualAppName: overrides.artifactRoot == null
                ? null
                : overrides.appName,
            manualPackageId: overrides.artifactRoot == null
                ? null
                : overrides.packageId,
            manualVersion: overrides.artifactRoot == null
                ? null
                : overrides.version,
            manualBuildNumber: overrides.artifactRoot == null
                ? null
                : overrides.buildNumber,
            manualExecutableRelativePath: overrides.artifactRoot == null
                ? null
                : overrides.executableRelativePath,
          ),
        );
    final buildResult = await adapter.build(
      ProjectBuildRequest(
        projectRoot: projectRoot,
        platform: platform,
        releaseMode: true,
      ),
    );
    final metadata = ProjectMetadata(
      version: buildResult.version,
      buildNumber: buildResult.buildNumber,
      appName: buildResult.appName,
      packageId: buildResult.packageId,
      platform: platform,
      profile: PlatformReleaseProfile.forPlatform(platform),
      input: buildResult.artifactRoot,
    );
    final useInnoInstaller =
        platform == "windows" && config.windows.installer.enabled;
    final innoOutputBaseName = useInnoInstaller
        ? await resolveInnoOutputBaseName(
            config: config.windows.installer,
            appName: metadata.appName,
            version: metadata.version,
            platform: platform,
          )
        : null;
    final macosArtifact = platform == "macos"
        ? config.macos.artifactKind
        : null;
    final artifactExtension = switch (macosArtifact) {
      MacOSArtifactKind.dmg => ".dmg",
      MacOSArtifactKind.pkg => ".pkg",
      _ => useInnoInstaller ? ".exe" : ".zip",
    };
    final layout = PublishLayout.create(
      outputDirectory: config.outputDirectory,
      baseUrl: config.baseUrl,
      version: metadata.version,
      platform: platform,
      appName: metadata.appName,
      artifactExtension: artifactExtension,
      artifactSuffix: useInnoInstaller ? "-setup" : "",
      artifactFileName: useInnoInstaller ? "$innoOutputBaseName.exe" : null,
    );

    await _copyAdditionalFiles(
      additionalFiles: config.additionalFiles,
      projectRoot: projectRoot,
      metadata: metadata,
      output: output,
    );

    await _runReleaseHooks(
      hooks: config.hooks.prePackage,
      phase: "prePackage",
      projectRoot: projectRoot,
      config: config,
      metadata: metadata,
      layout: layout,
      runHookCommand: runHookCommand,
      output: output,
    );

    if (platform == "macos" && config.macos.notarize) {
      await _notarizeMacOS(
        app: metadata.input,
        config: config.macos,
        runProcess: runProcess,
        output: output,
        trust: macOSReleaseTrust,
      );
    }

    output.writeln("Packaging update...");
    final archiveAppName = _artifactNameStem(metadata.appName);
    late final ReleasePackageResult packageResult;
    if (useInnoInstaller) {
      packageResult = await innoPackager.package(
        ReleasePackageRequest(
          input: metadata.input,
          outputDirectory: layout.releaseDirectory,
          packageId: metadata.packageId,
          appName: metadata.appName,
          version: metadata.version,
          buildNumber: metadata.buildNumber,
          platform: platform,
          channel: config.channel,
          artifactUrl: layout.artifactUrl,
          installStrategy: "innoInstaller",
          minimumUpdaterVersion: "2.5.0",
        ),
        config: config.windows.installer,
        outputBaseName: innoOutputBaseName,
      );
    } else if (platform == "macos" &&
        config.macos.artifactKind == MacOSArtifactKind.dmg) {
      packageResult = await dmgPackager.package(
        ReleasePackageRequest(
          input: metadata.input,
          outputDirectory: layout.releaseDirectory,
          packageId: metadata.packageId,
          appName: metadata.appName,
          version: metadata.version,
          buildNumber: metadata.buildNumber,
          platform: platform,
          channel: config.channel,
          artifactUrl: layout.artifactUrl,
          installStrategy: "wholeBundleReplace",
          minimumUpdaterVersion: "2.6.0",
        ),
        config: config.macos.dmg.resolveDefaultsForAppName(metadata.appName),
        publishConfig: config.macos,
      );
    } else if (platform == "macos" &&
        config.macos.artifactKind == MacOSArtifactKind.pkg) {
      packageResult = await pkgPackager.package(
        ReleasePackageRequest(
          input: metadata.input,
          outputDirectory: layout.releaseDirectory,
          packageId: metadata.packageId,
          appName: metadata.appName,
          version: metadata.version,
          buildNumber: metadata.buildNumber,
          platform: platform,
          channel: config.channel,
          artifactUrl: layout.artifactUrl,
          installStrategy: "pkgInstaller",
          minimumUpdaterVersion: "2.7.0",
        ),
        config: config.macos.pkg,
        publishConfig: config.macos,
      );
    } else {
      packageResult = await packager.package(
        ReleasePackageRequest(
          input: metadata.input,
          outputDirectory: layout.releaseDirectory,
          packageId: metadata.packageId,
          appName: metadata.appName,
          version: metadata.version,
          buildNumber: metadata.buildNumber,
          platform: platform,
          channel: config.channel,
          artifactUrl: layout.artifactUrl,
          installStrategy: metadata.profile.installStrategy,
        ),
      );
    }

    if (signedHistory != null) {
      await _writeFrozenHistoryToAppArchive(
        archiveFile: layout.appArchiveFile,
        archiveAppName: archiveAppName,
        history: signedHistory,
      );
    }
    await upsertAppArchive(
      archiveFile: layout.appArchiveFile,
      appName: archiveAppName,
      supportPolicy: overrides.minimumSupportedVersion == null
          ? null
          : ReleaseSupportPolicy(
              minimumSupportedVersion: overrides.minimumSupportedVersion!,
              enforcedAfter: overrides.enforcedAfter!,
            ),
      item: ReleaseIndexItem(
        version: metadata.version,
        buildNumber: metadata.buildNumber,
        platform: platform,
        channel: config.channel,
        mandatory: overrides.mandatory,
        freshInstall: overrides.freshInstallUrl == null
            ? null
            : ReleaseFreshInstall(
                downloadUrl: overrides.freshInstallUrl!,
                message: overrides.freshInstallMessage,
              ),
        release: layout.releaseUrl,
      ),
    );

    var manifest = _publishManifestFor(
      config: config,
      layout: layout,
      metadata: metadata,
      artifactKind: packageResult.descriptor.artifact.kind,
      artifactRelativePath: _relativePublishPath(
        root: config.outputDirectory,
        file: packageResult.artifact,
      ),
      artifactSha256: packageResult.descriptor.artifact.sha256,
      artifactLength: packageResult.descriptor.artifact.length,
    );
    await manifest.writeTo(layout.manifestFile);

    await _runReleaseHooks(
      hooks: config.hooks.postPackage,
      phase: "postPackage",
      projectRoot: projectRoot,
      config: config,
      metadata: metadata,
      layout: layout,
      runHookCommand: runHookCommand,
      output: output,
    );

    if (platform == "macos" && config.macos.notarize) {
      final appBundleName =
          packageResult.descriptor.install.macosDmg?.appBundleName ??
          (metadata.appName.endsWith(".app")
              ? metadata.appName
              : "${metadata.appName}.app");
      await (macOSReleaseTrust ?? MacOSReleaseTrust(runProcess: runProcess))
          .auditFinalArtifact(
            artifact: packageResult.artifact,
            kind: packageResult.descriptor.artifact.kind,
            appBundleName: appBundleName,
            expectedApplicationIdentifier: metadata.packageId,
          );
      output.writeln("Final macOS distributable trust audit: verified locally");
    }

    final finalArtifactSha256 = await sha256File(packageResult.artifact);
    final finalArtifactLength = await packageResult.artifact.length();
    final finalDescriptor = _releaseDescriptorForFinalArtifact(
      packageResult.descriptor,
      artifactSha256: finalArtifactSha256,
      artifactLength: finalArtifactLength,
    );
    await _writeJsonFile(layout.releaseFile, finalDescriptor.toJson());
    if (signedHistory != null) {
      await _writeFrozenHistoryToAppArchive(
        archiveFile: layout.appArchiveFile,
        archiveAppName: archiveAppName,
        history: signedHistory,
      );
    }
    await upsertAppArchive(
      archiveFile: layout.appArchiveFile,
      appName: archiveAppName,
      supportPolicy: overrides.minimumSupportedVersion == null
          ? null
          : ReleaseSupportPolicy(
              minimumSupportedVersion: overrides.minimumSupportedVersion!,
              enforcedAfter: overrides.enforcedAfter!,
            ),
      item: ReleaseIndexItem(
        version: metadata.version,
        buildNumber: metadata.buildNumber,
        platform: platform,
        channel: config.channel,
        mandatory: overrides.mandatory,
        freshInstall: overrides.freshInstallUrl == null
            ? null
            : ReleaseFreshInstall(
                downloadUrl: overrides.freshInstallUrl!,
                message: overrides.freshInstallMessage,
              ),
        release: layout.releaseUrl,
      ),
    );
    manifest = _publishManifestFor(
      config: config,
      layout: layout,
      metadata: metadata,
      artifactKind: finalDescriptor.artifact.kind,
      artifactRelativePath: _relativePublishPath(
        root: config.outputDirectory,
        file: packageResult.artifact,
      ),
      artifactSha256: finalDescriptor.artifact.sha256,
      artifactLength: finalDescriptor.artifact.length,
    );
    await manifest.writeTo(layout.manifestFile);

    var publicationValidator = ReleaseValidator(isMacOSHost: isMacOSHost);
    if (signing != null) {
      final publicKeyId = signing.publicKeyId.trim();
      final keyPair = await Ed25519().newKeyPairFromSeed(
        base64Decode(signing.privateKeyBase64.trim()),
      );
      final publicKey = await keyPair.extractPublicKey();
      final publicKeys = signing.trustedReleasePublicKeys;
      final activePublicKey = publicKeys[publicKeyId];
      if (activePublicKey == null ||
          activePublicKey != base64Encode(publicKey.bytes)) {
        throw const FormatException(
          "Active signing key does not match the release key profile.",
        );
      }
      final strictArtifactVerifier = ArtifactVerifier(
        policy: ArtifactVerificationPolicy.requireEd25519Signature(
          publicKeys: publicKeys,
        ),
      );
      await ReleaseDescriptorSigner().sign(
        releaseFile: layout.releaseFile,
        publicKeyId: publicKeyId,
        privateKeyBase64: signing.privateKeyBase64,
      );
      final descriptor = ReleaseDescriptor.fromJson(
        jsonDecode(await layout.releaseFile.readAsString())
            as Map<String, dynamic>,
      );
      try {
        if (descriptor.signature?.publicKeyId != publicKeyId) {
          throw StateError("Final release.json signature verification failed.");
        }
        await strictArtifactVerifier.verifyDescriptor(descriptor);
      } on Object {
        throw StateError("Final release.json signature verification failed.");
      }

      await ReleaseIndexSigner().sign(
        appArchiveFile: layout.appArchiveFile,
        publicKeyId: publicKeyId,
        privateKeyBase64: signing.privateKeyBase64,
      );
      final signedIndex = ReleaseIndex.fromJson(
        jsonDecode(await layout.appArchiveFile.readAsString())
            as Map<String, dynamic>,
      );
      final indexSignatureVerifier = Ed25519ReleaseIndexSignatureVerifier(
        publicKeys,
      );
      final valid = await indexSignatureVerifier.verify(signedIndex);
      if (!valid) {
        throw StateError(
          "Final app-archive.json signature verification failed.",
        );
      }
      publicationValidator = ReleaseValidator(
        client: httpClient,
        artifactVerifier: strictArtifactVerifier,
        requireIndexSignature: true,
        indexSignatureVerifier: indexSignatureVerifier,
        isMacOSHost: isMacOSHost,
      );
      output.writeln("Signed final app-archive.json.");
    }

    if (signedHistory != null) {
      await _assertRemoteIndexRevisionUnchanged(
        appArchiveUrl: layout.appArchiveUrl,
        expectedRevision: signedHistory.revision,
        client: httpClient ?? http.Client(),
      );
    }
    await _uploadAndValidate(
      provider: _providerFor(config.uploadProvider),
      config: config.uploadProvider,
      localRoot: config.outputDirectory,
      manifest: manifest,
      validator: publicationValidator,
      output: output,
      expectedRevision:
          signedHistory?.revision ?? const RemoteIndexRevision.absent(),
      trustedReleasePublicKeys: signing?.trustedReleasePublicKeys,
    );

    return manifest;
  }
}

Future<void> _copyAdditionalFiles({
  required List<AdditionalReleaseFileConfig> additionalFiles,
  required Directory projectRoot,
  required ProjectMetadata metadata,
  required StringSink output,
}) async {
  final matchingFiles = additionalFiles
      .where((file) => file.appliesTo(metadata.platform))
      .toList(growable: false);
  if (matchingFiles.isEmpty) {
    return;
  }

  for (final additionalFile in matchingFiles) {
    final destination = _additionalFileDestination(
      appRoot: metadata.input,
      relativeDestination: additionalFile.destination,
    );
    final sources = await _additionalFileSources(
      projectRoot: projectRoot,
      source: additionalFile.source,
    );
    for (final source in sources) {
      output.writeln(
        "Adding release file: ${source.path} -> ${destination.path}",
      );
      await _copyAdditionalFileSource(source: source, destination: destination);
    }
  }
}

PublishManifest _publishManifestFor({
  required ReleasePublishConfig config,
  required PublishLayout layout,
  required ProjectMetadata metadata,
  required String artifactKind,
  required String artifactRelativePath,
  required String artifactSha256,
  required int artifactLength,
}) {
  return PublishManifest(
    schemaVersion: 1,
    baseUrl: config.baseUrl,
    localRoot: config.outputDirectory.path,
    appArchive: PublishManifestFile(
      path: layout.appArchiveRelativePath,
      url: layout.appArchiveUrl,
    ),
    release: PublishManifestRelease(
      version: metadata.version,
      buildNumber: metadata.buildNumber,
      platform: metadata.platform,
      channel: config.channel,
      path: layout.releaseRelativePath,
      url: layout.releaseUrl,
    ),
    artifact: PublishManifestArtifact(
      kind: artifactKind,
      path: artifactRelativePath,
      url: layout.artifactUrl,
      sha256: artifactSha256,
      length: artifactLength,
    ),
  );
}

ReleaseDescriptor _releaseDescriptorForFinalArtifact(
  ReleaseDescriptor descriptor, {
  required String artifactSha256,
  required int artifactLength,
}) {
  return ReleaseDescriptor(
    schemaVersion: descriptor.schemaVersion,
    packageId: descriptor.packageId,
    appName: descriptor.appName,
    version: descriptor.version,
    buildNumber: descriptor.buildNumber,
    platform: descriptor.platform,
    channel: descriptor.channel,
    artifact: ReleaseArtifact(
      kind: descriptor.artifact.kind,
      url: descriptor.artifact.url,
      sha256: artifactSha256,
      length: artifactLength,
    ),
    install: descriptor.install,
    minimumUpdaterVersion: descriptor.minimumUpdaterVersion,
    generatedAt: descriptor.generatedAt,
    minimumOS: descriptor.minimumOS,
    deltaArtifacts: descriptor.deltaArtifacts,
  )..validate();
}

Future<void> _writeJsonFile(File file, Map<String, dynamic> json) async {
  await file.writeAsString(
    "${const JsonEncoder.withIndent("  ").convert(json)}\n",
  );
}

Future<_SignedPublicationHistory> _acquireSignedPublicationHistory({
  required Directory projectRoot,
  required Uri appArchiveUrl,
  required ReleasePublishOverrides overrides,
  required ReleaseSigningOptions signing,
  required http.Client client,
}) async {
  final verifier = Ed25519ReleaseIndexSignatureVerifier(
    signing.trustedReleasePublicKeys,
  );
  final hosted = await _fetchHostedAppArchive(
    appArchiveUrl: appArchiveUrl,
    client: client,
    verifier: verifier,
  );
  if (overrides.initializeFeed && hosted != null) {
    throw const FormatException(
      "--initialize-feed can only be used when hosted app-archive.json is absent.",
    );
  }

  final existingFile = _resolveExistingAppArchive(
    projectRoot: projectRoot,
    value: overrides.existingAppArchive,
  );
  final local = existingFile == null
      ? null
      : await _readSignedAppArchiveFile(existingFile, verifier: verifier);

  if (hosted == null) {
    if (!overrides.initializeFeed) {
      throw const FormatException(
        "Signed publishing requires a hosted signed app-archive.json. "
        "Pass --initialize-feed only for a first feed publication.",
      );
    }
    return _SignedPublicationHistory(
      index: local?.index,
      revision: const RemoteIndexRevision.absent(),
    );
  }

  if (local != null && local.sha256 != hosted.revision.sha256) {
    throw const FormatException(
      "--existing-app-archive does not match the hosted app-archive.json bytes.",
    );
  }
  return _SignedPublicationHistory(
    index: hosted.index,
    revision: hosted.revision,
  );
}

Future<void> _assertRemoteIndexRevisionUnchanged({
  required Uri appArchiveUrl,
  required RemoteIndexRevision expectedRevision,
  required http.Client client,
}) async {
  final response = await client.get(appArchiveUrl);
  if (expectedRevision.absent) {
    if (response.statusCode == 404) {
      return;
    }
    throw StateError(
      "Hosted app-archive.json changed before publish: expected absent, "
      "got HTTP ${response.statusCode}.",
    );
  }
  if (response.statusCode != 200) {
    throw StateError(
      "Hosted app-archive.json changed before publish: expected "
      "$expectedRevision, got HTTP ${response.statusCode}.",
    );
  }
  final actualRevision = _revisionForResponse(response);
  if (actualRevision != expectedRevision) {
    throw StateError(
      "Hosted app-archive.json changed before publish: expected "
      "$expectedRevision, got $actualRevision.",
    );
  }
}

Future<void> _writeFrozenHistoryToAppArchive({
  required File archiveFile,
  required String archiveAppName,
  required _SignedPublicationHistory history,
}) async {
  await archiveFile.parent.create(recursive: true);
  final index =
      history.index ??
      ReleaseIndex(schemaVersion: 3, appName: archiveAppName, items: const []);
  await _writeJsonFile(
    archiveFile,
    {...index.toJson(), "signature": null}
      ..removeWhere((key, value) => value == null),
  );
}

Future<_HostedSignedAppArchive?> _fetchHostedAppArchive({
  required Uri appArchiveUrl,
  required http.Client client,
  required Ed25519ReleaseIndexSignatureVerifier verifier,
}) async {
  final response = await client.get(appArchiveUrl);
  if (response.statusCode == 404) {
    return null;
  }
  if (response.statusCode != 200) {
    throw HttpException(
      "GET $appArchiveUrl failed with HTTP ${response.statusCode}.",
      uri: appArchiveUrl,
    );
  }
  final index = await _parseAndVerifySignedAppArchiveBytes(
    response.bodyBytes,
    verifier: verifier,
  );
  return _HostedSignedAppArchive(
    index: index,
    revision: _revisionForResponse(response),
  );
}

Future<_LocalSignedAppArchive> _readSignedAppArchiveFile(
  File file, {
  required Ed25519ReleaseIndexSignatureVerifier verifier,
}) async {
  final bytes = await file.readAsBytes();
  final index = await _parseAndVerifySignedAppArchiveBytes(
    bytes,
    verifier: verifier,
  );
  return _LocalSignedAppArchive(index: index, sha256: _sha256Bytes(bytes));
}

Future<ReleaseIndex> _parseAndVerifySignedAppArchiveBytes(
  List<int> bytes, {
  required Ed25519ReleaseIndexSignatureVerifier verifier,
}) async {
  final json = jsonDecode(utf8.decode(bytes));
  if (json is! Map<String, dynamic>) {
    throw const FormatException("app-archive.json must be a JSON object.");
  }
  final index = ReleaseIndex.fromJson(json);
  if (!await verifier.verify(index)) {
    throw const FormatException(
      "Hosted app-archive.json signature verification failed.",
    );
  }
  return index;
}

File? _resolveExistingAppArchive({
  required Directory projectRoot,
  required String? value,
}) {
  if (value == null || value.trim().isEmpty) {
    return null;
  }
  final trimmed = value.trim();
  return File(
    path.isAbsolute(trimmed) ? trimmed : path.join(projectRoot.path, trimmed),
  );
}

RemoteIndexRevision _revisionForResponse(http.Response response) {
  return RemoteIndexRevision.present(
    sha256: _sha256Bytes(response.bodyBytes),
    etag: response.headers["etag"],
  );
}

String _sha256Bytes(List<int> bytes) => crypto.sha256.convert(bytes).toString();

final class _SignedPublicationHistory {
  const _SignedPublicationHistory({
    required this.index,
    required this.revision,
  });

  final ReleaseIndex? index;
  final RemoteIndexRevision revision;
}

final class _HostedSignedAppArchive {
  const _HostedSignedAppArchive({required this.index, required this.revision});

  final ReleaseIndex index;
  final RemoteIndexRevision revision;
}

final class _LocalSignedAppArchive {
  const _LocalSignedAppArchive({required this.index, required this.sha256});

  final ReleaseIndex index;
  final String sha256;
}

String _relativePublishPath({required Directory root, required File file}) {
  final rootPath = path.normalize(root.absolute.path);
  final filePath = path.normalize(file.absolute.path);
  if (!path.isWithin(rootPath, filePath)) {
    throw FileSystemException(
      "Published artifact must stay inside the output directory",
      file.path,
    );
  }
  return path.relative(filePath, from: rootPath).replaceAll(r"\", "/");
}

Directory _additionalFileDestination({
  required FileSystemEntity appRoot,
  required String relativeDestination,
}) {
  final destination = relativeDestination.trim();
  if (destination.isEmpty || path.isAbsolute(destination)) {
    throw const FormatException(
      "additionalFiles destination must be relative to the release app.",
    );
  }

  final appRootPath = path.normalize(appRoot.path);
  final targetPath = path.normalize(path.join(appRootPath, destination));
  if (!path.equals(targetPath, appRootPath) &&
      !path.isWithin(appRootPath, targetPath)) {
    throw const FormatException(
      "additionalFiles destination must stay inside the release app.",
    );
  }
  return Directory(targetPath);
}

Future<List<FileSystemEntity>> _additionalFileSources({
  required Directory projectRoot,
  required String source,
}) async {
  final sourcePattern = source.trim();
  if (sourcePattern.isEmpty) {
    throw const FormatException("additionalFiles source is required.");
  }

  final absolutePattern = path.normalize(
    path.isAbsolute(sourcePattern)
        ? sourcePattern
        : path.join(projectRoot.path, sourcePattern),
  );
  if (!_containsGlob(absolutePattern)) {
    final type = await FileSystemEntity.type(
      absolutePattern,
      followLinks: false,
    );
    if (type == FileSystemEntityType.notFound) {
      throw FileSystemException(
        "additionalFiles source does not exist",
        source,
      );
    }
    return [_entityForType(absolutePattern, type)];
  }

  final searchRoot = _globSearchRoot(absolutePattern);
  if (!await Directory(searchRoot).exists()) {
    throw FileSystemException(
      "additionalFiles source root does not exist",
      source,
    );
  }

  final matcher = _globRegExp(absolutePattern);
  final matches = <FileSystemEntity>[];
  await for (final entity in Directory(
    searchRoot,
  ).list(recursive: _globNeedsRecursive(absolutePattern), followLinks: false)) {
    if (matcher.hasMatch(path.normalize(entity.path))) {
      matches.add(entity);
    }
  }
  matches.sort((a, b) => a.path.compareTo(b.path));
  if (matches.isEmpty) {
    throw FileSystemException(
      "additionalFiles source matched no files",
      source,
    );
  }
  return matches;
}

FileSystemEntity _entityForType(String entityPath, FileSystemEntityType type) {
  if (type == FileSystemEntityType.file) {
    return File(entityPath);
  }
  if (type == FileSystemEntityType.directory) {
    return Directory(entityPath);
  }
  if (type == FileSystemEntityType.link) {
    return Link(entityPath);
  }
  return File(entityPath);
}

Future<void> _copyAdditionalFileSource({
  required FileSystemEntity source,
  required Directory destination,
}) async {
  final type = await FileSystemEntity.type(source.path, followLinks: false);
  if (type == FileSystemEntityType.link) {
    throw FileSystemException(
      "additionalFiles sources must not be symbolic links",
      source.path,
    );
  }
  if (type == FileSystemEntityType.file) {
    final target = File(
      path.join(destination.path, path.basename(source.path)),
    );
    await _copyFile(File(source.path), target);
    return;
  }
  if (type == FileSystemEntityType.directory) {
    final target = Directory(
      path.join(destination.path, path.basename(source.path)),
    );
    await _replaceExisting(target.path);
    await _copyDirectory(Directory(source.path), target);
    return;
  }
  throw FileSystemException(
    "additionalFiles source must be a file or directory",
    source.path,
  );
}

Future<void> _copyDirectory(Directory source, Directory target) async {
  await target.create(recursive: true);
  await _preserveMode(source, target);
  await for (final entity in source.list(followLinks: false)) {
    final type = await FileSystemEntity.type(entity.path, followLinks: false);
    final targetPath = path.join(target.path, path.basename(entity.path));
    if (type == FileSystemEntityType.file) {
      await _copyFile(File(entity.path), File(targetPath));
    } else if (type == FileSystemEntityType.directory) {
      await _copyDirectory(Directory(entity.path), Directory(targetPath));
    } else if (type == FileSystemEntityType.link) {
      throw FileSystemException(
        "additionalFiles sources must not contain symbolic links",
        entity.path,
      );
    } else {
      throw FileSystemException(
        "additionalFiles source must contain only files and directories",
        entity.path,
      );
    }
  }
}

Future<void> _copyFile(File source, File target) async {
  await _replaceExisting(target.path);
  await target.parent.create(recursive: true);
  await source.copy(target.path);
  await _preserveMode(source, target);
}

Future<void> _replaceExisting(String targetPath) async {
  final type = await FileSystemEntity.type(targetPath, followLinks: false);
  if (type == FileSystemEntityType.notFound) {
    return;
  }
  if (type == FileSystemEntityType.directory) {
    await Directory(targetPath).delete(recursive: true);
  } else if (type == FileSystemEntityType.link) {
    await Link(targetPath).delete();
  } else {
    await File(targetPath).delete();
  }
}

Future<void> _preserveMode(
  FileSystemEntity source,
  FileSystemEntity target,
) async {
  if (Platform.isWindows) {
    return;
  }
  final mode = (await source.stat()).mode & 0x1ff;
  final result = await Process.run("/bin/chmod", [
    mode.toRadixString(8),
    target.path,
  ]);
  if (result.exitCode != 0) {
    throw ProcessException(
      "/bin/chmod",
      [mode.toRadixString(8), target.path],
      "${result.stdout}\n${result.stderr}",
      result.exitCode,
    );
  }
}

bool _containsGlob(String value) => value.contains("*");

String _globSearchRoot(String pattern) {
  final parts = path.split(path.normalize(pattern));
  final rootParts = <String>[];
  for (final part in parts) {
    if (_containsGlob(part)) {
      break;
    }
    rootParts.add(part);
  }
  if (rootParts.isEmpty) {
    return Directory.current.path;
  }
  return path.joinAll(rootParts);
}

bool _globNeedsRecursive(String pattern) {
  if (pattern.contains("**")) {
    return true;
  }
  final root = _globSearchRoot(pattern);
  final relativePattern = path.relative(pattern, from: root);
  return path.split(relativePattern).length > 1;
}

RegExp _globRegExp(String pattern) {
  final separator = RegExp.escape(path.separator);
  final normalized = path.normalize(pattern);
  final buffer = StringBuffer("^");
  for (var i = 0; i < normalized.length; i += 1) {
    final char = normalized[i];
    if (char == "*") {
      if (i + 1 < normalized.length && normalized[i + 1] == "*") {
        buffer.write(".*");
        i += 1;
      } else {
        buffer.write("[^$separator]*");
      }
      continue;
    }
    buffer.write(RegExp.escape(char));
  }
  buffer.write(r"$");
  return RegExp(buffer.toString());
}

Future<void> _runReleaseHooks({
  required List<ReleaseHookConfig> hooks,
  required String phase,
  required Directory projectRoot,
  required ReleasePublishConfig config,
  required ProjectMetadata metadata,
  required PublishLayout layout,
  required ReleaseHookCommandRunner runHookCommand,
  required StringSink output,
}) async {
  for (final hook in hooks.where((hook) => hook.appliesTo(metadata.platform))) {
    output.writeln("Running $phase hook: ${hook.command}");
    final result = await runHookCommand(
      hook.command,
      environment: _releaseHookEnvironment(
        phase: phase,
        projectRoot: projectRoot,
        config: config,
        metadata: metadata,
        layout: layout,
      ),
    );
    if (result.stdout.toString().isNotEmpty) {
      output.write(result.stdout);
    }
    if (result.stderr.toString().isNotEmpty) {
      output.write(result.stderr);
    }
    if (result.exitCode != 0) {
      throw ProcessException(
        "release hook",
        [phase, hook.command],
        "${result.stdout}\n${result.stderr}",
        result.exitCode,
      );
    }
  }
}

Map<String, String> _releaseHookEnvironment({
  required String phase,
  required Directory projectRoot,
  required ReleasePublishConfig config,
  required ProjectMetadata metadata,
  required PublishLayout layout,
}) {
  return {
    ...Platform.environment,
    "DESKTOP_UPDATER_HOOK_PHASE": phase,
    "DESKTOP_UPDATER_PLATFORM": metadata.platform,
    "DESKTOP_UPDATER_PROJECT_ROOT": projectRoot.path,
    "DESKTOP_UPDATER_APP_PATH": metadata.input.path,
    "DESKTOP_UPDATER_BASE_URL": config.baseUrl.toString(),
    "DESKTOP_UPDATER_OUTPUT_ROOT": config.outputDirectory.path,
    "DESKTOP_UPDATER_CHANNEL": config.channel,
    "DESKTOP_UPDATER_APP_NAME": metadata.appName,
    "DESKTOP_UPDATER_PACKAGE_ID": metadata.packageId,
    "DESKTOP_UPDATER_VERSION": metadata.version,
    if (metadata.buildNumber != null)
      "DESKTOP_UPDATER_BUILD_NUMBER": metadata.buildNumber.toString(),
    "DESKTOP_UPDATER_PUBLISH_MANIFEST": layout.manifestFile.path,
    "DESKTOP_UPDATER_APP_ARCHIVE_FILE": layout.appArchiveFile.path,
    "DESKTOP_UPDATER_RELEASE_FILE": layout.releaseFile.path,
    "DESKTOP_UPDATER_ARTIFACT_FILE": layout.artifactFile.path,
    "DESKTOP_UPDATER_ARTIFACT_KIND": _artifactKindForPath(
      layout.artifactFile.path,
    ),
    "DESKTOP_UPDATER_APP_ARCHIVE_URL": layout.appArchiveUrl.toString(),
    "DESKTOP_UPDATER_RELEASE_URL": layout.releaseUrl.toString(),
    "DESKTOP_UPDATER_ARTIFACT_URL": layout.artifactUrl.toString(),
  };
}

Future<void> _notarizeMacOS({
  required FileSystemEntity app,
  required MacOSPublishConfig config,
  required ProcessRunner runProcess,
  required StringSink output,
  MacOSReleaseTrust? trust,
}) async {
  if (app is! Directory) {
    throw FileSystemException(
      "macOS notarization requires an .app directory",
      app.path,
    );
  }

  final effectiveTrust = trust ?? MacOSReleaseTrust(runProcess: runProcess);
  final inventory = await effectiveTrust.preflight(app: app);
  output.writeln("Signing macOS app...");
  await effectiveTrust.signAndVerify(
    inventory: inventory,
    identity: config.developerIdApplication!,
  );

  final tempDir = await Directory.systemTemp.createTemp(
    "desktop_updater_notary_",
  );
  try {
    final notaryZip = path.join(tempDir.path, "notary.zip");
    output.writeln("Creating macOS notarization archive...");
    await runDittoCreateZip(
      appPath: app.path,
      archivePath: notaryZip,
      runProcess: runProcess,
    );
    final preStapleSha256 = await sha256File(File(notaryZip));
    final preStapleLength = await File(notaryZip).length();
    output.writeln(
      "macOS app pre-staple notarization archive SHA-256: "
      "$preStapleSha256 (length=$preStapleLength)",
    );

    output.writeln("Submitting macOS app for notarization...");
    final submission = await effectiveTrust.submit(
      archive: File(notaryZip),
      profile: config.notaryProfile!,
      keychain: config.keychain,
    );
    output.writeln("macOS app notarization: Accepted (${submission.id})");
  } finally {
    await tempDir.delete(recursive: true);
  }

  output.writeln("Stapling macOS notarization ticket...");
  await effectiveTrust.stapleAndAssess(
    artifact: app,
    gatekeeperExecute: config.gatekeeperAssess,
    gatekeeperInstall: false,
  );
}

FileSystemEntity? _resolveManualArtifactRoot(
  Directory projectRoot,
  String? configuredPath,
) {
  final value = configuredPath?.trim();
  if (value == null || value.isEmpty) {
    return null;
  }
  final resolved = path.normalize(
    path.isAbsolute(value) ? value : path.join(projectRoot.path, value),
  );
  return switch (FileSystemEntity.typeSync(resolved, followLinks: false)) {
    FileSystemEntityType.file => File(resolved),
    FileSystemEntityType.link => Link(resolved),
    _ => Directory(resolved),
  };
}

/// Default shell runner for configured release hook commands.
Future<ProcessResult> defaultReleaseHookCommandRunner(
  String command, {
  required Map<String, String> environment,
}) {
  if (Platform.isWindows) {
    return _runWindowsReleaseHook(command, environment);
  }
  return Process.run("/bin/sh", ["-c", command], environment: environment);
}

Future<ProcessResult> _runWindowsReleaseHook(
  String command,
  Map<String, String> environment,
) async {
  final tempDir = await Directory.systemTemp.createTemp(
    "desktop_updater_hook_",
  );
  try {
    final script = File(path.join(tempDir.path, "hook.cmd"));
    await script.writeAsString("@echo off\r\n$command\r\n");
    return await Process.run("cmd", [
      "/d",
      "/e:on",
      "/v:off",
      "/c",
      script.path,
    ], environment: environment);
  } finally {
    await tempDir.delete(recursive: true);
  }
}

UploadProvider _providerFor(UploadConfig config) {
  if (config is ManualUploadConfig) {
    return const ManualUploadProvider();
  }
  if (config is S3UploadConfig) {
    return const S3UploadProvider();
  }
  if (config is SftpUploadConfig) {
    return const SftpUploadProvider();
  }
  if (config is FtpUploadConfig) {
    return const FtpUploadProvider();
  }
  if (config is CustomCommandUploadConfig) {
    return const CustomCommandUploadProvider();
  }
  throw FormatException(
    "Upload provider ${config.providerName} is not implemented yet.",
  );
}

Future<void> _uploadAndValidate({
  required UploadProvider provider,
  required UploadConfig config,
  required Directory localRoot,
  required PublishManifest manifest,
  required ReleaseValidator validator,
  required StringSink output,
  required RemoteIndexRevision expectedRevision,
  required Map<String, String>? trustedReleasePublicKeys,
}) async {
  if (config is ManualUploadConfig) {
    await validator.validateLocalReleaseFiles(
      localRoot: localRoot,
      manifest: manifest,
      output: output,
    );
    output
      ..writeln()
      ..writeln(
        validator.requireIndexSignature
            ? "Signed manual publication package: ready for upload."
            : "Candidate-only manual publication package: signatures are not "
                  "required.",
      )
      ..writeln("Frozen hosted app-archive revision: $expectedRevision")
      ..writeln(
        trustedReleasePublicKeys == null
            ? "Trusted release public-key map: not configured (candidate-only)."
            : "Trusted release public-key map: "
                  "${jsonEncode(trustedReleasePublicKeys)}",
      )
      ..writeln(
        "Upload release.json and artifacts first; publish app-archive.json "
        "last using the frozen revision above.",
      );
    await provider.upload(
      localRoot: localRoot,
      manifest: manifest,
      config: config,
      output: output,
    );
    return;
  }

  if (provider is OrderedUploadProvider) {
    output.writeln("Uploading versioned files...");
    await provider.uploadVersionedFiles(
      localRoot: localRoot,
      manifest: manifest,
      config: config,
      output: output,
    );
    output.writeln("Validating hosted release descriptor...");
    await validator.validateReleaseFiles(manifest: manifest, output: output);
    output.writeln("Publishing app-archive.json last...");
    final receipt = await provider.uploadAppArchive(
      localRoot: localRoot,
      manifest: manifest,
      config: config,
      output: output,
      expectedRevision: expectedRevision,
    );
    final localIndexSha256 = await sha256File(
      File(path.join(localRoot.path, manifest.appArchive.path)),
    );
    if (receipt.observedPriorRevision != expectedRevision) {
      throw StateError(
        "Upload provider observed a different app-archive.json revision.",
      );
    }
    if (receipt.publishedSha256 != localIndexSha256) {
      throw StateError(
        "Upload provider published a different app-archive.json digest.",
      );
    }
  } else {
    throw const FormatException(
      "Automatic upload providers must publish versioned files first and "
      "return an ordered app-archive.json receipt.",
    );
  }

  output.writeln("Validating hosted update selection...");
  await validator.validate(
    manifestFile: File(
      path.join(localRoot.path, ".desktop_updater_publish.json"),
    ),
    fromVersion: null,
    output: output,
  );
  output
    ..writeln()
    ..writeln("OK: Published and validated.")
    ..writeln()
    ..writeln("App archive:")
    ..writeln(manifest.appArchive.url)
    ..writeln()
    ..writeln("Release:")
    ..writeln(manifest.release.url)
    ..writeln()
    ..writeln("Artifact:")
    ..writeln(manifest.artifact.url);
}

String _artifactNameStem(String appName) {
  var stem = path.basename(appName);
  if (stem.endsWith(".app")) {
    stem = stem.substring(0, stem.length - ".app".length);
  }
  if (stem.endsWith(".exe")) {
    stem = stem.substring(0, stem.length - ".exe".length);
  }
  return stem;
}

String _artifactKindForPath(String artifactPath) {
  if (artifactPath.endsWith(".exe")) {
    return "innoInstaller";
  }
  if (artifactPath.endsWith(".dmg")) {
    return "dmg";
  }
  if (artifactPath.endsWith(".pkg")) {
    return "pkgInstaller";
  }
  return "zip";
}
