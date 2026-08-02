// ignore_for_file: depend_on_referenced_packages

import "dart:async";
import "dart:convert";
import "dart:io";

import "package:archive/archive.dart";
import "package:crypto/crypto.dart" as crypto;
import "package:cryptography_plus/cryptography_plus.dart";
// The direct Windows and Linux helper smokes write the same schema-v3 signed
// release descriptor the native helper consumes after public staging runs.
// ignore: implementation_imports
import "package:desktop_updater/src/core/release_descriptor.dart";
// The direct helper smoke intentionally exercises the package's internal
// provenance handoff instead of expanding the released Flutter API.
// ignore: implementation_imports
import "package:desktop_updater/src/core/staged_update_provenance.dart";

const _smokePackageId = "com.example.desktop_updater";
const _smokeStageNonce = "123e4567-e89b-42d3-a456-426614174000";
const _smokePublicKeyId = "native-runtime-smoke-stable";
const _smokeDescriptorSha256 =
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const _smokeArtifactSha256 =
    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const _artifactFileName = ".desktop_updater_artifact.zip";
const _releaseManifestFileName = ".desktop_updater_release_manifest.json";
const _installedIdentityFileName = ".desktop_updater_install_identity.json";
const _installedIdentity =
    '{"packageId":"com.example.desktop_updater","schemaVersion":1}';
const _defaultInitialAppExitTimeout = Duration(seconds: 30);
const _windowsInitialAppExitTimeout = Duration(seconds: 60);
const _windowsExternalRelaunchCleanupEnvironment =
    "DESKTOP_UPDATER_SMOKE_EXTERNAL_RELAUNCH_CLEANUP";
final _windowsPathSeparator = String.fromCharCode(92);
const _windowsHelperEventNames = <int, String>{
  1000: "helper scheduled",
  1001: "waiting for parent process",
  1002: "parent process exited",
  1003: "staging path validation",
  1004: "backup start",
  1005: "backup success",
  1006: "backup failure",
  1007: "move start",
  1008: "move success",
  1009: "move failure",
  1010: "rollback start",
  1011: "rollback success",
  1012: "rollback failure",
  1013: "cleanup start",
  1014: "cleanup success",
  1015: "cleanup failure",
  1016: "relaunch attempt",
};

class _NativeTargetContext {
  const _NativeTargetContext({
    required this.installRoot,
    required this.executableRelativePath,
  });

  final String installRoot;
  final String executableRelativePath;
}

class _PreparedLinuxXauthority {
  const _PreparedLinuxXauthority(this.path, {required this.shouldDelete});

  final String path;
  final bool shouldDelete;

  Future<void> dispose() async {
    if (!shouldDelete) {
      return;
    }
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    } on FileSystemException {
      // Best-effort cleanup for a throwaway smoke-test auth copy.
    }
  }
}

