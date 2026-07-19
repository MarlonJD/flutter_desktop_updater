import "dart:convert";
import "dart:io";

import "package:args/args.dart";
import "package:crypto/crypto.dart" as crypto;
import "package:desktop_updater/src/core/staged_update_provenance.dart";
import "package:path/path.dart" as path;

import "native_runtime_smoke_server.dart" as smoke_server;

const _targetPath = "/Applications/Desktop Updater SMAppService PKG E2E.app";
const _bundleIdentifier = "net.monolib.updater";
const _receiptIdentifier = "net.monolib.updater.pkg";
const _ownerMarkerText = "desktop_updater macOS production smoke";
const _ownerMarkerName = "desktop_updater_smoke_owner.txt";
const _teamIdentifier = "UPK4SC93AN";
const _v1Version = "2.7.0";
const _v1Build = "270";
const _v2Version = "2.7.1";
const _v2Build = "271";
const _artifactKind = "pkgInstaller";
const _launchMode = "privilegedInstallerTool";
const _minimumUpdaterVersion = "2.7.0";
const _approvalCode = "PrivilegedHelperApprovalRequired";
const _settingsAction = "openMacOSBackgroundItemsSettings";
const _settingsInstructions =
    "System Settings > General > Login Items & Extensions > "
    "Allow in the Background: enable the Desktop Updater smoke helper.";
