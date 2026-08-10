import "dart:convert";
import "dart:ffi";
import "dart:io";

import "package:args/args.dart";
import "package:crypto/crypto.dart" as crypto;
import "package:desktop_updater/src/core/staged_update_provenance.dart";
import "package:path/path.dart" as path;

import "native_runtime_smoke_server.dart" as smoke_server;

const _targetPath = "/Applications/Desktop Updater Smoke.app";
const _bundleIdentifier = "com.example.desktopUpdaterSmoke";
const _receiptIdentifier = "com.example.desktopUpdaterSmoke.pkg";
const _ownerMarkerText = "desktop_updater macOS production smoke";
const _ownerMarkerName = "desktop_updater_smoke_owner.txt";
const _teamIdentifier = "UPK4SC93AN";
const _v1Version = "1.0.0";
const _v1Build = "100";
const _v2Version = "1.1.0";
const _v2Build = "110";
const _artifactKind = "pkgInstaller";
const _launchMode = "privilegedInstallerTool";
const _smokePublicKeyId = "native-runtime-smoke-stable";
const _minimumUpdaterVersion = "3.1.0";
const _approvalCode = "PrivilegedHelperApprovalRequired";
const _settingsAction = "openMacOSBackgroundItemsSettings";
const _settingsInstructions =
    "System Settings > General > Login Items & Extensions > "
    "Allow in the Background: enable the Desktop Updater smoke helper.";
const _openSettingsOption = "--open-settings";
const _readyMarker =
    "/private/var/tmp/com.example.desktopUpdaterSmoke.pkg-recovery.ready";
const _releaseMarker =
    "/private/var/tmp/com.example.desktopUpdaterSmoke.pkg-recovery.release";

final _sha256Pattern = RegExp(r"^[0-9a-f]{64}$");
final _commitPattern = RegExp(r"^[0-9a-f]{40}$");
final _uuidPattern = RegExp(
  r"^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-"
  r"[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
  caseSensitive: false,
);
final _servicePattern = RegExp(
  r"^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?"
  r"(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)+$",
);
final _executablePattern = RegExp(r"^[A-Za-z0-9_-]+$");
final _flutterProbeStderrPattern = RegExp(
  r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+ "
  r"desktop_updater_example\[\d+:\d+\] "
  r"Running with merged UI and platform thread\. Experimental\.$",
);

bool _hasOnlyExpectedFlutterProbeStderr(String output) {
  final lines = output
      .split("\n")
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty);
  return lines.every(_flutterProbeStderrPattern.hasMatch);
}

typedef _ProcPIDPathNative = Int32 Function(
  Int32,
  Pointer<Void>,
  Uint32,
);
typedef _ProcPIDPathDart = int Function(
  int,
  Pointer<Void>,
  int,
);
typedef _MallocNative = Pointer<Void> Function(IntPtr);
typedef _MallocDart = Pointer<Void> Function(int);
typedef _FreeNative = Void Function(Pointer<Void>);
typedef _FreeDart = void Function(Pointer<Void>);

final _ProcPIDPathDart _procPIDPath = DynamicLibrary.process()
    .lookupFunction<_ProcPIDPathNative, _ProcPIDPathDart>("proc_pidpath");
final _MallocDart _malloc = DynamicLibrary.process()
    .lookupFunction<_MallocNative, _MallocDart>("malloc");
final _FreeDart _free =
    DynamicLibrary.process().lookupFunction<_FreeNative, _FreeDart>("free");

Future<void> main(List<String> arguments) async {
  try {
    if (!Platform.isMacOS) {
      throw const _SmokeFailure("macos-host-required");
    }
    final request = _SmokeRequest.parse(arguments);
    final smoke = _PrivilegedPkgSmoke(request);
    switch (request.mode) {
      case "bootstrap-v1":
        await smoke.bootstrapV1();
      case "verify-v1":
        await smoke.verifyV1();
      case "approval":
        await smoke.approval();
      case "install":
        await smoke.install();
      default:
        throw const _SmokeFailure("unsupported-mode");
    }
  } on FormatException catch (_) {
    stderr.writeln("macOS privileged PKG smoke: invalid arguments");
    exitCode = 64;
  } on _ApprovalPause catch (_) {
    stdout.writeln(
      jsonEncode({
        "status": "requiresApproval",
        "action": _settingsInstructions,
      }),
    );
    exitCode = 75;
  } on _SmokeFailure catch (error) {
    stderr.writeln("macOS privileged PKG smoke: ${error.failureClass}");
    exitCode = 1;
  } on Object catch (_) {
    stderr.writeln("macOS privileged PKG smoke: unexpected-failure");
    exitCode = 1;
  }
}

final class _SmokeRequest {
  const _SmokeRequest({
    required this.mode,
    required this.v1App,
    required this.recoveryApp,
    required this.v1Pkg,
    required this.v2Pkg,
    required this.gitCommit,
    required this.artifactSHA256,
    required this.notarizationSubmissionId,
    required this.evidenceDirectory,
    required this.smokeRoot,
    required this.openSettings,
  });

  factory _SmokeRequest.parse(List<String> arguments) {
    final parser = ArgParser()
      ..addOption("mode", mandatory: true)
      ..addOption("v1-app", mandatory: true)
      ..addOption("recovery-app", mandatory: true)
      ..addOption("v1-pkg", mandatory: true)
      ..addOption("v2-pkg", mandatory: true)
      ..addOption("git-commit", mandatory: true)
      ..addOption("artifact-sha256", mandatory: true)
      ..addOption("notarization-submission-id", mandatory: true)
      ..addOption("evidence-dir", mandatory: true)
      ..addOption("smoke-root", mandatory: true)
      ..addFlag(_openSettingsOption.substring(2), negatable: false);
    final values = parser.parse(arguments);
    final mode = values.option("mode")!;
    final commit = values.option("git-commit")!;
    final hash = values.option("artifact-sha256")!;
    final submission = values.option("notarization-submission-id")!;
    if (!{"bootstrap-v1", "verify-v1", "approval", "install"}.contains(mode) ||
        !_commitPattern.hasMatch(commit) ||
        !_sha256Pattern.hasMatch(hash) ||
        !_uuidPattern.hasMatch(submission)) {
      throw const FormatException("invalid smoke identity");
    }
    return _SmokeRequest(
      mode: mode,
      v1App: Directory(values.option("v1-app")!),
      recoveryApp: Directory(values.option("recovery-app")!),
      v1Pkg: File(values.option("v1-pkg")!),
      v2Pkg: File(values.option("v2-pkg")!),
      gitCommit: commit,
      artifactSHA256: hash,
      notarizationSubmissionId: submission,
      evidenceDirectory: Directory(values.option("evidence-dir")!),
      smokeRoot: Directory(values.option("smoke-root")!),
      openSettings: values.flag(_openSettingsOption.substring(2)),
    );
  }

  final String mode;
  final Directory v1App;
  final Directory recoveryApp;
  final File v1Pkg;
  final File v2Pkg;
  final String gitCommit;
  final String artifactSHA256;
  final String notarizationSubmissionId;
  final Directory evidenceDirectory;
  final Directory smokeRoot;
  final bool openSettings;
}

final class _PrivilegedPkgSmoke {
  const _PrivilegedPkgSmoke(this.request);

  final _SmokeRequest request;