Future<void> main(List<String> args) async {
  final relaunch = args.contains("--relaunch");
  final productionGates = args.contains("--production-gates");
  final config = _argValue(args, "--config") ?? "Debug";
  if (config != "Debug" && config != "Release") {
    stderr.writeln("--config must be Debug or Release.");
    _usage();
    exit(64);
  }

  final appPath =
      _absolutePath(_argValue(args, "--app") ?? _defaultAppPath(config));
  final stagedAppPath = _absolutePath(_argValue(args, "--staged-app"));

  if (appPath == null) {
    _usage();
    exit(64);
  }

  if (Platform.isMacOS && productionGates && stagedAppPath == null) {
    stderr.writeln(
      "--production-gates requires --staged-app with a signed, notarized, "
      "stapled .app that already contains the smoke sentinel.",
    );
    _usage();
    exit(64);
  }

  final executablePath = _executablePath(appPath);
  final installRoot = _installRoot(appPath);

  if (!File(executablePath).existsSync()) {
    stderr.writeln("Executable not found: $executablePath");
    _usage();
    exit(66);
  }

  final nativeTargetContext = Platform.isWindows || Platform.isLinux
      ? _nativeTargetContext(executablePath)
      : null;
  final effectiveInstallRoot = nativeTargetContext?.installRoot ?? installRoot;

  if (Platform.isWindows || Platform.isLinux) {
    await File(
      _join(effectiveInstallRoot, _installedIdentityFileName),
    ).writeAsString(_installedIdentity, flush: true);
  }

  final tempRoot = await Directory.systemTemp.createTemp(
    "desktop_updater_smoke_",
  );
  final ownedStageRoot = await createOwnedStagingDirectory(
    parent: tempRoot,
    nonce: _smokeStageNonce,
  );
  final stagingRoot = await _prepareStagingRoot(
    appPath: appPath,
    stagedAppPath: stagedAppPath,
    stageParent: ownedStageRoot,
  );
  final markerPath = _join(tempRoot.path, "marker.txt");
  final diagnosticsLogPath =
      _absolutePath(_argValue(args, "--diagnostics-log")) ??
          _join(tempRoot.path, "helper-diagnostics.jsonl");
  final diagnosticsLog = File(diagnosticsLogPath);
  await diagnosticsLog.parent.create(recursive: true);
  if (await diagnosticsLog.exists()) {
    await diagnosticsLog.delete();
  }
  final linuxStateHome =
      Platform.isLinux ? Directory(_join(tempRoot.path, "state")) : null;
  if (linuxStateHome != null) {
    await linuxStateHome.create();
    await _chmod(linuxStateHome.path, "700");
  }
  final sentinelRelativePath = Platform.isMacOS
      ? _join("Resources", "desktop_updater_smoke.txt")
      : "desktop_updater_smoke.txt";
  final stagedSentinel = File(
    _join(_stagingContentRoot(stagingRoot.path), sentinelRelativePath),
  );
  final installedSentinel =
      File(_join(effectiveInstallRoot, sentinelRelativePath));

  if (installedSentinel.existsSync()) {
    if (productionGates) {
      stderr.writeln(
        "Installed app already contains ${installedSentinel.path}; refusing "
        "to mutate a production-gates app before the update.",
      );
      exit(65);
    }
    installedSentinel.deleteSync();
  }

  if (productionGates) {
    if (!stagedSentinel.existsSync()) {
      stderr.writeln(
        "Production staged app must already contain ${stagedSentinel.path} "
        "before signing, notarization, and stapling.",
      );
      exit(66);
    }
  } else {
    await stagedSentinel.parent.create(recursive: true);
    await stagedSentinel.writeAsString(
      "desktop_updater smoke ${DateTime.now().toIso8601String()}",
    );
  }

  final nativeStageControl = Platform.isLinux
      ? await _writeLinuxNativeStageControl(
          installRoot: effectiveInstallRoot,
          stagingRoot: stagingRoot.path,
          executablePath: executablePath,
        )
      : Platform.isWindows
          ? await _writeWindowsNativeStageControl(
              installRoot: effectiveInstallRoot,
              stagingRoot: stagingRoot.path,
              executablePath: executablePath,
            )
          : null;

  final provenance = await writeStagedUpdateProvenance(
    stageRoot: ownedStageRoot,
    nonce: _smokeStageNonce,
    packageId: _smokePackageId,
    descriptorSha256:
        nativeStageControl?.descriptorSha256 ?? _smokeDescriptorSha256,
    artifactSha256: nativeStageControl?.artifactSha256 ?? _smokeArtifactSha256,
  );

  final linuxXauthority =
      Platform.isLinux ? await _prepareLinuxRelaunchXauthority() : null;
  final helperEventStart = DateTime.now().toUtc().subtract(
        const Duration(seconds: 1),
      );
  try {
    stdout
      ..writeln("Launching $executablePath")
      ..writeln("Staging update in ${stagingRoot.path}");

    final process = await Process.start(
      executablePath,
      const [],
      environment: {
        "DESKTOP_UPDATER_SMOKE_STAGING": stagingRoot.path,
        "DESKTOP_UPDATER_SMOKE_MARKER": markerPath,
        "DESKTOP_UPDATER_SMOKE_DIAGNOSTICS_LOG": diagnosticsLogPath,
        "DESKTOP_UPDATER_SMOKE_PACKAGE_ID": _smokePackageId,
        "DESKTOP_UPDATER_SMOKE_PROVENANCE_SHA256": provenance.markerSha256,
        if (nativeTargetContext != null) ...{
          "DESKTOP_UPDATER_SMOKE_INSTALL_ROOT": nativeTargetContext.installRoot,
          "DESKTOP_UPDATER_SMOKE_EXECUTABLE_RELATIVE_PATH":
              nativeTargetContext.executableRelativePath,
        },
        if (linuxStateHome != null) "XDG_STATE_HOME": linuxStateHome.path,
        if (linuxXauthority != null) "XAUTHORITY": linuxXauthority.path,
        if (!relaunch) "DESKTOP_UPDATER_SMOKE_SKIP_RELAUNCH": "1",
        if (Platform.isMacOS && !productionGates)
          "DESKTOP_UPDATER_SMOKE_ALLOW_UNSIGNED_MACOS": "1",
      },
      mode: ProcessStartMode.normal,
      workingDirectory: File(executablePath).parent.path,
    );

    final stdoutSubscription = process.stdout.listen(stdout.add);
    final stderrSubscription = process.stderr.listen(stderr.add);

    await _waitForFileText(
      markerPath,
      "installing",
      const Duration(seconds: 15),
    );
    stdout.writeln("App scheduled native installation and is closing...");

    final initialAppExitTimeout = Platform.isWindows
        ? _windowsInitialAppExitTimeout
        : _defaultInitialAppExitTimeout;
    final exitCode = await process.exitCode.timeout(
      initialAppExitTimeout,
      onTimeout: () {
        process.kill();
        throw TimeoutException("App did not exit after scheduling update.");
      },
    );

    stdout.writeln("Initial app process exited with code $exitCode");
    await stdoutSubscription.cancel();
    await stderrSubscription.cancel();

    await _waitFor(
      installedSentinel.existsSync,
      const Duration(seconds: 45),
      "Timed out waiting for staged file to be copied into "
      "$effectiveInstallRoot",
    );

    if (Platform.isLinux && linuxStateHome != null) {
      await _expectLinuxTransactionEvents(
        stateHome: linuxStateHome,
        diagnosticsLogPath: diagnosticsLogPath,
        expectedEvents: const <String>[
          "activation verified",
          "transaction completed",
        ],
      );
    } else {
      await _waitFor(
        () => !stagingRoot.existsSync(),
        const Duration(seconds: 10),
        "Timed out waiting for staging directory cleanup.",
      );

      if (Platform.isWindows) {
        if (!relaunch) {
          await _closeWindowsSmokeRelaunch(executablePath);
        }
        await _writeWindowsHelperEventDiagnostics(
          diagnosticsLogPath: diagnosticsLogPath,
          eventStart: helperEventStart,
        );
      }

      await _expectDiagnosticsLog(
        diagnosticsLogPath,
        const <String>[
          "helper scheduled",
          "backup start",
          "move start",
          "cleanup success",
        ],
      );
    }

    stdout
      ..writeln("Smoke update installed: ${installedSentinel.path}")
      ..writeln("Helper diagnostics log: $diagnosticsLogPath")
      ..writeln(
        relaunch
            ? "Relaunch was enabled; close the relaunched example app manually."
            : "Relaunch was skipped for test cleanup. Pass --relaunch to test it.",
      );
  } finally {
    if (linuxXauthority != null) {
      await linuxXauthority.dispose();
    }
  }
}