const _openSettingsOption = "--open-settings";

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
    await _verifyPackage(request.v1Pkg);
    await _verifyPackage(request.v2Pkg);
    await _inspectTarget(
      allowedVersions: const {(_v1Version, _v1Build), (_v2Version, _v2Build)},
      requireTrust: true,
      requireLoadedService: false,
    );
    final v1Payload = await _extractPackagePayload(
      request.v1Pkg,
      expectedVersion: _v1Version,
      expectedBuild: _v1Build,
    );
    final v2Payload = await _extractPackagePayload(
      request.v2Pkg,
      expectedVersion: _v2Version,
      expectedBuild: _v2Build,
    );
    try {
      if (!await _bundlesShareCodeIdentity(request.v1App, v1Payload.app)) {
        throw const _SmokeFailure("v1-source-payload-mismatch");
      }
      if (await _bundlesShareCodeIdentity(
        Directory(_targetPath),
        v1Payload.app,
      )) {
        stdout.writeln(
          jsonEncode(
            {"status": "verified locally", "baseline": "2.7.0+270"},
          ),
        );
        return;
      }

      if (!await _bundlesShareCodeIdentity(
        Directory(_targetPath),
        v2Payload.app,
      )) {
        await _prepareSmokeRoot();
        final refresh = await _runRuntime(
          artifact: request.v2Pkg,
          releaseVersion: _v2Version,
          releaseBuild: int.parse(_v2Build),
          expectApproval: true,
        );
        await _failFastAtApprovalBoundary(refresh);
        if (!await _waitForBundleIdentity(
          v2Payload.app,
          version: _v2Version,
          build: _v2Build,
          timeout: const Duration(seconds: 150),
        )) {
          await _pauseIfApproval(refresh);
          throw const _SmokeFailure("fresh-v2-bootstrap-failed");
        }
        await _removeVerifiedBootstrapRefreshStage();
      }

      await _prepareSmokeRoot();
      final downgrade = await _runRuntime(
        artifact: request.v1Pkg,
        releaseVersion: _v1Version,
        releaseBuild: int.parse(_v1Build),
        expectApproval: true,
        currentVersion: "2.6.9",
        currentBuild: 269,
      );
      await _failFastAtApprovalBoundary(downgrade);
      if (!await _waitForBundleIdentity(
        v1Payload.app,
        version: _v1Version,
        build: _v1Build,
        timeout: const Duration(seconds: 150),
      )) {
        await _pauseIfApproval(downgrade);
        throw const _SmokeFailure("v1-bootstrap-failed");
      }
      await _inspectTarget(
        allowedVersions: const {(_v1Version, _v1Build)},
        requireTrust: true,
        requireLoadedService: true,
      );
      await _waitForOwnedStageEmpty();
      stdout.writeln(
        jsonEncode({"status": "verified locally", "baseline": "2.7.0+270"}),
      );
    } finally {
      await v1Payload.close();
      await v2Payload.close();
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
      if (!await _bundlesShareCodeIdentity(request.v1App, payload.app) ||
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
      jsonEncode({"status": "verified locally", "baseline": "2.7.0+270"}),
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
    await _prepareSmokeRoot(preserveExisting: true);
    final result = await _runRuntime(
      artifact: request.v2Pkg,
      releaseVersion: _v2Version,
      releaseBuild: int.parse(_v2Build),
      expectApproval: false,
    );
    if (result.exitCode != 0 ||
        !result.output.contains("installAndRelaunch scheduled $_v2Version")) {
      if (_typedApprovalEvent(result) != null) {
        if (request.openSettings) await _openBackgroundItemsSettings();
        throw const _ApprovalPause();
      }
      throw const _SmokeFailure("privileged-install-not-scheduled");
    }
    if (!await _waitForTargetVersion(
      version: _v2Version,
      build: _v2Build,
      timeout: const Duration(seconds: 150),
    )) {
      throw const _SmokeFailure("privileged-install-timeout");
    }
    final installed = await _inspectTarget(
      allowedVersions: const {(_v2Version, _v2Build)},
      requireTrust: true,
      requireLoadedService: true,
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
      "launchDaemonPID": installed.servicePID,
      "artifactKind": _artifactKind,
      "launchMode": _launchMode,
      "minimumUpdaterVersion": _minimumUpdaterVersion,
      "fixedInstallerAuthority": true,
      "stageRemovedAfterCompletion": true,
    };
    await _writeEvidence("elevation.json", evidence, kind: "elevation");
    stdout.writeln(
      jsonEncode({"status": "verified locally", "installed": "2.7.1+271"}),
    );
  }

  Future<void> _validateInputs({required bool requireV2Hash}) async {
    await _requireNode(request.v1App.path, FileSystemEntityType.directory);
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
      final component = Directory(path.join(expanded.path, "component.pkg"));
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
      servicePID: servicePID,
    );
  }

  Future<_BundleMetadata> _readBundleMetadata(Directory app) async {
    final info = File(path.join(app.path, "Contents", "Info.plist"));
    await _requireNode(info.path, FileSystemEntityType.file);
    final executable = await _plistValue(info, "CFBundleExecutable");
    final service =
        await _plistValue(info, "DesktopUpdaterInstallHelperServiceID");
    if (executable != "MacOSRuntimeCompile" ||
        !_servicePattern.hasMatch(service)) {
      throw const _SmokeFailure("bundle-metadata-invalid");
    }
    return _BundleMetadata(
      bundleIdentifier: await _plistValue(info, "CFBundleIdentifier"),
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
    String? currentVersion,
    int? currentBuild,
  }) async {
    final server = await _SmokeServer.open(
      artifact: artifact,
      version: releaseVersion,
      build: releaseBuild,
    );
    try {
      final metadata = await _readBundleMetadata(Directory(_targetPath));
      final host = path.join(
        _targetPath,
        "Contents",
        "MacOS",
        metadata.executable,
      );
      final diagnostics = path.join(request.smokeRoot.path, "helper.jsonl");
      final result = await Process.run(host, [
        "--smoke",
        "--app-archive-url",
        server.archiveURL.toString(),
        "--public-key-base64",
        server.publicKeyBase64,
        "--package-id",
        _bundleIdentifier,
        "--smoke-root",
        request.smokeRoot.path,
        "--diagnostics-log",
        diagnostics,
        "--expected-team-identifier",
        _teamIdentifier,
        if (currentVersion != null) ...[
          "--current-version",
          currentVersion,
        ],
        if (currentBuild != null) ...[
          "--current-build-number",
          "$currentBuild",
        ],
        if (expectApproval) "--expect-helper-approval-required",
      ]).timeout(const Duration(minutes: 3));
      return _RuntimeResult(
        exitCode: result.exitCode,
        output: "${result.stdout}\n${result.stderr}",
      );
    } on ProcessException {
      throw const _SmokeFailure("runtime-launch-failed");
    } finally {
      await server.close();
    }
  }

  Map<String, Object?>? _typedApprovalEvent(_RuntimeResult result) {
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

  Future<void> _failFastAtApprovalBoundary(_RuntimeResult result) async {
    if (result.output.contains(
      "SMAppService helper unexpectedly avoided approval.",
    )) {
      return;
    }
    await _pauseIfApproval(result);
    if (result.exitCode != 0) {
      throw const _SmokeFailure("runtime-handoff-failed");
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

  Future<void> _removeVerifiedBootstrapRefreshStage() async {
    // This is only the transition from a previously installed helper to the
    // current helper. Final v1 -> v2 acceptance never calls this fallback.
    await _inspectTarget(
      allowedVersions: const {(_v2Version, _v2Build)},
      requireTrust: true,
      requireLoadedService: false,
    );
    final staging = Directory(path.join(request.smokeRoot.path, "staging"));
    await _requireSafeDirectory(staging, create: false);
    final entries = await staging.list(followLinks: false).toList();
    if (entries.isEmpty) return;
    if (entries.length != 1 ||
        await FileSystemEntity.type(entries.single.path, followLinks: false) !=
            FileSystemEntityType.directory ||
        !path.basename(entries.single.path).startsWith(
              desktopUpdaterStagingPrefix,
            )) {
      throw const _SmokeFailure("bootstrap-stage-authority-invalid");
    }
    final stage = Directory(entries.single.path);
    final state = await readStagedUpdateProvenance(stageRoot: stage);
    if (state.provenance.packageId != _bundleIdentifier ||
        state.provenance.artifactSha256 != request.artifactSHA256) {
      throw const _SmokeFailure("bootstrap-stage-provenance-mismatch");
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
    if ((await staging.list(followLinks: false).toList()).isNotEmpty) {
      throw const _SmokeFailure("bootstrap-stage-cleanup-incomplete");
    }
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

  Future<bool> _waitForBundleIdentity(
    Directory expected, {
    required String version,
    required String build,
    required Duration timeout,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await _waitForTargetVersion(
            version: version,
            build: build,
            timeout: const Duration(milliseconds: 1),
          ) &&
          await _bundlesShareCodeIdentity(Directory(_targetPath), expected)) {
        return true;
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
    required this.servicePID,
  });

  final String version;
  final String build;
  final int? servicePID;
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