  Future<void> bootstrapV1() async {
    await _validateInputs(requireV2Hash: true);
    await _verifySourceV1(request.v1App);
    await _verifySourceRecoveryApp(request.recoveryApp);
    await _verifyPackage(request.v1Pkg);
    await _verifyPackage(request.v2Pkg);
    await _inspectTarget(
      allowedVersions: const {(_v1Version, _v1Build)},
      requireTrust: true,
      requireLoadedService: false,
    );
    final v1Payload = await _extractPackagePayload(
      request.v1Pkg,
      expectedVersion: _v1Version,
      expectedBuild: _v1Build,
    );
    try {
      // Stapling a product package may rewrite the nested app/helper code
      // signatures while preserving the sealed bundle contract. The source
      // app therefore binds to the payload by bundle metadata and owner
      // marker; the installed target remains bound to the exact packaged code
      // identity below.
      if (!await _bundlesShareBundleIdentity(request.v1App, v1Payload.app)) {
        throw const _SmokeFailure("v1-source-payload-mismatch");
      }
      if (await _bundlesShareCodeIdentity(
        Directory(_targetPath),
        v1Payload.app,
      )) {
        stdout.writeln(
          jsonEncode(
            {"status": "verified locally", "baseline": "1.0.0+100"},
          ),
        );
        return;
      }

      // A release smoke must start from the package-installed v1 baseline.
      // Never forge the current version through a production environment hook
      // to force a downgrade through the updater itself.
      throw const _SmokeFailure("v1-package-baseline-required");
    } finally {
      await v1Payload.close();
    }
  }

  Future<void> verifyV1() async {
    await _validateInputs(requireV2Hash: true);
    await _verifySourceV1(request.v1App);
    await _verifyPackage(request.v2Pkg);
    await _inspectTarget(
      allowedVersions: const {(_v1Version, _v1Build)},
      requireTrust: true,
      requireLoadedService: false,
    );
    final payload = await _extractPackagePayload(
      request.v1Pkg,
      expectedVersion: _v1Version,
      expectedBuild: _v1Build,
    );
    try {
      // Product-package stapling can rewrite nested app/helper signatures.
      // Bind the supplied source app to the payload by the signed bundle
      // contract, then bind the installed target to the exact payload code.
      if (!await _bundlesShareBundleIdentity(request.v1App, payload.app) ||
          !await _bundlesShareCodeIdentity(
            Directory(_targetPath),
            payload.app,
          )) {
        throw const _SmokeFailure("installed-v1-payload-mismatch");
      }
    } finally {
      await payload.close();
    }
    stdout.writeln(
      jsonEncode({"status": "verified locally", "baseline": "1.0.0+100"}),
    );
  }

  Future<void> approval() async {
    await verifyV1();
    await _prepareSmokeRoot();
    final result = await _runRuntime(
      artifact: request.v2Pkg,
      releaseVersion: _v2Version,
      releaseBuild: int.parse(_v2Build),
      expectApproval: true,
    );
    final event = _typedApprovalEvent(result);
    if (event == null) {
      throw const _SmokeFailure("typed-approval-not-observed");
    }
    await _inspectTarget(
      allowedVersions: const {(_v1Version, _v1Build)},
      requireTrust: true,
      requireLoadedService: false,
    );
    if (!await _ownedStageRetained()) {
      throw const _SmokeFailure("approval-stage-not-retained");
    }
    final evidence = <String, Object?>{
      "schemaVersion": 1,
      "status": "verified locally",
      "gitCommit": request.gitCommit,
      "artifactSHA256": request.artifactSHA256,
      "notarizationSubmissionId": request.notarizationSubmissionId,
      "event": "installFailed",
      "code": _approvalCode,
      "remediationActions": const [_settingsAction],
      "bundleIdentifier": _bundleIdentifier,
      "receiptIdentifier": _receiptIdentifier,
      "baselineVersion": _v1Version,
      "baselineBuild": _v1Build,
      "teamIdentifier": _teamIdentifier,
      "approvalStatus": "requiresApproval",
      "stageRetained": true,
      "artifactKind": _artifactKind,
      "launchMode": _launchMode,
      "minimumUpdaterVersion": _minimumUpdaterVersion,
    };
    await _writeEvidence("approval.json", evidence, kind: "approval");
    if (request.openSettings) await _openBackgroundItemsSettings();
    throw const _ApprovalPause();
  }

  Future<void> install() async {
    await verifyV1();
    final approvalEvidence = File(
      path.join(request.evidenceDirectory.path, "approval.json"),
    );
    if (await approvalEvidence.exists()) {
      await _removeVerifiedApprovalStage();
    }
    await _prepareSmokeRoot();
    if ((await _providerTransactionIDs()).isNotEmpty) {
      throw const _SmokeFailure("provider-journal-already-present");
    }
    final result = await _runRuntime(
      artifact: request.v2Pkg,
      releaseVersion: _v2Version,
      releaseBuild: int.parse(_v2Build),
      expectApproval: false,
    );
    if (result.exitCode != 0 ||
        !result.output.contains("prepareInstall committed $_v2Version")) {
      if (_typedApprovalEvent(result) != null) {
        if (request.openSettings) await _openBackgroundItemsSettings();
        throw const _ApprovalPause();
      }
      throw const _SmokeFailure("privileged-install-not-scheduled");
    }
    final manager = await _waitForFixedInstallerManager(
      const Duration(seconds: 90),
    );
    await _releaseRecoveryGate(manager.processIdentifier);
    if (!await _waitForTargetVersion(
      version: _v2Version,
      build: _v2Build,
      timeout: const Duration(seconds: 150),
    )) {
      throw const _SmokeFailure("privileged-install-timeout");
    }
    final installedServicePID = await _probeInstalledLaunchDaemon(
      expectedVersion: _v2Version,
      expectedBuild: _v2Build,
    );
    await _inspectTarget(
      allowedVersions: const {(_v2Version, _v2Build)},
      requireTrust: true,
      requireLoadedService: false,
    );
    final payload = await _extractPackagePayload(
      request.v2Pkg,
      expectedVersion: _v2Version,
      expectedBuild: _v2Build,
    );
    try {
      if (!await _bundlesShareCodeIdentity(
        Directory(_targetPath),
        payload.app,
      )) {
        throw const _SmokeFailure("installed-v2-payload-mismatch");
      }
    } finally {
      await payload.close();
    }
    await _recoverBlockingBootstrapTransaction(
      expectedState: "completed",
      expectedResultCode: "succeeded",
      required: false,
    );
    await _waitForOwnedStageEmpty();
    final evidence = <String, Object?>{
      "schemaVersion": 1,
      "status": "verified locally",
      "gitCommit": request.gitCommit,
      "artifactSHA256": request.artifactSHA256,
      "notarizationSubmissionId": request.notarizationSubmissionId,
      "bundleIdentifier": _bundleIdentifier,
      "receiptIdentifier": _receiptIdentifier,
      "version": _v2Version,
      "build": _v2Build,
      "receiptVersion": _v2Version,
      "teamIdentifier": _teamIdentifier,
      "appOwnership": "root:wheel",
      "mainExecutableOwnership": "root:wheel",
      "helperOwnership": "root:wheel",
      "launchDaemonOwnership": "root:wheel",
      "appSignatureValid": true,
      "mainExecutableSignatureValid": true,
      "helperSignatureValid": true,
      "hardenedRuntime": true,
      "gatekeeperAccepted": true,
      "stapleValid": true,
      "launchDaemonActive": true,
      "launchDaemonPID": installedServicePID,
      "artifactKind": _artifactKind,
      "launchMode": _launchMode,
      "minimumUpdaterVersion": _minimumUpdaterVersion,
      "fixedInstallerAuthority": true,
      "stageRemovedAfterCompletion": true,
    };
    await _writeEvidence("elevation.json", evidence, kind: "elevation");
    stdout.writeln(
      jsonEncode({"status": "verified locally", "installed": "1.1.0+110"}),
    );
  }