String? _defaultAppPath(String config) {
  if (Platform.isMacOS) {
    return _joinAll([
      "build",
      "macos",
      "Build",
      "Products",
      config,
      "desktop_updater_example.app",
    ]);
  }

  if (Platform.isWindows) {
    return _joinAll([
      "build",
      "windows",
      "x64",
      "runner",
      config,
      "desktop_updater_example.exe",
    ]);
  }

  if (Platform.isLinux) {
    return _joinAll([
      "build",
      "linux",
      "x64",
      config.toLowerCase(),
      "bundle",
      "desktop_updater_example",
    ]);
  }

  return null;
}

String _executablePath(String appPath) {
  if (Platform.isMacOS && appPath.endsWith(".app")) {
    return _joinAll([appPath, "Contents", "MacOS", "desktop_updater_example"]);
  }

  return appPath;
}

String _installRoot(String appPath) {
  if (Platform.isMacOS && appPath.endsWith(".app")) {
    return _join(appPath, "Contents");
  }

  return File(appPath).parent.path;
}

_NativeTargetContext _nativeTargetContext(String executablePath) {
  final canonicalExecutable = File(executablePath).resolveSymbolicLinksSync();
  final installRoot = Directory(File(canonicalExecutable).parent.path)
      .resolveSymbolicLinksSync();
  return _NativeTargetContext(
    installRoot: installRoot,
    executableRelativePath: _basename(canonicalExecutable),
  );
}

Future<Directory> _prepareStagingRoot({
  required String appPath,
  required String? stagedAppPath,
  required Directory stageParent,
}) async {
  if (!Platform.isMacOS) {
    await _copyInstallTree(
      sourceRoot: Directory(_installRoot(appPath)),
      destinationRoot: stageParent,
    );
    return stageParent;
  }
  final sourceAppPath = stagedAppPath ?? appPath;
  final stagedApp =
      Directory(_join(stageParent.path, _basename(sourceAppPath)));
  final result = await Process.run("/usr/bin/ditto", [
    sourceAppPath,
    stagedApp.path,
  ]);
  if (result.exitCode != 0) {
    throw ProcessException(
      "/usr/bin/ditto",
      [appPath, stagedApp.path],
      "${result.stdout}${result.stderr}",
      result.exitCode,
    );
  }

  await File(
    _join(stageParent.path, ".desktop_updater_release_manifest.json"),
  ).writeAsString("{}");
  return stagedApp;
}

Future<void> _copyInstallTree({
  required Directory sourceRoot,
  required Directory destinationRoot,
}) async {
  late final String executable;
  late final List<String> arguments;
  if (Platform.isWindows) {
    executable = "robocopy";
    arguments = [
      sourceRoot.path,
      destinationRoot.path,
      "/E",
      "/COPY:DAT",
      "/DCOPY:DAT",
      "/R:0",
      "/W:0",
    ];
  } else {
    executable = "/bin/cp";
    arguments = ["-a", "${sourceRoot.path}/.", destinationRoot.path];
  }
  final result = await Process.run(executable, arguments);
  final succeeded = Platform.isWindows
      ? result.exitCode >= 0 && result.exitCode < 8
      : result.exitCode == 0;
  if (!succeeded) {
    throw ProcessException(
      executable,
      arguments,
      "${result.stdout}${result.stderr}",
      result.exitCode,
    );
  }
}

class _NativeStageControl {
  const _NativeStageControl({
    required this.descriptorSha256,
    required this.artifactSha256,
  });

  final String descriptorSha256;
  final String artifactSha256;
}

Future<_NativeStageControl> _writeLinuxNativeStageControl({
  required String installRoot,
  required String stagingRoot,
  required String executablePath,
}) async {
  final helperPath = _locateLinuxPortableHelper(installRoot);
  final helperRelativePath = _relativePathUnderRoot(helperPath, installRoot);
  final stagedHelperPath = _join(stagingRoot, helperRelativePath);
  if (!await File(stagedHelperPath).exists()) {
    throw StateError("Staged Linux helper not found: $stagedHelperPath");
  }
  for (final helper in [File(helperPath), File(stagedHelperPath)]) {
    await _chmod(helper.parent.path, "755");
    await _chmod(helper.path, "755");
  }

  final publicKey = await _smokeKeyPair().then(
    (keyPair) => keyPair.extractPublicKey(),
  );
  final policy = _canonicalJson({
    "allowedApplicationSigner": {
      "kind": "sha256",
      "value": await _sha256File(File(executablePath)),
    },
    "allowedHelperSigner": {
      "kind": "sha256",
      "value": await _sha256File(File(helperPath)),
    },
    "allowedInstallRoots": <Object?>[],
    "allowedStrategies": [
      {
        "provider": "platformDirectory",
        "strategy": "directoryReplace",
      },
    ],
    "allowedTargetClasses": ["sameUserWritable"],
    "applicationPackageId": _smokePackageId,
    "helperServiceId": "com.example.desktop-updater.helper",
    "minimumHelperProtocolVersion": 1,
    "policyId": "com.example.desktop-updater.portable",
    "policyVersion": 1,
    "releaseRootPublicKeys": [
      {
        "algorithm": "ed25519",
        "keyId": _smokePublicKeyId,
        "publicKeyBase64": base64Encode(publicKey.bytes),
      },
    ],
  });

  for (final policyFile in [
    File(
      _join(
        File(helperPath).parent.path,
        "desktop-updater-helper.policy.json",
      ),
    ),
    File(
      _join(
        File(stagedHelperPath).parent.path,
        "desktop-updater-helper.policy.json",
      ),
    ),
  ]) {
    await policyFile.writeAsString(policy, flush: true);
    await _chmod(policyFile.path, "600");
  }

  return _writeSignedNativeStageControl(
    stagingRoot: stagingRoot,
    platform: "linux",
    minimumOS: "glibc-2.35",
  );
}