  Future<void> _validateInputs({required bool requireV2Hash}) async {
    await _requireNode(request.v1App.path, FileSystemEntityType.directory);
    await _requireNode(
      request.recoveryApp.path,
      FileSystemEntityType.directory,
    );
    await _requireNode(request.v1Pkg.path, FileSystemEntityType.file);
    await _requireNode(request.v2Pkg.path, FileSystemEntityType.file);
    await _requireSafeDirectory(request.evidenceDirectory, create: true);
    await _requireSafeDirectory(request.smokeRoot, create: true);
    if (requireV2Hash &&
        await _sha256(request.v2Pkg) != request.artifactSHA256) {
      throw const _SmokeFailure("artifact-hash-mismatch");
    }
  }

  Future<void> _verifySourceV1(Directory app) async {
    final metadata = await _readBundleMetadata(app);
    if (metadata.bundleIdentifier != _bundleIdentifier ||
        metadata.version != _v1Version ||
        metadata.build != _v1Build) {
      throw const _SmokeFailure("v1-source-identity-mismatch");
    }
    await _verifyOwnerMarker(app);
    await _verifySignedBundle(app, metadata, requireOwnership: false);
  }

  Future<void> _verifySourceRecoveryApp(Directory app) async {
    final metadata = await _readBundleMetadata(app);
    if (metadata.bundleIdentifier != _bundleIdentifier ||
        metadata.version != _v2Version ||
        metadata.build != _v2Build) {
      throw const _SmokeFailure("recovery-app-identity-mismatch");
    }
    await _verifyOwnerMarker(app);
    await _verifySignedBundle(app, metadata, requireOwnership: false);
  }

  Future<void> _verifyPackage(File package) async {
    await _runChecked(
      "/usr/sbin/pkgutil",
      ["--check-signature", package.path],
      failureClass: "package-signature-invalid",
      outputContains: _teamIdentifier,
    );
    await _runChecked(
      "/usr/sbin/spctl",
      ["--assess", "--type", "install", "--verbose=2", package.path],
      failureClass: "package-gatekeeper-rejected",
    );
    await _runChecked(
      "/usr/bin/xcrun",
      ["stapler", "validate", package.path],
      failureClass: "package-staple-invalid",
    );
  }

  Future<_PackagePayload> _extractPackagePayload(
    File package, {
    required String expectedVersion,
    required String expectedBuild,
  }) async {
    final root = await Directory.systemTemp.createTemp("macos_pkg_payload_");
    try {
      final expanded = Directory(path.join(root.path, "expanded"));
      await _runChecked(
        "/usr/sbin/pkgutil",
        ["--expand-full", package.path, expanded.path],
        failureClass: "package-expand-failed",
      );
      final componentEntries = await expanded
          .list(followLinks: false)
          .where(
            (entry) =>
                entry is Directory &&
                path.basename(entry.path).endsWith(".pkg"),
          )
          .toList();
      if (componentEntries.length != 1) {
        throw const _SmokeFailure("package-payload-shape-invalid");
      }
      final component = componentEntries.single as Directory;
      final payload = Directory(path.join(component.path, "Payload"));
      final app =
          Directory(path.join(payload.path, path.basename(_targetPath)));
      await _requireNode(component.path, FileSystemEntityType.directory);
      await _requireNode(payload.path, FileSystemEntityType.directory);
      await _requireNode(app.path, FileSystemEntityType.directory);
      final payloadEntries = await payload.list(followLinks: false).toList();
      if (payloadEntries.length != 1 ||
          payloadEntries.single.path != app.path) {
        throw const _SmokeFailure("package-payload-shape-invalid");
      }
      final metadata = await _readBundleMetadata(app);
      if (metadata.bundleIdentifier != _bundleIdentifier ||
          metadata.version != expectedVersion ||
          metadata.build != expectedBuild) {
        throw const _SmokeFailure("package-payload-identity-mismatch");
      }
      await _verifyOwnerMarker(app);
      await _verifySignedBundle(app, metadata, requireOwnership: false);
      return _PackagePayload(root: root, app: app);
    } on Object {
      if (await root.exists()) await root.delete(recursive: true);
      rethrow;
    }
  }

  Future<bool> _bundlesShareCodeIdentity(
    Directory first,
    Directory second,
  ) async {
    try {
      final firstMetadata = await _readBundleMetadata(first);
      final secondMetadata = await _readBundleMetadata(second);
      if (firstMetadata.bundleIdentifier != secondMetadata.bundleIdentifier ||
          firstMetadata.version != secondMetadata.version ||
          firstMetadata.build != secondMetadata.build ||
          firstMetadata.executable != secondMetadata.executable ||
          firstMetadata.serviceIdentifier != secondMetadata.serviceIdentifier) {
        return false;
      }
      final firstHelper = path.join(
        first.path,
        "Contents",
        "Helpers",
        "DesktopUpdaterInstallHelper",
      );
      final secondHelper = path.join(
        second.path,
        "Contents",
        "Helpers",
        "DesktopUpdaterInstallHelper",
      );
      return await _codeDirectoryHash(first.path) ==
              await _codeDirectoryHash(second.path) &&
          await _codeDirectoryHash(firstHelper) ==
              await _codeDirectoryHash(secondHelper);
    } on Object {
      return false;
    }
  }

  Future<bool> _bundlesShareBundleIdentity(
    Directory first,
    Directory second,
  ) async {
    try {
      final firstMetadata = await _readBundleMetadata(first);
      final secondMetadata = await _readBundleMetadata(second);
      return firstMetadata.bundleIdentifier ==
              secondMetadata.bundleIdentifier &&
          firstMetadata.version == secondMetadata.version &&
          firstMetadata.build == secondMetadata.build &&
          firstMetadata.executable == secondMetadata.executable &&
          firstMetadata.serviceIdentifier == secondMetadata.serviceIdentifier;
    } on Object {
      return false;
    }
  }

  Future<String> _codeDirectoryHash(String target) async {
    final details = await _runChecked(
      "/usr/bin/codesign",
      ["-dv", "--verbose=4", target],
      failureClass: "code-identity-unavailable",
    );
    final hash = RegExp(r"^CDHash=([0-9a-f]+)\s*$", multiLine: true)
        .firstMatch(details.output)
        ?.group(1);
    if (hash == null || hash.length < 40) {
      throw const _SmokeFailure("code-identity-invalid");
    }
    return hash;
  }

  Future<_InstalledTarget> _inspectTarget({
    required Set<(String, String)> allowedVersions,
    required bool requireTrust,
    required bool requireLoadedService,
  }) async {
    await _requireNode(_targetPath, FileSystemEntityType.directory);
    final app = Directory(_targetPath);
    if (await app.resolveSymbolicLinks() != _targetPath) {
      throw const _SmokeFailure("target-path-mismatch");
    }
    final metadata = await _readBundleMetadata(app);
    if (metadata.bundleIdentifier != _bundleIdentifier ||
        !allowedVersions.contains((metadata.version, metadata.build))) {
      throw const _SmokeFailure("target-bundle-identity-mismatch");
    }
    await _verifyOwnerMarker(app);
    final receipt = await _receiptVersion();
    if (receipt != metadata.version) {
      throw const _SmokeFailure("target-receipt-identity-mismatch");
    }
    if (requireTrust) {
      await _verifySignedBundle(app, metadata, requireOwnership: true);
    }
    final servicePID = await _launchDaemonPID(metadata.serviceIdentifier);
    if (requireLoadedService && servicePID == null) {
      throw const _SmokeFailure("launch-daemon-not-active");
    }
    return _InstalledTarget(
      version: metadata.version,
      build: metadata.build,
      receiptVersion: receipt,
      servicePID: servicePID,
    );
  }