Future<_NativeStageControl> _writeWindowsNativeStageControl({
  required String installRoot,
  required String stagingRoot,
  required String executablePath,
}) async {
  await _writeWindowsPortableHelperPolicy(
    installRoot: installRoot,
    stagingRoot: stagingRoot,
    executablePath: executablePath,
  );
  return _writeSignedNativeStageControl(
    stagingRoot: stagingRoot,
    platform: "windows",
    minimumOS: "10.0.19045",
  );
}

Future<void> _writeWindowsPortableHelperPolicy({
  required String installRoot,
  required String stagingRoot,
  required String executablePath,
}) async {
  final executable = File(executablePath);
  final helperPath = _join(
    installRoot,
    "desktop_updater_install_helper.exe",
  );
  final helper = File(helperPath);
  if (!await helper.exists()) {
    throw StateError(
        "Packaged Windows install helper is unavailable: $helperPath");
  }
  final stagedHelperPath = _join(
    stagingRoot,
    _relativePathUnderRoot(helperPath, installRoot),
  );
  if (!await File(stagedHelperPath).exists()) {
    throw StateError(
      "Staged Windows install helper is unavailable: $stagedHelperPath",
    );
  }
  final publicKey = await (await _smokeKeyPair()).extractPublicKey();
  final policy = _canonicalJson({
    "allowedApplicationSigner": {
      "kind": "sha256",
      "value": await _sha256File(executable),
    },
    "allowedHelperSigner": {
      "kind": "sha256",
      "value": await _sha256File(helper),
    },
    "allowedInstallRoots": <Object?>[],
    "allowedStrategies": [
      {
        "provider": "platformDirectory",
        "strategy": "directoryReplace",
      },
      {
        "provider": "platformFile",
        "strategy": "singleFileReplace",
      },
    ],
    "allowedTargetClasses": ["sameUserWritable"],
    "applicationPackageId": _smokePackageId,
    "helperServiceId": "com.example.desktop-updater.helper",
    "minimumHelperProtocolVersion": 1,
    "policyId": "com.example.desktop-updater.portable",
    "policyVersion": 1,
    "releaseRootPublicKeys": [
      {
        "algorithm": "ed25519",
        "keyId": _smokePublicKeyId,
        "publicKeyBase64": base64Encode(publicKey.bytes),
      },
    ],
  });
  final policyPaths = <String>{
    _join(installRoot, "desktop_updater_helper_policy.json"),
    _join(stagingRoot, "desktop_updater_helper_policy.json"),
  };
  for (final policyPath in policyPaths) {
    await File(policyPath).writeAsString(policy, flush: true);
  }
}

Future<_NativeStageControl> _writeSignedNativeStageControl({
  required String stagingRoot,
  required String platform,
  required String minimumOS,
}) async {
  final artifact = File(_join(stagingRoot, _artifactFileName));
  await _writeNativeArtifactZip(stagingRoot: stagingRoot, artifact: artifact);
  if (Platform.isLinux) {
    await _chmod(artifact.path, "600");
  }

  final artifactBytes = await artifact.readAsBytes();
  final artifactSha256 = crypto.sha256.convert(artifactBytes).toString();
  final descriptor = ReleaseDescriptor(
    schemaVersion: 3,
    packageId: _smokePackageId,
    appName: "desktop_updater smoke",
    version: "2.7.1",
    buildNumber: 271,
    platform: platform,
    channel: "stable",
    artifact: ReleaseArtifact(
      kind: "zip",
      url: Uri.parse("https://example.invalid/desktop-updater-smoke.zip"),
      sha256: artifactSha256,
      length: artifactBytes.length,
    ),
    install: const ReleaseInstall(strategy: "wholeDirectoryReplace"),
    signature: const ReleaseSignature(
      algorithm: "ed25519",
      publicKeyId: _smokePublicKeyId,
      value: "",
    ),
    minimumUpdaterVersion: "2.0.0",
    minimumOS: {platform: minimumOS},
    generatedAt: DateTime.utc(2026),
  )..validate();
  final signature = await Ed25519().sign(
    descriptor.canonicalSignatureBytes(),
    keyPair: await _smokeKeyPair(),
  );
  final signedDescriptor = ReleaseDescriptor(
    schemaVersion: descriptor.schemaVersion,
    packageId: descriptor.packageId,
    appName: descriptor.appName,
    version: descriptor.version,
    buildNumber: descriptor.buildNumber,
    platform: descriptor.platform,
    channel: descriptor.channel,
    artifact: descriptor.artifact,
    install: descriptor.install,
    signature: ReleaseSignature(
      algorithm: "ed25519",
      publicKeyId: _smokePublicKeyId,
      value: base64Encode(signature.bytes),
    ),
    minimumUpdaterVersion: descriptor.minimumUpdaterVersion,
    minimumOS: descriptor.minimumOS,
    generatedAt: descriptor.generatedAt,
  )..validate();
  final manifestBytes = utf8.encode(_canonicalJson(signedDescriptor.toJson()));
  await File(_join(stagingRoot, _releaseManifestFileName)).writeAsBytes(
    manifestBytes,
    flush: true,
  );

  return _NativeStageControl(
    descriptorSha256: crypto.sha256.convert(manifestBytes).toString(),
    artifactSha256: artifactSha256,
  );
}

Future<void> _writeNativeArtifactZip({
  required String stagingRoot,
  required File artifact,
}) async {
  final archive = Archive();
  final files = <File>[];
  await for (final entity in Directory(stagingRoot).list(
    recursive: true,
    followLinks: false,
  )) {
    if (entity is! File) {
      continue;
    }
    final relativePath = _relativePathUnderRoot(entity.path, stagingRoot);
    if (_isNativeStageControlPath(relativePath)) {
      continue;
    }
    files.add(entity);
  }
  files.sort((left, right) {
    return _relativePathUnderRoot(left.path, stagingRoot)
        .compareTo(_relativePathUnderRoot(right.path, stagingRoot));
  });
  for (final file in files) {
    final relativePath = _relativePathUnderRoot(
      file.path,
      stagingRoot,
    ).replaceAll(_windowsPathSeparator, "/");
    final mode = (await file.stat()).mode;
    final entry = ArchiveFile.bytes(relativePath, await file.readAsBytes())
      ..mode = mode;
    archive.addFile(entry);
  }
  await artifact.writeAsBytes(ZipEncoder().encode(archive), flush: true);
}

bool _isNativeStageControlPath(String relativePath) {
  final normalized = relativePath.replaceAll(_windowsPathSeparator, "/");
  return normalized == _artifactFileName ||
      normalized == _releaseManifestFileName ||
      normalized == ".desktop_updater_stage_provenance.json" ||
      normalized == ".desktop_updater_payload_seal.json";
}

String _locateLinuxPortableHelper(String installRoot) {
  final candidates = [
    _joinAll([installRoot, "lib", "desktop-updater-helper"]),
    _join(installRoot, "desktop-updater-helper"),
  ];
  if (_basename(installRoot) == "bin") {
    candidates.add(
      _joinAll([
        Directory(installRoot).parent.path,
        "libexec",
        "desktop-updater-helper",
      ]),
    );
  }
  for (final candidate in candidates) {
    if (File(candidate).existsSync()) {
      return File(candidate).resolveSymbolicLinksSync();
    }
  }
  throw StateError("Packaged Linux install helper is unavailable.");
}

String _relativePathUnderRoot(String path, String root) {
  final rootWithSeparator = root.endsWith(Platform.pathSeparator)
      ? root
      : "$root${Platform.pathSeparator}";
  if (!path.startsWith(rootWithSeparator)) {
    throw StateError("$path is outside $root");
  }
  return path.substring(rootWithSeparator.length);
}

String _canonicalJson(Object? value) {
  return jsonEncode(sortJsonValue(value));
}

Future<String> _sha256File(File file) async {
  return crypto.sha256.bind(file.openRead()).first.then((digest) {
    return digest.toString();
  });
}

Future<void> _chmod(String path, String mode) async {
  final result = await Process.run("/bin/chmod", [mode, path]);
  if (result.exitCode != 0) {
    throw ProcessException(
      "/bin/chmod",
      [mode, path],
      "${result.stdout}${result.stderr}",
      result.exitCode,
    );
  }
}