  Future<void> _recoverBlockingBootstrapTransaction({
    required String expectedState,
    required String expectedResultCode,
    required bool required,
  }) async {
    final applications = Directory(path.dirname(_targetPath));
    final targetName = path.basename(_targetPath);
    final journalPattern = RegExp(
      "^\\.${RegExp.escape(targetName)}\\.desktop-updater-"
      "([0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-"
      r"[89ab][0-9a-f]{3}-[0-9a-f]{12})\.provider\.json$",
    );
    final transactionIDs = <String>[];
    await for (final entry in applications.list(followLinks: false)) {
      final match = journalPattern.firstMatch(path.basename(entry.path));
      if (match == null) continue;
      if (await FileSystemEntity.type(entry.path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw const _SmokeFailure("bootstrap-recovery-journal-invalid");
      }
      transactionIDs.add(match.group(1)!);
    }
    if (transactionIDs.isEmpty && !required) return;
    if (transactionIDs.length != 1) {
      throw const _SmokeFailure("bootstrap-recovery-journal-ambiguous");
    }
    final runtimeApp = Directory(_targetPath);
    final metadata = await _readBundleMetadata(runtimeApp);
    final host = path.join(
      runtimeApp.path,
      "Contents",
      "MacOS",
      metadata.executable,
    );
    final result = await Process.run(
      host,
      [
        "--smoke",
        "--recover-transaction",
        transactionIDs.single,
      ],
      environment: {
        ...Platform.environment,
        "DESKTOP_UPDATER_CONTROLLER_SMOKE": "1",
        "DESKTOP_UPDATER_CONTROLLER_SMOKE_TARGET": _targetPath,
        "DESKTOP_UPDATER_NATIVE_CONTROLLER_SMOKE": "1",
      },
    );
    final runtime = _RuntimeResult(
      exitCode: result.exitCode,
      output: "${result.stdout}\n${result.stderr}",
    );
    await _pauseIfApproval(runtime);
    if (runtime.exitCode != 0) {
      throw const _SmokeFailure("bootstrap-recovery-call-failed");
    }
    Map<String, Object?>? event;
    for (final line in runtime.output.split("\n")) {
      try {
        final value = jsonDecode(line.trim());
        if (value is Map<String, Object?> &&
            value.keys.toSet().difference(
              const {"event", "state", "resultCode"},
            ).isEmpty &&
            value.keys.length == 3 &&
            value["event"] == "recovery") {
          event = value;
        }
      } on FormatException {
        // Ignore unrelated Swift runtime output.
      }
    }
    if (event?["state"] != expectedState ||
        event?["resultCode"] != expectedResultCode) {
      throw const _SmokeFailure("bootstrap-recovery-outcome-invalid");
    }
    final lock = File(
      path.join(
        applications.path,
        ".$targetName.desktop-updater-lock",
      ),
    );
    if (await FileSystemEntity.type(lock.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const _SmokeFailure("bootstrap-recovery-lock-retained");
    }
    if (expectedState == "completed") {
      final remaining = await applications
          .list(followLinks: false)
          .where(
            (entry) => journalPattern.hasMatch(path.basename(entry.path)),
          )
          .toList();
      if (remaining.isNotEmpty) {
        throw const _SmokeFailure("bootstrap-recovery-journal-retained");
      }
    }
  }

  Future<_BundleMetadata> _readBundleMetadata(Directory app) async {
    final info = File(path.join(app.path, "Contents", "Info.plist"));
    await _requireNode(info.path, FileSystemEntityType.file);
    final executable = await _plistValue(info, "CFBundleExecutable");
    final service =
        await _plistValue(info, "DesktopUpdaterInstallHelperServiceID");
    final bundleIdentifier = await _plistValue(info, "CFBundleIdentifier");
    if (bundleIdentifier != _bundleIdentifier ||
        !_executablePattern.hasMatch(executable) ||
        !_servicePattern.hasMatch(service)) {
      throw const _SmokeFailure("bundle-metadata-invalid");
    }
    await _requireNode(
      path.join(app.path, "Contents", "MacOS", executable),
      FileSystemEntityType.file,
    );
    return _BundleMetadata(
      bundleIdentifier: bundleIdentifier,
      version: await _plistValue(info, "CFBundleShortVersionString"),
      build: await _plistValue(info, "CFBundleVersion"),
      executable: executable,
      serviceIdentifier: service,
    );
  }

  Future<void> _verifyOwnerMarker(Directory app) async {
    final marker = File(
      path.join(app.path, "Contents", "Resources", _ownerMarkerName),
    );
    await _requireNode(marker.path, FileSystemEntityType.file);
    final contents = await marker.readAsString();
    if (!contents.split("\n").contains(_ownerMarkerText) ||
        !contents.split("\n").contains("packageId=$_bundleIdentifier")) {
      throw const _SmokeFailure("owner-marker-mismatch");
    }
  }

  Future<void> _verifySignedBundle(
    Directory app,
    _BundleMetadata metadata, {
    required bool requireOwnership,
  }) async {
    final mainExecutable =
        File(path.join(app.path, "Contents", "MacOS", metadata.executable));
    final helper = File(
      path.join(
        app.path,
        "Contents",
        "Helpers",
        "DesktopUpdaterInstallHelper",
      ),
    );
    final launchDaemon = File(
      path.join(
        app.path,
        "Contents",
        "Library",
        "LaunchDaemons",
        "${metadata.serviceIdentifier}.plist",
      ),
    );
    for (final file in [mainExecutable, helper, launchDaemon]) {
      await _requireNode(file.path, FileSystemEntityType.file);
    }
    if (await _plistValue(launchDaemon, "Label") !=
            metadata.serviceIdentifier ||
        await _plistValue(launchDaemon, "BundleProgram") !=
            "Contents/Helpers/DesktopUpdaterInstallHelper" ||
        await _plistHasKey(launchDaemon, "Program") ||
        await _plistHasKey(launchDaemon, "ProgramArguments")) {
      throw const _SmokeFailure("launch-daemon-metadata-invalid");
    }
    await _verifyCodeSignature(app.path, deep: true);
    await _verifyCodeSignature(mainExecutable.path, deep: false);
    await _verifyCodeSignature(helper.path, deep: false);
    await _runChecked(
      "/usr/sbin/spctl",
      ["--assess", "--type", "execute", "--verbose=2", app.path],
      failureClass: "app-gatekeeper-rejected",
    );
    await _runChecked(
      "/usr/bin/xcrun",
      ["stapler", "validate", app.path],
      failureClass: "app-staple-invalid",
    );
    if (requireOwnership) {
      for (final target in [
        app.path,
        mainExecutable.path,
        helper.path,
        launchDaemon.path,
      ]) {
        final ownership = await _runChecked(
          "/usr/bin/stat",
          ["-f", "%Su:%Sg", target],
          failureClass: "ownership-inspection-failed",
        );
        if (ownership.output.trim() != "root:wheel") {
          throw const _SmokeFailure("root-ownership-mismatch");
        }
      }
    }
  }

  Future<void> _verifyCodeSignature(String target, {required bool deep}) async {
    await _runChecked(
      "/usr/bin/codesign",
      ["--verify", if (deep) "--deep", "--strict", "--verbose=2", target],
      failureClass: "strict-signature-invalid",
    );
    final details = await _runChecked(
      "/usr/bin/codesign",
      ["-dv", "--verbose=4", target],
      failureClass: "signature-details-unavailable",
      acceptedExitCodes: const {0},
    );
    if (!RegExp(
          "^TeamIdentifier=${RegExp.escape(_teamIdentifier)}\$",
          multiLine: true,
        ).hasMatch(details.output) ||
        !RegExp(r"^CodeDirectory .*flags=.*\(runtime\)", multiLine: true)
            .hasMatch(details.output)) {
      throw const _SmokeFailure("team-or-runtime-mismatch");
    }
  }

  Future<String> _receiptVersion() async {
    final receipt = await _runChecked(
      "/usr/sbin/pkgutil",
      ["--pkg-info", _receiptIdentifier],
      failureClass: "receipt-missing",
    );
    final id = RegExp(r"^package-id: (\S+)\s*$", multiLine: true)
        .firstMatch(receipt.output)
        ?.group(1);
    final version = RegExp(r"^version: (\S+)\s*$", multiLine: true)
        .firstMatch(receipt.output)
        ?.group(1);
    if (id != _receiptIdentifier || version == null) {
      throw const _SmokeFailure("receipt-identity-mismatch");
    }
    return version;
  }

  Future<_RuntimeResult> _runRuntime({
    required File artifact,
    required String releaseVersion,
    required int releaseBuild,
    required bool expectApproval,
  }) async {
    final server = await _SmokeServer.open(
      artifact: artifact,
      version: releaseVersion,
      build: releaseBuild,
    );
    try {
      // The privileged helper authenticates the caller's executable path and
      // process identity against the protected target. Run the actual smoke
      // app installed at /Applications so this E2E exercises that contract;
      // a temporary recovery fixture is not an authenticated caller.
      final runtimeApp = Directory(_targetPath);
      final metadata = await _readBundleMetadata(runtimeApp);
      final host = path.join(
        runtimeApp.path,
        "Contents",
        "MacOS",
        metadata.executable,
      );
      final staging = Directory(
        path.join(request.smokeRoot.path, "staging"),
      );
      await staging.create(recursive: true);
      final marker = File(
        path.join(request.smokeRoot.path, "controller-smoke.marker"),
      );
      final diagnostics = File(
        path.join(request.smokeRoot.path, "controller-smoke-diagnostics.log"),
      );
      final recoveryStore = File(
        path.join(request.smokeRoot.path, "pending-install.json"),
      );
      final process = await Process.start(
        host,
        const [],
        environment: {
          "TMPDIR": "${staging.path}/",
          "DESKTOP_UPDATER_CONTROLLER_SMOKE": "1",
          "DESKTOP_UPDATER_APP_ARCHIVE_URL": server.archiveURL.toString(),
          "DESKTOP_UPDATER_EXPECTED_PACKAGE_ID": _bundleIdentifier,
          "DESKTOP_UPDATER_TRUSTED_PUBLIC_KEY_ID": _smokePublicKeyId,
          "DESKTOP_UPDATER_TRUSTED_PUBLIC_KEY": server.publicKeyBase64,
          "DESKTOP_UPDATER_RECOVERY_STORE_PATH": recoveryStore.path,
          "DESKTOP_UPDATER_SMOKE_MARKER": marker.path,
          "DESKTOP_UPDATER_SMOKE_DIAGNOSTICS_LOG": diagnostics.path,
          "DESKTOP_UPDATER_SMOKE_SKIP_RELAUNCH": "1",
          "DESKTOP_UPDATER_SMOKE_EXIT_AFTER_FAILURE": "1",
          "DESKTOP_UPDATER_CONTROLLER_SMOKE_TARGET": _targetPath,
        },
        includeParentEnvironment: true,
        workingDirectory: path.dirname(host),
      );
      final stdoutFuture = utf8.decoder.bind(process.stdout).join();
      final stderrFuture = utf8.decoder.bind(process.stderr).join();
      final markerValue = await _waitForControllerSmokeMarker(
        marker,
        waitForFailure: expectApproval,
      );
      if (markerValue.startsWith("failed:")) {
        final processExitCode = await _terminateRuntimeProcess(process);
        final output = "${await stdoutFuture}\n${await stderrFuture}";
        if (expectApproval && markerValue.contains(_approvalCode)) {
          return _RuntimeResult(
            exitCode: 0,
            output: jsonEncode({
              "event": "installFailed",
              "code": _approvalCode,
              "remediationActions": [_settingsAction],
            }),
          );
        }
        if (markerValue.contains("recoveryRequired: true")) {
          return _RuntimeResult(
            exitCode: 0,
            output: "$output\n$markerValue\n"
                "prepareInstall committed $releaseVersion",
          );
        }
        return _RuntimeResult(
          exitCode: processExitCode == 0 ? 1 : processExitCode,
          output: "$output\n$markerValue",
        );
      }
      final exitCode = await process.exitCode.timeout(
        const Duration(minutes: 3),
        onTimeout: () {
          process.kill(ProcessSignal.sigterm);
          process.kill(ProcessSignal.sigkill);
          throw const _SmokeFailure("runtime-launch-timeout");
        },
      );
      return _RuntimeResult(
        exitCode: exitCode,
        output: "${await stdoutFuture}\n${await stderrFuture}\n"
            "prepareInstall committed $releaseVersion",
      );
    } on ProcessException {
      throw const _SmokeFailure("runtime-launch-failed");
    } finally {
      await server.close();
    }
  }

  Future<int> _terminateRuntimeProcess(Process process) async {
    process.kill(ProcessSignal.sigterm);
    process.kill(ProcessSignal.sigkill);
    try {
      await Process.run("/bin/kill", ["-KILL", process.pid.toString()]);
    } on Object {
      // The direct Process.kill call remains the primary cleanup path.
    }
    return process.exitCode.timeout(
      const Duration(seconds: 2),
      onTimeout: () => -9,
    );
  }

  Future<String> _waitForControllerSmokeMarker(
    File marker, {
    required bool waitForFailure,
  }) async {
    final deadline = DateTime.now().add(const Duration(minutes: 2));
    while (DateTime.now().isBefore(deadline)) {
      if (await marker.exists()) {
        final value = (await marker.readAsString()).trim();
        if (value.startsWith("failed:")) {
          return value;
        }
        if (!waitForFailure && value == "installing") {
          // A protected PKG may report the transient installing state before
          // the native handoff returns a terminal recoveryRequired failure.
          // Give that failure a bounded window without delaying ordinary
          // successful installs indefinitely.
          await Future<void>.delayed(const Duration(milliseconds: 750));
          if (await marker.exists()) {
            final terminalValue = (await marker.readAsString()).trim();
            if (terminalValue.startsWith("failed:")) return terminalValue;
          }
          return value;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw const _SmokeFailure("controller-smoke-marker-timeout");
  }

  Map<String, Object?>? _typedApprovalEvent(_RuntimeResult result) {
    final hasApprovalCode = result.output.contains(_approvalCode);
    final hasSettingsAction = result.output.contains(_settingsAction);
    if (hasApprovalCode && hasSettingsAction) {
      return {
        "event": "installFailed",
        "code": _approvalCode,
        "remediationActions": [_settingsAction],
      };
    }
    if (result.exitCode != 0) return null;
    for (final line in result.output.split("\n")) {
      final candidate = line.trim();
      if (!candidate.startsWith("{")) continue;
      try {
        final value = jsonDecode(candidate);
        if (value is Map<String, Object?> &&
            value.keys.toSet().difference(
              const {"event", "code", "remediationActions"},
            ).isEmpty &&
            value["event"] == "installFailed" &&
            value["code"] == _approvalCode &&
            _stringList(value["remediationActions"]).length == 1 &&
            _stringList(value["remediationActions"]).single ==
                _settingsAction) {
          return value;
        }
      } on FormatException {
        // Ignore unrelated structured runtime output.
      }
    }
    return null;
  }

  Future<void> _pauseIfApproval(_RuntimeResult result) async {
    if (_typedApprovalEvent(result) != null ||
        result.output.contains(
          "Expected SMAppService admin approval requirement",
        ) ||
        result.output.contains(
          "Administrator approval is required before the privileged macOS "
          "updater helper can run.",
        ) ||
        result.output.contains(_approvalCode)) {
      if (request.openSettings) await _openBackgroundItemsSettings();
      throw const _ApprovalPause();
    }
  }

  Future<void> _removeVerifiedApprovalStage() async {
    final approval = File(
      path.join(request.evidenceDirectory.path, "approval.json"),
    );
    await _requireNode(approval.path, FileSystemEntityType.file);
    if (await approval.length() > 64 * 1024) {
      throw const _SmokeFailure("approval-evidence-oversized");
    }
    final decoded = jsonDecode(await approval.readAsString());
    if (decoded is! Map<String, Object?>) {
      throw const _SmokeFailure("approval-evidence-invalid");
    }
    _validateEvidenceDocument(decoded, kind: "approval");
    if (decoded["gitCommit"] != request.gitCommit ||
        decoded["artifactSHA256"] != request.artifactSHA256 ||
        decoded["notarizationSubmissionId"] !=
            request.notarizationSubmissionId ||
        decoded["bundleIdentifier"] != _bundleIdentifier ||
        decoded["receiptIdentifier"] != _receiptIdentifier ||
        decoded["event"] != "installFailed" ||
        decoded["code"] != _approvalCode ||
        _stringList(decoded["remediationActions"]).length != 1 ||
        _stringList(decoded["remediationActions"]).single != _settingsAction ||
        decoded["baselineVersion"] != _v1Version ||
        decoded["baselineBuild"] != _v1Build ||
        decoded["teamIdentifier"] != _teamIdentifier ||
        decoded["approvalStatus"] != "requiresApproval" ||
        decoded["stageRetained"] != true ||
        decoded["artifactKind"] != _artifactKind ||
        decoded["launchMode"] != _launchMode ||
        decoded["minimumUpdaterVersion"] != _minimumUpdaterVersion) {
      throw const _SmokeFailure("approval-evidence-authority-mismatch");
    }
    final staging = Directory(path.join(request.smokeRoot.path, "staging"));
    await _requireSafeDirectory(staging, create: false);
    final entries = await staging.list(followLinks: false).toList();
    if (entries.length != 1 ||
        await FileSystemEntity.type(entries.single.path, followLinks: false) !=
            FileSystemEntityType.directory ||
        !path.basename(entries.single.path).startsWith(
              desktopUpdaterStagingPrefix,
            )) {
      throw const _SmokeFailure("approval-stage-authority-invalid");
    }
    final stage = Directory(entries.single.path);
    final state = await readStagedUpdateProvenance(stageRoot: stage);
    if (state.provenance.packageId != _bundleIdentifier ||
        state.provenance.artifactSha256 != request.artifactSHA256) {
      throw const _SmokeFailure("approval-stage-provenance-mismatch");
    }
    await verifyStagedUpdateProvenance(
      stageRoot: stage,
      expectedMarkerSha256: state.markerSha256,
    );
    await deleteOwnedStagingDirectory(
      parent: staging,
      stageRoot: stage,
      nonce: state.provenance.nonce,
    );
  }

  Future<_FixedInstallerManager> _waitForFixedInstallerManager(
    Duration timeout,
  ) async {
    final readyDeadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(readyDeadline)) {
      final type = await FileSystemEntity.type(
        _readyMarker,
        followLinks: false,
      );
      if (type == FileSystemEntityType.file) break;
      if (type != FileSystemEntityType.notFound) {
        throw const _SmokeFailure("recovery-ready-node-invalid");
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (await FileSystemEntity.type(_readyMarker, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const _SmokeFailure("recovery-ready-timeout");
    }
    final authority = await _runChecked(
      "/usr/bin/stat",
      ["-f", "%Su:%Sg:%Lp", _readyMarker],
      failureClass: "recovery-ready-authority-unavailable",
    );
    if (authority.output.trim() != "root:wheel:600") {
      throw const _SmokeFailure("recovery-ready-authority-invalid");
    }

    final transactionDeadline = DateTime.now().add(
      const Duration(seconds: 30),
    );
    while (DateTime.now().isBefore(transactionDeadline)) {
      final transactions = await _providerTransactionIDs();
      if (transactions.length > 1) {
        throw const _SmokeFailure("provider-journal-ambiguous");
      }
      if (transactions.length == 1) {
        final managers = await _fixedInstallerProcesses(
          transactions.single,
        );
        if (managers.length > 1) {
          throw const _SmokeFailure("installer-manager-ambiguous");
        }
        if (managers.length == 1) {
          return _FixedInstallerManager(
            processIdentifier: managers.single,
            transactionID: transactions.single,
          );
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw const _SmokeFailure("installer-manager-not-found");
  }

  Future<Set<String>> _providerTransactionIDs() async {
    final targetName = path.basename(_targetPath);
    final pattern = RegExp(
      "^\\.${RegExp.escape(targetName)}\\.desktop-updater-"
      "([0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-"
      r"[89ab][0-9a-f]{3}-[0-9a-f]{12})\.provider\.json$",
    );
    final transactions = <String>{};
    await for (final entry in Directory("/Applications").list(
      followLinks: false,
    )) {
      final match = pattern.firstMatch(path.basename(entry.path));
      if (match == null) continue;
      if (await FileSystemEntity.type(entry.path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw const _SmokeFailure("provider-journal-node-invalid");
      }
      transactions.add(match.group(1)!);
    }
    return transactions;
  }

  Future<List<int>> _fixedInstallerProcesses(String transactionID) async {
    final result = await _runChecked(
      "/bin/ps",
      ["-ww", "-axo", "pid=,command="],
      failureClass: "process-inspection-failed",
    );
    final expected = RegExp(
      r"^/usr/sbin/installer -pkg "
      r"/Library/PrivilegedHelperTools/\.desktop-updater-stages-"
      r"[0-9a-f]{64}/desktop-updater-stage-"
      "${RegExp.escape(transactionID)}"
      r"/installer\.pkg -target /$",
    );
    final linePattern = RegExp(r"^\s*([0-9]+)\s+(.+)$");
    final matches = <int>[];
    for (final line in result.output.split("\n")) {
      final parsed = linePattern.firstMatch(line);
      if (parsed != null && expected.hasMatch(parsed.group(2)!)) {
        matches.add(int.parse(parsed.group(1)!));
      }
    }
    return matches;
  }

  Future<void> _releaseRecoveryGate(int managerPID) async {
    if (managerPID <= 0 ||
        await FileSystemEntity.type(_releaseMarker, followLinks: false) !=
            FileSystemEntityType.notFound) {
      throw const _SmokeFailure("recovery-release-authority-invalid");
    }
    final release = File(_releaseMarker);
    await release.create(exclusive: true);
    final handle = await release.open(mode: FileMode.write);
    try {
      await handle.writeString("$managerPID\n");
      await handle.flush();
    } finally {
      await handle.close();
    }
  }

  Future<int> _probeInstalledLaunchDaemon({
    required String expectedVersion,
    required String expectedBuild,
  }) async {
    final metadata = await _readBundleMetadata(Directory(_targetPath));
    if (metadata.bundleIdentifier != _bundleIdentifier ||
        metadata.version != expectedVersion ||
        metadata.build != expectedBuild) {
      throw const _SmokeFailure("installed-helper-probe-target-invalid");
    }
    final host = path.join(
      _targetPath,
      "Contents",
      "MacOS",
      metadata.executable,
    );
    final helper = path.join(
      _targetPath,
      "Contents",
      "Helpers",
      "DesktopUpdaterInstallHelper",
    );
    final process = await Process.start(
      host,
      [
        "--smoke",
        "--probe-helper",
        "--hold-helper-active",
      ],
      environment: {
        ...Platform.environment,
        "DESKTOP_UPDATER_CONTROLLER_SMOKE": "1",
        "DESKTOP_UPDATER_CONTROLLER_SMOKE_TARGET": _targetPath,
        "DESKTOP_UPDATER_NATIVE_CONTROLLER_SMOKE": "1",
      },
    );
    final stdoutFuture = utf8.decoder.bind(process.stdout).join();
    final stderrFuture = utf8.decoder.bind(process.stderr).join();
    try {
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      int? servicePID;
      while (DateTime.now().isBefore(deadline)) {
        servicePID = await _launchDaemonPID(metadata.serviceIdentifier);
        if (servicePID != null) break;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      if (servicePID == null) {
        throw const _SmokeFailure("launch-daemon-not-active");
      }
      if (_processExecutablePath(servicePID) != helper) {
        throw const _SmokeFailure("launch-daemon-executable-mismatch");
      }
      final code = await process.exitCode.timeout(
        const Duration(seconds: 30),
      );
      final output = await stdoutFuture;
      final errorOutput = await stderrFuture;
      if (code != 0 ||
          !_hasOnlyExpectedFlutterProbeStderr(errorOutput) ||
          !output.contains('"event":"helperProbe"') ||
          !output.contains('"status":"healthy"')) {
        throw const _SmokeFailure("installed-helper-probe-failed");
      }
      return servicePID;
    } on Object {
      process.kill(ProcessSignal.sigterm);
      await process.exitCode;
      await stdoutFuture;
      await stderrFuture;
      rethrow;
    }
  }

  Future<void> _prepareSmokeRoot({bool preserveExisting = false}) async {
    await _requireSafeDirectory(request.smokeRoot, create: true);
    final staging = Directory(path.join(request.smokeRoot.path, "staging"));
    if (!preserveExisting && await staging.exists()) {
      final entries = await staging.list(followLinks: false).toList();
      if (entries.isNotEmpty) {
        throw const _SmokeFailure("owned-stage-already-present");
      }
    }
  }

  Future<bool> _ownedStageRetained() async {
    // Only an updater-owned stage may be retained at the approval boundary.
    final staging = Directory(path.join(request.smokeRoot.path, "staging"));
    if (await FileSystemEntity.type(staging.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      return false;
    }
    final entries = await staging.list(followLinks: false).toList();
    if (entries.isEmpty) return false;
    for (final entry in entries) {
      if (await FileSystemEntity.type(entry.path, followLinks: false) !=
              FileSystemEntityType.directory ||
          !path.basename(entry.path).startsWith(desktopUpdaterStagingPrefix)) {
        throw const _SmokeFailure("unexpected-owned-stage-entry");
      }
    }
    return true;
  }

  Future<void> _waitForOwnedStageEmpty() async {
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    while (DateTime.now().isBefore(deadline)) {
      final staging = Directory(path.join(request.smokeRoot.path, "staging"));
      if (await FileSystemEntity.type(staging.path, followLinks: false) ==
              FileSystemEntityType.directory &&
          await staging.list(followLinks: false).isEmpty) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    throw const _SmokeFailure("completed-stage-not-removed");
  }

  Future<bool> _waitForTargetVersion({
    required String version,
    required String build,
    required Duration timeout,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        final metadata = await _readBundleMetadata(Directory(_targetPath));
        if (metadata.bundleIdentifier == _bundleIdentifier &&
            metadata.version == version &&
            metadata.build == build &&
            await _receiptVersion() == version) {
          return true;
        }
      } on Object {
        // The package transaction can briefly replace the target and receipt.
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    return false;
  }

  Future<int?> _launchDaemonPID(String serviceIdentifier) async {
    final result = await Process.run(
      "/bin/launchctl",
      ["print", "system/$serviceIdentifier"],
    );
    if (result.exitCode != 0) return null;
    final match = RegExp(r"^\s*pid = ([1-9][0-9]*)\s*$", multiLine: true)
        .firstMatch("${result.stdout}");
    return match == null ? null : int.parse(match.group(1)!);
  }

  Future<void> _writeEvidence(
    String name,
    Map<String, Object?> evidence, {
    required String kind,
  }) async {
    _validateEvidenceDocument(evidence, kind: kind);
    await _requireSafeDirectory(request.evidenceDirectory, create: true);
    final output = File(path.join(request.evidenceDirectory.path, name));
    final temporary = File("${output.path}.tmp");
    if (await FileSystemEntity.type(output.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const _SmokeFailure("evidence-output-symlink");
    }
    await temporary.writeAsString(
      "${const JsonEncoder.withIndent("  ").convert(evidence)}\n",
      flush: true,
    );
    await temporary.rename(output.path);
  }

  Future<void> _openBackgroundItemsSettings() async {
    final result = await Process.run(
      "/usr/bin/open",
      ["x-apple.systempreferences:com.apple.LoginItems-Settings.extension"],
    );
    if (result.exitCode != 0) {
      throw const _SmokeFailure("background-settings-open-failed");
    }
  }
}

String? _processExecutablePath(int pid) {
  const bufferSize = 4096;
  if (pid <= 0) return null;
  final buffer = _malloc(bufferSize);
  if (buffer.address == 0) return null;
  try {
    final read = _procPIDPath(pid, buffer, bufferSize);
    if (read <= 0 || read > bufferSize) return null;
    final bytes = buffer.cast<Uint8>().asTypedList(read);
    final terminator = bytes.indexOf(0);
    final value = utf8.decode(
      terminator < 0 ? bytes : bytes.sublist(0, terminator),
      allowMalformed: false,
    );
    return path.isAbsolute(value) ? value : null;
  } on FormatException {
    return null;
  } finally {
    _free(buffer);
  }
}

String? macOSProcessExecutablePathForTesting(int pid) =>
    _processExecutablePath(pid);

void _validateEvidenceDocument(
  Map<String, Object?> evidence, {
  required String kind,
}) {
  const common = {
    "schemaVersion",
    "status",
    "gitCommit",
    "artifactSHA256",
    "notarizationSubmissionId",
    "bundleIdentifier",
    "receiptIdentifier",
    "teamIdentifier",
    "artifactKind",
    "launchMode",
    "minimumUpdaterVersion",
  };
  const approval = {
    ...common,
    "event",
    "code",
    "remediationActions",
    "baselineVersion",
    "baselineBuild",
    "approvalStatus",
    "stageRetained",
  };
  const elevation = {
    ...common,
    "version",
    "build",
    "receiptVersion",
    "appOwnership",
    "mainExecutableOwnership",
    "helperOwnership",
    "launchDaemonOwnership",
    "appSignatureValid",
    "mainExecutableSignatureValid",
    "helperSignatureValid",
    "hardenedRuntime",
    "gatekeeperAccepted",
    "stapleValid",
    "launchDaemonActive",
    "launchDaemonPID",
    "fixedInstallerAuthority",
    "stageRemovedAfterCompletion",
  };
  final allowed = switch (kind) {
    "approval" => approval,
    "elevation" => elevation,
    _ => throw const _SmokeFailure("evidence-kind-invalid"),
  };
  if (evidence.keys.toSet().difference(allowed).isNotEmpty ||
      allowed.difference(evidence.keys.toSet()).isNotEmpty ||
      evidence["schemaVersion"] != 1 ||
      evidence["status"] != "verified locally" ||
      evidence["gitCommit"] is! String ||
      !_commitPattern.hasMatch(evidence["gitCommit"]! as String) ||
      evidence["artifactSHA256"] is! String ||
      !_sha256Pattern.hasMatch(evidence["artifactSHA256"]! as String) ||
      evidence["notarizationSubmissionId"] is! String ||
      !_uuidPattern.hasMatch(evidence["notarizationSubmissionId"]! as String)) {
    throw const _SmokeFailure("evidence-schema-invalid");
  }
  void inspect(Object? value) {
    if (value is String &&
        (value.startsWith("/") || value.contains("Keychain"))) {
      throw const _SmokeFailure("evidence-private-data-rejected");
    }
    if (value is List) {
      for (final item in value) {
        inspect(item);
      }
    }
    if (value is Map) {
      for (final item in value.values) {
        inspect(item);
      }
    }
  }

  inspect(evidence);
}

Future<void> _requireNode(String target, FileSystemEntityType expected) async {
  if (await FileSystemEntity.type(target, followLinks: false) != expected) {
    throw const _SmokeFailure("filesystem-node-mismatch");
  }
}

Future<void> _requireSafeDirectory(
  Directory directory, {
  required bool create,
}) async {
  if (create && !await directory.exists()) {
    await directory.create(recursive: true);
  }
  await _requireNode(directory.path, FileSystemEntityType.directory);
  if (await directory.resolveSymbolicLinks() != directory.absolute.path) {
    throw const _SmokeFailure("directory-symlink-rejected");
  }
}

Future<String> _plistValue(File plist, String key) async {
  final result = await Process.run(
    "/usr/bin/plutil",
    ["-extract", key, "raw", "-o", "-", plist.path],
  );
  final value = "${result.stdout}".trim();
  if (result.exitCode != 0 || value.isEmpty) {
    throw const _SmokeFailure("plist-value-missing");
  }
  return value;
}

Future<bool> _plistHasKey(File plist, String key) async {
  final result = await Process.run(
    "/usr/bin/plutil",
    ["-extract", key, "raw", "-o", "-", plist.path],
  );
  return result.exitCode == 0;
}

Future<String> _sha256(File file) async =>
    (await crypto.sha256.bind(file.openRead()).first).toString();

Future<_CommandResult> _runChecked(
  String executable,
  List<String> arguments, {
  required String failureClass,
  String? outputContains,
  Set<int> acceptedExitCodes = const {0},
}) async {
  final result = await Process.run(executable, arguments);
  final output = "${result.stdout}\n${result.stderr}";
  if (!acceptedExitCodes.contains(result.exitCode) ||
      (outputContains != null && !output.contains(outputContains))) {
    throw _SmokeFailure(failureClass);
  }
  return _CommandResult(exitCode: result.exitCode, output: output);
}

List<String> _stringList(Object? value) => value is List
    ? value.whereType<String>().toList(growable: false)
    : const [];

final class _SmokeServer {
  const _SmokeServer({
    required this.server,
    required this.root,
    required this.archiveURL,
    required this.publicKeyBase64,
  });

  static Future<_SmokeServer> open({
    required File artifact,
    required String version,
    required int build,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final root =
        await Directory.systemTemp.createTemp("macos_pkg_smoke_server_");
    final base = Uri.parse("http://127.0.0.1:${server.port}");
    final descriptor = await smoke_server.signedDescriptor(
      platform: "macos",
      artifactKind: _artifactKind,
      packageId: _bundleIdentifier,
      appName: path.basename(_targetPath),
      version: version,
      buildNumber: build,
      artifactURL: base.resolve("/artifact.pkg"),
      artifactBytes: await artifact.readAsBytes(),
      allowUnsignedArtifact: false,
      publisherThumbprint: null,
      minimumUpdaterVersion: _minimumUpdaterVersion,
    );
    if (descriptor["minimumUpdaterVersion"] != _minimumUpdaterVersion ||
        ((descriptor["install"] as Map<String, dynamic>)["macosPkg"]
                as Map<String, dynamic>)["launchMode"] !=
            _launchMode) {
      throw const _SmokeFailure("release-authority-invalid");
    }
    final index = await smoke_server.signedIndex(
      appName: path.basename(_targetPath),
      version: version,
      buildNumber: build,
      platform: "macos",
      releaseURL: base.resolve("/release.json"),
    );
    final indexFile = File(path.join(root.path, "app-archive.json"));
    final descriptorFile = File(path.join(root.path, "release.json"));
    await indexFile.writeAsString(jsonEncode(index));
    await descriptorFile.writeAsString(jsonEncode(descriptor));
    final publicKey = await smoke_server.smokeKeyPair().then(
          (pair) => pair.extractPublicKey(),
        );
    server.listen((request) {
      smoke_server.serveRequest(
        request,
        files: {
          "/app-archive.json": indexFile,
          "/release.json": descriptorFile,
          "/artifact.pkg": artifact,
        },
        shutdownToken: "unused",
        onShutdown: () {},
      );
    });
    return _SmokeServer(
      server: server,
      root: root,
      archiveURL: base.resolve("/app-archive.json"),
      publicKeyBase64: base64Encode(publicKey.bytes),
    );
  }

  final HttpServer server;
  final Directory root;
  final Uri archiveURL;
  final String publicKeyBase64;

  Future<void> close() async {
    await server.close(force: true);
    if (await root.exists()) await root.delete(recursive: true);
  }
}

final class _BundleMetadata {
  const _BundleMetadata({
    required this.bundleIdentifier,
    required this.version,
    required this.build,
    required this.executable,
    required this.serviceIdentifier,
  });

  final String bundleIdentifier;
  final String version;
  final String build;
  final String executable;
  final String serviceIdentifier;
}

final class _InstalledTarget {
  const _InstalledTarget({
    required this.version,
    required this.build,
    required this.receiptVersion,
    required this.servicePID,
  });

  final String version;
  final String build;
  final String receiptVersion;
  final int? servicePID;
}

final class _FixedInstallerManager {
  const _FixedInstallerManager({
    required this.processIdentifier,
    required this.transactionID,
  });

  final int processIdentifier;
  final String transactionID;
}

final class _PackagePayload {
  const _PackagePayload({required this.root, required this.app});

  final Directory root;
  final Directory app;

  Future<void> close() async {
    if (await root.exists()) await root.delete(recursive: true);
  }
}

final class _RuntimeResult {
  const _RuntimeResult({required this.exitCode, required this.output});

  final int exitCode;
  final String output;
}

final class _CommandResult {
  const _CommandResult({required this.exitCode, required this.output});

  final int exitCode;
  final String output;
}

final class _SmokeFailure implements Exception {
  const _SmokeFailure(this.failureClass);

  final String failureClass;
}

final class _ApprovalPause implements Exception {
  const _ApprovalPause();
}