Future<_PreparedLinuxXauthority?> _prepareLinuxRelaunchXauthority() async {
  final sourcePath = Platform.environment["XAUTHORITY"];
  if (sourcePath == null || sourcePath.isEmpty) {
    return null;
  }
  final source = File(sourcePath);
  if (!await source.exists()) {
    return null;
  }
  final home = Platform.environment["HOME"];
  if (home == null || home.isEmpty) {
    return null;
  }
  final homeRoot = Directory(home).absolute.path;
  final directory = Directory(_join(homeRoot, ".desktop_updater_smoke"));
  await directory.create(recursive: true);
  await _chmod(directory.path, "700");
  final target = File(
    _join(
      directory.path,
      "xauthority-$pid-${DateTime.now().microsecondsSinceEpoch}",
    ),
  );
  await target.writeAsBytes(await source.readAsBytes(), flush: true);
  await _chmod(target.path, "600");
  return _PreparedLinuxXauthority(target.path, shouldDelete: true);
}

Future<SimpleKeyPair> _smokeKeyPair() {
  return Ed25519().newKeyPairFromSeed(
    List<int>.generate(32, (index) => 255 - index),
  );
}

String _stagingContentRoot(String stagingPath) {
  if (Platform.isMacOS && stagingPath.endsWith(".app")) {
    return _join(stagingPath, "Contents");
  }
  return stagingPath;
}

Future<void> _waitForFileText(
  String filePath,
  String expected,
  Duration timeout,
) async {
  await _waitFor(
    () =>
        File(filePath).existsSync() &&
        File(filePath).readAsStringSync().trim() == expected,
    timeout,
    "Timed out waiting for smoke marker '$expected'.",
  );
}

Future<void> _waitFor(
  bool Function() condition,
  Duration timeout,
  String timeoutMessage,
) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  throw TimeoutException(timeoutMessage);
}

Future<void> _expectLinuxTransactionEvents({
  required Directory stateHome,
  required String diagnosticsLogPath,
  required List<String> expectedEvents,
}) async {
  final eventsLog = File(
    _joinAll([
      stateHome.path,
      "desktop-updater",
      "transactions",
      "events.jsonl",
    ]),
  );

  await _waitFor(
    () {
      if (!eventsLog.existsSync()) {
        return false;
      }
      final contents = eventsLog.readAsStringSync();
      return expectedEvents.every(
        (event) => contents.contains('"event":"$event"'),
      );
    },
    const Duration(seconds: 30),
    "Timed out waiting for Linux transaction events at ${eventsLog.path}.",
  );

  await File(diagnosticsLogPath).writeAsString(
    await eventsLog.readAsString(),
    flush: true,
  );
}

Future<void> _writeWindowsHelperEventDiagnostics({
  required String diagnosticsLogPath,
  required DateTime eventStart,
}) async {
  final start = _powershellSingleQuoted(eventStart.toIso8601String());
  final command = """
\$eventStart = [DateTime]::Parse('$start').ToLocalTime()
\$events = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; StartTime = \$eventStart } -ErrorAction Stop |
  Where-Object { \$_.ProviderName -eq 'DesktopUpdater.InstallHelper.ProtocolV1' } |
  Sort-Object TimeCreated, RecordId |
  Select-Object -First 128 |
  ForEach-Object {
    [PSCustomObject]@{
      id = \$_.Id
      timestampUtc = \$_.TimeCreated.ToUniversalTime().ToString('o')
    }
  })
\$events | ConvertTo-Json -Compress -Depth 3
""";
  final result = await Process.run(
    "powershell.exe",
    <String>[
      "-NoLogo",
      "-NoProfile",
      "-NonInteractive",
      "-Command",
      command,
    ],
    runInShell: false,
  );
  if (result.exitCode != 0) {
    throw ProcessException(
      "powershell.exe",
      const <String>["Get-WinEvent"],
      "${result.stdout}${result.stderr}",
      result.exitCode,
    );
  }

  final output = result.stdout.toString().trim();
  if (output.isEmpty) {
    throw StateError(
      "Windows helper Event Log diagnostics were empty for the smoke run.",
    );
  }
  final decoded = jsonDecode(output);
  final records = decoded is List ? decoded : <Object?>[decoded];
  final lines = <String>[];
  for (final record in records) {
    if (record is! Map) {
      continue;
    }
    final id = int.tryParse(record["id"].toString());
    final event = id == null ? null : _windowsHelperEventNames[id];
    if (event == null) {
      continue;
    }
    lines.add(
      jsonEncode(<String, Object?>{
        "event": event,
        "id": id,
        "timestampUtc": record["timestampUtc"],
      }),
    );
  }
  if (lines.isEmpty) {
    throw StateError(
      "Windows helper Event Log diagnostics contained no known helper events.",
    );
  }
  await File(diagnosticsLogPath).writeAsString(
    "${lines.join("\n")}\n",
    flush: true,
  );
}

Future<void> _closeWindowsSmokeRelaunch(String executablePath) async {
  final targetName = File(executablePath).uri.pathSegments.last;
  for (var attempt = 0; attempt < 20; attempt++) {
    await Process.run(
      "taskkill.exe",
      <String>["/F", "/T", "/IM", targetName],
      runInShell: false,
    );
    final remaining = await _windowsSmokeProcessIds(executablePath);
    if (remaining.isEmpty) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  if (Platform.environment[_windowsExternalRelaunchCleanupEnvironment] == "1") {
    stdout.writeln(
      "Windows smoke relaunch cleanup deferred to elevated wrapper.",
    );
    return;
  }
  throw StateError(
    "Windows smoke relaunch process remained after bounded cleanup: "
    "$executablePath",
  );
}

Future<List<int>> _windowsSmokeProcessIds(String executablePath) async {
  final targetName = File(executablePath).uri.pathSegments.last;
  final result = await Process.run(
    "tasklist.exe",
    <String>[
      "/FI",
      "IMAGENAME eq $targetName",
      "/FO",
      "CSV",
      "/NH",
    ],
    runInShell: false,
  );
  if (result.exitCode != 0) {
    throw ProcessException(
      "tasklist.exe",
      const <String>["/FO", "CSV"],
      "${result.stdout}${result.stderr}",
      result.exitCode,
    );
  }
  return RegExp(r'"[^"]+","(\d+)"')
      .allMatches(result.stdout.toString())
      .map((match) => int.parse(match.group(1)!))
      .toList(growable: false);
}

String _powershellSingleQuoted(String value) {
  return value.replaceAll("'", "''");
}

Future<void> _expectDiagnosticsLog(
  String logPath,
  List<String> expectedEvents,
) async {
  final log = File(logPath);
  await _waitFor(
    log.existsSync,
    const Duration(seconds: 10),
    "Timed out waiting for helper diagnostics log at $logPath.",
  );

  final contents = await log.readAsString();
  for (final event in expectedEvents) {
    if (!contents.contains('"event":"$event"')) {
      stderr.writeln(contents);
      throw StateError(
        "Helper diagnostics log missing event '$event' in $logPath.",
      );
    }
  }
}

String? _argValue(List<String> args, String name) {
  final index = args.indexOf(name);
  if (index == -1 || index + 1 >= args.length) {
    return null;
  }
  return args[index + 1];
}

String _join(String left, String right) {
  if (left.endsWith(Platform.pathSeparator)) {
    return "$left$right";
  }
  return "$left${Platform.pathSeparator}$right";
}

String _joinAll(List<String> parts) {
  return parts.reduce(_join);
}

String _basename(String path) {
  final normalized = path.endsWith(Platform.pathSeparator)
      ? path.substring(0, path.length - 1)
      : path;
  return normalized.split(Platform.pathSeparator).last;
}

String? _absolutePath(String? path) {
  if (path == null) {
    return null;
  }
  return File(path).absolute.path;
}

void _usage() {
  stderr.writeln(
    "Usage: dart run tool/updater_smoke.dart [--app <path>] "
    "[--config Debug|Release] [--diagnostics-log <path>] [--relaunch]\n"
    "\n"
    "Use --production-gates --staged-app <path> on macOS with a signed, "
    "notarized, stapled Release .app that already contains the smoke sentinel.\n"
    "\n"
    "Build the example first:\n"
    "  flutter build macos --debug\n"
    "  flutter build macos --release\n"
    "  flutter build windows --debug\n"
    "  flutter build windows --release\n"
    "  flutter build linux --debug\n"
    "  flutter build linux --release\n",
  );
}
